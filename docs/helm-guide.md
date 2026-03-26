# Guia de Helm - Entendiendo el caminito completo

Esta guia sigue la estructura real de este repositorio para explicar como funciona
Helm y como se integra con ArgoCD en un patron App of Apps.

---

## Indice

1. [Que es Helm y para que sirve](#1-que-es-helm-y-para-que-sirve)
2. [Anatomia de un Chart](#2-anatomia-de-un-chart)
3. [El sistema de templates](#3-el-sistema-de-templates)
4. [Values: la cascada de configuracion](#4-values-la-cascada-de-configuracion)
5. [El caminito completo: del commit al pod](#5-el-caminito-completo-del-commit-al-pod)
6. [Comandos utiles para experimentar](#6-comandos-utiles-para-experimentar)

---

## 1. Que es Helm y para que sirve

Kubernetes trabaja con archivos YAML que describen recursos (Deployments, Services,
ConfigMaps, etc.). El problema es que si tenes 10 microservicios, terminas con
decenas de YAMLs casi identicos donde solo cambia el nombre, la imagen o un puerto.

Helm resuelve esto con **charts**: paquetes de templates YAML parametrizables.
En vez de copiar y pegar, escribis el template una sola vez y lo alimentas con
distintos `values.yaml` para cada app o ambiente.

**Analogia simple**: Un chart es como un molde de galletitas. Los values son los
ingredientes. Con el mismo molde podes hacer galletitas de chocolate o de vainilla.

En este repo, el chart generico esta en:

```
manifests/helm-base/      <-- El molde (un solo chart para todas las apps)
```

Y los "ingredientes" vienen de dos lugares:

```
codigo/example-app/values-dev.yaml                               <-- Lo que define el dev
gitops/proyectos/example-project/dev/values/example-app-override.yaml  <-- Lo que define infra
```

---

## 2. Anatomia de un Chart

Un chart de Helm es simplemente un directorio con una estructura definida.
Este es el nuestro:

```
manifests/helm-base/
  Chart.yaml              <-- Identidad del chart (nombre, version)
  values.yaml             <-- Valores por defecto
  templates/              <-- Los templates que Helm va a renderizar
    _helpers.tpl          <-- Funciones auxiliares reutilizables
    deployment.yaml       <-- Template del Deployment
    service.yaml          <-- Template del Service
    serviceaccount.yaml   <-- Template del ServiceAccount
    configmap-properties.yaml  <-- Template del ConfigMap (condicional)
    ingress.yaml          <-- Template del Ingress (condicional)
    hpa.yaml              <-- Template del HPA (condicional)
```

### Chart.yaml - La identidad

```yaml
# manifests/helm-base/Chart.yaml
apiVersion: v2
name: app-component
description: A generic Helm chart for deploying application components.
type: application
version: 0.1.0
appVersion: "1.0.0"
```

| Campo        | Que hace                                                    |
|-------------|-------------------------------------------------------------|
| `name`      | Nombre del chart. Se usa en templates como `.Chart.Name`    |
| `version`   | Version del chart (el empaquetado, no la app)               |
| `appVersion`| Version por defecto de la app. Se usa si `image.tag` esta vacio |

### values.yaml - Los defaults

```yaml
# manifests/helm-base/values.yaml (resumido)
replicaCount: 1

image:
  repository: nginx
  pullPolicy: IfNotPresent
  tag: ""              # <-- Si esta vacio, usa appVersion del Chart.yaml

service:
  type: ClusterIP
  port: 8080

envFromProperties:
  enabled: false       # <-- El ConfigMap solo se crea si esto es true

ingress:
  enabled: false       # <-- El Ingress solo se crea si esto es true

autoscaling:
  enabled: false       # <-- El HPA solo se crea si esto es true
```

Estos son los valores "de fabrica". Cualquier value que pases despues los
sobreescribe (merge profundo). Si nadie pasa nada, estos son los que se usan.

---

## 3. El sistema de templates

Los archivos dentro de `templates/` son YAML con sintaxis de Go templates.
Helm los procesa, reemplaza las expresiones `{{ }}` con valores reales, y
genera YAML puro de Kubernetes.

### 3.1. _helpers.tpl - Funciones reutilizables

Este archivo **no genera ningun recurso de Kubernetes**. Define funciones que
los otros templates pueden llamar. Se usa `define` para crear la funcion y
`include` para invocarla.

```
{{- define "app-component.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
```

**Que hace**: Si pasas `fullnameOverride: "example-app"` en tus values, todos
los recursos se van a llamar `example-app`. Si no, usa el nombre del Release
(lo que pasas con `helm install MI-RELEASE ...`).

| Funcion                            | Para que se usa                              |
|------------------------------------|----------------------------------------------|
| `app-component.fullname`          | Nombre de todos los recursos K8s             |
| `app-component.serviceAccountName`| Nombre del ServiceAccount                    |
| `app-component.labels`            | Labels comunes en todos los recursos         |

### 3.2. deployment.yaml - El template principal

Vamos linea por linea con las partes importantes:

```yaml
# manifests/helm-base/templates/deployment.yaml

apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "app-component.fullname" . }}
  #      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  #      Llama a la funcion de _helpers.tpl
  #      Si values tiene fullnameOverride: "example-app" → name: example-app
  labels:
    {{- include "app-component.labels" . | nindent 4 }}
    #   nindent 4 = agrega 4 espacios de indentacion
spec:
  replicas: {{ .Values.replicaCount }}
  #          ^^^^^^^^^^^^^^^^^^^^^^^^
  #          Lee el valor de replicaCount de los values
  #          Default: 1 (values.yaml) → Dev: 1 → Override: 2 (gana 2)
```

La seccion del container:

```yaml
      containers:
        - name: {{ include "app-component.fullname" . }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          #       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
          #       nginx                          1.27 (de dev values) o "1.0.0" si tag esta vacio
```

La logica de `| default .Chart.AppVersion` significa:
- Si `image.tag` tiene valor → lo usa (ej: `"1.27"` o `"latest"`)
- Si `image.tag` esta vacio (`""`) → usa `appVersion` del Chart.yaml (`"1.0.0"`)

Variables de entorno:

```yaml
          env:
            {{- toYaml .Values.env | nindent 12 }}
            # Toma la lista de env del values y la pega tal cual con indentacion
            # En dev: [{name: ENVIRONMENT, value: dev}, {name: LOG_LEVEL, value: debug}]
```

ConfigMap referencia (condicional):

```yaml
          {{- if .Values.envFromProperties.enabled }}
          envFrom:
            - configMapRef:
                name: {{ .Values.envFromProperties.configMapName | default (include "app-component.fullname" .) }}
          {{- end }}
          # Solo aparece si envFromProperties.enabled = true
          # El nombre del ConfigMap: si configMapName esta vacio, usa el fullname
```

### 3.3. Recursos condicionales

Algunos templates solo generan recursos si un flag esta habilitado:

```yaml
# configmap-properties.yaml
{{- if .Values.envFromProperties.enabled }}
apiVersion: v1
kind: ConfigMap
...
{{- end }}
```

```yaml
# ingress.yaml
{{- if .Values.ingress.enabled -}}
...
{{- end }}
```

```yaml
# hpa.yaml
{{- if .Values.autoscaling.enabled }}
...
{{- end }}
```

**Esto es clave**: con un solo chart podes tener apps simples (solo Deployment +
Service) o apps complejas (con Ingress, HPA, ConfigMaps) simplemente prendiendo
o apagando flags en los values.

### 3.4. Sintaxis rapida de Go templates

| Sintaxis | Que hace | Ejemplo |
|----------|----------|---------|
| `{{ .Values.X }}` | Lee un valor | `{{ .Values.replicaCount }}` → `2` |
| `{{ include "fn" . }}` | Llama una funcion de _helpers.tpl | `{{ include "app-component.fullname" . }}` → `example-app` |
| `{{- ... -}}` | Los guiones eliminan espacios en blanco sobrantes | Evita lineas vacias en el YAML final |
| `{{ toYaml X \| nindent N }}` | Convierte a YAML e indenta N espacios | Usado para listas/objetos complejos |
| `{{ X \| default Y }}` | Si X esta vacio usa Y | `{{ .Values.image.tag \| default "latest" }}` |
| `{{- if X }}...{{- end }}` | Condicional | Renderiza el bloque solo si X es truthy |
| `{{- range X }}...{{- end }}` | Loop | Itera sobre listas (usado en ingress.yaml) |
| `{{ .Release.Name }}` | Nombre del release de Helm | Lo que pasas en `helm install NOMBRE` |
| `{{ .Chart.AppVersion }}` | appVersion del Chart.yaml | `"1.0.0"` |

---

## 4. Values: la cascada de configuracion

Aca esta la magia del patron que usamos. Un mismo chart recibe **tres capas de
values** que se mergean en orden (el ultimo gana):

```
CAPA 1 (base)     manifests/helm-base/values.yaml
   ↓ merge
CAPA 2 (dev)      codigo/example-app/values-dev.yaml
   ↓ merge
CAPA 3 (infra)    gitops/proyectos/example-project/dev/values/example-app-override.yaml
```

### Ejemplo concreto: replicaCount

| Capa | Archivo | Valor | Gana? |
|------|---------|-------|-------|
| Base | `manifests/helm-base/values.yaml` | `replicaCount: 1` | No |
| Dev | `codigo/example-app/values-dev.yaml` | `replicaCount: 1` | No |
| Infra | `gitops/.../values/example-app-override.yaml` | `replicaCount: 2` | **Si** |

**Resultado final**: `replicaCount: 2` (el pod corre con 2 replicas)

### Ejemplo concreto: image.tag

| Capa | Valor | Gana? |
|------|-------|-------|
| Base | `tag: ""` (vacio) | No |
| Dev | `tag: "1.27"` | No |
| Infra | `tag: "latest"` | **Si** |

**Resultado final**: `image: nginx:latest`

### Ejemplo concreto: envFromProperties.data.LOG_LEVEL

| Capa | Valor | Gana? |
|------|-------|-------|
| Base | (no definido) | No |
| Dev | `LOG_LEVEL: debug` | No |
| Infra | `LOG_LEVEL: info` | **Si** |

**Resultado final en el ConfigMap**: `LOG_LEVEL: info`

### Por que tres capas?

Este patron separa responsabilidades:

```
manifests/helm-base/values.yaml
└── Quien lo mantiene: Equipo de plataforma
└── Que define: Defaults seguros para cualquier app
└── Ejemplo: resources.requests.cpu: 100m

codigo/example-app/values-dev.yaml
└── Quien lo mantiene: Equipo de desarrollo
└── Que define: Configuracion de la app (imagen, puertos, env vars)
└── Ejemplo: image.tag: "1.27", service.port: 80

gitops/.../values/example-app-override.yaml
└── Quien lo mantiene: Equipo de infra/plataforma
└── Que define: Ajustes del ambiente (replicas, image override, URLs)
└── Ejemplo: replicaCount: 2, LOG_LEVEL: info
```

En un flujo real con repos separados:
- El dev hace push → su pipeline actualiza `values-dev.yaml` en el repo de codigo
- Infra ajusta el override en el repo de gitops
- ArgoCD detecta el cambio y reconcilia automaticamente

---

## 5. El caminito completo: del commit al pod

Este es el flujo completo de como un cambio en Git termina siendo un pod corriendo
en Kubernetes. Seguilo con los archivos reales del repo.

### Paso 1: Bootstrap - El punto de entrada

Aplicamos manualmente los archivos de `gitops/core/`:

```bash
kubectl apply -f gitops/core/
```

Esto crea 3 recursos en el namespace `argocd`:

| Archivo | Que crea | Tipo |
|---------|----------|------|
| `argocd-project.yaml` | Proyecto `argocd-management` | AppProject |
| `repo-secret.yaml` | Conexion al repo de GitHub | Secret |
| `applications.yaml` | **App raiz "applications"** | Application |

### Paso 2: La App raiz escanea `gitops/proyectos/`

```
gitops/core/applications.yaml
  spec.source.path: gitops/proyectos    <-- Escanea esta carpeta
```

ArgoCD mira todo lo que hay en `gitops/proyectos/` y aplica los YAMLs que
encuentra. Actualmente encuentra:

```
gitops/proyectos/
  argocd-management-app.yaml      → Crea Application "argocd-management-app"
  example-project.yaml            → Crea AppProject + ApplicationSet
  argocd-management/              → (escaneado por argocd-management-app)
  example-project/                → (escaneado por el ApplicationSet)
```

### Paso 3: argocd-management-app gestiona repos y permisos

```
argocd-management-app.yaml
  spec.source.path: gitops/proyectos/argocd-management
```

Escanea `argocd-management/` y aplica:

```
argocd-management/
  repositories-app.yaml   → Crea Application "repositorios"
  rolebinding.yaml         → Crea ClusterRoleBinding (permisos)
```

La app "repositorios" a su vez escanea `gitops/repositorios/` y aplica:

```
gitops/repositorios/
  devops-repository.yaml   → Crea Secret (repo helm-base registrado en ArgoCD)
```

### Paso 4: example-project.yaml genera el ambiente dev

`example-project.yaml` es un List con 2 items:

**Item 1: AppProject `example-project`**
- Define que namespaces puede tocar (`dev-example-project`, `tst-...`, etc.)
- Define que tipo de recursos puede crear

**Item 2: ApplicationSet `example-project-set`**
- Usa un generador `list` con los ambientes:

```yaml
generators:
  - list:
      elements:
        - env: dev
          project: example-project
        # Agregar mas ambientes aca:
        # - env: tst
        #   project: example-project
```

- Por cada elemento genera una Application. Con `env: dev` genera:

```
Application: "dev-example-project"
  namespace destino: dev-example-project
  source.path: gitops/proyectos/example-project/dev
  directory.recurse: true
  directory.exclude: '{values/*,values/**}'   <-- Ignora la carpeta values/
```

### Paso 5: dev-example-project escanea el ambiente dev

```
gitops/proyectos/example-project/dev/
  apps/
    example-app.yaml      → Crea Application "dev-example-app" (sync-wave: 1)
  project/
    dev-project.yaml       → Crea Namespace + AppProject (sync-wave: -1)
  values/
    example-app-override.yaml  → IGNORADO por el exclude (solo lo lee Helm)
  commons/                → Vacia (para recursos compartidos del ambiente)
```

Gracias a los sync-waves:
1. **Primero** (wave -1): Se crea el Namespace `dev-example-project` y el AppProject `dev-example-project`
2. **Despues** (wave 1): Se crea la Application `dev-example-app`

### Paso 6: dev-example-app renderiza Helm (Multi-Source)

Aca es donde Helm hace su trabajo. La Application usa **multi-source**:

```yaml
# gitops/proyectos/example-project/dev/apps/example-app.yaml
sources:
  # SOURCE 1: El chart + referencia a value files
  - path: manifests/helm-base           # <-- El chart
    helm:
      valueFiles:
        - $developer-values/codigo/example-app/values-dev.yaml
        - $gitops-override/gitops/.../values/example-app-override.yaml

  # SOURCE 2: Alias "developer-values" (para resolver $developer-values)
  - ref: developer-values
    repoURL: https://github.com/NicoMiretti/devops.git

  # SOURCE 3: Alias "gitops-override" (para resolver $gitops-override)
  - ref: gitops-override
    repoURL: https://github.com/NicoMiretti/devops.git
```

**Como funciona el multi-source**:
1. ArgoCD clona el repo 3 veces (en la practica usa cache)
2. El source con `ref: developer-values` crea un alias `$developer-values` que
   apunta a la raiz del repo
3. El source con `ref: gitops-override` crea otro alias `$gitops-override`
4. En el source del chart, Helm resuelve los `valueFiles` usando esos alias
5. Helm renderiza: `values.yaml` (base) + `values-dev.yaml` (dev) + `example-app-override.yaml` (infra)

### Paso 7: Los recursos llegan al cluster

Helm genera el YAML final y ArgoCD lo aplica en el namespace `dev-example-project`:

```
Namespace: dev-example-project
  ServiceAccount/example-app
  ConfigMap/example-app        (ENVIRONMENT=dev, LOG_LEVEL=info, URL=...)
  Service/example-app          (ClusterIP, port 80)
  Deployment/example-app       (2 replicas, nginx:latest)
    Pod/example-app-xxxx-yyy   (Running)
    Pod/example-app-xxxx-zzz   (Running)
```

### Diagrama del caminito completo

```
kubectl apply -f gitops/core/
         |
         v
  [applications]  (App of Apps raiz)
    escanea: gitops/proyectos/
         |
         +---> [argocd-management-app]
         |       escanea: gitops/proyectos/argocd-management/
         |         |
         |         +---> [repositorios]
         |         |       escanea: gitops/repositorios/
         |         |       crea: Secrets de repos
         |         |
         |         +---> ClusterRoleBinding (permisos)
         |
         +---> [example-project] (AppProject + ApplicationSet)
                 genera: [dev-example-project]
                   escanea: gitops/proyectos/example-project/dev/
                     |
                     +---> Namespace + AppProject (wave -1)
                     |
                     +---> [dev-example-app] (wave 1)
                             Helm multi-source:
                               chart:  manifests/helm-base/
                               values: codigo/example-app/values-dev.yaml
                               values: gitops/.../values/example-app-override.yaml
                                 |
                                 v
                             Deployment (2x nginx:latest)
                             Service (port 80)
                             ConfigMap (env vars)
                             ServiceAccount
```

---

## 6. Comandos utiles para experimentar

### Renderizar el chart localmente (sin aplicar nada)

```bash
# Solo con los defaults del chart
helm template my-release manifests/helm-base/

# Con los values del dev
helm template my-release manifests/helm-base/ \
  -f codigo/example-app/values-dev.yaml

# Con dev + override (como lo hace ArgoCD)
helm template my-release manifests/helm-base/ \
  -f codigo/example-app/values-dev.yaml \
  -f gitops/proyectos/example-project/dev/values/example-app-override.yaml

# En un namespace especifico
helm template my-release manifests/helm-base/ \
  -f codigo/example-app/values-dev.yaml \
  -f gitops/proyectos/example-project/dev/values/example-app-override.yaml \
  --namespace dev-example-project
```

Compara la salida entre cada comando para ver como los values van sobreescribiendo.

### Ver que tiene ArgoCD en vivo

```bash
# Listar todas las Applications
kubectl -n argocd get applications

# Ver detalle de una app
kubectl -n argocd get application dev-example-app -o yaml

# Ver los recursos deployados
kubectl -n dev-example-project get all

# Ver el ConfigMap resultante
kubectl -n dev-example-project get configmap example-app -o yaml

# Ver los logs de un pod
kubectl -n dev-example-project logs deployment/example-app
```

### Probar cambios

```bash
# 1. Edita un value (ej: cambiar replicas a 3)
#    Editar: gitops/proyectos/example-project/dev/values/example-app-override.yaml
#    Cambiar: replicaCount: 3

# 2. Commit y push
git add -A && git commit -m "scale to 3 replicas" && git push

# 3. Esperar ~3 min o forzar refresh
kubectl -n argocd patch application dev-example-app \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}'

# 4. Ver que ArgoCD sincroniza
kubectl -n argocd get application dev-example-app
kubectl -n dev-example-project get pods
```

### Validar el chart

```bash
# Lint: busca errores de sintaxis y buenas practicas
helm lint manifests/helm-base/ -f codigo/example-app/values-dev.yaml

# Dry-run contra el cluster (valida que K8s aceptaria los recursos)
helm install --dry-run --debug test-release manifests/helm-base/ \
  -f codigo/example-app/values-dev.yaml \
  --namespace dev-example-project
```

---

## Resumen

| Concepto | Donde esta en el repo | Para que sirve |
|----------|----------------------|----------------|
| Chart | `manifests/helm-base/` | Template reutilizable de K8s resources |
| Values base | `manifests/helm-base/values.yaml` | Defaults seguros |
| Values dev | `codigo/example-app/values-dev.yaml` | Config del dev (imagen, puerto) |
| Values override | `gitops/.../values/example-app-override.yaml` | Ajustes de infra (replicas, URLs) |
| App of Apps | `gitops/core/applications.yaml` | Punto de entrada de ArgoCD |
| ApplicationSet | `gitops/proyectos/example-project.yaml` | Genera apps por ambiente |
| Multi-source | `gitops/.../apps/example-app.yaml` | Combina chart + N value files |

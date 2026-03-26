# DevOps Local - Kind + ArgoCD + GitOps

Ambiente local de Kubernetes con ArgoCD usando el patron **App of Apps** con Helm puro (sin Kustomize).

Todo corre en [Kind](https://kind.sigs.k8s.io/) y se gestiona via GitOps: cualquier cambio
en este repo es detectado y aplicado automaticamente por ArgoCD.

---

## Estructura del repositorio

```
.
├── bootstrap.sh                     # Script para levantar todo desde cero
├── kind-config.yaml                 # Configuracion del cluster Kind
│
├── manifests/                       # Charts de Helm (templates reutilizables)
│   └── helm-base/                   # Chart generico para cualquier microservicio
│       ├── Chart.yaml
│       ├── values.yaml              # Valores por defecto
│       └── templates/
│           ├── _helpers.tpl         # Funciones auxiliares (nombres, labels)
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── serviceaccount.yaml
│           ├── configmap-properties.yaml   # Condicional (envFromProperties.enabled)
│           ├── ingress.yaml                # Condicional (ingress.enabled)
│           └── hpa.yaml                    # Condicional (autoscaling.enabled)
│
├── codigo/                          # Codigo y configuracion de los equipos de desarrollo
│   └── example-app/
│       └── values-dev.yaml          # Values del dev para el ambiente dev
│
├── gitops/                          # Configuracion de ArgoCD y ambientes
│   ├── core/                        # Bootstrap: se aplica manualmente una sola vez
│   │   ├── applications.yaml        # App of Apps raiz
│   │   ├── argocd-project.yaml      # Proyecto raiz de ArgoCD
│   │   └── repo-secret.yaml         # Conexion al repo de GitHub
│   │
│   ├── proyectos/                   # Proyectos gestionados por ArgoCD
│   │   ├── argocd-management-app.yaml
│   │   ├── argocd-management/
│   │   │   ├── repositories-app.yaml
│   │   │   └── rolebinding.yaml
│   │   │
│   │   ├── example-project.yaml     # AppProject + ApplicationSet
│   │   └── example-project/
│   │       ├── dev/
│   │       │   ├── apps/            # Applications de ArgoCD (multi-source Helm)
│   │       │   ├── project/         # Namespace + AppProject del ambiente
│   │       │   ├── values/          # Overrides de infra (no los aplica ArgoCD directo)
│   │       │   └── commons/         # Recursos compartidos del ambiente (vacio)
│   │       ├── tst/                 # (vacio, listo para agregar)
│   │       ├── pre/                 # (vacio, listo para agregar)
│   │       └── prod/                # (vacio, listo para agregar)
│   │
│   └── repositorios/                # Secrets de repositorios para ArgoCD
│       └── devops-repository.yaml
│
└── docs/
    └── helm-guide.md                # Guia detallada de como funciona Helm en este repo
```

---

## Componentes

### kind-config.yaml

Configuracion del cluster Kind. Define un solo nodo control-plane con port mappings
para acceder a ArgoCD desde el navegador:

| Puerto host | Puerto NodePort | Uso |
|-------------|----------------|-----|
| 8080 | 30080 | ArgoCD HTTP |
| 8443 | 30443 | ArgoCD HTTPS |

### bootstrap.sh

Script que levanta todo el ambiente desde cero. Ejecuta en orden:

1. Crea el cluster Kind (`devops-local`)
2. Instala ArgoCD en el namespace `argocd`
3. Espera a que los deployments esten listos
4. Patchea el Service de ArgoCD a NodePort (30080/30443)
5. Muestra las credenciales de acceso

Despues de correr el script, hay que aplicar el bootstrap manualmente:

```bash
kubectl apply -f gitops/core/
```

---

### manifests/helm-base/

Chart de Helm generico que sirve como base para cualquier microservicio.
No se instala directamente: ArgoCD lo usa como source en las Applications.

**Recursos que genera:**

| Template | Siempre se crea | Condicion |
|----------|:-:|---|
| Deployment | Si | - |
| Service | Si | - |
| ServiceAccount | Si | `serviceAccount.create: true` (default) |
| ConfigMap | No | `envFromProperties.enabled: true` |
| Ingress | No | `ingress.enabled: true` |
| HPA | No | `autoscaling.enabled: true` |

Los templates usan funciones definidas en `_helpers.tpl` para generar nombres
y labels consistentes. El nombre de todos los recursos se controla con
`fullnameOverride` en los values.

---

### codigo/

Contiene los values de Helm que gestionan los equipos de desarrollo. Cada app
tiene su carpeta con un `values-{env}.yaml` por ambiente.

```
codigo/
  example-app/
    values-dev.yaml    # imagen, puerto, env vars para dev
```

Estos values definen **que** se deploya: imagen, tag, puerto del servicio,
variables de entorno. En un flujo real, el pipeline de CI/CD actualiza el
`image.tag` aca despues de cada build.

---

### gitops/core/

Los archivos de bootstrap. Se aplican **una sola vez** con `kubectl apply` y
despues ArgoCD se encarga de todo lo demas.

#### applications.yaml

La Application raiz del patron App of Apps. Escanea `gitops/proyectos/` y
aplica todo lo que encuentra. Cualquier YAML nuevo que agregues en esa
carpeta se convierte automaticamente en un recurso de ArgoCD.

- Auto-sync habilitado con selfHeal
- Prune deshabilitado (no borra apps si sacas el YAML, por seguridad)

#### argocd-project.yaml

El AppProject `argocd-management`. Define los permisos del proyecto raiz:
que tipos de recursos puede crear y en que namespaces puede operar.
Todos los componentes de gestion de ArgoCD pertenecen a este proyecto.

#### repo-secret.yaml

Secret que registra el repositorio de GitHub en ArgoCD para que pueda
clonarlo. Como el repo es publico, no necesita token de autenticacion.

---

### gitops/proyectos/

Carpeta escaneada por la App raiz. Todo lo que pongas aca se aplica
automaticamente en ArgoCD.

#### argocd-management-app.yaml

Application que gestiona los recursos de `argocd-management/` (repos, permisos).
Sync-wave `-5` para que se cree antes que los proyectos de aplicacion.

#### argocd-management/

| Archivo | Que crea | Para que |
|---------|----------|----------|
| `repositories-app.yaml` | Application `repositorios` | Gestiona los Secrets de `gitops/repositorios/` |
| `rolebinding.yaml` | ClusterRoleBinding | Da permisos cluster-admin al controller de ArgoCD |

#### example-project.yaml

Un List de Kubernetes con 2 recursos:

1. **AppProject `example-project`**: Define los namespaces permitidos para cada
   ambiente (dev, tst, pre, prod) y los tipos de recursos que las apps pueden crear.

2. **ApplicationSet `example-project-set`**: Generador basado en lista que crea
   una Application por cada ambiente configurado. Actualmente solo tiene `dev`:

```yaml
generators:
  - list:
      elements:
        - env: dev
          project: example-project
```

Para agregar un nuevo ambiente (ej: `tst`), hay que:
1. Agregar el elemento a la lista: `- env: tst`
2. Crear la carpeta `example-project/tst/` con su estructura (`apps/`, `project/`, `values/`)

El ApplicationSet excluye la carpeta `values/` del scan de directorio para que
ArgoCD no intente aplicar los archivos de values como manifiestos de Kubernetes.

#### example-project/dev/

Estructura de un ambiente:

```
dev/
  project/           # Infraestructura del ambiente (sync-wave: -1, se crea primero)
    dev-project.yaml   Namespace dev-example-project + AppProject dev-example-project

  apps/              # Applications de ArgoCD (sync-wave: 1, se crea despues)
    example-app.yaml   Application multi-source Helm

  values/            # Overrides de infra (NO los aplica ArgoCD, solo los lee Helm)
    example-app-override.yaml

  commons/           # Recursos compartidos del ambiente (ConfigMaps globales, etc.)
```

La Application `dev-example-app` en `apps/example-app.yaml` usa el patron
**multi-source** de ArgoCD para combinar tres fuentes en un solo render de Helm:

```
Source 1: manifests/helm-base/          (el chart)
  valueFiles:
    - $developer-values/codigo/example-app/values-dev.yaml     (values del dev)
    - $gitops-override/gitops/.../values/example-app-override.yaml  (override de infra)

Source 2: ref: developer-values         (alias al repo para resolver $developer-values)
Source 3: ref: gitops-override          (alias al repo para resolver $gitops-override)
```

Los values se aplican en orden: base → dev → override. El ultimo gana en caso
de conflicto.

---

### gitops/repositorios/

Secrets que registran repositorios en ArgoCD. La Application `repositorios`
(creada por `argocd-management`) escanea esta carpeta y aplica todo.

Para agregar un nuevo repo, crear un nuevo YAML aca con el label
`argocd.argoproj.io/secret-type: repository`.

---

## Como levantar el ambiente

### Prerequisitos

- Docker Engine corriendo
- kind, kubectl, helm instalados

### Pasos

```bash
# 1. Levantar cluster + ArgoCD
./bootstrap.sh

# 2. Aplicar el bootstrap de App of Apps
kubectl apply -f gitops/core/

# 3. Esperar ~1 minuto y verificar
kubectl -n argocd get applications
```

### Acceso a ArgoCD

| | |
|---|---|
| URL | https://localhost:8443 |
| Usuario | admin |
| Password | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \| base64 -d` |

---

## Como agregar una nueva app

1. **Crear los values del dev** en `codigo/`:

```
codigo/mi-nueva-app/values-dev.yaml
```

2. **Crear la Application multi-source** en el ambiente:

```
gitops/proyectos/example-project/dev/apps/mi-nueva-app.yaml
```

Copiar `example-app.yaml` y cambiar los nombres y rutas de values.

3. **Crear el override de infra** (opcional):

```
gitops/proyectos/example-project/dev/values/mi-nueva-app-override.yaml
```

4. **Commit y push**. ArgoCD lo detecta y deploya automaticamente.

---

## Como agregar un nuevo ambiente

1. Agregar el elemento en `gitops/proyectos/example-project.yaml`:

```yaml
generators:
  - list:
      elements:
        - env: dev
          project: example-project
        - env: tst                    # <-- nuevo
          project: example-project
```

2. Agregar el namespace destino en el AppProject del mismo archivo:

```yaml
destinations:
  - namespace: tst-example-project    # <-- nuevo
    server: https://kubernetes.default.svc
```

3. Crear la estructura del ambiente:

```
gitops/proyectos/example-project/tst/
  project/tst-project.yaml     # Namespace + AppProject
  apps/example-app.yaml        # Application (apuntando a values de tst)
  values/example-app-override.yaml
  commons/
```

4. Crear los values del dev para el nuevo ambiente:

```
codigo/example-app/values-tst.yaml
```

5. Commit y push.

---

## Como agregar un nuevo proyecto

1. Crear `gitops/proyectos/mi-proyecto.yaml` con el AppProject + ApplicationSet
   (copiar `example-project.yaml` como referencia)

2. Crear la estructura de ambientes en `gitops/proyectos/mi-proyecto/dev/...`

3. Crear los values en `codigo/`

4. Commit y push. La App raiz lo detecta automaticamente.

---

## Documentacion adicional

- [Guia de Helm](docs/helm-guide.md) - Explicacion detallada de como funciona Helm
  y el patron multi-source en este repo

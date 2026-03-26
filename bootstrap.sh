#!/bin/bash
set -e

echo "============================================"
echo " DevOps Local - Bootstrap Script"
echo "============================================"

# 1. Crear cluster Kind
echo "[1/5] Creando cluster Kind..."
if kind get clusters | grep -q "devops-local"; then
  echo "  -> Cluster 'devops-local' ya existe. Saltando..."
else
  kind create cluster --config kind-config.yaml
  echo "  -> Cluster creado."
fi

# 2. Instalar ArgoCD
echo "[2/5] Instalando ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
echo "  -> Manifiestos de ArgoCD aplicados."

# 3. Esperar a que ArgoCD este listo
echo "[3/5] Esperando a que ArgoCD este listo..."
kubectl -n argocd rollout status deployment argocd-server --timeout=300s
kubectl -n argocd rollout status deployment argocd-repo-server --timeout=300s
echo "  -> ArgoCD listo."

# 4. Patchear ArgoCD server para NodePort
echo "[4/5] Configurando acceso NodePort para ArgoCD..."
kubectl -n argocd patch svc argocd-server -p '{"spec": {"type": "NodePort", "ports": [{"port": 443, "targetPort": 8080, "nodePort": 30443, "name": "https"}, {"port": 80, "targetPort": 8080, "nodePort": 30080, "name": "http"}]}}'
echo "  -> ArgoCD accesible en https://localhost:8443"

# 5. Obtener password de admin
echo "[5/5] Obteniendo password de ArgoCD..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo ""
echo "============================================"
echo " ArgoCD esta listo!"
echo "============================================"
echo " URL:      https://localhost:8443"
echo " Usuario:  admin"
echo " Password: ${ARGOCD_PASSWORD}"
echo "============================================"
echo ""
echo "Para aplicar el bootstrap de App of Apps:"
echo "  kubectl apply -f gitops/core/"
echo ""

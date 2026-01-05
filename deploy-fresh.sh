#!/bin/bash
set -euo pipefail

# =========================
# DEPLOY FRESH - Full deployment script with Traefik
# =========================
# This script performs a complete fresh deployment:
# - Deletes and recreates Minikube cluster
# - Deploys CVAT via Helm with Traefik ingress
# - Traefik handles all proxying and CSRF headers automatically
#
# Use this script for:
# - Initial deployment
# - Complete reset/redeployment
#
# For updating configuration only, use: ./deploy-update.sh
# =========================

# =========================
# CONFIG (EDIT THESE)
# =========================
export NAMESPACE="cvat"
export RELEASE_NAME="cvat"

# Внешний IP/домен сервера (то, что ты вбиваешь в браузере)
export PUBLIC_HOST="10.144.165.63"

# Порт, по которому CVAT будет доступен снаружи (должен совпадать с Traefik NodePort)
export EXTERNAL_PORT="30080"

# =========================
# 0) Sanity
# =========================
command -v minikube >/dev/null
command -v kubectl >/dev/null
command -v helm >/dev/null

# =========================
# 1) Recreate minikube with published NodePort
# =========================
minikube delete --all --purge || true

minikube start \
  --driver=docker \
  --listen-address=0.0.0.0 \
  --ports="${EXTERNAL_PORT}:${EXTERNAL_PORT}"

kubectl config use-context minikube

# Wait for apiserver
kubectl wait --for=condition=Ready node/minikube --timeout=5m

# =========================
# 2) Deploy CVAT via Helm (with Traefik)
# =========================
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

# Update Helm dependencies
helm dependency update ./helm-chart

# Deploy CVAT with Traefik ingress
helm upgrade --install "${RELEASE_NAME}" ./helm-chart \
  -n "${NAMESPACE}" \
  --create-namespace \
  -f ./helm-chart/values.yaml \
  -f ./helm-chart/values.override.yaml

# Wait for Traefik to be ready
echo "Waiting for Traefik to be ready..."
kubectl -n "${NAMESPACE}" wait --for=condition=ready pod \
  -l app.kubernetes.io/name=traefik \
  --timeout=10m || true

# Wait for core components
kubectl -n "${NAMESPACE}" rollout status deploy/cvat-backend-server --timeout=20m
kubectl -n "${NAMESPACE}" rollout status deploy/cvat-frontend --timeout=20m

# =========================
# 3) Configure CSRF for external URL
# =========================
export PUBLIC_URL="http://${PUBLIC_HOST}:${EXTERNAL_PORT}"

# Extract scheme, host and port from PUBLIC_URL
export PUBLIC_SCHEME="http"
export PUBLIC_HOST_ONLY="${PUBLIC_HOST}"

echo "Setting CSRF_TRUSTED_ORIGINS=${PUBLIC_URL}"

# Set environment variables for CVAT backend
# Traefik will handle proper headers, but we still need to set trusted origins
kubectl -n "${NAMESPACE}" set env deploy/cvat-backend-server \
  ALLOWED_HOSTS="*" \
  CSRF_TRUSTED_ORIGINS="${PUBLIC_URL}" \
  CSRF_COOKIE_DOMAIN="" \
  CSRF_COOKIE_SECURE="false" \
  CVAT_UI_SCHEME="${PUBLIC_SCHEME}" \
  CVAT_UI_HOST="${PUBLIC_HOST_ONLY}" \
  CVAT_UI_PORT="${EXTERNAL_PORT}" \
  CORS_ALLOW_CREDENTIALS="true"

# Restart deployment to apply environment variables
echo "Restarting backend server to apply CSRF settings..."
kubectl -n "${NAMESPACE}" rollout restart deploy/cvat-backend-server
kubectl -n "${NAMESPACE}" rollout status deploy/cvat-backend-server --timeout=10m

# Also update all worker deployments with the same CSRF settings
echo "Updating CSRF settings for worker deployments..."
for deployment in cvat-backend-worker-export cvat-backend-worker-import cvat-backend-worker-annotation \
                   cvat-backend-worker-webhooks cvat-backend-worker-qualityreports cvat-backend-worker-chunks \
                   cvat-backend-worker-consensus cvat-backend-worker-utils; do
  if kubectl -n "${NAMESPACE}" get deploy "${deployment}" >/dev/null 2>&1; then
    kubectl -n "${NAMESPACE}" set env deploy/"${deployment}" \
      CSRF_TRUSTED_ORIGINS="${PUBLIC_URL}" \
      CSRF_COOKIE_DOMAIN="" \
      CSRF_COOKIE_SECURE="false" || true
  fi
done

# =========================
# 4) Verify deployment
# =========================
export PUBLIC_URL="http://${PUBLIC_HOST}:${EXTERNAL_PORT}"

echo
echo "Checking Traefik service..."
kubectl -n "${NAMESPACE}" get svc -l app.kubernetes.io/name=traefik

echo
echo "Checking Ingress..."
kubectl -n "${NAMESPACE}" get ingress

echo
echo "Testing: ${PUBLIC_URL}/api/server/about"
if curl -sS -f "${PUBLIC_URL}/api/server/about" >/dev/null 2>&1; then
    echo "✓ API is accessible through Traefik"
    curl -sS -i "${PUBLIC_URL}/api/server/about" | head -n 20
else
    echo "⚠ Warning: API test failed. Check if Traefik and services are running."
    echo "  Check Traefik pods: kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=traefik"
    echo "  Check Traefik service: kubectl get svc -n ${NAMESPACE} -l app.kubernetes.io/name=traefik"
    echo "  Check Ingress: kubectl get ingress -n ${NAMESPACE}"
fi

echo
echo "Deployment complete!"
echo "Open in browser: ${PUBLIC_URL}/"
echo
echo "Note: Traefik is handling all proxying and CSRF headers automatically."

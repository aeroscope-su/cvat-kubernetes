#!/bin/bash
set -euo pipefail

# =========================
# DEPLOY UPDATE - Update configuration only
# =========================
# This script updates only the configuration:
# - Updates Helm release with new values
# - Updates CSRF settings
# - Does NOT recreate cluster or Traefik
#
# Use this script for:
# - Updating values.override.yaml
# - Quick configuration changes
# =========================

# =========================
# CONFIG (EDIT THESE)
# =========================
export NAMESPACE="cvat"
export RELEASE_NAME="cvat"

# ??????? IP/????? ??????? (??, ??? ?? ???????? ? ????????)
export PUBLIC_HOST="10.144.165.63"

# ????, ?? ???????? CVAT ????? ???????? ???????
export EXTERNAL_PORT="30080"

# =========================
# 0) Sanity
# =========================
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
command -v helm >/dev/null || { echo "helm not found"; exit 1; }

# ???????? ??? namespace ??????????
if ! kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Error: Namespace ${NAMESPACE} does not exist. Run deploy-fresh.sh first."
    exit 1
fi

# ???????? ??? release ??????????
if ! helm list -n "${NAMESPACE}" | grep -q "^${RELEASE_NAME}"; then
    echo "Error: Helm release ${RELEASE_NAME} does not exist in namespace ${NAMESPACE}. Run deploy-fresh.sh first."
    exit 1
fi

# =========================
# 1) Update Helm dependencies
# =========================
echo "Updating Helm chart dependencies..."
helm dependency update ./helm-chart

# =========================
# 2) Update Helm release with new values
# =========================
echo "Updating Helm release ${RELEASE_NAME} with new configuration..."
helm upgrade "${RELEASE_NAME}" ./helm-chart \
  -n "${NAMESPACE}" \
  -f ./helm-chart/values.yaml \
  -f ./helm-chart/values.override.yaml

# Wait for core components to be updated
echo "Waiting for deployments to update..."
kubectl -n "${NAMESPACE}" rollout status deploy/cvat-backend-server --timeout=20m || true
kubectl -n "${NAMESPACE}" rollout status deploy/cvat-frontend --timeout=20m || true

# Wait for Traefik if it was updated
if kubectl -n "${NAMESPACE}" get deploy -l app.kubernetes.io/name=traefik >/dev/null 2>&1; then
    echo "Waiting for Traefik to be ready..."
    kubectl -n "${NAMESPACE}" rollout status deploy -l app.kubernetes.io/name=traefik --timeout=10m || true
fi

# =========================
# 3) Update CSRF settings for external URL
# =========================
export PUBLIC_URL="http://${PUBLIC_HOST}:${EXTERNAL_PORT}"

# Extract scheme, host and port from PUBLIC_URL
export PUBLIC_SCHEME="http"
export PUBLIC_HOST_ONLY="${PUBLIC_HOST}"

echo "Updating CSRF settings for ${PUBLIC_URL}..."

# Set environment variables for CVAT backend
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
kubectl -n "${NAMESPACE}" rollout status deploy/cvat-backend-server --timeout=10m || true

# Also update all worker deployments with the same CSRF settings
echo "Updating CSRF settings for worker deployments..."
for deployment in cvat-backend-worker-export cvat-backend-worker-import cvat-backend-worker-annotation \
                   cvat-backend-worker-webhooks cvat-backend-worker-qualityreports cvat-backend-worker-chunks \
                   cvat-backend-worker-consensus cvat-backend-worker-utils; do
  if kubectl -n "${NAMESPACE}" get deploy "${deployment}" >/dev/null 2>&1; then
    echo "  Updating ${deployment}..."
    kubectl -n "${NAMESPACE}" set env deploy/"${deployment}" \
      CSRF_TRUSTED_ORIGINS="${PUBLIC_URL}" \
      CSRF_COOKIE_DOMAIN="" \
      CSRF_COOKIE_SECURE="false" || true
  fi
done

# =========================
# 4) Verify deployment
# =========================
echo
echo "Verifying deployment..."
export PUBLIC_URL="http://${PUBLIC_HOST}:${EXTERNAL_PORT}"

echo "Testing: ${PUBLIC_URL}/api/server/about"
if curl -sS -f "${PUBLIC_URL}/api/server/about" >/dev/null 2>&1; then
    echo "? API is accessible through Traefik"
    curl -sS -i "${PUBLIC_URL}/api/server/about" | head -n 20
else
    echo "? Warning: API test failed. Check if services are running."
    echo "  Check pods: kubectl get pods -n ${NAMESPACE}"
    echo "  Check services: kubectl get svc -n ${NAMESPACE}"
    echo "  Check Traefik: kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=traefik"
fi

echo
echo "Update complete!"
echo "Open in browser: ${PUBLIC_URL}/"
echo
echo "Note: Traefik is handling all proxying and CSRF headers automatically."

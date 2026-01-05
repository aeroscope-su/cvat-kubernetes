#!/bin/bash
set -euo pipefail

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

# =========================
# 3) Update Edge Nginx ConfigMap if needed
# =========================
echo "Updating Edge Nginx configuration..."
kubectl -n "${NAMESPACE}" apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cvat-edge-nginx
data:
  default.conf: |
    server {
      listen 8080;
      server_name _;
      client_max_body_size 0;

      location /api/ {
        proxy_pass http://cvat-backend-service:8080/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
      }

      location / {
        proxy_pass http://cvat-frontend-service:8000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
      }
    }
YAML

# Restart edge nginx to pick up config changes
if kubectl -n "${NAMESPACE}" get deploy cvat-edge >/dev/null 2>&1; then
    echo "Restarting Edge Nginx to apply config changes..."
    kubectl -n "${NAMESPACE}" rollout restart deploy/cvat-edge
    kubectl -n "${NAMESPACE}" rollout status deploy/cvat-edge --timeout=5m || true
fi

# =========================
# 4) Update CSRF settings for external URL
# =========================
export PUBLIC_URL="http://${PUBLIC_HOST}:${EXTERNAL_PORT}"

# Extract scheme, host and port from PUBLIC_URL
export PUBLIC_SCHEME="http"
export PUBLIC_HOST_ONLY="${PUBLIC_HOST}"

echo "Updating CSRF settings for ${PUBLIC_URL}..."

# Set environment variables for CVAT backend
echo "Setting CSRF_TRUSTED_ORIGINS=${PUBLIC_URL}"
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
# 5) Verify deployment
# =========================
echo
echo "Verifying deployment..."
export PUBLIC_URL="http://${PUBLIC_HOST}:${EXTERNAL_PORT}"

echo "Testing: ${PUBLIC_URL}/api/server/about"
if curl -sS -f "${PUBLIC_URL}/api/server/about" >/dev/null 2>&1; then
    echo "? API is accessible"
    curl -sS -i "${PUBLIC_URL}/api/server/about" | head -n 20
else
    echo "? Warning: API test failed. Check if services are running."
    echo "  Check pods: kubectl get pods -n ${NAMESPACE}"
    echo "  Check services: kubectl get svc -n ${NAMESPACE}"
fi

echo
echo "Update complete!"
echo "Open in browser: ${PUBLIC_URL}/"

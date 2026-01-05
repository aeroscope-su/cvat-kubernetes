#!/bin/bash
#!/bin/bash
set -euo pipefail

# =========================
# DEPLOY FRESH - Full deployment script
# =========================
# This script performs a complete fresh deployment:
# - Deletes and recreates Minikube cluster
# - Deploys CVAT via Helm
# - Sets up Edge Nginx
# - Configures CSRF settings
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

# Порт, по которому CVAT будет доступен снаружи
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
# 2) Deploy CVAT via Helm
# =========================
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

# Если у тебя зависимости чарта используются:
helm dependency update ./helm-chart

helm upgrade --install "${RELEASE_NAME}" ./helm-chart \
  -n "${NAMESPACE}" \
  --create-namespace \
  -f ./helm-chart/values.yaml \
  -f ./helm-chart/values.override.yaml

# Wait for core components
kubectl -n "${NAMESPACE}" rollout status deploy/cvat-backend-server --timeout=20m
kubectl -n "${NAMESPACE}" rollout status deploy/cvat-frontend --timeout=20m

# =========================
# 3) Edge Nginx inside cluster (UI + /api)
# =========================
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
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cvat-edge
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cvat-edge
  template:
    metadata:
      labels:
        app: cvat-edge
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: cfg
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: cfg
          configMap:
            name: cvat-edge-nginx
---
apiVersion: v1
kind: Service
metadata:
  name: cvat-edge
spec:
  type: NodePort
  selector:
    app: cvat-edge
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      nodePort: 30080
YAML

kubectl -n "${NAMESPACE}" rollout status deploy/cvat-edge --timeout=5m

# =========================
# 4) Fix CSRF for external URL
# =========================
export PUBLIC_URL="http://${PUBLIC_HOST}:${EXTERNAL_PORT}"

# Extract scheme, host and port from PUBLIC_URL
export PUBLIC_SCHEME="http"
export PUBLIC_HOST_ONLY="${PUBLIC_HOST}"

# Set environment variables for CVAT backend
# CSRF_TRUSTED_ORIGINS should be a comma-separated list for Django
# Note: Django 4.2+ supports CSRF_TRUSTED_ORIGINS via environment variable
# Format: comma-separated list of origins (without trailing slash)
# Also set CSRF_COOKIE_DOMAIN to empty to allow cookies from any domain
kubectl -n "${NAMESPACE}" set env deploy/cvat-backend-server \
  ALLOWED_HOSTS="*" \
  CSRF_TRUSTED_ORIGINS="${PUBLIC_URL}" \
  CSRF_COOKIE_DOMAIN="" \
  CSRF_COOKIE_SECURE="false" \
  CVAT_UI_SCHEME="${PUBLIC_SCHEME}" \
  CVAT_UI_HOST="${PUBLIC_HOST_ONLY}" \
  CVAT_UI_PORT="${EXTERNAL_PORT}" \
  CORS_ALLOW_CREDENTIALS="true"

kubectl -n "${NAMESPACE}" rollout status deploy/cvat-backend-server --timeout=10m

# Also update all worker deployments with the same CSRF settings
# (workers may need CSRF settings for some operations)
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
# 5) Verify API returns JSON through edge
# =========================
echo "Testing: ${PUBLIC_URL}/api/server/about"
curl -sS -i "${PUBLIC_URL}/api/server/about" | head -n 20

echo
echo "Open in browser:"
echo "  ${PUBLIC_URL}/"

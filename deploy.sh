set -euo pipefail

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
      }

      location / {
        proxy_pass http://cvat-frontend-service:8000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
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

kubectl -n "${NAMESPACE}" set env deploy/cvat-backend-server \
  ALLOWED_HOSTS="*" \
  CSRF_TRUSTED_ORIGINS="${PUBLIC_URL}"

kubectl -n "${NAMESPACE}" rollout status deploy/cvat-backend-server --timeout=10m

# =========================
# 5) Verify API returns JSON through edge
# =========================
echo "Testing: ${PUBLIC_URL}/api/server/about"
curl -sS -i "${PUBLIC_URL}/api/server/about" | head -n 20

echo
echo "Open in browser:"
echo "  ${PUBLIC_URL}/"

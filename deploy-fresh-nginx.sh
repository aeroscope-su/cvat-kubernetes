#!/bin/bash
set -euo pipefail

export NAMESPACE="cvat"
export RELEASE_NAME="cvat"

export PUBLIC_IP="10.144.165.63"
export EXTERNAL_HTTP_PORT="30080"
export EXTERNAL_HTTPS_PORT="30443"

# sslip.io hostname
PUBLIC_HOST_DASHED="${PUBLIC_IP//./-}"
export PUBLIC_HOST="${PUBLIC_HOST_DASHED}.sslip.io"
export PUBLIC_URL="http://${PUBLIC_HOST}:${EXTERNAL_HTTP_PORT}"

command -v minikube >/dev/null
command -v kubectl >/dev/null
command -v helm >/dev/null

minikube delete --all --purge || true

minikube start \
  --driver=docker \
  --listen-address=0.0.0.0 \
  --ports="${EXTERNAL_HTTP_PORT}:${EXTERNAL_HTTP_PORT},${EXTERNAL_HTTPS_PORT}:${EXTERNAL_HTTPS_PORT}"

kubectl config use-context minikube
kubectl wait --for=condition=Ready node/minikube --timeout=5m

kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"
kubectl get ns ingress-nginx >/dev/null 2>&1 || kubectl create ns ingress-nginx

# Ingress-NGINX
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http="${EXTERNAL_HTTP_PORT}" \
  --set controller.service.nodePorts.https="${EXTERNAL_HTTPS_PORT}" \
  --set controller.ingressClassResource.name=nginx \
  --set controller.ingressClass=nginx

kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=10m

# CVAT
helm dependency update ./helm-chart
helm upgrade --install "${RELEASE_NAME}" ./helm-chart \
  -n "${NAMESPACE}" \
  --create-namespace \
  -f ./helm-chart/values.yaml \
  -f ./helm-chart/values.override.yaml

kubectl -n "${NAMESPACE}" rollout status deploy/cvat-backend-server --timeout=20m
kubectl -n "${NAMESPACE}" rollout status deploy/cvat-frontend --timeout=20m

echo
echo "Ingress-NGINX service:"
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide

echo
echo "CVAT ingress:"
kubectl -n "${NAMESPACE}" get ingress -o wide

echo
echo "Testing: ${PUBLIC_URL}/api/server/about"
curl -sS -i "${PUBLIC_URL}/api/server/about" | head -n 30 || true

echo
echo "Done. Open: ${PUBLIC_URL}/"

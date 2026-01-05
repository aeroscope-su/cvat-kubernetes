#!/bin/bash
# Script to check CSRF settings in CVAT backend pods

set -euo pipefail

export NAMESPACE="${NAMESPACE:-cvat}"
export RELEASE_NAME="${RELEASE_NAME:-cvat}"

echo "Checking CSRF settings in CVAT backend pods..."
echo

# Get backend server pod
BACKEND_POD=$(kubectl get pod -n "${NAMESPACE}" \
  -l tier=backend,component=server,app.kubernetes.io/instance="${RELEASE_NAME}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "${BACKEND_POD}" ]; then
    echo "Error: Backend server pod not found"
    exit 1
fi

echo "Backend pod: ${BACKEND_POD}"
echo

# Check environment variables
echo "Environment variables:"
kubectl exec -n "${NAMESPACE}" "${BACKEND_POD}" -c cvat-backend -- env | grep -E "CSRF|ALLOWED_HOSTS|CVAT_UI" || echo "No CSRF-related variables found"
echo

# Check Django settings (if possible)
echo "Checking Django CSRF settings..."
kubectl exec -n "${NAMESPACE}" "${BACKEND_POD}" -c cvat-backend -- \
  python -c "
import os
import django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'cvat.settings.production')
try:
    django.setup()
    from django.conf import settings
    print(f'CSRF_TRUSTED_ORIGINS: {getattr(settings, \"CSRF_TRUSTED_ORIGINS\", \"NOT SET\")}')
    print(f'CSRF_COOKIE_DOMAIN: {getattr(settings, \"CSRF_COOKIE_DOMAIN\", \"NOT SET\")}')
    print(f'CSRF_COOKIE_SECURE: {getattr(settings, \"CSRF_COOKIE_SECURE\", \"NOT SET\")}')
    print(f'ALLOWED_HOSTS: {getattr(settings, \"ALLOWED_HOSTS\", \"NOT SET\")}')
except Exception as e:
    print(f'Error checking settings: {e}')
" 2>&1 || echo "Could not check Django settings (may need to rebuild image with changes)"

echo
echo "To fix CSRF issues:"
echo "1. Make sure CSRF_TRUSTED_ORIGINS environment variable is set"
echo "2. Restart the backend pod: kubectl rollout restart deploy/cvat-backend-server -n ${NAMESPACE}"
echo "3. If using custom image, rebuild it with updated base.py settings"

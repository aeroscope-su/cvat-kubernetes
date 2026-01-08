# Руководство по развертыванию CVAT в Kubernetes

Это руководство описывает **текущий** способ деплоя CVAT из этого репозитория: Helm chart + Ingress-NGINX (NodePort) + Ingress-ресурс CVAT, с настройками из `values.override.yaml` и (для “с нуля”) скриптом `deploy-fresh-nginx.sh`.

Актуальность: 2026-01-06 (сверено по `deploy-fresh-nginx.sh` и `values.override.yaml`).

## Содержание

1. [Предварительные требования](#предварительные-требования)
2. [Быстрый старт: “с нуля” на Minikube + Ingress-NGINX](#быстрый-старт-с-нуля-на-minikube--ingress-nginx)
3. [Конфигурация Helm: что реально используется в values.override.yaml](#конфигурация-helm-что-реально-используется-в-valuesoverrideyaml)
4. [Деплой в существующий кластер (не Minikube)](#деплой-в-существующий-кластер-не-minikube)
5. [Пост-развертывание](#пост-развертывание)
6. [Настройка внешнего MinIO (S3-compatible)](#настройка-внешнего-minio-s3-compatible)
7. [Обновление развертывания](#обновление-развертывания)
8. [Решение проблем](#решение-проблем)
9. [Полезные команды](#полезные-команды)

---

## Предварительные требования

### Обязательные компоненты

- Kubernetes кластер (для Helm chart). Для Minikube-скрипта — локальный Minikube кластер.
- `kubectl`
- `helm`

Проверка:

```bash
kubectl version --client --short
helm version
kubectl cluster-info
```

### Для “быстрого старта” (скрипт)

Скрипт `deploy-fresh-nginx.sh` **ожидает**:

- установленный `minikube`
- доступ к Docker (используется `--driver=docker`)
- свободные порты на хосте, которые вы задаёте как `EXTERNAL_HTTP_PORT` и `EXTERNAL_HTTPS_PORT` (по умолчанию 30080/30443)

---

## Быстрый старт: “с нуля” на Minikube + Ingress-NGINX

Этот путь соответствует `deploy-fresh-nginx.sh`:

- удаляет все профили Minikube
- поднимает Minikube (docker driver) с пробросом портов
- ставит Ingress-NGINX как NodePort на указанных портах
- деплоит CVAT Helm chart с `values.yaml` + `values.override.yaml`
- ждёт rollout `cvat-backend-server` и `cvat-frontend`
- проверяет `GET /api/server/about` и печатает URL

### 1) Запуск

Из корня репозитория:

```bash
chmod +x ./deploy-fresh-nginx.sh
./deploy-fresh-nginx.sh
```

### 2) Что скрипт считает “публичным URL”

В скрипте используются переменные:

- `PUBLIC_IP` (по умолчанию `10.144.165.63`)
- `EXTERNAL_HTTP_PORT` (по умолчанию `30080`)
- `EXTERNAL_HTTPS_PORT` (по умолчанию `30443`)
- `PUBLIC_HOST` формируется через `sslip.io`:
  `10.144.165.63` → `10-144-165-63.sslip.io`
- `PUBLIC_URL` по умолчанию: `http://10-144-165-63.sslip.io:30080`

Важно: **URL в браузере должен совпадать** с тем, что указано в `CSRF_TRUSTED_ORIGINS` (см. ниже), иначе получите CSRF-ошибку.

---

## Конфигурация Helm: что реально используется в values.override.yaml

Файл `values.override.yaml` задаёт “рабочую” конфигурацию для текущего варианта с Ingress-NGINX.

### Пароли (сейчас стоят тестовые — заменить обязательно)

В текущем файле стоят значения `test`:

- `postgresql.secret.password / postgres_password / replication_password`
- `redis.secret.password`
- `cvat.kvrocks.secret.password`

Перед любым деплоем, который не одноразовый тест, замените на нормальные значения.

### CVAT backend образ

Используется:

```yaml
cvat:
  backend:
    image: cvat/server
    tag: dev
    imagePullPolicy: Always
```

Для продакшена рекомендуется заменить `tag: dev` на конкретную версию CVAT и поставить `IfNotPresent`.

### Реплики воркеров

В `values.override.yaml` задано:

- `backend.server.replicas: 1`
- worker’ы: export/import по 2, chunks — 2, остальные по 1

При нехватке ресурсов в кластере — уменьшайте.

### CSRF/Hosts (самая частая причина “не открывается”)

В override заданы переменные окружения backend сервера:

```yaml
cvat:
  backend:
    server:
      envs:
        ALLOWED_HOSTS: "*"
        CSRF_TRUSTED_ORIGINS: "http://10-144-165-63.sslip.io:30080"
        CSRF_COOKIE_SECURE: "false"
        CORS_ALLOW_CREDENTIALS: "true"
```

Если вы меняете IP/hostname/порт/схему (http/https) — **обновляйте `CSRF_TRUSTED_ORIGINS`** под ваш реальный URL.

### Ingress (NGINX)

Override включает Ingress и выключает Traefik:

```yaml
ingress:
  enabled: true
  hostname: 10-144-165-63.sslip.io
  className: "nginx"
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
  tls: false
  tlsSecretName: ingress-tls-cvat

traefik:
  enabled: false
```

---

## Деплой в существующий кластер (не Minikube)

Ниже — “ручной” вариант тех же действий, что делает `deploy-fresh-nginx.sh`, но без Minikube.

### 1) Подготовьте Ingress-NGINX

Если Ingress-NGINX уже установлен — пропустите.

Пример установки через Helm (NodePort):

```bash
kubectl get ns ingress-nginx >/dev/null 2>&1 || kubectl create ns ingress-nginx

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx   -n ingress-nginx   --set controller.service.type=NodePort   --set controller.service.nodePorts.http=30080   --set controller.service.nodePorts.https=30443   --set controller.ingressClassResource.name=nginx   --set controller.ingressClass=nginx

kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=10m
```

Если у вас LoadBalancer — используйте `controller.service.type=LoadBalancer` и корректный внешний адрес.

### 2) Подготовьте значения `values.override.yaml`

- выставьте `ingress.hostname` на ваш домен/хост
- выставьте `cvat.backend.server.envs.CSRF_TRUSTED_ORIGINS` на **реальный URL** (scheme + host + port)
- при HTTPS включите `ingress.tls: true` и `CSRF_COOKIE_SECURE: "true"`

### 3) Деплой CVAT Helm chart

```bash
export NAMESPACE="cvat"
export RELEASE_NAME="cvat"

kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

helm dependency update ./helm-chart

helm upgrade --install "${RELEASE_NAME}" ./helm-chart   -n "${NAMESPACE}"   --create-namespace   -f ./helm-chart/values.yaml   -f ./helm-chart/values.override.yaml

kubectl -n "${NAMESPACE}" rollout status deploy/cvat-backend-server --timeout=20m
kubectl -n "${NAMESPACE}" rollout status deploy/cvat-frontend --timeout=20m
```

### 4) Проверка

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
kubectl -n "${NAMESPACE}" get ingress -o wide

# Замените на свой URL
curl -sS -i "http://10-144-165-63.sslip.io:30080/api/server/about" | head -n 30
```

---

## Пост-развертывание

### 1) Создание суперпользователя

```bash
export NAMESPACE="cvat"
export RELEASE_NAME="cvat"

BACKEND_POD_NAME="$(
  kubectl get pod -n "${NAMESPACE}"     -l app.kubernetes.io/instance="${RELEASE_NAME}",tier=backend,component=server     -o jsonpath='{.items[0].metadata.name}'
)"

kubectl exec -it -n "${NAMESPACE}" "${BACKEND_POD_NAME}" -c cvat-backend   -- python manage.py createsuperuser
```

### 2) Открытие UI

Откройте URL, соответствующий вашему Ingress + NodePort/LoadBalancer. Для дефолтного сценария из скрипта:

- `http://10-144-165-63.sslip.io:30080/`

---

## Настройка внешнего MinIO (S3-compatible)

Текущая стратегия (и она же самая стабильная): **настроить Cloud Storage через UI**.

### Вариант A: через CVAT UI

1. Зайдите в CVAT как админ
2. Settings → Cloud Storages → Create cloud storage
3. Provider: AWS S3
4. Bucket name: ваш bucket
5. Endpoint URL: `http://<minio-host>:9000`
6. Access/Secret key: от MinIO
7. Region: `us-east-1`

### Вариант B: через Kubernetes Secret (для дефолтных AWS_* переменных)

`values.override.yaml` содержит заготовку (закомментировано). Общая идея:

```bash
kubectl create secret generic cvat-minio-credentials   --from-literal=AWS_ACCESS_KEY_ID=...   --from-literal=AWS_SECRET_ACCESS_KEY=...   --from-literal=AWS_DEFAULT_REGION=us-east-1   --from-literal=AWS_ENDPOINT_URL=http://minio.example.com:9000   -n cvat
```

Затем раскомментировать `cvat.backend.additionalEnv` и сделать `helm upgrade`.

Важно: сам CVAT всё равно “подключает” S3-сторедж через сущность Cloud Storage (UI/API). Эти переменные полезны, если вы хотите задать дефолтные креды для SDK.

---

## Обновление развертывания

После правок `values.override.yaml`:

```bash
helm upgrade "${RELEASE_NAME}" ./helm-chart   -n "${NAMESPACE}"   -f ./helm-chart/values.yaml   -f ./helm-chart/values.override.yaml
```

Проверка:

```bash
helm status "${RELEASE_NAME}" -n "${NAMESPACE}"
kubectl get pods -n "${NAMESPACE}" -w
```

---

## Решение проблем

### CSRF Failed: Origin checking failed

Причина: URL в браузере **не совпадает** с `CSRF_TRUSTED_ORIGINS`.

Что делать:

1. Узнайте, по какому URL вы реально открываете CVAT (scheme + host + port).
2. Поставьте этот URL в `cvat.backend.server.envs.CSRF_TRUSTED_ORIGINS` в `values.override.yaml`.
3. Примените `helm upgrade`.

Проверка текущих env внутри backend:

```bash
kubectl -n cvat exec deploy/cvat-backend-server -c cvat-backend --   sh -lc 'env | grep -E "CSRF|ALLOWED_HOSTS|DJANGO" | sort'
```

### Ingress работает, но большие файлы не загружаются / таймауты

В override уже проставлены аннотации:

- `proxy-body-size: "0"`
- `proxy-read-timeout: "3600"`
- `proxy-send-timeout: "3600"`
- `proxy-buffering: "off"`

Если всё равно режет — проверьте, что именно этот Ingress применяется к нужному IngressClass (`nginx`) и что контроллер реально читает эти аннотации.

### Поды не стартуют / CrashLoopBackOff

Быстрый чек:

```bash
kubectl get pods -n cvat
kubectl get events -n cvat --sort-by='.lastTimestamp' | tail -n 50
kubectl logs -n cvat deploy/cvat-backend-server -c cvat-backend --tail=200
```

### Нет доступа снаружи к NodePort

- убедитесь, что вы попадаете на **IP ноды**, где открыт NodePort
- проверьте firewall/security groups
- проверьте, что сервис ingress-nginx-controller реально NodePort и на нужных портах:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
```

---

## Полезные команды

### Статус и диагностика

```bash
helm list -n cvat
helm status cvat -n cvat

kubectl get pods -n cvat -o wide
kubectl get svc -n cvat -o wide
kubectl get ingress -n cvat -o wide

kubectl describe ingress -n cvat
kubectl describe pod -n cvat <pod>
```

### Полное удаление (внимание: данные будут потеряны)

```bash
helm uninstall cvat -n cvat
kubectl delete ns cvat
```

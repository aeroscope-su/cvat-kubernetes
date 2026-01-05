# Руководство по развертыванию CVAT в Kubernetes

Это руководство содержит пошаговые инструкции по развертыванию CVAT в кластере Kubernetes с использованием Helm chart.

## Содержание

1. [Предварительные требования](#предварительные-требования)
2. [Подготовка окружения](#подготовка-окружения)
3. [Настройка конфигурации](#настройка-конфигурации)
4. [Развертывание](#развертывание)
5. [Пост-развертывание](#пост-развертывание)
6. [Настройка внешнего MinIO](#настройка-внешнего-minio)
7. [Обновление развертывания](#обновление-развертывания)
8. [Решение проблем](#решение-проблем)

## Предварительные требования

### Обязательные компоненты

1. **Kubernetes кластер** версии 1.23 или выше
   - Рабочий кластер с настроенным kubectl
   - Проверьте версию: `kubectl version --client --short`

2. **kubectl** установлен и настроен
   - Проверьте подключение: `kubectl cluster-info`
   - Убедитесь, что контекст правильный: `kubectl config current-context`

3. **Helm** версии 3.x
   - Установите Helm: https://helm.sh/docs/intro/install/
   - Проверьте версию: `helm version`

4. **Доступ к namespace** в кластере
   - Создайте namespace или убедитесь, что у вас есть права на его использование

### Опциональные компоненты

- **Minikube** (для локальной разработки/тестирования)
- **Ingress Controller** (nginx, traefik и т.д.) для внешнего доступа
- **Cert-Manager** для автоматического управления TLS сертификатами

## Подготовка окружения

### 1. Клонирование репозитория

Если вы еще не клонировали репозиторий:

```bash
git clone <repository-url>
cd cvat-kubernetes
```

### 2. Выбор namespace

Определите namespace, в котором будет развернут CVAT:

```bash
export NAMESPACE="cvat"  # Или выберите другое имя
export RELEASE_NAME="cvat"  # Имя Helm release
```

Создайте namespace (если его нет):

```bash
kubectl create namespace $NAMESPACE
```

### 3. Проверка контекста Kubernetes

Убедитесь, что вы используете правильный контекст:

```bash
kubectl config current-context
```

Если нужно переключить контекст:

```bash
kubectl config use-context <your-context-name>
```

### 4. Установка зависимостей Helm chart

Перейдите в директорию helm-chart и обновите зависимости:

```bash
cd helm-chart
helm dependency update
```

Эта команда загрузит все необходимые зависимости:
- PostgreSQL chart (Bitnami)
- Redis chart (Bitnami)
- Nuclio chart (если включен)
- Traefik chart (если включен)
- И другие зависимости

Убедитесь, что команда завершилась успешно. Зависимости будут загружены в директорию `charts/`.

## Настройка конфигурации

### 1. Создание файла values.override.yaml

Файл `values.override.yaml` уже создан в директории `helm-chart/`. Откройте его для редактирования:

```bash
cd helm-chart
vim values.override.yaml  # или используйте другой редактор
```

### 2. Настройка обязательных параметров

#### Пароли PostgreSQL (ОБЯЗАТЕЛЬНО)

Найдите секцию `postgresql.secret` и замените все `<CHANGE_ME_*>` на безопасные пароли:

```yaml
postgresql:
  secret:
    password: your_secure_postgresql_password
    postgres_password: your_secure_postgres_postgres_password
    replication_password: your_secure_replication_password
```

ВАЖНО: Используйте сильные пароли. Сохраните их в безопасном месте.

#### Пароли Redis (рекомендуется)

```yaml
redis:
  secret:
    password: your_secure_redis_password
```

#### Пароль KVRocks (рекомендуется)

```yaml
cvat:
  kvrocks:
    secret:
      password: your_secure_kvrocks_password
```

### 3. Настройка опциональных параметров

#### Изменение образа CVAT

По умолчанию используется `dev` тег. Для production используйте конкретную версию:

```yaml
cvat:
  backend:
    image: cvat/server
    tag: "2.54.1"  # Укажите нужную версию
    imagePullPolicy: IfNotPresent  # Для production
```

#### Настройка реплик

Настройте количество реплик в зависимости от нагрузки:

```yaml
cvat:
  backend:
    server:
      replicas: 2  # Увеличьте для высокой нагрузки
    worker:
      export:
        replicas: 3
      import:
        replicas: 3
```

#### Настройка хранилища

Измените размер PersistentVolumeClaim:

```yaml
cvat:
  backend:
    defaultStorage:
      size: 50Gi  # Увеличьте при необходимости
      # storageClassName: fast-ssd  # Укажите класс хранилища
```

#### Настройка Ingress

Для доступа извне кластера включите Ingress:

```yaml
ingress:
  enabled: true
  hostname: cvat.yourdomain.com  # Ваш домен
  className: "nginx"  # Или "traefik", в зависимости от вашего ingress controller
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"  # Если используете cert-manager
  tls: true
  tlsSecretName: cvat-tls
```

#### Настройка Traefik

Если вы используете Traefik как ingress controller:

```yaml
traefik:
  enabled: true
  # Для Minikube может потребоваться:
  # service:
  #   externalIPs:
  #     - "192.168.49.2"  # IP адрес Minikube (получите через: minikube ip)
```

Для Minikube также добавьте запись в /etc/hosts:

```bash
echo "$(minikube ip) cvat.local" | sudo tee -a /etc/hosts
```

### 4. Настройка внешних сервисов (опционально)

#### Использование внешнего PostgreSQL

Если у вас уже есть PostgreSQL сервер:

```yaml
postgresql:
  enabled: false
  external:
    host: postgresql.example.com
    port: 5432
  auth:
    username: cvat
    database: cvat
  secret:
    password: your_external_db_password
```

#### Использование внешнего Redis

```yaml
redis:
  enabled: false
  external:
    host: redis.example.com
  secret:
    password: your_external_redis_password
```

## Развертывание

### 1. Предварительная проверка

Перед развертыванием проверьте конфигурацию:

```bash
# Проверка синтаксиса Helm chart
helm lint ./helm-chart -f ./helm-chart/values.yaml -f ./helm-chart/values.override.yaml

# Предварительный просмотр манифестов (dry-run)
helm upgrade $RELEASE_NAME ./helm-chart \
  -n $NAMESPACE \
  --create-namespace \
  -f ./helm-chart/values.yaml \
  -f ./helm-chart/values.override.yaml \
  --dry-run --debug
```

### 2. Развертывание

Выполните развертывание:

```bash
helm upgrade $RELEASE_NAME ./helm-chart \
  -n $NAMESPACE \
  --create-namespace \
  -i \
  -f ./helm-chart/values.yaml \
  -f ./helm-chart/values.override.yaml
```

Флаги:
- `-i` или `--install`: установить release, если его еще нет
- `--create-namespace`: создать namespace, если его нет
- `-f`: указать файлы с values

### 3. Мониторинг развертывания

Отслеживайте статус развертывания:

```bash
# Проверка статуса Helm release
helm status $RELEASE_NAME -n $NAMESPACE

# Просмотр подов
kubectl get pods -n $NAMESPACE -w

# Просмотр сервисов
kubectl get svc -n $NAMESPACE

# Просмотр PersistentVolumeClaims
kubectl get pvc -n $NAMESPACE
```

Ожидайте, пока все поды перейдут в состояние `Running`:

```bash
kubectl wait --for=condition=ready pod \
  -l app=cvat-app \
  -n $NAMESPACE \
  --timeout=300s
```

### 4. Проверка логов

Если что-то пошло не так, проверьте логи:

```bash
# Логи backend сервера
kubectl logs -n $NAMESPACE -l tier=backend,component=server --tail=100

# Логи конкретного пода
kubectl logs -n $NAMESPACE <pod-name> --tail=100

# Логи с предыдущего контейнера (если под перезапускался)
kubectl logs -n $NAMESPACE <pod-name> --previous
```

## Пост-развертывание

### 1. Создание суперпользователя

После успешного развертывания создайте администратора:

```bash
HELM_RELEASE_NAMESPACE="$NAMESPACE"
HELM_RELEASE_NAME="$RELEASE_NAME"
BACKEND_POD_NAME=$(kubectl get pod --namespace $HELM_RELEASE_NAMESPACE \
  -l tier=backend,app.kubernetes.io/instance=$HELM_RELEASE_NAME,component=server \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -it --namespace $HELM_RELEASE_NAMESPACE $BACKEND_POD_NAME \
  -c cvat-backend -- python manage.py createsuperuser
```

Следуйте инструкциям для ввода имени пользователя, email и пароля.

### 2. Получение доступа к приложению

#### Через Ingress (если настроен)

Если вы настроили Ingress, откройте в браузере:

```
http://cvat.yourdomain.com  # или https:// если настроен TLS
```

#### Через Port Forward (для тестирования)

Если Ingress не настроен, используйте port-forward:

```bash
# Получите имя сервиса
kubectl get svc -n $NAMESPACE

# Проброс порта для frontend
kubectl port-forward -n $NAMESPACE svc/$RELEASE_NAME-frontend 8000:8000

# В другом терминале - проброс для backend
kubectl port-forward -n $NAMESPACE svc/$RELEASE_NAME-backend-server 8080:8080
```

Затем откройте в браузере: `http://localhost:8000`

#### Через NodePort (если настроен)

Если сервисы имеют тип NodePort:

```bash
kubectl get svc -n $NAMESPACE
# Найдите EXTERNAL-IP или используйте <node-ip>:<nodeport>
```

### 3. Проверка работоспособности

1. Откройте веб-интерфейс CVAT
2. Войдите с учетными данными суперпользователя
3. Проверьте, что все компоненты работают:
   - Создание задачи
   - Загрузка данных
   - Экспорт аннотаций

## Настройка внешнего MinIO

### Вариант 1: Настройка через CVAT Web UI (рекомендуется)

1. Войдите в CVAT как администратор
2. Перейдите в Settings > Cloud Storages
3. Нажмите "Create cloud storage"
4. Заполните форму:
   - **Provider**: AWS S3
   - **Bucket name**: имя вашего bucket в MinIO
   - **Endpoint URL**: `http://your-minio-server:9000` (или `https://` если используется TLS)
   - **Access key ID**: ваш MinIO access key
   - **Secret access key**: ваш MinIO secret key
   - **Region**: `us-east-1` (MinIO не требует реальный регион)
5. Нажмите "Submit"

### Вариант 2: Настройка через API

Создайте cloud storage через REST API:

```bash
# Получите токен авторизации
TOKEN=$(curl -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"your_password"}' \
  | jq -r '.key')

# Создайте cloud storage
curl -X POST http://localhost:8080/api/cloudstorages \
  -H "Authorization: Token $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "provider_type": "AWS_S3_BUCKET",
    "resource": "your-bucket-name",
    "credentials_type": "KEY_SECRET_KEY_PAIR",
    "specific_attributes": "endpoint_url=http://your-minio-server:9000",
    "key": "your-minio-access-key",
    "secret_key": "your-minio-secret-key"
  }'
```

### Вариант 3: Использование переменных окружения (для дефолтных credentials)

Если вы хотите установить дефолтные credentials через переменные окружения:

1. Создайте Kubernetes Secret:

```bash
kubectl create secret generic cvat-minio-credentials \
  --from-literal=AWS_ACCESS_KEY_ID=your-access-key \
  --from-literal=AWS_SECRET_ACCESS_KEY=your-secret-key \
  --from-literal=AWS_DEFAULT_REGION=us-east-1 \
  --from-literal=AWS_ENDPOINT_URL=http://minio.example.com:9000 \
  -n $NAMESPACE
```

2. Раскомментируйте и настройте секцию `Option B` в `values.override.yaml`:

```yaml
cvat:
  backend:
    additionalEnv:
      - name: AWS_ACCESS_KEY_ID
        valueFrom:
          secretKeyRef:
            name: cvat-minio-credentials
            key: AWS_ACCESS_KEY_ID
      # ... и так далее для других переменных
```

3. Обновите развертывание:

```bash
helm upgrade $RELEASE_NAME ./helm-chart \
  -n $NAMESPACE \
  -f ./helm-chart/values.yaml \
  -f ./helm-chart/values.override.yaml
```

### Важные замечания по сетевой связности

#### MinIO на другом сервере

- Убедитесь, что MinIO доступен из Kubernetes кластера
- Используйте IP адрес или hostname сервера MinIO
- Проверьте firewall правила
- Убедитесь, что порты MinIO (обычно 9000 и 9001) открыты

#### MinIO локально, но вне Kubernetes

**Для Minikube:**

```bash
# Получите IP Minikube
minikube ip

# Используйте этот IP для доступа к MinIO, если он запущен на хосте
# Или используйте специальный адрес для доступа к хосту из Minikube
```

**Для Docker Desktop:**

Используйте `host.docker.internal` как hostname MinIO в endpoint URL.

**Для других Kubernetes дистрибутивов:**

- Настройте Service или Ingress для MinIO
- Или используйте NodePort для доступа к MinIO
- Или используйте ExternalName Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: minio-external
  namespace: $NAMESPACE
spec:
  type: ExternalName
  externalName: your-minio-server.example.com
  ports:
    - port: 9000
      targetPort: 9000
```

Затем используйте `minio-external.$NAMESPACE.svc.cluster.local:9000` как endpoint URL.

### Проверка подключения к MinIO

После настройки проверьте подключение:

1. В CVAT UI перейдите в Settings > Cloud Storages
2. Найдите созданное хранилище
3. Проверьте статус - должно быть "AVAILABLE"
4. Попробуйте просмотреть содержимое bucket

## Обновление развертывания

### Обновление конфигурации

После изменения `values.override.yaml`:

```bash
# Предварительный просмотр изменений
helm diff upgrade $RELEASE_NAME ./helm-chart \
  -n $NAMESPACE \
  -f ./helm-chart/values.yaml \
  -f ./helm-chart/values.override.yaml

# Применить изменения
helm upgrade $RELEASE_NAME ./helm-chart \
  -n $NAMESPACE \
  -f ./helm-chart/values.yaml \
  -f ./helm-chart/values.override.yaml
```

### Обновление версии CVAT

1. Измените тег образа в `values.override.yaml`:

```yaml
cvat:
  backend:
    tag: "2.54.2"  # Новая версия
  frontend:
    tag: "2.54.2"
```

2. Выполните обновление:

```bash
helm upgrade $RELEASE_NAME ./helm-chart \
  -n $NAMESPACE \
  -f ./helm-chart/values.yaml \
  -f ./helm-chart/values.override.yaml
```

3. Проверьте статус:

```bash
helm status $RELEASE_NAME -n $NAMESPACE
kubectl get pods -n $NAMESPACE -w
```

### Откат к предыдущей версии

Если что-то пошло не так:

```bash
# Просмотр истории
helm history $RELEASE_NAME -n $NAMESPACE

# Откат к предыдущей версии
helm rollback $RELEASE_NAME -n $NAMESPACE

# Или к конкретной ревизии
helm rollback $RELEASE_NAME <revision-number> -n $NAMESPACE
```

## Решение проблем

### Проблема: Поды не запускаются

**Диагностика:**

```bash
# Проверьте статус подов
kubectl get pods -n $NAMESPACE

# Проверьте события
kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp'

# Проверьте описание пода
kubectl describe pod <pod-name> -n $NAMESPACE

# Проверьте логи
kubectl logs <pod-name> -n $NAMESPACE
```

**Возможные причины:**
- Недостаточно ресурсов в кластере
- Проблемы с PersistentVolume
- Неправильная конфигурация
- Проблемы с образами

### Проблема: Поды в состоянии ImagePullBackOff

**Решение:**

1. Проверьте доступность образа:

```bash
kubectl describe pod <pod-name> -n $NAMESPACE | grep -A 5 Events
```

2. Если используется приватный registry, настройте imagePullSecrets:

```bash
# Создайте secret для registry
kubectl create secret docker-registry regcred \
  --docker-server=<registry-url> \
  --docker-username=<username> \
  --docker-password=<password> \
  -n $NAMESPACE

# Добавьте в values.override.yaml
imagePullSecrets:
  - name: regcred
```

### Проблема: Ошибка "field is immutable" при обновлении

Эта ошибка возникает при попытке изменить неизменяемые поля в Deployment.

**Решение:**

```bash
# Удалите Deployments перед обновлением
kubectl delete deployments --namespace=$NAMESPACE -l app=cvat-app

# Затем выполните обновление
helm upgrade $RELEASE_NAME ./helm-chart \
  -n $NAMESPACE \
  -f ./helm-chart/values.yaml \
  -f ./helm-chart/values.override.yaml
```

### Проблема: PostgreSQL не подключается

**Диагностика:**

```bash
# Проверьте статус PostgreSQL
kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=postgresql

# Проверьте логи PostgreSQL
kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=postgresql

# Проверьте секреты
kubectl get secrets -n $NAMESPACE | grep postgres
```

**Решение:**
- Убедитесь, что пароли правильно установлены в `values.override.yaml`
- Проверьте, что PostgreSQL pod запущен и готов
- Проверьте сетевую связность между подами

### Проблема: Не могу подключиться к MinIO

**Диагностика:**

1. Проверьте доступность MinIO из пода:

```bash
# Зайдите в backend pod
kubectl exec -it -n $NAMESPACE <backend-pod-name> -c cvat-backend -- /bin/bash

# Попробуйте подключиться к MinIO
curl -v http://your-minio-server:9000
```

2. Проверьте DNS разрешение:

```bash
kubectl exec -it -n $NAMESPACE <backend-pod-name> -c cvat-backend -- nslookup your-minio-server
```

**Решение:**
- Убедитесь, что MinIO доступен из кластера
- Проверьте firewall правила
- Для локального MinIO используйте правильный адрес (host.docker.internal, minikube ip и т.д.)
- Проверьте правильность endpoint URL в конфигурации cloud storage

### Проблема: PersistentVolume не создается

**Диагностика:**

```bash
# Проверьте PVC
kubectl get pvc -n $NAMESPACE

# Проверьте описание PVC
kubectl describe pvc <pvc-name> -n $NAMESPACE

# Проверьте StorageClass
kubectl get storageclass
```

**Решение:**
- Убедитесь, что в кластере настроен StorageClass
- Укажите правильный `storageClassName` в `values.override.yaml`
- Проверьте, что в кластере достаточно ресурсов для создания PV

### Проблема: Ingress не работает

**Диагностика:**

```bash
# Проверьте Ingress
kubectl get ingress -n $NAMESPACE

# Проверьте описание Ingress
kubectl describe ingress -n $NAMESPACE

# Проверьте ingress controller
kubectl get pods -n <ingress-controller-namespace>
```

**Решение:**
- Убедитесь, что ingress controller установлен и работает
- Проверьте правильность `className` в конфигурации
- Для Minikube включите ingress addon: `minikube addons enable ingress`
- Проверьте DNS записи для вашего домена

### Проблема: Высокое использование ресурсов

**Решение:**

1. Настройте лимиты ресурсов в `values.override.yaml`:

```yaml
cvat:
  backend:
    server:
      resources:
        requests:
          memory: "2Gi"
          cpu: "1000m"
        limits:
          memory: "4Gi"
          cpu: "2000m"
```

2. Уменьшите количество реплик, если ресурсов не хватает
3. Используйте HorizontalPodAutoscaler для автоматического масштабирования

### Получение дополнительной информации

Для получения более подробной информации:

```bash
# Полная информация о release
helm get all $RELEASE_NAME -n $NAMESPACE

# Манифесты ресурсов
helm get manifest $RELEASE_NAME -n $NAMESPACE

# Значения конфигурации
helm get values $RELEASE_NAME -n $NAMESPACE
```

## Полезные команды

### Мониторинг

```bash
# Следить за логами всех подов
kubectl logs -f -n $NAMESPACE -l app=cvat-app

# Следить за статусом подов
watch kubectl get pods -n $NAMESPACE

# Использование ресурсов
kubectl top pods -n $NAMESPACE
kubectl top nodes
```

### Управление данными

```bash
# Резервное копирование PostgreSQL
kubectl exec -n $NAMESPACE <postgresql-pod> -- pg_dump -U cvat cvat > backup.sql

# Восстановление из backup
kubectl exec -i -n $NAMESPACE <postgresql-pod> -- psql -U cvat cvat < backup.sql

# Просмотр размера PVC
kubectl get pvc -n $NAMESPACE
```

### Очистка

```bash
# Удаление release (ВНИМАНИЕ: удалит все данные!)
helm uninstall $RELEASE_NAME -n $NAMESPACE

# Удаление namespace (удалит все ресурсы в namespace)
kubectl delete namespace $NAMESPACE
```

## Дополнительные ресурсы

- Официальная документация CVAT: https://docs.cvat.ai/
- Документация Helm: https://helm.sh/docs/
- Kubernetes документация: https://kubernetes.io/docs/
- CVAT GitHub: https://github.com/cvat-ai/cvat

## Поддержка

Если вы столкнулись с проблемами, которые не описаны в этом руководстве:

1. Проверьте официальную документацию CVAT
2. Проверьте issues на GitHub
3. Обратитесь в сообщество CVAT

---

Примечание: Это руководство предназначено для развертывания CVAT в production-подобном окружении. Для production развертывания обязательно:
- Используйте конкретные версии образов (не `dev` тег)
- Настройте правильные лимиты ресурсов
- Настройте мониторинг и алертинг
- Настройте резервное копирование
- Используйте безопасные пароли
- Настройте TLS для всех внешних соединений
- Настройте сетевые политики
- Регулярно обновляйте компоненты

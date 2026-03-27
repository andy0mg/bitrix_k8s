# Bitrix24 в Kubernetes

Набор манифестов для деплоя **1С-Битрикс24** в Kubernetes.
Используются официальные образы [bitrix-tools/env-docker](https://github.com/bitrix-tools/env-docker).

## Архитектура

```
Ingress TLS (YOUR_DOMAIN)
│
├── / ──────────────────────────► bitrix-web (ClusterIP :80)
│                                   │
│   Web Deployment (3 реплики + HPA)
│   ┌────────────────────────────────────────────┐
│   │  Pod 1 / Pod 2 / Pod 3                     │
│   │  ┌──────────┐ ┌──────────┐ ┌───────────┐  │
│   │  │  nginx   │ │ php-fpm  │ │ memcached │  │
│   │  │:80       │ │:9000     │ │:11211     │  │
│   │  └──────────┘ └──────────┘ └───────────┘  │
│   └────────────────────────────────────────────┘
│           │              │            │
│           │         /opt/www (RWX PVC)│
│           │              │            │
│           │         postgres:5432     │
│           │              │            │
│           │    memcached-headless ────┘
│           │    (headless Service → all pod IPs,
│           │     consistent hashing)
│
├── /bitrix/sub/ ───────────────► bitrix-push-sub :80 (→8893)
│                                   │
└── /bitrix/pub/ ───────────────► bitrix-push-pub :80 (→8895)
                                    │
                                 redis:6379
                                 (Push транспорт)

CronJob (каждую минуту)
  └── php cron_events.php ──────► /opt/www (RWX PVC) + postgres:5432

Sphinx :9306 ◄──────────────────── php-fpm (поисковые запросы)
```

### Сервисы и образы

| Сервис | Образ | Назначение |
|---|---|---|
| nginx (sidecar) | `bitrix24/nginx:1.28.2-v1-alpine` | Веб-сервер |
| php-fpm (sidecar) | `quay.io/bitrix24/php:8.2.30-fpm-v1-alpine` | PHP 8.2 |
| memcached (sidecar) | `memcached:1.6.41-alpine` | Кеш + сессии |
| postgres | `postgres:16.13-trixie` | База данных |
| redis | `redis:8.2.5-alpine` | Транспорт Push |
| push-pub | `bitrix24/push:3.2-v1-alpine` | Push публикация |
| push-sub | `bitrix24/push:3.2-v1-alpine` | Push подписка |
| sphinx | `bitrix24/sphinx:2.2.11-v2-alpine` | Полнотекстовый поиск |
| cronjob | `quay.io/bitrix24/php:8.2.30-fpm-v1-alpine` | Агенты Битрикс |

### Memcached как кластер

Каждый веб-под содержит `memcached` sidecar. Headless Service `memcached-headless` возвращает DNS-записью IP всех подов. PHP-расширение `memcache` подключается к ним через consistent hashing — ключи детерминировано распределяются по экземплярам. При масштабировании HPA новый под автоматически попадает в пул через DNS TTL.

Сессии используют режим `separated`: токен авторизации хранится в зашифрованной cookie (не зависит от пода), данные сессии — в memcached.

---

## Структура репозитория

```
helm/bitrix/                Helm chart (рекомендуемый деплой)
├── Chart.yaml
├── values.yaml              self-hosted / production
├── values-minikube.yaml    локальная разработка
├── NOTES.txt
└── templates/               манифесты с шаблонами

k8s/
├── 00-namespace.yaml       Namespace "bitrix"
├── secret.yaml             Шаблон Secret (пароли БД, Redis, Push)
├── pvc-www.yaml            PVC ReadWriteMany для /opt/www
├── postgres.yaml           PostgreSQL StatefulSet + Services + PVC
├── redis.yaml              Redis Deployment + Service
├── sphinx.yaml             Sphinx ConfigMap + PVC + Deployment + Service
├── push-pub.yaml           Push-pub Deployment + Service
├── push-sub.yaml           Push-sub Deployment + Service
├── configmap-nginx.yaml    nginx default.conf для Битрикс
├── configmap-php.yaml      php.ini (лимиты, OPcache, timezone)
├── web.yaml                Web Deployment (3 контейнера) + 2 Services
├── ingress.yaml            Ingress TLS с маршрутами Push
├── hpa.yaml                HorizontalPodAutoscaler (min:3, max:10)
├── cronjob.yaml            CronJob агентов (каждую минуту)
└── settings-template.php  Шаблон /bitrix/.settings.php

automation/                 Ansible + скрипты
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/hosts.yml.example
│   ├── group_vars/all.yml.example
│   ├── playbooks/
│   │   ├── site.yml              # по умолчанию: kubeadm + NFS + Helm + Bitrix
│   │   ├── site-k3s.yml          # опционально: k3s вместо kubeadm
│   │   ├── kubeadm-bootstrap.yml
│   │   ├── k3s-bootstrap.yml
│   │   └── cluster-common.yml    # NFS, аддоны, Helm Bitrix
│   ├── roles/nfs_server/       # NFS (nfs-kernel-server), вызывается из cluster-common.yml
│   └── templates/
└── scripts/
    ├── init-ansible-config.sh
    └── helm-deploy-from-kubeconfig.sh
```

---

## С нуля до работающего сайта (пошагово)

Ниже — один сквозной сценарий: **ваш ноутбук/ПК** гоняет Ansible по SSH, на **ВМ** поднимается Kubernetes (kubeadm), NFS и Bitrix в кластере.

### 0. Что должно быть заранее

- Несколько **виртуальных машин с Ubuntu 22.04** (или Debian). Минимально разумно: **2 ВМ** — одна под кластер (control plane), вторая под **NFS**. Лучше ещё **1–2 ВМ worker**, иначе поды с Битриксом на master **не запустятся** (на control plane по умолчанию стоит taint `NoSchedule`).
- У всех ВМ **статичные IP**, доступ по **SSH** с вашей машины (логин с `sudo` без пароля или знайте пароль sudo).
- На **вашей машине** (Linux, macOS или **WSL** в Windows): установлены **Git**, **Ansible**, **kubectl**, **Helm**. На Ubuntu/Debian проще всего поставить **ansible-core** из репозитория дистрибутива:
  ```bash
  sudo apt update && sudo apt install -y git ansible-core curl
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  ```
  На **ARM64** в URL замените `amd64` на `arm64`. Если Ansible запускаете **на отдельной ВМ** (бастионе), поставьте `helm` и `kubectl` **на неё**, а не только на ноды кластера.  
  Нужна более свежая версия Ansible — тогда `pip install --user ansible` (потребуется `python3-pip`).
- **Домен** для сайта (например `bitrix.company.ru`) желателен для TLS. Пока можно работать по **IP** (см. шаг 9) — Let’s Encrypt по IP не выдаст, тогда в `group_vars/all.yml` отключите TLS для теста или используйте свой сертификат позже.

### 1. Склонировать проект

```bash
git clone https://github.com/andy0mg/bitrix_k8s.git
cd bitrix_k8s
```

(Либо свой форк/репозиторий — главное, чтобы был каталог с `automation/ansible`.)

### 2. Подготовить конфиги Ansible

```bash
bash automation/scripts/init-ansible-config.sh
```

Откройте в редакторе:

1. **`automation/ansible/inventory/hosts.yml`** (скопирован из примера).  
   - `k8s_control` — **одна** ВМ, с неё будет `kubeadm init`. Укажите **`ansible_host`** = её IP.  
   - `k8s_workers` — **остальные** ВМ под приложения (рекомендуется). У каждой свой `ansible_host`.  
   - `nfs_server` — ВМ с NFS (можно отдельная).  
   - Группа **`ansible_controller`** с хостом **`deploy`** (`ansible_connection: local`) оставьте как в примере: так inventory валиден для любой версии Ansible; `group_vars` на плеях `localhost` всё равно подгружается через `include_vars` в плейбуке.  
   - Везде один и тот же `ansible_user` (например `ubuntu`), если логин одинаковый.

2. **`automation/ansible/group_vars/all.yml`** (скопирован из примера). Обязательно поменяйте:
   - **`bitrix_domain`** — ваш домен (или временно IP вида `192.168.1.10.nip.io`, если используете nip.io для теста).
   - **`k8s_join_workers: true`**, если в inventory есть worker-ноды.
   - **`kubeadm_kubeconfig_public_address`** — **тот же IP**, что у первой control plane, **как с вашего ПК достигается API** (часто внешний/локальный IP первой ВМ). Нужен для файла `kubeconfig` на вашей машине.
   - **`letsencrypt_email`** — реальный email для сертификата (если TLS включён).

Для **кластера без workers** (только один master): после установки **снимите taint**, иначе поды не встанут:

```bash
export KUBECONFIG=$PWD/automation/build/kubeconfig
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-
```

(Лучше всё же добавить хотя бы одну worker-ВМ и `k8s_join_workers: true`.)

### 3. Запустить полный деплой

```bash
cd automation/ansible
ansible-playbook playbooks/site.yml
```

Ansible по очереди: подготовит ноды, **kubeadm init**, сеть **Flannel**, при необходимости **join** workers, положит **`../../automation/build/kubeconfig`**, настроит **NFS**, поставит **ingress / nfs-client provisioner / metrics / cert-manager** и **Helm chart Bitrix**.

Время — от **15–40 минут**, зависимо от сети и железа.

### 4. Проверить кластер и Bitrix

```bash
export KUBECONFIG="$(pwd)/../../automation/build/kubeconfig"
kubectl get nodes
kubectl get pods -n bitrix
```

Все поды в `bitrix` должны стать **Running** (PostgreSQL и веб могут стартовать дольше).

Пароли БД/Redis лежат в **`automation/build/bitrix-secrets.yaml`** (файл в `.gitignore`).

### 5. Как открыть сайт в браузере

- Узнайте IP, на котором висит **Ingress** (по умолчанию Ansible ставит **ingress-nginx на control-plane** ноды — см. `ingress_nginx_on_control_plane` в `group_vars`):
  ```bash
  kubectl get svc -n ingress-nginx
  ```
  Если **EXTERNAL-IP** пустой — на «голом» железе поставьте **MetalLB** или смотрите **NodePort** и заходите `http://IP-ноды:NodePort` (в зависимости от сервиса; для учебника проще поднять MetalLB или один внешний L4).

- Пропишите **DNS**: имя из **`bitrix_domain`** → IP Ingress (или в файл `hosts` на своём ПК для теста).

- Откройте **`https://ваш-домен/`** (или **http** если TLS отключали). Мастер установки может быть по **`/bitrixsetup.php`** — смотрите раздел «Первичная установка» ниже в README.

### 6. Если что-то пошло не так

- **`ansible-playbook` падает на SSH** — проверьте ключи: `ssh ubuntu@IP` с той же машины.  
- **`pending` у PVC** — нет StorageClass **nfs-client** или NFS недоступен с нод. Проверьте экспорт на ВМ NFS и Helm **nfs-subdir-external-provisioner**.  
- **Поды не на нодах** — taint на master и нет workers; см. шаг 2.  
- **`Установить ingress-nginx` долго крутится** — Helm ждёт hook Job (admission webhook). На закинутом control-plane без workers Job мог быть **Pending**, если не хватает tolerations; в чарте для этого добавлены `admissionWebhooks.patch` в values. Параллельно: `kubectl get pods,job -n ingress-nginx`. Таймаут Helm: **`helm_install_timeout`** в `group_vars`.  
- **`Установить cert-manager` зависает** — то же: post-install **startupapicheck** Job и поды webhook ждут ноду; при **только control-plane** в `automation/build/cert-manager-values.yaml` задаются tolerations (по умолчанию синхронно с **`ingress_nginx_on_control_plane`**). Смотреть: `kubectl get pods,job -n cert-manager`.  
- **Сертификат Let’s Encrypt не выдаётся** — порт **80** с интернета до Ingress и корректный **DNS** на этот IP.

### 7. Не хотите Ansible — только Helm

Если Kubernetes у вас уже есть и есть **kubeconfig**:

```bash
export KUBECONFIG=/путь/к/admin.conf
LE_EMAIL=you@mail.com bash automation/scripts/helm-deploy-from-kubeconfig.sh ваш-домен.ru
```

(Предварительно в кластере должны быть **RWX** StorageClass, **ingress-nginx** и при TLS — **cert-manager** по желанию.)

---

## Автоматизация деплоя

Нужны: **Ansible**, **Helm** и **kubectl** на **той же машине**, откуда вызываете `ansible-playbook` (плейи `addons`/`bitrix` идут на `localhost`). Если запускаете Ansible на отдельном бастионе/ВМ — поставьте клиенты там. **SSH** к Ubuntu/Debian ВМ кластера. По умолчанию **`playbooks/site.yml`** поднимает **Kubernetes через kubeadm** (containerd, официальный apt kubernetes, **Flannel**), сохраняет `automation/build/kubeconfig`, при необходимости настраивает **NFS**, затем через **Helm** — ingress-nginx, nfs-subdir-external-provisioner, metrics-server, cert-manager и чарт **Bitrix**. Вместо kubeadm можно использовать **k3s**: `ansible-playbook playbooks/site-k3s.yml` (в `group_vars` для metrics часто нужно `metrics_server_patch_kubelet_insecure_tls: true`).

### Быстрый старт (kubeadm)

```bash
bash automation/scripts/init-ansible-config.sh
# inventory: группы k8s_control, k8s_workers, nfs_server; all.yml — домен, k8s_join_workers и т.д.
cd automation/ansible
ansible-playbook playbooks/site.yml
```

Точечно (теги): например `--tags kubeadm`, `--tags nfs`, `--tags addons`, `--tags bitrix`. Уже есть кластер и `automation/build/kubeconfig`: `--tags nfs,addons,bitrix` или только `--tags bitrix`.

### Только Helm при готовом кластере

```bash
export KUBECONFIG=/path/to/kubeconfig
LE_EMAIL=you@example.com bash automation/scripts/helm-deploy-from-kubeconfig.sh portal.example.com
```

Пароли сохраняются в `automation/build/bitrix-secrets.yaml` (каталог в `.gitignore`).

**Ограничения:** узлы кластера и NFS — **Debian/Ubuntu** (`apt`). **HA control plane** (несколько master) автоматом не собирается: задайте `kubeadm_control_plane_endpoint` и добавьте остальные CP по [документации kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/). Для bare-metal **Ingress** часто нужен L4 или **MetalLB**. Домен должен указывать на IP Ingress до Let’s Encrypt.

---

## Предварительные требования

- Kubernetes 1.24+
- [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) или другой Ingress-контроллер
- [metrics-server](https://github.com/kubernetes-sigs/metrics-server) (для HPA)
- StorageClass с поддержкой **ReadWriteMany** (NFS, CephFS, Longhorn RWX, Azure Files, EFS и т.д.)
- TLS-сертификат для домена (cert-manager или ручной)

---

## Деплой через Helm

Чарт: [`helm/bitrix`](helm/bitrix/). Релиз ставится в namespace (рекомендуется `bitrix`), имя Secret с паролями по умолчанию — `bitrix`.

### Параметры values

| Параметр | Назначение |
|----------|------------|
| `global.domain` | Домен в Ingress и для `bitrixsetup.php` |
| `global.storageClass.rwx` | StorageClass с **ReadWriteMany** для `bitrix-www` |
| `global.storageClass.rwo` | **ReadWriteOnce** для PostgreSQL / Sphinx (пусто = default SC) |
| `secrets.*` | Пароли БД, Redis, `pushSecurityKey` (128 символов) |
| `web.replicaCount` | Реплики веба (в Minikube — 1) |
| `wwwBootstrap` | Скачивание и распаковка дистрибутива в `/opt/www` при первом старте (`url`, `stripComponents`, `sha256sum`, `enabled`) |
| `hpa.enabled` | Включить HPA (в Minikube — `false`) |
| `ingress.tls.enabled` / `ingress.tls.certManager` | TLS и Let's Encrypt через cert-manager |
| `certManager.createClusterIssuer` | Создать ClusterIssuer в кластере |

### Сценарий A: свои VM / Kubernetes (kubeadm или иной кластер)

1. Подготовьте кластер (например `ansible-playbook playbooks/site.yml` или свой **kubeadm**/дистрибутив), **NFS + nfs-subdir-external-provisioner** или другой RWX StorageClass, **ingress-nginx**, при необходимости **cert-manager**, **metrics-server**.
2. Сгенерируйте секреты и установите чарт:

```bash
helm install bitrix ./helm/bitrix -n bitrix --create-namespace \
  --set global.domain=example.com \
  --set global.storageClass.rwx=nfs-client \
  --set global.storageClass.rwo=longhorn \
  --set secrets.postgresPassword="$(openssl rand -base64 24)" \
  --set secrets.redisPassword="$(openssl rand -base64 24)" \
  --set secrets.pushSecurityKey="$(cat /dev/urandom | tr -dc A-Za-z0-9 | head -c 128)"
```

Опционально файл с секретами (не коммитьте в git):

```bash
# secrets-local.yaml
secrets:
  postgresPassword: "..."
  redisPassword: "..."
  pushSecurityKey: "..."

helm install bitrix ./helm/bitrix -n bitrix --create-namespace -f secrets-local.yaml --set global.domain=example.com
```

TLS вручную (без cert-manager):

```bash
kubectl create secret tls bitrix-tls --cert=fullchain.pem --key=privkey.pem -n bitrix
helm install bitrix ./helm/bitrix -n bitrix --create-namespace \
  --set global.domain=example.com \
  --set ingress.tls.enabled=true \
  --set ingress.tls.secretName=bitrix-tls \
  --set ingress.tls.certManager.enabled=false
```

Let's Encrypt через cert-manager (включите создание ClusterIssuer и совпадающее имя issuer):

```yaml
# extra-le.yaml или --set
certManager:
  createClusterIssuer: true
  clusterIssuer:
    name: letsencrypt-prod
    email: you@example.com
ingress:
  tls:
    enabled: true
    secretName: bitrix-tls
    certManager:
      enabled: true
      clusterIssuer: letsencrypt-prod
```

### Сценарий B: Minikube

```bash
minikube start --driver=hyperv --memory=4096 --cpus=4   # или ваш driver
minikube addons enable ingress
minikube addons enable metrics-server

# В отдельном терминале (для LoadBalancer IP при необходимости):
minikube tunnel

PUSH_KEY=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 128)   # Git Bash / Linux / macOS
helm install bitrix ./helm/bitrix -n bitrix --create-namespace \
  -f ./helm/bitrix/values-minikube.yaml \
  --set global.domain="$(minikube ip).nip.io" \
  --set secrets.postgresPassword="$(openssl rand -base64 18)" \
  --set secrets.redisPassword="$(openssl rand -base64 18)" \
  --set secrets.pushSecurityKey="$PUSH_KEY"
```

> В чистом PowerShell без `/dev/urandom` удобнее задать секреты через `-f secrets-local.yaml`.

На Minikube PVC сайта в профиле values — **ReadWriteOnce** и **одна** реплика веба (без HPA), TLS в Ingress отключён; откройте `http://<domain>/bitrixsetup.php`.

### Обновление релиза

```bash
helm upgrade bitrix ./helm/bitrix -n bitrix -f your-values.yaml
```

Образ PHP и веб меняются в `values.yaml` (`images.php`, `images.nginx` и т.д.).

---

## Деплой (манифесты kubectl)

### 1. Заполните секреты

Откройте `k8s/secret.yaml` и замените все значения `CHANGE_ME_*`:

```yaml
stringData:
  POSTGRES_PASSWORD: "ВашСильныйПароль"
  REDIS_PASSWORD:    "ВашСильныйПароль"
  PUSH_SECURITY_KEY: "128-символьный-случайный-ключ"
```

Сгенерировать значения:
```bash
# Пароль (24 символа)
openssl rand -base64 24

# PUSH_SECURITY_KEY (128 символов)
cat /dev/urandom | tr -dc A-Za-z0-9 | head -c 128 && echo
```

### 2. Укажите StorageClass для RWX

В `k8s/pvc-www.yaml` замените `CHANGE_ME_RWX_STORAGECLASS`:
```yaml
storageClassName: "nfs-client"   # ваш RWX StorageClass
```

### 3. Укажите домен в Ingress

В `k8s/ingress.yaml` замените `YOUR_DOMAIN`:
```yaml
tls:
  - hosts: ["example.com"]
    secretName: bitrix-tls
rules:
  - host: example.com
```

Создайте TLS-секрет (если не используете cert-manager):
```bash
kubectl create secret tls bitrix-tls \
  --cert=fullchain.pem \
  --key=privkey.pem \
  -n bitrix
```

### 4. Замените пароль PG в sphinx.conf

В `k8s/sphinx.yaml` в блоке ConfigMap замените `CHANGE_ME_POSTGRES_PASSWORD`:
```yaml
sql_pass = ВашПарольPostgres
```

### 5. Примените манифесты

```bash
# Namespace создаётся первым
kubectl apply -f k8s/00-namespace.yaml

# Secrets, PVC и ConfigMap
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/pvc-www.yaml
kubectl apply -f k8s/configmap-nginx.yaml
kubectl apply -f k8s/configmap-php.yaml

# Данные
kubectl apply -f k8s/postgres.yaml
kubectl apply -f k8s/redis.yaml
kubectl apply -f k8s/sphinx.yaml

# Push
kubectl apply -f k8s/push-pub.yaml
kubectl apply -f k8s/push-sub.yaml

# Веб + автомасштабирование
kubectl apply -f k8s/web.yaml
kubectl apply -f k8s/hpa.yaml
kubectl apply -f k8s/ingress.yaml

# Крон
kubectl apply -f k8s/cronjob.yaml
```

Или одной командой (порядок по алфавиту — namespace применится первым):
```bash
kubectl apply -f k8s/
```

### 6. Проверьте статус

```bash
kubectl get pods -n bitrix
kubectl get pvc  -n bitrix
kubectl get ingress -n bitrix
```

Все поды должны перейти в `Running`. Postgres и Sphinx могут стартовать дольше остальных.

---

## Первичная установка Битрикс

По умолчанию (Helm `wwwBootstrap.enabled: true` и манифест `k8s/web.yaml`) init-контейнер один раз скачивает архив **bitrix24_enterprise_postgresql_encode.tar.gz** с сайта 1С-Битрикс и распаковывает его в `/opt/www` (при нескольких репликах используется блокировка на томе). Повторный запуск пропускается, если есть маркер `.bitrix-portal-extracted` или непустой `bitrix/`. Отключить: в values задайте `wwwBootstrap.enabled: false` или уберите init `fetch-portal-archive` из `k8s/web.yaml`.

После того как все поды запущены и PVC `bitrix-www` примонтирован:

```bash
# Подключитесь к php-fpm поду
kubectl exec -it -n bitrix deployment/bitrix-web -c php-fpm -- sh

# Если ставили только bitrixsetup.php без полного дистрибутива — скачайте установщик:
cd /opt/www
wget https://www.1c-bitrix.ru/download/scripts/bitrixsetup.php
# или для восстановления из бэкапа:
wget https://www.1c-bitrix.ru/download/scripts/restore.php
```

Откройте в браузере `https://YOUR_DOMAIN/bitrixsetup.php` и пройдите мастер.

При настройке БД используйте:
- Хост: `postgres`
- Пользователь: `bitrix`
- Пароль: из `secret.yaml`
- База данных: `bitrix`

После установки скопируйте шаблон `.settings.php`:
```bash
kubectl cp k8s/settings-template.php \
  bitrix/$(kubectl get pod -n bitrix -l app=bitrix-web -o jsonpath='{.items[0].metadata.name}'):/opt/www/bitrix/.settings.php
```

Замените в нём `YOUR_DOMAIN`, пароли и `PUSH_SECURITY_KEY`.

---

## Настройка после установки

### Агенты на cron

Добавьте в `/opt/www/bitrix/php_interface/dbconn.php`:
```php
define("BX_CRONTAB_SUPPORT", true);
define("BX_TEMPORARY_FILES_DIRECTORY", "/opt/.bx_temp");
```

### Sphinx (полнотекстовый поиск)

1. `/bitrix/admin/settings.php?mid=search` → Морфология → **Sphinx**
2. Строка подключения: `sphinx:9306`
3. Запустите переиндексацию: `/bitrix/admin/search_reindex.php?lang=ru`

### Push-сервер

Параметры автоматически берутся из `settings-template.php` (блок `pull`).
Проверка: `/bitrix/admin/site_checker.php?lang=ru` → вкладка **Работа портала**.

> **Важно:** имена переменных среды push-сервера (`REDIS_ADDR`, `SECURITY_KEY`, `LISTEN_ADDR`, `MODE`)
> соответствуют образу `bitrix24/push:3.2-v1-alpine`. При несоответствии уточните актуальные имена:
> ```bash
> docker run --rm bitrix24/push:3.2-v1-alpine --help
> ```

### Масштабирование

HPA автоматически добавляет/убирает поды при нагрузке:
- Порог CPU: 70%
- Порог памяти: 80%
- Min: 3 реплики, Max: 10

Каждая новая реплика автоматически получает свой memcached sidecar и включается в пул через headless Service `memcached-headless`.

---

## Обновление

### PHP-образ (например, 8.2 → 8.3)

**Helm:** в `helm/bitrix/values.yaml` (или через `--set`) обновите `images.php`, затем:

```bash
helm upgrade bitrix ./helm/bitrix -n bitrix
```

**Манифесты kubectl:** в `k8s/web.yaml` и `k8s/cronjob.yaml` замените тег образа:
```yaml
image: quay.io/bitrix24/php:8.3.30-fpm-v1-alpine
```

Обновите ConfigMap php с путём к конфигам (если нужно для 8.3):
```yaml
# k8s/configmap-php.yaml — конфиги остаются те же
```

Примените изменения:
```bash
kubectl apply -f k8s/web.yaml
kubectl apply -f k8s/cronjob.yaml
kubectl rollout status deployment/bitrix-web -n bitrix
```

---

## Резервное копирование

```bash
# Снапшот PVC PostgreSQL (через VolumeSnapshot, если поддерживается CSI)
kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: postgres-backup-$(date +%Y%m%d)
  namespace: bitrix
spec:
  volumeSnapshotClassName: csi-snapclass
  source:
    persistentVolumeClaimName: postgres-data-postgres-0
EOF

# Дамп PostgreSQL вручную
kubectl exec -n bitrix statefulset/postgres -- \
  pg_dump -U bitrix bitrix | gzip > bitrix_db_$(date +%Y%m%d).sql.gz

# Резервная копия файлов сайта (с пода)
kubectl exec -n bitrix deployment/bitrix-web -c php-fpm -- \
  tar czf /tmp/www_backup.tar.gz /opt/www
kubectl cp bitrix/$(kubectl get pod -n bitrix -l app=bitrix-web \
  -o jsonpath='{.items[0].metadata.name}'):/tmp/www_backup.tar.gz ./
```

#!/usr/bin/env bash
# Деплой только Bitrix chart при уже готовом кластере и kubeconfig.
# Использование:
#   export KUBECONFIG=/path/to/kubeconfig
#   LE_EMAIL=you@example.com ./helm-deploy-from-kubeconfig.sh portal.example.com
# Одна нода с taint на master (по умолчанию): tolerations в extra-values. Отключить: BITRIX_ON_CONTROL_PLANE=false
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOMAIN="${1:?Укажите домен FQDN, например portal.example.com}"
NS="${NS:-bitrix}"
REL="${REL:-bitrix}"
RWX="${RWX:-nfs-client}"
RWO="${RWO:-}"
: "${LE_EMAIL:=admin@example.com}"
: "${BITRIX_ON_CONTROL_PLANE:=true}"

if ! command -v helm >/dev/null 2>&1; then
  echo "Нужен helm в PATH" >&2
  exit 1
fi
if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "Задайте KUBECONFIG" >&2
  exit 1
fi

BUILD="$ROOT/automation/build"
mkdir -p "$BUILD"
SECRETS="$BUILD/bitrix-secrets.yaml"
EXTRA="$BUILD/bitrix-extra-values.sh.yaml"

PG="$(openssl rand -base64 24)"
RD="$(openssl rand -base64 24)"
PU="$(openssl rand -hex 64)"

umask 077
cat >"$SECRETS" <<EOF
secrets:
  postgresPassword: "$PG"
  redisPassword: "$RD"
  pushSecurityKey: "$PU"
EOF

RWO_LINE=""
if [[ -n "$RWO" ]]; then
  RWO_LINE="    rwo: \"$RWO\""
fi

CP_BLOCK=""
if [[ "${BITRIX_ON_CONTROL_PLANE}" == "true" ]]; then
  CP_BLOCK="  nodeSelector:
    node-role.kubernetes.io/control-plane: \"\"
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
    - key: node-role.kubernetes.io/master
      operator: Exists
      effect: NoSchedule
"
fi

cat >"$EXTRA" <<EOF
global:
  domain: "$DOMAIN"
  storageClass:
    rwx: "$RWX"
$RWO_LINE
$CP_BLOCK
createNamespace: false
ingress:
  enabled: true
  className: nginx
  tls:
    enabled: true
    secretName: bitrix-tls
    certManager:
      enabled: true
      clusterIssuer: letsencrypt-prod
certManager:
  createClusterIssuer: true
  clusterIssuer:
    name: letsencrypt-prod
    email: "$LE_EMAIL"
    server: https://acme-v02.api.letsencrypt.org/directory
EOF
umask 022

helm upgrade --install "$REL" "$ROOT/helm/bitrix" \
  --namespace "$NS" --create-namespace \
  -f "$SECRETS" -f "$EXTRA"

echo "Пароли БД/Redis/Push: $SECRETS (файл в .gitignore)."

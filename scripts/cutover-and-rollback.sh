#!/usr/bin/env bash
# Atomic cutover from legacy hosting panel web stack to Coolify proxy with automatic rollback.
# Never stops protected services (mysql, mariadb, postgresql, redis, exim, postfix, dovecot, ftp, sshd).

set -euo pipefail

MODE="dry-run"
BACKUP_DIR="/var/backups/coolify-migration-latest"
DOMAINS=""
STOP_SERVICES=""
STOP_FOREVER=""
STOP_PM2=""
START_CONTAINERS=""
PROXY_CONTAINER="coolify-proxy"
PROXY_COMPOSE_DIR="/data/coolify/proxy"
EXPECT_CODES="200,204,301,302,307,308"

PROTECTED_REGEX='^(mysql|mysqld|mariadb|postgresql.*|redis.*|exim.*|postfix|dovecot|proftpd|pure-ftpd|vsftpd|ssh|sshd|ufw|iptables|nftables|docker)$'

usage() {
  cat <<EOF
Usage: cutover-and-rollback.sh [--dry-run|--apply|--rollback] --backup-dir DIR --domains "d1,d2" [options]
Options:
  --dry-run                    Print exact plan without changing anything (default)
  --apply                      Execute cutover; auto-rollback if live HTTPS probes fail
  --rollback                   Immediately stop coolify-proxy and restore legacy web services
  --backup-dir DIR             Backup directory containing MANIFEST.env
  --domains "a.com,b.com"      Comma-separated live domains verified after cutover
  --stop-services "nginx,..."  Host web services to stop/disable (overrides MANIFEST.env)
  --stop-forever "uid1,uid2"   Forever process UIDs/names to stop right before starting API containers
  --stop-pm2 "app1,app2"       PM2 process names to stop right before starting API containers
  --start-containers "c1,c2"   Coolify backend containers to start right after stopping legacy workers
  --proxy-container NAME       Traefik proxy container name (default: coolify-proxy)
  --proxy-compose-dir DIR      Coolify proxy compose dir (default: /data/coolify/proxy)
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --apply) MODE="apply"; shift ;;
    --rollback) MODE="rollback"; shift ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    --domains) DOMAINS="$2"; shift 2 ;;
    --stop-services) STOP_SERVICES="$2"; shift 2 ;;
    --stop-forever) STOP_FOREVER="$2"; shift 2 ;;
    --stop-pm2) STOP_PM2="$2"; shift 2 ;;
    --start-containers) START_CONTAINERS="$2"; shift 2 ;;
    --proxy-container) PROXY_CONTAINER="$2"; shift 2 ;;
    --proxy-compose-dir) PROXY_COMPOSE_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if [ ! -f "${BACKUP_DIR}/MANIFEST.env" ]; then
  echo "ABORT: Backup manifest not found at ${BACKUP_DIR}/MANIFEST.env. Run backup-state.sh first." >&2
  exit 1
fi

# shellcheck disable=SC1090
. "${BACKUP_DIR}/MANIFEST.env"
[ -z "${STOP_SERVICES}" ] && STOP_SERVICES="${ACTIVE_WEB_SERVICES:-}"

IFS=',' read -ra SVC_LIST <<< "${STOP_SERVICES}"
for s in "${SVC_LIST[@]}"; do
  s=$(echo "$s" | xargs)
  [ -z "$s" ] && continue
  if echo "$s" | grep -qE "${PROTECTED_REGEX}"; then
    echo "SECURITY ABORT: Refusing to touch protected service '${s}'." >&2
    exit 1
  fi
done

do_rollback() {
  echo ">>> EXECUTING ROLLBACK TO LEGACY STACK <<<"
  docker stop "${PROXY_CONTAINER}" >/dev/null 2>&1 || true
  if [ -n "${START_CONTAINERS}" ]; then
    IFS=',' read -ra C_LIST <<< "${START_CONTAINERS}"
    for c in "${C_LIST[@]}"; do
      c=$(echo "$c" | xargs)
      [ -n "$c" ] && docker stop "$c" >/dev/null 2>&1 || true
    done
  fi
  for s in "${SVC_LIST[@]}"; do
    s=$(echo "$s" | xargs)
    [ -z "$s" ] && continue
    systemctl enable "$s" >/dev/null 2>&1 || true
    systemctl start "$s" || echo "WARN: Failed to restart $s" >&2
  done
  echo ">>> ROLLBACK COMPLETE: Legacy services restarted (${STOP_SERVICES:-none}). Manual check recommended for forever/pm2 if stopped. <<<"
}

if [ "${MODE}" = "rollback" ]; then
  do_rollback
  exit 0
fi

if [ -z "${DOMAINS}" ]; then
  echo "ABORT: --domains is required for dry-run and apply modes." >&2
  exit 2
fi

echo "=== CUTOVER PLAN (mode=${MODE}) ==="
echo "  Backup Manifest:  ${BACKUP_DIR}/MANIFEST.env (panel=${PANEL_TYPE:-unknown})"
echo "  Stop forever:     ${STOP_FOREVER:-none}"
echo "  Stop pm2:         ${STOP_PM2:-none}"
echo "  Start containers: ${START_CONTAINERS:-none}"
echo "  Stop/Disable web: ${STOP_SERVICES:-none}"
echo "  Start proxy:      ${PROXY_CONTAINER} (${PROXY_COMPOSE_DIR})"
echo "  Verify domains:   ${DOMAINS}"

if [ "${MODE}" = "dry-run" ]; then
  echo "DRY-RUN COMPLETE. Re-run with --apply when ready."
  exit 0
fi

# Verify docker & proxy compose exist before stopping anything
if [ ! -f "${PROXY_COMPOSE_DIR}/docker-compose.yml" ] && ! docker inspect "${PROXY_CONTAINER}" >/dev/null 2>&1; then
  echo "ABORT: Neither ${PROXY_COMPOSE_DIR}/docker-compose.yml nor container ${PROXY_CONTAINER} exists." >&2
  exit 1
fi

trap 'echo "ERROR during cutover! Triggering automatic rollback..."; do_rollback; exit 1' ERR

# Step 1: Stop legacy forever/pm2 processes immediately before starting guarded Coolify API containers
if [ -n "${STOP_FOREVER}" ] && command -v forever >/dev/null 2>&1; then
  IFS=',' read -ra F_LIST <<< "${STOP_FOREVER}"
  for uid in "${F_LIST[@]}"; do
    uid=$(echo "$uid" | xargs)
    [ -n "$uid" ] && forever stop "$uid" || true
  done
  sleep 1
fi

if [ -n "${STOP_PM2}" ] && command -v pm2 >/dev/null 2>&1; then
  IFS=',' read -ra P_LIST <<< "${STOP_PM2}"
  for app in "${P_LIST[@]}"; do
    app=$(echo "$app" | xargs)
    [ -n "$app" ] && pm2 stop "$app" || true
  done
  sleep 1
fi

# Step 2: Start Coolify backend/API containers
if [ -n "${START_CONTAINERS}" ]; then
  IFS=',' read -ra C_LIST <<< "${START_CONTAINERS}"
  for c in "${C_LIST[@]}"; do
    c=$(echo "$c" | xargs)
    [ -n "$c" ] && docker start "$c"
  done
  sleep 2
fi

# Step 3: Stop & disable legacy host HTTP services (so reboot cannot conflict with :80/:443)
for s in "${SVC_LIST[@]}"; do
  s=$(echo "$s" | xargs)
  [ -z "$s" ] && continue
  systemctl disable --now "$s" || true
done

# Step 4: Start Coolify Traefik proxy
if docker inspect "${PROXY_CONTAINER}" >/dev/null 2>&1; then
  docker start "${PROXY_CONTAINER}"
else
  docker compose -f "${PROXY_COMPOSE_DIR}/docker-compose.yml" up -d
fi

sleep 3

# Confirm ports 80 and 443 are listening
if ! ss -tln | grep -qE ':80\s' || ! ss -tln | grep -qE ':443\s'; then
  echo "FAIL: Ports 80/443 are not listening after starting ${PROXY_CONTAINER}!" >&2
  false
fi

# Step 5: Live verification across all declared domains
IFS=',' read -ra D_LIST <<< "${DOMAINS}"
for dom in "${D_LIST[@]}"; do
  dom=$(echo "$dom" | xargs)
  [ -z "$dom" ] && continue
  code=$(curl -skL --max-time 10 --resolve "${dom}:443:127.0.0.1" -o /dev/null -w "%{http_code}" "https://${dom}/" || echo "000")
  ok=0
  IFS=',' read -ra CODES <<< "${EXPECT_CODES}"
  for c in "${CODES[@]}"; do
    [ "$code" = "$c" ] && ok=1 && break
  done
  if [ "$ok" -eq 0 ]; then
    echo "FAIL: Live check failed for https://${dom}/ (HTTP ${code})" >&2
    false
  fi
  echo "  [LIVE OK] https://${dom}/ -> HTTP ${code}"
done

trap - ERR
echo "CUTOVER SUCCEEDED. Next: run stage-verify.sh --target 127.0.0.1:443 to record verification receipt."

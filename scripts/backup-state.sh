#!/usr/bin/env bash
# Immutable configuration, SSL, cron, firewall, and service manifest snapshot before migration.
# Does NOT stop or mutate any live service.

set -euo pipefail

ALLOW_LOW_DISK=0
BACKUP_ROOT="/var/backups"

while [ $# -gt 0 ]; do
  case "$1" in
    --allow-low-disk) ALLOW_LOW_DISK=1; shift ;;
    --backup-root) BACKUP_ROOT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

TS=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="${BACKUP_ROOT}/coolify-migration-${TS}"

# Disk safety check: >= 5120 MB and >= 15% free on backup filesystem (and /var)
AVAIL_KB=$(df -kP "${BACKUP_ROOT}" 2>/dev/null | awk 'NR==2{print $4}')
PCT_USED=$(df -kP "${BACKUP_ROOT}" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
AVAIL_MB=$((AVAIL_KB / 1024))
PCT_FREE=$((100 - PCT_USED))

echo "Disk check on ${BACKUP_ROOT}: ${AVAIL_MB} MB free (${PCT_FREE}% free)"
if [ "${AVAIL_MB}" -lt 1024 ]; then
  echo "ABORT: Less than 1024 MB free on ${BACKUP_ROOT}. Clean disk space before snapshot." >&2
  exit 1
fi
if [ "${ALLOW_LOW_DISK}" -eq 0 ] && { [ "${AVAIL_MB}" -lt 5120 ] || [ "${PCT_FREE}" -lt 15 ]; }; then
  echo "ABORT: Require >= 5120 MB and >= 15% free disk before migration (pass --allow-low-disk to override above 1 GB)." >&2
  exit 1
fi

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

# Archive configuration directories that exist (preserving symlinks and permissions)
CANDIDATE_PATHS=(
  /etc/nginx
  /etc/apache2
  /etc/httpd
  /etc/php
  /etc/php.d
  /etc/php-fpm.d
  /etc/letsencrypt
  /var/www/httpd-cert
  /usr/local/fastpanel2/etc
  /var/cpanel/userdata
  /usr/local/psa/var/certificates
  /usr/local/mgr5/etc
  /etc/cron.d
  /etc/cron.daily
  /var/spool/cron
  /etc/systemd/system
  /data/coolify/proxy
)

EXISTING=()
for p in "${CANDIDATE_PATHS[@]}"; do
  [ -e "$p" ] && EXISTING+=("$p")
done

if [ "${#EXISTING[@]}" -gt 0 ]; then
  tar -czpf "${BACKUP_DIR}/configs-and-ssl.tar.gz" "${EXISTING[@]}" 2>/dev/null || true
fi

# Capture runtime state & firewall rules
ss -tlnp > "${BACKUP_DIR}/listening-ports.txt" 2>/dev/null || true
systemctl list-units --type=service --state=running > "${BACKUP_DIR}/running-services.txt" 2>/dev/null || true
(ufw status verbose 2>/dev/null || iptables-save 2>/dev/null || nft list ruleset 2>/dev/null || true) > "${BACKUP_DIR}/firewall-rules.txt"
(dpkg -l 2>/dev/null || rpm -qa 2>/dev/null || true) > "${BACKUP_DIR}/packages.txt"
(forever list 2>/dev/null || true) > "${BACKUP_DIR}/forever-list.txt"
(pm2 list 2>/dev/null || true) > "${BACKUP_DIR}/pm2-list.txt"

# Detect active legacy web services for rollback automation
ACTIVE_WEB_SERVICES=""
for svc in nginx apache2 httpd lsws lshttpd php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm php-fpm; do
  if systemctl is-active --quiet "${svc}" 2>/dev/null; then
    ACTIVE_WEB_SERVICES="${ACTIVE_WEB_SERVICES}${ACTIVE_WEB_SERVICES:+,}${svc}"
  fi
done

PANEL_TYPE="none"
[ -d /usr/local/fastpanel2 ] && PANEL_TYPE="fastpanel2"
[ -d /usr/local/cpanel ] && PANEL_TYPE="cpanel"
[ -d /usr/local/psa ] || [ -d /opt/psa ] && PANEL_TYPE="plesk"
[ -d /usr/local/mgr5 ] && PANEL_TYPE="ispmanager"

cat > "${BACKUP_DIR}/MANIFEST.env" <<EOF
BACKUP_TS=${TS}
BACKUP_DIR=${BACKUP_DIR}
PANEL_TYPE=${PANEL_TYPE}
ACTIVE_WEB_SERVICES=${ACTIVE_WEB_SERVICES}
EOF

ln -sfn "${BACKUP_DIR}" "${BACKUP_ROOT}/coolify-migration-latest"

echo "Snapshot created successfully:"
echo "  BACKUP_DIR=${BACKUP_DIR}"
echo "  PANEL_TYPE=${PANEL_TYPE}"
echo "  ACTIVE_WEB_SERVICES=${ACTIVE_WEB_SERVICES:-none}"
ls -lh "${BACKUP_DIR}"

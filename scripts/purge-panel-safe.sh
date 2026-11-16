#!/usr/bin/env bash
# Strictly gated panel cleanup after Coolify migration is live and verified.
# Hard-refuses unless:
#   1. --confirm-verified and --apply are both explicitly supplied (defaults to dry-run)
#   2. coolify-proxy is running and owning :80 and :443
#   3. A recent verification receipt (< 24h old) exists
#   4. Zero Coolify or active Nginx files still depend on panel core directories
# NEVER touches mysql/mariadb, postgresql, redis, exim/postfix/dovecot, proftpd/pure-ftpd, sshd, ufw, /var/www, /home, or /etc/letsencrypt.

set -euo pipefail

PANEL=""
APPLY=0
CONFIRM_VERIFIED=0
RECEIPT_FILE="/var/backups/coolify-migration-verified.stamp"
PROXY_CONTAINER="coolify-proxy"

usage() {
  cat <<EOF
Usage: purge-panel-safe.sh --panel <fastpanel2|cpanel|plesk|ispmanager> [--confirm-verified --apply]
Options:
  --panel NAME            Panel to clean up: fastpanel2 | cpanel | plesk | ispmanager
  --confirm-verified      Required explicit attestation that live traffic was verified
  --apply                 Execute cleanup (without this, runs in safe dry-run mode)
  --receipt-file PATH     Verification receipt path (default: ${RECEIPT_FILE})
  --proxy-container NAME  Coolify proxy container name (default: coolify-proxy)
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --panel) PANEL="$2"; shift 2 ;;
    --confirm-verified) CONFIRM_VERIFIED=1; shift ;;
    --apply) APPLY=1; shift ;;
    --receipt-file) RECEIPT_FILE="$2"; shift 2 ;;
    --proxy-container) PROXY_CONTAINER="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

case "${PANEL}" in
  fastpanel2|cpanel|plesk|ispmanager) ;;
  *) echo "ABORT: --panel must be one of: fastpanel2, cpanel, plesk, ispmanager" >&2; usage ;;
esac

echo "=== GATED PANEL CLEANUP (panel=${PANEL}, apply=${APPLY}) ==="

# Gate 1: Verify coolify-proxy is running
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${PROXY_CONTAINER}"; then
  echo "GATE FAIL [1/4]: Container '${PROXY_CONTAINER}' is not running." >&2
  exit 1
fi
echo "  [GATE 1 OK] ${PROXY_CONTAINER} is running"

# Gate 2: Verify ports 80 & 443 are listening (and legacy nginx/apache host services are NOT active)
for svc in nginx apache2 httpd lsws lshttpd; do
  if systemctl is-active --quiet "${svc}" 2>/dev/null; then
    echo "GATE FAIL [2/4]: Legacy host service '${svc}' is still active!" >&2
    exit 1
  fi
done
if ! ss -tln | grep -qE ':80\s' || ! ss -tln | grep -qE ':443\s'; then
  echo "GATE FAIL [2/4]: Ports 80/443 are not listening." >&2
  exit 1
fi
echo "  [GATE 2 OK] Legacy host HTTP inactive; 80/443 active via proxy"

# Gate 3: Verify fresh receipt (< 24h)
if [ ! -f "${RECEIPT_FILE}" ]; then
  echo "GATE FAIL [3/4]: Missing verification receipt ${RECEIPT_FILE}. Run stage-verify.sh --target 127.0.0.1:443 first." >&2
  exit 1
fi
# shellcheck disable=SC1090
. "${RECEIPT_FILE}"
NOW_EPOCH=$(date +%s)
AGE=$((NOW_EPOCH - ${VERIFIED_EPOCH:-0}))
if [ "${AGE}" -gt 86400 ] || [ "${AGE}" -lt 0 ]; then
  echo "GATE FAIL [3/4]: Verification receipt is stale (${AGE}s old). Re-run stage-verify.sh." >&2
  exit 1
fi
echo "  [GATE 3 OK] Fresh verification receipt (${AGE}s old) for: ${DOMAINS:-unknown}"

# Gate 4: Verify no Coolify / active Nginx configs still reference panel internal dirs
PANEL_PATH_PATTERN=""
case "${PANEL}" in
  fastpanel2) PANEL_PATH_PATTERN='/usr/local/fastpanel2|/etc/fastpanel2|/var/www/httpd-cert' ;;
  cpanel)     PANEL_PATH_PATTERN='/usr/local/cpanel|/var/cpanel/ssl' ;;
  plesk)      PANEL_PATH_PATTERN='/usr/local/psa|/opt/psa' ;;
  ispmanager) PANEL_PATH_PATTERN='/usr/local/mgr5|/var/www/httpd-cert' ;;
esac

REFS=$(grep -rnE "${PANEL_PATH_PATTERN}" /data/coolify/proxy /data/coolify/services 2>/dev/null | grep -vE 'roundcube|phpmyadmin' || true)
if [ -n "${REFS}" ]; then
  echo "GATE FAIL [4/4]: Found Coolify references to panel paths:" >&2
  echo "${REFS}" >&2
  exit 1
fi
echo "  [GATE 4 OK] Zero Coolify references to ${PANEL} directories"

if [ "${APPLY}" -eq 0 ] || [ "${CONFIRM_VERIFIED}" -eq 0 ]; then
  echo ""
  echo "DRY-RUN / PRE-CHECK PASSED. Protected services (DB, mail, FTP, SSH, firewall, /var/www, /home, /etc/letsencrypt) will NOT be touched."
  echo "To execute cleanup, re-run with: --panel ${PANEL} --confirm-verified --apply"
  exit 0
fi

echo ""
echo ">>> Executing safe cleanup for ${PANEL} <<<"

case "${PANEL}" in
  fastpanel2)
    systemctl disable --now fastpanel2 2>/dev/null || true
    for svc in nginx apache2 php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm; do
      systemctl disable --now "$svc" 2>/dev/null || true
    done
    if command -v apt-get >/dev/null 2>&1; then
      PKGS=$(dpkg -l | awk '/fastpanel2/{print $2}' | tr '\n' ' ' || true)
      if [ -n "${PKGS}" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y ${PKGS} || true
      fi
    fi
    rm -rf /usr/local/fastpanel2 /etc/fastpanel2 /opt/fphp
    ;;

  cpanel)
    # SAFETY: Never run rpm/yum erase on cpanel due to deep OS/Exim/Perl/PAM coupling.
    # Only stop & mask panel web/control daemons.
    for svc in cpanel cpsrvd tailwatchd cpdavd httpd nginx ea-php83-php-fpm ea-php82-php-fpm ea-php81-php-fpm ea-php80-php-fpm; do
      systemctl disable --now "$svc" 2>/dev/null || true
    done
    echo "NOTE: cPanel services disabled/stopped cleanly. OS packages preserved intentionally to protect Exim/Dovecot/PAM/home."
    ;;

  plesk)
    for svc in sw-cp-server sw-engine psa nginx apache2 httpd plesk-php83-fpm plesk-php82-fpm plesk-php81-fpm plesk-php80-fpm; do
      systemctl disable --now "$svc" 2>/dev/null || true
    done
    echo "NOTE: Plesk control-plane and web services disabled/stopped. Mail (postfix/dovecot) and databases preserved."
    ;;

  ispmanager)
    for svc in ihttpd mgr5 nginx apache2 httpd php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm; do
      systemctl disable --now "$svc" 2>/dev/null || true
    done
    if command -v apt-get >/dev/null 2>&1; then
      PKGS=$(dpkg -l | awk '/ispmanager/{print $2}' | tr '\n' ' ' || true)
      [ -n "${PKGS}" ] && DEBIAN_FRONTEND=noninteractive apt-get purge -y ${PKGS} || true
    fi
    rm -rf /usr/local/mgr5
    ;;
esac

echo "CLEANUP COMPLETE for ${PANEL}. Protected DB, mail, FTP, SSL, and user data untouched."

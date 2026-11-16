#!/usr/bin/env bash
# Read-only preflight inventory for FastPanel2, cPanel, Plesk, and ISPmanager -> Coolify migrations.
# Safe to run on live production servers: performs ZERO writes or service restarts.

set -uo pipefail

echo "=== PANEL-TO-COOLIFY PREFLIGHT INVENTORY (READ-ONLY) ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Hostname:  $(hostname -f 2>/dev/null || hostname)"

# 1. OS & Resources
echo ""
echo "--- [1] OS & Resources ---"
if [ -f /etc/os-release ]; then
  . /etc/os-release
  echo "OS: ${PRETTY_NAME:-unknown}"
fi
echo "Kernel: $(uname -r)"
free -h 2>/dev/null | awk '/Mem:/ {print "Memory: total="$2" used="$3" avail="$7}'
df -hP / /var /data 2>/dev/null | awk 'NR==1 || !seen[$6]++ {print}'

# 2. Public IP detection
PUBLIC_IP=$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || \
            hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
echo "Primary IPv4: ${PUBLIC_IP}"

# 3. Panel Detection
echo ""
echo "--- [2] Hosting Panel Detection ---"
PANELS=""
[ -d /usr/local/fastpanel2 ] || dpkg -l 2>/dev/null | grep -qi fastpanel2 && PANELS="${PANELS} fastpanel2"
[ -d /usr/local/cpanel ] && PANELS="${PANELS} cpanel"
[ -d /usr/local/psa ] || [ -d /opt/psa ] && PANELS="${PANELS} plesk"
[ -d /usr/local/mgr5 ] && PANELS="${PANELS} ispmanager"
PANELS=$(echo "${PANELS}" | xargs)
echo "Detected panels: ${PANELS:-none}"

# 4. Coolify & Docker Status
echo ""
echo "--- [3] Docker & Coolify Status ---"
if command -v docker >/dev/null 2>&1; then
  docker --version
  docker ps -a --format '{{.Names}} | {{.Status}} | {{.Ports}}' 2>/dev/null | head -n 40 || true
  [ -d /data/coolify ] && echo "Coolify dir: /data/coolify PRESENT" || echo "Coolify dir: ABSENT"
else
  echo "Docker: NOT INSTALLED"
fi

# 5. Services & Listening Ports
echo ""
echo "--- [4] Active Services (Web / DB / Mail / FTP / Panel) ---"
for svc in fastpanel2 cpanel cpsrvd sw-cp-server psa ihttpd nginx apache2 httpd lsws lshttpd \
           php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm php-fpm \
           mysql mysqld mariadb postgresql postgresql@16-main postgresql@15-main postgresql@14-main \
           redis redis-server exim exim4 postfix dovecot proftpd pure-ftpd vsftpd ufw fail2ban ssh sshd docker; do
  if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 || systemctl status "${svc}" >/dev/null 2>&1; then
    active=$(systemctl is-active "${svc}" 2>/dev/null || echo "inactive")
    enabled=$(systemctl is-enabled "${svc}" 2>/dev/null || echo "unknown")
    if [ "${active}" = "active" ] || [ "${enabled}" = "enabled" ]; then
      printf "  %-20s active=%-10s enabled=%s\n" "${svc}" "${active}" "${enabled}"
    fi
  fi
done

echo ""
echo "--- [5] Listening TCP Ports ---"
ss -tlnp 2>/dev/null | head -n 50 || netstat -tlnp 2>/dev/null | head -n 50 || true

# 6. Process Managers (Node/Python/Workers)
echo ""
echo "--- [6] Process Managers (forever / pm2 / supervisor / custom systemd) ---"
if command -v forever >/dev/null 2>&1; then
  echo "[forever]"
  forever list 2>/dev/null || true
fi
if command -v pm2 >/dev/null 2>&1; then
  echo "[pm2]"
  pm2 list 2>/dev/null || true
fi
if command -v supervisorctl >/dev/null 2>&1; then
  echo "[supervisorctl]"
  supervisorctl status 2>/dev/null || true
fi

# 7. Discovered Domains & Live DNS Check
echo ""
echo "--- [7] Discovered Domains & Live DNS Resolution ---"
DOMAINS_RAW=$(
  {
    grep -RhoE 'server_name[[:space:]]+[^;]+' \
      /etc/nginx/fastpanel2-sites/*/*.conf \
      /etc/nginx/vhosts/*/*.conf \
      /etc/nginx/sites-enabled/* \
      /etc/nginx/conf.d/*.conf \
      /var/www/vhosts/system/*/conf/nginx.conf 2>/dev/null | sed 's/server_name//g'
    grep -RhoE '(ServerName|ServerAlias)[[:space:]]+[^#]+' \
      /etc/apache2/fastpanel2-sites/*/*.conf \
      /etc/apache2/sites-enabled/*.conf \
      /etc/httpd/conf/httpd.conf \
      /etc/apache2/conf/httpd.conf 2>/dev/null | sed -E 's/(ServerName|ServerAlias)//g'
    ls /var/cpanel/userdata/*/* 2>/dev/null | xargs -r grep -hE '^servername:' 2>/dev/null | sed 's/servername://g' || true
  } | tr ' \t' '\n' | sed 's/[;"'\'']//g' | grep -E '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' | grep -vE '^(localhost|default|_)$' | sort -u
)

if [ -z "${DOMAINS_RAW}" ]; then
  echo "No domains parsed automatically from standard vhost paths."
else
  echo "${DOMAINS_RAW}" | while read -r dom; do
    [ -z "${dom}" ] && continue
    resolved=""
    if command -v dig >/dev/null 2>&1; then
      resolved=$(dig +short A "${dom}" 2>/dev/null | head -n 1 || true)
    elif command -v getent >/dev/null 2>&1; then
      resolved=$(getent ahostsv4 "${dom}" 2>/dev/null | awk 'NR==1{print $1}' || true)
    fi
    if [ -z "${resolved}" ]; then
      status="DEAD_OR_NO_DNS"
    elif [ "${resolved}" = "${PUBLIC_IP}" ]; then
      status="LIVE_DIRECT"
    else
      status="EXTERNAL_OR_CDN(${resolved})"
    fi
    printf "  %-40s %s\n" "${dom}" "${status}"
  done
fi

# 8. Panel SSL & Code Drift Check
echo ""
echo "--- [8] Panel SSL Path Dependencies ---"
grep -RlnE '/usr/local/fastpanel2|/var/www/httpd-cert|/var/cpanel/ssl|/usr/local/psa/var|/opt/psa/var|/usr/local/mgr5' \
  /etc/nginx /etc/apache2 /etc/httpd 2>/dev/null | head -n 30 || echo "  None detected"

echo ""
echo "--- [9] Git Worktree / Drift Check in Web Roots ---"
find /var/www /home /opt -maxdepth 4 -name ".git" -type d 2>/dev/null | head -n 25 | while read -r gitdir; do
  appdir=$(dirname "${gitdir}")
  dirty=$(git -C "${appdir}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  branch=$(git -C "${appdir}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
  printf "  %-50s branch=%-15s dirty_files=%s\n" "${appdir}" "${branch}" "${dirty}"
done

echo ""
echo "=== END PREFLIGHT INVENTORY ==="

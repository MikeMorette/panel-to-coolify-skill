#!/usr/bin/env bash
# Read-only preflight inventory for FastPanel2, cPanel, Plesk, and ISPmanager -> Coolify migrations.
# Avoids intentional service changes; SSH, DNS, TLS and system tools can still log activity.

set -uo pipefail

DNS_LIMIT=12
PUBLIC_IP=""
GIT_SCAN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dns-limit|--public-ip)
      [ "$#" -ge 2 ] || { printf 'Missing value for %s\n' "$1" >&2; exit 2; }
      case "$1" in --dns-limit) DNS_LIMIT=$2 ;; --public-ip) PUBLIC_IP=$2 ;; esac
      shift 2 ;;
    --git-scan) GIT_SCAN=1; shift ;;
    -h|--help) printf '%s\n' 'Usage: preflight-inventory.sh [--public-ip IPV4] [--dns-limit N] [--git-scan]'; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ "$DNS_LIMIT" =~ ^[0-9]+$ ]] || { printf '%s\n' 'DNS limit must be a non-negative number.' >&2; exit 2; }

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

# Public egress address may differ from ingress/NAT; do not guess it.
printf 'User-supplied public IPv4: %s\n' "${PUBLIC_IP:-not supplied}"

# 3. Panel Detection
echo ""
echo "--- [2] Hosting Panel Detection ---"
PANELS=""
if command -v dpkg-query >/dev/null 2>&1 && [ "$(dpkg-query -W -f='${db:Status-Status}' fastpanel2 2>/dev/null || true)" = installed ]; then
  PANELS="${PANELS} fastpanel2"
elif [ -d /usr/local/fastpanel2 ]; then
  echo 'FastPanel files remain; package/service status requires separate verification.'
fi
[ -d /usr/local/cpanel ] && PANELS="${PANELS} cpanel"
[ -d /usr/local/psa ] || [ -d /opt/psa ] && PANELS="${PANELS} plesk"
[ -d /usr/local/mgr5 ] && PANELS="${PANELS} ispmanager"
PANELS=$(echo "${PANELS}" | xargs)
echo "Detected installed panel or panel footprints: ${PANELS:-none}"

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

# 5. Services & Listening Ports (two service listings, rather than one call per unit)
echo ""
echo "--- [4] Active and Enabled Relevant Services ---"
if command -v systemctl >/dev/null 2>&1; then
  relevant='fastpanel|faststat|cpanel|cpsrvd|sw-cp-server|psa|ihttpd|nginx|apache|httpd|lsws|lshttpd|php.*fpm|mysql|mysqld|mariadb|postgresql|redis|exim|postfix|dovecot|proftpd|pure-ftpd|vsftpd|ufw|fail2ban|ssh|docker'
  systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | awk -v re="$relevant" 'tolower($1) ~ re {print "  RUNNING " $1}' || true
  systemctl list-unit-files --type=service --state=enabled --no-legend --no-pager 2>/dev/null | awk -v re="$relevant" 'tolower($1) ~ re {print "  ENABLED " $1}' || true
fi

echo ""
echo "--- [5] Listening TCP and UDP Ports (truncated to 50 each) ---"
ss -tlnp 2>/dev/null | head -n 51 || netstat -tlnp 2>/dev/null | head -n 51 || true
ss -ulnp 2>/dev/null | head -n 51 || true

# 6. Process Managers: the CLI commands themselves can create state.
echo ""
echo "--- [6] Process Manager Process Names ---"
ps -eo pid,ppid,user,comm 2>/dev/null | awk 'NR==1 || tolower($4) ~ /forever|pm2|supervisord/' | head -n 35 || true
echo "  PM2/forever CLIs were not invoked; inspect specific running instances only when needed."

# 7. Discovered Domains & Live DNS Check
echo ""
echo "--- [7] Discovered Domains & Live DNS Resolution ---"
if command -v python3 >/dev/null 2>&1; then
  DOMAINS_RAW=$(
    {
      grep -RhoE 'server_name[[:space:]]+[^;]+' \
        /etc/nginx/fastpanel2-sites/*/*.conf /etc/nginx/vhosts/*/*.conf \
        /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf \
        /var/www/vhosts/system/*/conf/nginx.conf 2>/dev/null | sed 's/server_name//g'
      grep -RhoE '(ServerName|ServerAlias)[[:space:]]+[^#]+' \
        /etc/apache2/fastpanel2-sites/*/*.conf /etc/apache2/sites-enabled/*.conf \
        /etc/httpd/conf/httpd.conf /etc/apache2/conf/httpd.conf 2>/dev/null | sed -E 's/(ServerName|ServerAlias)//g'
      grep -hE '^servername:' /var/cpanel/userdata/*/* 2>/dev/null | sed 's/servername://g' || true
    } | tr ' \t' '\n' | python3 -c '
import re, sys
for line in sys.stdin:
    raw = line.strip().strip(";\"\x27").rstrip(".")
    wildcard = raw.startswith("*.")
    if wildcard: raw = raw[2:]
    try: host = raw.encode("idna").decode("ascii").lower()
    except (UnicodeError, ValueError): continue
    labels = host.split(".")
    if len(labels) < 2 or len(host) > 253: continue
    if not all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", part) for part in labels): continue
    print(("*." if wildcard else "") + host)
' | sort -u
  )
else
  DOMAINS_RAW=""
  echo 'Python 3 unavailable: automatic IDN discovery skipped; inspect vhosts manually.'
fi

if [ -z "${DOMAINS_RAW}" ]; then
  echo "No domains parsed automatically from standard vhost paths."
else
  count=0
  while IFS= read -r dom; do
    [ -z "$dom" ] && continue
    if [[ "$dom" = '*.'* ]]; then printf '  %-42s WILDCARD_UNCHECKED\n' "$dom"; continue; fi
    count=$((count + 1))
    if [ "$count" -gt "$DNS_LIMIT" ]; then printf '  %-42s DNS_NOT_CHECKED\n' "$dom"; continue; fi
    a=""; aaaa=""
    if command -v dig >/dev/null 2>&1; then
      a=$(dig +time=1 +tries=1 +short A "$dom" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n 4 | tr '\n' ',' || true)
      aaaa=$(dig +time=1 +tries=1 +short AAAA "$dom" 2>/dev/null | grep ':' | head -n 4 | tr '\n' ',' || true)
    elif command -v getent >/dev/null 2>&1; then
      if command -v timeout >/dev/null 2>&1; then
        a=$(timeout 2 getent ahostsv4 "$dom" 2>/dev/null | awk 'NR==1{print $1}' || true)
      else
        a=$(getent ahostsv4 "$dom" 2>/dev/null | awk 'NR==1{print $1}' || true)
      fi
      aaaa=not_checked
    fi
    status=UNCONFIRMED
    if [ -n "$PUBLIC_IP" ] && [[ ",$a," = *",$PUBLIC_IP,"* ]]; then status=MATCHES_SUPPLIED_IPV4; fi
    printf '  %-42s %s A=%s AAAA=%s\n' "$dom" "$status" "${a:-unresolved}" "${aaaa:-unresolved}"
  done <<< "$DOMAINS_RAW"
  echo "  Discovery may be incomplete; unresolved DNS is not proof of a dead domain. Verify public A/AAAA and CDN paths before ACME."
fi

# 8. Panel SSL & Code Drift Check
echo ""
echo "--- [8] Panel SSL Path Dependencies ---"
grep -RIlE 'fastpanel|/opt/fphp|/var/www/httpd-cert|/var/cpanel/ssl|/usr/local/psa/var|/opt/psa/var|/usr/local/mgr5' \
  /etc/nginx /etc/apache2 /etc/httpd /etc/mysql /etc/postgresql /etc/ssh /etc/php /etc/exim4 /etc/dovecot /etc/proftpd /data/coolify/proxy 2>/dev/null | head -n 30 || true
echo '  File-name hints only; verify which references are active and retained.'

echo ""
echo "--- [9] Git Worktree / Drift Check in Web Roots ---"
if [ "$GIT_SCAN" -eq 1 ]; then
  find /var/www /home /opt -maxdepth 4 -name ".git" -type d 2>/dev/null | head -n 25 | while read -r gitdir; do
    appdir=$(dirname "${gitdir}")
    dirty=$(GIT_OPTIONAL_LOCKS=0 git -C "${appdir}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    branch=$(GIT_OPTIONAL_LOCKS=0 git -C "${appdir}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    printf "  %-50s branch=%-15s dirty_files=%s\n" "${appdir}" "${branch}" "${dirty}"
  done
else
  echo '  Broad filesystem scan skipped; check specific live images/worktrees before any rebuild. Pass --git-scan to scan.'
fi

echo ""
echo "=== END PREFLIGHT INVENTORY ==="

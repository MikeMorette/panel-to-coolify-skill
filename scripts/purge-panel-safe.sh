#!/usr/bin/env bash
# Read-only panel retirement plan. Generic package scripts cannot prove whether
# untracked site data, service configuration, mail, or runtime dependencies are safe.
set -euo pipefail

PANEL=""
APPLY=0
RECEIPT_FILE=""
PROXY_CONTAINER=coolify-proxy

usage() {
  cat <<'USAGE'
Usage: purge-panel-safe.sh --panel <fastpanel2|cpanel|plesk|ispmanager> [options]
  --proxy-container NAME     Container to inspect (default: coolify-proxy)
  --receipt-file PATH        Report an existing receipt path; does not attest safety
  --confirm-verified         Accepted for compatibility; does not authorize removal
  --apply                    Refused: this generic helper performs no mutations

For Debian/Ubuntu FastPanel, the report includes a simulated removal of installed
panel packages, with autoremove disabled. Inspect package-owned conffiles, maintainer
scripts and live dependencies; use a reviewed, server-specific removal plan.
USAGE
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --panel|--proxy-container|--receipt-file)
      [ "$#" -ge 2 ] || { printf 'Missing value for %s\n' "$1" >&2; exit 2; }
      case "$1" in
        --panel) PANEL=$2 ;;
        --proxy-container) PROXY_CONTAINER=$2 ;;
        --receipt-file) RECEIPT_FILE=$2 ;;
      esac
      shift 2 ;;
    --confirm-verified) shift ;; # Retained for compatibility; never enables mutation.
    --apply) APPLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$PANEL" in fastpanel2|cpanel|plesk|ispmanager) ;; *) usage >&2; exit 2 ;; esac
if [ "$APPLY" -eq 1 ]; then
  printf '%s\n' 'REFUSED: generic panel removal cannot verify all protected dependencies; no changes were made.' >&2
  printf '%s\n' 'Use the panel-specific dependency audit and an explicitly reviewed removal plan.' >&2
  exit 1
fi

printf '%s\n' '=== PANEL RETIREMENT PLAN ONLY — NO CHANGES ==='
printf 'Panel: %s\n' "$PANEL"
if command -v docker >/dev/null 2>&1; then
  docker inspect --format 'Proxy status: {{.State.Status}}' "$PROXY_CONTAINER" 2>/dev/null || printf '%s\n' 'Proxy status: unavailable'
fi
if command -v ss >/dev/null 2>&1; then
  printf '%s\n' 'Listeners on HTTP/HTTPS (listener identity must be verified separately):'
  ss -H -lntp '( sport = :80 or sport = :443 )' 2>/dev/null || true
fi
if [ -n "$RECEIPT_FILE" ]; then
  if [ -f "$RECEIPT_FILE" ]; then printf '%s\n' 'A route-check receipt exists; it is not proof of application or removal safety.'
  else printf '%s\n' 'Route-check receipt not found.'; fi
fi
printf '%s\n' 'Check active dependencies, package conffiles and maintainer scripts, backups, cert renewal, mail/FTP/SSH, and scheduled jobs.'
printf '%s\n' 'Keep live Apache/PHP/nginx, user data and generated configs when still needed.'

if [ "$PANEL" = fastpanel2 ] && command -v dpkg-query >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
  packages=()
  for p in fastpanel2 fastpanel2-nginx fastpanel2-fphp fastpanel2-backup fastpanel2-diff fastpanel2-ai-bolit fastpanel2-phpmyadmin fastpanel2-roundcube; do
    status=$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || true)
    [ "$status" = installed ] && packages+=("$p")
  done
  if [ "${#packages[@]}" -gt 0 ]; then
    printf 'Installed panel packages:'
    printf ' %s' "${packages[@]}"
    printf '\n%s\n' 'Simulation only; verify the exact package set and all maintainer scripts:'
    apt-get -s -o APT::Get::AutomaticRemove=false remove "${packages[@]}" || {
      printf '%s\n' 'Simulation failed; no removal is authorized by this output.' >&2
      exit 1
    }
  else
    printf '%s\n' 'No known FastPanel packages reported installed.'
  fi
fi
printf '%s\n' 'PLAN COMPLETE. No services, packages, files, or firewall rules were changed.'

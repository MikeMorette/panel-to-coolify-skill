#!/usr/bin/env bash
# This generic helper is intentionally planning-only. It cannot provide an independent
# rollback if SSH, the shell, Docker or the host dies during a production cutover.
set -euo pipefail

MODE=dry-run
BACKUP_DIR=""
DOMAINS=""
STOP_SERVICES=""
STOP_FOREVER=""
STOP_PM2=""
START_CONTAINERS=""
PROXY_CONTAINER=coolify-proxy
PROXY_COMPOSE_DIR=/data/coolify/proxy

usage() {
  cat <<'USAGE'
Usage: cutover-and-rollback.sh [--dry-run|--apply|--rollback] [options]
  --backup-dir DIR             Recovery artifact directory, if one exists
  --domains "a.com,b.com"      Intended public route checks
  --stop-services "nginx,..."  Candidate host units to stop
  --stop-forever "uid,..."     Candidate forever processes to stop
  --stop-pm2 "name,..."        Candidate PM2 processes to stop
  --start-containers "c1,..."  Candidate containers to start
  --proxy-container NAME       Proxy container (default: coolify-proxy)
  --proxy-compose-dir DIR      Proxy compose directory

This helper only prints a plan. --apply and --rollback are refused: an actual
switch needs a server-specific, independently timed and tested recovery mechanism.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry-run; shift ;;
    --apply) MODE=apply; shift ;;
    --rollback) MODE=rollback; shift ;;
    --backup-dir|--domains|--stop-services|--stop-forever|--stop-pm2|--start-containers|--proxy-container|--proxy-compose-dir)
      [ "$#" -ge 2 ] || { printf 'Missing value for %s\n' "$1" >&2; exit 2; }
      case "$1" in
        --backup-dir) BACKUP_DIR=$2 ;;
        --domains) DOMAINS=$2 ;;
        --stop-services) STOP_SERVICES=$2 ;;
        --stop-forever) STOP_FOREVER=$2 ;;
        --stop-pm2) STOP_PM2=$2 ;;
        --start-containers) START_CONTAINERS=$2 ;;
        --proxy-container) PROXY_CONTAINER=$2 ;;
        --proxy-compose-dir) PROXY_COMPOSE_DIR=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ "$MODE" != dry-run ]; then
  printf '%s\n' 'REFUSED: this generic helper has no independent watchdog or verified recovery; no changes were made.' >&2
  printf '%s\n' 'Use a reviewed server-specific cutover and rollback plan; see SKILL.md and references/safety-invariants.md.' >&2
  exit 1
fi

printf '%s\n' '=== CUTOVER PLAN ONLY — NO CHANGES ==='
printf 'Recovery artifacts: %s\n' "${BACKUP_DIR:-not supplied}"
printf 'Candidate web units: %s\n' "${STOP_SERVICES:-none supplied}"
printf 'Candidate forever/PM2: %s / %s\n' "${STOP_FOREVER:-none}" "${STOP_PM2:-none}"
printf 'Candidate containers: %s\n' "${START_CONTAINERS:-none}"
printf 'Proxy: %s (%s)\n' "$PROXY_CONTAINER" "$PROXY_COMPOSE_DIR"
printf 'Route checks: %s\n' "${DOMAINS:-not supplied}"
printf '%s\n' 'Explicitly identify current dependencies; prepare and verify independent rollback before switching.'

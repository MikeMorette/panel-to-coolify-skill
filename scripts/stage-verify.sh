#!/usr/bin/env bash
# Route/status checks against a selected endpoint. Success does not prove app
# login, write operations, WebSockets, renewal, or cutover recovery.
set -euo pipefail

DOMAINS=""
TARGET=127.0.0.1:443
SCHEME=https
SPA_DOMAIN=""
SPA_ROUTE=""
UPLOAD_URL=""
EXPECT_CODES=200,204,301,302,307,308
WRITE_RECEIPT=0
RECEIPT_FILE=/var/backups/coolify-migration-verified.stamp
CA_FILE=""
INSECURE=0
RETRIES=1

usage() {
  cat <<'USAGE'
Usage: stage-verify.sh --domains "a.com,b.com" [options]
  --target HOST:PORT        Destination to connect to (default: 127.0.0.1:443)
  --scheme http|https       Request scheme (default: https)
  --expect 200,301,...      Accepted HTTP statuses
  --retry N                 Retry transient failures N times (default: 1, max: 5)
  --cacert PATH             CA bundle for a private staged certificate
  --insecure                Skip TLS authentication for a diagnostic only
  --spa-domain DOMAIN --spa-route /path
  --upload-url URL          Check reading an existing asset; does not test upload writes
  --write-receipt           Write route evidence explicitly, only with verified HTTPS
  --receipt-file PATH       Evidence destination

Domains must be ASCII/Punycode. TLS identity and chain are verified by default.
Redirects are not followed, so the selected target and Host header remain intact.
A receipt records only route checks; it is not an authorization to remove a panel.
USAGE
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --domains|--target|--scheme|--expect|--spa-domain|--spa-route|--upload-url|--receipt-file|--cacert|--retry)
      [ "$#" -ge 2 ] || { printf 'Missing value for %s\n' "$1" >&2; exit 2; }
      case "$1" in
        --domains) DOMAINS=$2 ;;
        --target) TARGET=$2 ;;
        --scheme) SCHEME=$2 ;;
        --expect) EXPECT_CODES=$2 ;;
        --spa-domain) SPA_DOMAIN=$2 ;;
        --spa-route) SPA_ROUTE=$2 ;;
        --upload-url) UPLOAD_URL=$2 ;;
        --receipt-file) RECEIPT_FILE=$2 ;;
        --cacert) CA_FILE=$2 ;;
        --retry) RETRIES=$2 ;;
      esac
      shift 2 ;;
    --write-receipt) WRITE_RECEIPT=1; shift ;;
    --insecure) INSECURE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$DOMAINS" ] || { usage >&2; exit 2; }
case "$SCHEME" in http|https) ;; *) printf '%s\n' 'Invalid scheme.' >&2; exit 2 ;; esac
[[ "$EXPECT_CODES" =~ ^[0-9]{3}(,[0-9]{3})*$ ]] || { printf '%s\n' 'Invalid expected status list.' >&2; exit 2; }
[[ "$RETRIES" =~ ^[0-5]$ ]] || { printf '%s\n' 'Retry count must be 0 through 5.' >&2; exit 2; }
if [ "$WRITE_RECEIPT" -eq 1 ] && { [ "$SCHEME" != https ] || [ "$INSECURE" -eq 1 ]; }; then
  printf '%s\n' 'A receipt requires authenticated HTTPS; insecure or HTTP-only probes cannot write one.' >&2
  exit 2
fi
if [ "$INSECURE" -eq 1 ] && [ -n "$CA_FILE" ]; then printf '%s\n' 'Choose --cacert or --insecure, not both.' >&2; exit 2; fi
[ -z "$CA_FILE" ] || [ -f "$CA_FILE" ] || { printf '%s\n' 'CA file not found.' >&2; exit 2; }
HOST_IP=${TARGET%:*}
HOST_PORT=${TARGET##*:}
if [ "$HOST_IP" = "$TARGET" ] || [ -z "$HOST_IP" ] || ! [[ "$HOST_PORT" =~ ^[0-9]+$ ]] || [ "$HOST_PORT" -lt 1 ] || [ "$HOST_PORT" -gt 65535 ]; then
  printf '%s\n' 'Invalid target; use HOST:PORT or [IPv6]:PORT.' >&2
  exit 2
fi
valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [[ "$1" != *..* ]]
}
CURL_OPTS=(--silent --show-error --noproxy '*' --connect-timeout 4 --max-time 10)
[ "$INSECURE" -eq 0 ] || CURL_OPTS+=(--insecure)
[ -z "$CA_FILE" ] || CURL_OPTS+=(--cacert "$CA_FILE")
status_for() {
  local domain=$1 public_port=$2 url=$3 code
  if code=$(curl "${CURL_OPTS[@]}" --connect-to "${domain}:${public_port}:${HOST_IP}:${HOST_PORT}" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null); then
    printf '%s' "$code"
  else
    printf '000'
  fi
}
expect_status() { case ",$EXPECT_CODES," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
probe_status() {
  local domain=$1 public_port=$2 url=$3 mode=$4 code initial attempt=0
  code=$(status_for "$domain" "$public_port" "$url")
  initial=$code
  while [ "$attempt" -lt "$RETRIES" ]; do
    if [ "$mode" = expected ] && expect_status "$code"; then break; fi
    if [ "$mode" = exact200 ] && [ "$code" = 200 ]; then break; fi
    case "$code" in 000|429|502|503|504) ;; *) break ;; esac
    attempt=$((attempt + 1))
    printf '[RETRY] %s initial HTTP %s, retry %s/%s\n' "$domain" "$initial" "$attempt" "$RETRIES" >&2
    sleep 1
    code=$(status_for "$domain" "$public_port" "$url")
  done
  printf '%s' "$code"
}

printf '=== ROUTE CHECKS: %s via %s ===\n' "$SCHEME" "$TARGET"
[ "$INSECURE" -eq 0 ] || printf '%s\n' 'WARNING: TLS authentication is disabled for these diagnostic checks.'
SCHEME_PORT=443
[ "$SCHEME" = https ] || SCHEME_PORT=80
FAILURES=0
CHECKED=0
IFS=',' read -ra DOMAIN_LIST <<< "$DOMAINS"
for dom in "${DOMAIN_LIST[@]}"; do
  dom=${dom#"${dom%%[![:space:]]*}"}
  dom=${dom%"${dom##*[![:space:]]}"}
  if ! valid_domain "$dom"; then printf '%s\n' 'Invalid domain: use ASCII/Punycode and list each actual hostname.' >&2; exit 2; fi
  code=$(probe_status "$dom" "$SCHEME_PORT" "$SCHEME://$dom/" expected)
  CHECKED=$((CHECKED + 1))
  if expect_status "$code"; then printf '[PASS] %s HTTP %s\n' "$dom" "$code"
  else printf '[FAIL] %s HTTP %s\n' "$dom" "$code"; FAILURES=$((FAILURES + 1)); fi
done

if [ -n "$SPA_DOMAIN" ] || [ -n "$SPA_ROUTE" ]; then
  if ! valid_domain "$SPA_DOMAIN" || [[ "$SPA_ROUTE" != /* ]] || [[ "$SPA_ROUTE" = *$'\n'* ]]; then
    printf '%s\n' 'Both a valid --spa-domain and absolute --spa-route are required.' >&2; exit 2
  fi
  code=$(probe_status "$SPA_DOMAIN" "$SCHEME_PORT" "$SCHEME://$SPA_DOMAIN$SPA_ROUTE" exact200)
  if [ "$code" = 200 ]; then printf '[PASS] SPA route HTTP %s\n' "$code"
  else printf '[FAIL] SPA route HTTP %s\n' "$code"; FAILURES=$((FAILURES + 1)); fi
fi
if [ -n "$UPLOAD_URL" ]; then
  if ! [[ "$UPLOAD_URL" =~ ^(https?)://([^/:?#]+)(:([0-9]+))?([/?][^#]*)?$ ]]; then
    printf '%s\n' 'Invalid upload URL.' >&2; exit 2
  fi
  up_scheme=${BASH_REMATCH[1]}; up_domain=${BASH_REMATCH[2]}; up_port=${BASH_REMATCH[4]}
  valid_domain "$up_domain" || { printf '%s\n' 'Invalid upload hostname.' >&2; exit 2; }
  if [ -z "$up_port" ]; then
    case "$up_scheme" in https) up_port=443 ;; *) up_port=80 ;; esac
  fi
  code=$(probe_status "$up_domain" "$up_port" "$UPLOAD_URL" exact200)
  if [ "$code" = 200 ]; then printf '[PASS] Existing upload read HTTP %s\n' "$code"
  else printf '[FAIL] Existing upload read HTTP %s\n' "$code"; FAILURES=$((FAILURES + 1)); fi
fi
[ "$CHECKED" -gt 0 ] && [ "$FAILURES" -eq 0 ] || { printf 'RESULT: FAILED (%s checks)\n' "$FAILURES"; exit 1; }
if [ "$WRITE_RECEIPT" -eq 1 ]; then
  umask 077
  mkdir -p "$(dirname "$RECEIPT_FILE")"
  receipt_tmp=$(mktemp "${RECEIPT_FILE}.XXXXXX")
  trap 'rm -f "$receipt_tmp"' EXIT
  printf 'VERIFIED_AT=%s\nVERIFIED_EPOCH=%s\nTARGET=%s\nDOMAINS=%s\nSCOPE=route_checks_only\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" "$TARGET" "$DOMAINS" > "$receipt_tmp"
  mv -f "$receipt_tmp" "$RECEIPT_FILE"
  trap - EXIT
  printf 'Route evidence written: %s\n' "$RECEIPT_FILE"
fi
printf '%s\n' 'RESULT: ROUTE CHECKS PASSED; application login and write operations were not tested.'

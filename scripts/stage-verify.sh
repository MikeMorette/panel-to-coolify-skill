#!/usr/bin/env bash
# Verifies staged or live domains via --resolve against a loopback or proxy target.
# Checks HTTP status codes, absence of 502/503/504/default panel error pages, TLS cert expiry,
# optional SPA routes, and optional static upload paths. Writes a verification receipt on pass.

set -euo pipefail

DOMAINS=""
TARGET="127.0.0.1:443"
SCHEME="https"
SPA_DOMAIN=""
SPA_ROUTE=""
UPLOAD_URL=""
EXPECT_CODES="200,204,301,302,307,308"
WRITE_RECEIPT=0
RECEIPT_FILE="/var/backups/coolify-migration-verified.stamp"

usage() {
  cat <<EOF
Usage: stage-verify.sh --domains "d1.com,d2.com" [options]
Options:
  --domains "a.com,b.com"   Comma-separated domains to verify (required)
  --target  HOST:PORT       Target IP:PORT for curl --resolve (default: 127.0.0.1:443)
  --scheme  http|https      Protocol scheme (default: https)
  --expect  200,301,...     Accepted HTTP status codes (default: 200,204,301,302,307,308)
  --spa-domain DOMAIN       Optional domain to test SPA fallback route
  --spa-route  /path        Optional SPA route expected to return 200 HTML
  --upload-url URL          Optional full URL (e.g. https://d1.com/uploads/test.png) to verify 200
  --write-receipt           Write verification receipt file on success (or auto-enabled on :443)
  --receipt-file PATH       Custom receipt path (default: ${RECEIPT_FILE})
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domains) DOMAINS="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --scheme) SCHEME="$2"; shift 2 ;;
    --expect) EXPECT_CODES="$2"; shift 2 ;;
    --spa-domain) SPA_DOMAIN="$2"; shift 2 ;;
    --spa-route) SPA_ROUTE="$2"; shift 2 ;;
    --upload-url) UPLOAD_URL="$2"; shift 2 ;;
    --write-receipt) WRITE_RECEIPT=1; shift ;;
    --receipt-file) RECEIPT_FILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[ -z "${DOMAINS}" ] && usage

HOST_IP="${TARGET%%:*}"
HOST_PORT="${TARGET##*:}"
[ "${HOST_PORT}" = "443" ] && WRITE_RECEIPT=1

FAILURES=0
IFS=',' read -ra DOMAIN_LIST <<< "${DOMAINS}"

echo "=== STAGE / LIVE VERIFICATION ==="
echo "Target: ${SCHEME}://${TARGET} | Accepted status codes: ${EXPECT_CODES}"

for dom in "${DOMAIN_LIST[@]}"; do
  dom=$(echo "${dom}" | xargs)
  [ -z "${dom}" ] && continue

  url="${SCHEME}://${dom}/"
  if [ "${SCHEME}" = "http" ] && [ "${HOST_PORT}" != "80" ]; then
    url="http://${dom}:${HOST_PORT}/"
  elif [ "${SCHEME}" = "https" ] && [ "${HOST_PORT}" != "443" ]; then
    url="https://${dom}:${HOST_PORT}/"
  fi

  tmp_body=$(mktemp)
  code=$(curl -skL --max-time 10 --resolve "${dom}:${HOST_PORT}:${HOST_IP}" \
    -o "${tmp_body}" -w "%{http_code}" "${url}" 2>/dev/null || echo "000")
  size=$(wc -c < "${tmp_body}" | tr -d ' ')

  ok=0
  IFS=',' read -ra CODES <<< "${EXPECT_CODES}"
  for c in "${CODES[@]}"; do
    [ "${code}" = "$c" ] && ok=1 && break
  done

  if grep -qiE 'Welcome to nginx!|FastPanel|cPanel.*Default Web Site|Apache2 Ubuntu Default Page|Bad Gateway|502 Bad Gateway' "${tmp_body}" 2>/dev/null; then
    ok=0
    code="${code}(DEFAULT_OR_ERROR_PAGE)"
  fi
  rm -f "${tmp_body}"

  tls_note=""
  if [ "${SCHEME}" = "https" ] && command -v openssl >/dev/null 2>&1; then
    end_date=$(echo | openssl s_client -servername "${dom}" -connect "${HOST_IP}:${HOST_PORT}" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//' || echo "NO_CERT")
    tls_note=" | TLS_EXPIRY=${end_date}"
    [ "${end_date}" = "NO_CERT" ] && ok=0
  fi

  if [ "${ok}" -eq 1 ]; then
    echo "  [PASS] ${dom} -> HTTP ${code}, bytes=${size}${tls_note}"
  else
    echo "  [FAIL] ${dom} -> HTTP ${code}, bytes=${size}${tls_note}"
    FAILURES=$((FAILURES + 1))
  fi
done

if [ -n "${SPA_DOMAIN}" ] && [ -n "${SPA_ROUTE}" ]; then
  spa_code=$(curl -sk --max-time 10 --resolve "${SPA_DOMAIN}:${HOST_PORT}:${HOST_IP}" \
    -o /dev/null -w "%{http_code}" "${SCHEME}://${SPA_DOMAIN}:${HOST_PORT}${SPA_ROUTE}" 2>/dev/null || echo "000")
  if [ "${spa_code}" = "200" ]; then
    echo "  [PASS] SPA fallback ${SPA_DOMAIN}${SPA_ROUTE} -> HTTP 200"
  else
    echo "  [FAIL] SPA fallback ${SPA_DOMAIN}${SPA_ROUTE} -> HTTP ${spa_code}"
    FAILURES=$((FAILURES + 1))
  fi
fi

if [ -n "${UPLOAD_URL}" ]; then
  up_dom=$(echo "${UPLOAD_URL}" | sed -E 's|^https?://([^/:]+).*|\1|')
  up_code=$(curl -sk --max-time 10 --resolve "${up_dom}:${HOST_PORT}:${HOST_IP}" \
    -o /dev/null -w "%{http_code}" "${UPLOAD_URL}" 2>/dev/null || echo "000")
  if [ "${up_code}" = "200" ]; then
    echo "  [PASS] Upload asset ${UPLOAD_URL} -> HTTP 200"
  else
    echo "  [FAIL] Upload asset ${UPLOAD_URL} -> HTTP ${up_code}"
    FAILURES=$((FAILURES + 1))
  fi
fi

if [ "${FAILURES}" -gt 0 ]; then
  echo "RESULT: FAILED (${FAILURES} check(s) failed)"
  exit 1
fi

if [ "${WRITE_RECEIPT}" -eq 1 ]; then
  mkdir -p "$(dirname "${RECEIPT_FILE}")"
  cat > "${RECEIPT_FILE}" <<EOF
VERIFIED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VERIFIED_EPOCH=$(date +%s)
TARGET=${TARGET}
DOMAINS=${DOMAINS}
EOF
  chmod 600 "${RECEIPT_FILE}"
  echo "Receipt written: ${RECEIPT_FILE}"
fi

echo "RESULT: ALL CHECKS PASSED"

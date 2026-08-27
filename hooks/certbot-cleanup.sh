#!/usr/bin/env bash
# Certbot DNS-01 cleanup hook: remove _acme-challenge TXT via Porkbun (or InternetBS).
# Keep stdout/stderr clean for Certbot (see certbot-auth.sh).
set -euo pipefail

PROXIES_ROOT="${PROXIES_ROOT:-/opt/proxies}"
PROXIES_ETC="${PROXIES_ETC:-/etc/proxies}"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/porkbun.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/internetbs.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/registrar.sh"

load_credentials

: "${CERTBOT_DOMAIN:?CERTBOT_DOMAIN not set}"
: "${CERTBOT_VALIDATION:?CERTBOT_VALIDATION not set}"

log "Cleanup hook: removing TXT _acme-challenge.${CERTBOT_DOMAIN}"
registrar_dns_remove "${CERTBOT_DOMAIN}" "_acme-challenge" "TXT" "${CERTBOT_VALIDATION}" || true
exit 0

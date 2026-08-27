#!/usr/bin/env bash
# Daily domain rotation: register new .com, DNS, wildcard cert, nginx vhosts.
# Existing domains remain reachable until older than DOMAIN_RETENTION_DAYS (default 14).
#
# If a previous run purchased a domain but failed later (e.g. SSL), the next run
# resumes that domain instead of buying a new one.
set -euo pipefail

PROXIES_ROOT="${PROXIES_ROOT:-/opt/proxies}"

# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/porkbun.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/internetbs.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/registrar.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/ssl.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/nginx.sh"
# shellcheck disable=SC1091
source "${PROXIES_ROOT}/lib/urls.sh"

usage() {
  cat <<'EOF'
Usage: rotate-domain.sh [options]

Porkbun mode (default): register a random .com, then DNS + wildcard SSL + nginx.
Manual mode (DOMAIN_SOURCE=manual): activate the next domain from
/etc/proxies/domains.list — no Domain/Create.

If a prior setup was incomplete, resumes that domain (no new spend / no skip).

Options:
  --api-key KEY           Porkbun API key (optional if credentials.env exists)
  --password PASS         Porkbun secret API key
  --secret-key KEY        Alias for --password
  --client-name NAME      Client name
  --use-domain NAME       Set up this domain (manual list or already purchased)
  --resume-domain NAME    Alias for --use-domain
  --force-new             Next domain even if an incomplete one exists
  --skip-cleanup          Do not remove domains older than retention window
  --cleanup-only          Only remove expired local domain configs/certs
  -h, --help              Show this help
EOF
}

SKIP_CLEANUP=0
CLEANUP_ONLY=0
FORCE_NEW=0
RESUME_DOMAIN=""
USE_DOMAIN=""
CLI_API_KEY=""
CLI_PASSWORD=""
CLI_CLIENT_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key)
      CLI_API_KEY="${2:-}"
      shift 2
      ;;
    --password|--secret-key)
      CLI_PASSWORD="${2:-}"
      shift 2
      ;;
    --client-name)
      CLI_CLIENT_NAME="${2:-}"
      shift 2
      ;;
    --use-domain|--resume-domain)
      USE_DOMAIN="${2:-}"
      RESUME_DOMAIN="${2:-}"
      shift 2
      ;;
    --force-new)
      FORCE_NEW=1
      shift
      ;;
    --skip-cleanup)
      SKIP_CLEANUP=1
      shift
      ;;
    --cleanup-only)
      CLEANUP_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

require_root
require_ubuntu_2604
ensure_runtime_dirs

if [[ -n "${CLI_API_KEY}" || -n "${CLI_PASSWORD}" || -n "${CLI_CLIENT_NAME}" ]]; then
  mkdir -p "${PROXIES_ETC}"
  # Preserve existing origins/email when only overriding a subset via CLI.
  if [[ -f "${CREDENTIALS_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck disable=SC1090
    source "${CREDENTIALS_FILE}"
    set +a
  fi
  DOMAIN_SOURCE="${DOMAIN_SOURCE:-porkbun}"
  if [[ "${DOMAIN_SOURCE}" == "internetbs" ]]; then
    INTERNETBS_API_KEY="${CLI_API_KEY:-${INTERNETBS_API_KEY:-}}"
    INTERNETBS_PASSWORD="${CLI_PASSWORD:-${INTERNETBS_PASSWORD:-}}"
  else
    PORKBUN_API_KEY="${CLI_API_KEY:-${PORKBUN_API_KEY:-}}"
    PORKBUN_SECRET_KEY="${CLI_PASSWORD:-${PORKBUN_SECRET_KEY:-}}"
  fi
  cat >"${CREDENTIALS_FILE}" <<EOF
DOMAIN_SOURCE="${DOMAIN_SOURCE}"
PORKBUN_API_KEY="${PORKBUN_API_KEY:-}"
PORKBUN_SECRET_KEY="${PORKBUN_SECRET_KEY:-}"
INTERNETBS_API_KEY="${INTERNETBS_API_KEY:-}"
INTERNETBS_PASSWORD="${INTERNETBS_PASSWORD:-}"
CDN_ORIGIN="${CDN_ORIGIN:-}"
BACKEND_ORIGIN="${BACKEND_ORIGIN:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
ROTATION_INTERVAL_DAYS="${ROTATION_INTERVAL_DAYS:-1}"
DOMAIN_RETENTION_DAYS="${DOMAIN_RETENTION_DAYS:-14}"
EOF
  chmod 600 "${CREDENTIALS_FILE}"
  if [[ -n "${CLI_CLIENT_NAME}" ]]; then
    mkdir -p "${CLIENTS_DIR}"
    if [[ ! -f "${CLIENTS_DIR}/${CLI_CLIENT_NAME}.env" ]]; then
      printf '# Added via rotate-domain.sh --client-name\n' >"${CLIENTS_DIR}/${CLI_CLIENT_NAME}.env"
      chmod 600 "${CLIENTS_DIR}/${CLI_CLIENT_NAME}.env"
      log "Created ${CLIENTS_DIR}/${CLI_CLIENT_NAME}.env"
    fi
  fi
fi

load_credentials
if [[ "${DOMAIN_SOURCE}" == "internetbs" ]]; then
  load_registrant
fi
ensure_prefix_files

if [[ "${CLEANUP_ONLY}" -eq 1 ]]; then
  cleanup_expired_domains
  exit 0
fi

ROTATION_INTERVAL_DAYS="${ROTATION_INTERVAL_DAYS:-1}"
DOMAIN_RETENTION_DAYS="${DOMAIN_RETENTION_DAYS:-14}"
log "Starting domain rotation for clients=${CLIENT_NAMES[*]} source=${DOMAIN_SOURCE} (interval=${ROTATION_INTERVAL_DAYS}d; retention=${DOMAIN_RETENTION_DAYS}d)"

PUBLIC_IP="$(detect_public_ip)"
log "Detected public IP: ${PUBLIC_IP}"

DOMAIN=""
RESUME=0
STATUS=""

select_manual_domain() {
  local selected=""
  load_manual_domains
  [[ ${#MANUAL_DOMAINS[@]} -gt 0 ]] || die "DOMAIN_SOURCE=manual but ${MANUAL_DOMAINS_FILE} has no domains. Add one FQDN per line or pass --use-domain NAME."

  if selected="$(find_unused_manual_domain)"; then
    printf '%s\n' "${selected}"
    return 0
  fi
  if [[ "${FORCE_ROTATION:-0}" -eq 1 || "${FORCE_NEW}" -eq 1 ]]; then
    selected="$(next_manual_domain_after_current)" || die "Could not pick the next manual domain"
    printf '%s\n' "${selected}"
    return 0
  fi
  return 1
}

if [[ -n "${USE_DOMAIN}" ]]; then
  DOMAIN="$(normalize_domain_name "${USE_DOMAIN}")"
  validate_domain_name "${DOMAIN}"
  if domain_source_is_manual; then
    append_manual_domain "${DOMAIN}"
  fi
  RESUME=1
  STATUS="$(get_domain_status "${DOMAIN}")"
  [[ -n "${STATUS}" ]] || STATUS="${DOMAIN_STATUS_PURCHASED}"
  set_domain_status "${DOMAIN}" "${STATUS}"
  set_pending_domain "${DOMAIN}"
  log "Using explicit domain ${DOMAIN} (status=${STATUS})"
elif [[ "${FORCE_NEW}" -eq 0 ]] && DOMAIN="$(find_incomplete_domain)"; then
  RESUME=1
  STATUS="$(get_domain_status "${DOMAIN}")"
  [[ -n "${STATUS}" ]] || STATUS="${DOMAIN_STATUS_PURCHASED}"
  log "Found incomplete domain ${DOMAIN} (status=${STATUS}); resuming instead of selecting a new one"
else
  # New domain path: honor ROTATION_INTERVAL_DAYS unless force-rotate / --force-new.
  if [[ "${FORCE_ROTATION:-0}" -eq 0 && "${FORCE_NEW}" -eq 0 ]] && rotation_interval_not_elapsed; then
    log "Skipping scheduled rotation: current domain is within ROTATION_INTERVAL_DAYS=${ROTATION_INTERVAL_DAYS}"
    if [[ "${SKIP_CLEANUP}" -eq 0 ]]; then
      cleanup_expired_domains
    fi
    exit 0
  fi
  if domain_source_is_manual; then
    if ! DOMAIN="$(select_manual_domain)"; then
      log "No unused manual domains in ${MANUAL_DOMAINS_FILE}; nothing to activate"
      if [[ "${SKIP_CLEANUP}" -eq 0 ]]; then
        cleanup_expired_domains
      fi
      exit 0
    fi
    log "Selected manual domain: ${DOMAIN}"
    mark_domain_purchased "${DOMAIN}"
    STATUS="${DOMAIN_STATUS_PURCHASED}"
  else
    log "Searching for an available random .com via ${DOMAIN_SOURCE}"
    REGISTRAR_SELECTED_DOMAIN=""
    DOMAIN="$(registrar_find_available_domain 30)"
    DOMAIN="${REGISTRAR_SELECTED_DOMAIN:-${DOMAIN}}"
    if [[ -z "${DOMAIN}" && -f "${PORKBUN_QUOTE_FILE:-}" ]]; then
      read -r DOMAIN _ <"${PORKBUN_QUOTE_FILE}" || true
    fi
    [[ -n "${DOMAIN}" ]] || die "Registrar did not select a domain"
    log "Selected available domain: ${DOMAIN}"
    registrar_register_domain "${DOMAIN}"
    mark_domain_purchased "${DOMAIN}"
    STATUS="${DOMAIN_STATUS_PURCHASED}"
  fi
fi

# --- DNS ---
if dns_api_configured; then
  if [[ "${STATUS}" == "${DOMAIN_STATUS_PURCHASED}" ]]; then
    registrar_point_domain_to_ip "${DOMAIN}" "${PUBLIC_IP}"
    mark_domain_dns_configured "${DOMAIN}"
    STATUS="${DOMAIN_STATUS_DNS}"
    log "Waiting briefly for DNS zone to settle before ACME challenge"
    sleep 30
  elif [[ "${STATUS}" == "${DOMAIN_STATUS_DNS}" || "${STATUS}" == "${DOMAIN_STATUS_SSL}" ]]; then
    log "Re-asserting DNS A records for ${DOMAIN} -> ${PUBLIC_IP}"
    registrar_point_domain_to_ip "${DOMAIN}" "${PUBLIC_IP}" || true
  fi
else
  if [[ "${STATUS}" == "${DOMAIN_STATUS_PURCHASED}" ]]; then
    log "No DNS API configured: skipping DNS writes. Point ${DOMAIN} and *.${DOMAIN} A records to ${PUBLIC_IP} yourself."
    mark_domain_dns_configured "${DOMAIN}"
    STATUS="${DOMAIN_STATUS_DNS}"
  fi
fi

# --- SSL ---
if [[ "${STATUS}" == "${DOMAIN_STATUS_DNS}" ]]; then
  ensure_domain_certificate "${DOMAIN}"
  mark_domain_ssl_issued "${DOMAIN}"
  STATUS="${DOMAIN_STATUS_SSL}"
elif [[ "${STATUS}" == "${DOMAIN_STATUS_SSL}" ]]; then
  ensure_domain_certificate "${DOMAIN}"
elif [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  ensure_domain_certificate "${DOMAIN}"
  mark_domain_ssl_issued "${DOMAIN}"
  STATUS="${DOMAIN_STATUS_SSL}"
fi

# --- nginx + API JSON ---
install_websocket_map
install_server_names_hash
enable_domain_sites "${DOMAIN}"
ensure_url_prefixes_file
write_current_urls_json "${DOMAIN}"
render_api_ip_vhost
nginx_test_and_reload

mark_domain_active "${DOMAIN}"
log "Domain ${DOMAIN} is active and will remain reachable for ${DOMAIN_RETENTION_DAYS} days"
log "Query current URLs: curl -u USER:PASS http://${PUBLIC_IP}/api/game/url-extended/<client>"

if [[ "${SKIP_CLEANUP}" -eq 0 ]]; then
  cleanup_expired_domains
fi

if [[ "${RESUME}" -eq 1 ]]; then
  log "Resume complete: ${DOMAIN}"
else
  log "Rotation complete: ${DOMAIN}"
fi
printf '%s\n' "${DOMAIN}"

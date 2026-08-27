#!/usr/bin/env bash
# Shared helpers for the domain-rotation toolkit.

set -euo pipefail

PROXIES_ROOT="${PROXIES_ROOT:-/opt/proxies}"
PROXIES_ETC="${PROXIES_ETC:-/etc/proxies}"
PROXIES_STATE="${PROXIES_STATE:-/var/lib/proxies}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-${PROXIES_ETC}/credentials.env}"
REGISTRANT_FILE="${REGISTRANT_FILE:-${PROXIES_ETC}/registrant.env}"
URL_PREFIXES_FILE="${URL_PREFIXES_FILE:-${PROXIES_ETC}/url-prefixes.env}"
PREFIXES_CLIENT_FILE="${PREFIXES_CLIENT_FILE:-${PROXIES_ETC}/prefixes-client.env}"
PREFIXES_SHARED_FILE="${PREFIXES_SHARED_FILE:-${PROXIES_ETC}/prefixes-shared.env}"
CLIENTS_DIR="${CLIENTS_DIR:-${PROXIES_ETC}/clients}"
CURRENT_DOMAIN_FILE="${CURRENT_DOMAIN_FILE:-${PROXIES_STATE}/current-domain}"
PENDING_DOMAIN_FILE="${PENDING_DOMAIN_FILE:-${PROXIES_STATE}/pending-domain}"
CURRENT_URLS_JSON="${CURRENT_URLS_JSON:-${PROXIES_STATE}/current-urls.json}"
URLS_DIR="${URLS_DIR:-${PROXIES_STATE}/urls}"
DOMAINS_DIR="${DOMAINS_DIR:-${PROXIES_STATE}/domains}"
DOMAIN_RETENTION_DAYS="${DOMAIN_RETENTION_DAYS:-14}"
ROTATION_INTERVAL_DAYS="${ROTATION_INTERVAL_DAYS:-1}"
API_HTPASSWD_FILE="${API_HTPASSWD_FILE:-${PROXIES_ETC}/api.htpasswd}"
# Leftover path from the old HTTPS IP API; unused, removed on vhost render.
API_TLS_DIR="${API_TLS_DIR:-${PROXIES_ETC}/ssl}"
# Manual domain list (one FQDN per line). Used when DOMAIN_SOURCE=manual.
MANUAL_DOMAINS_FILE="${MANUAL_DOMAINS_FILE:-${PROXIES_ETC}/domains.list}"
ACME_WEBROOT="${ACME_WEBROOT:-${PROXIES_STATE}/acme}"
# porkbun (default): buy random .com via Porkbun.
# internetbs: legacy registrar.
# manual: use domains from MANUAL_DOMAINS_FILE / --domain; never Domain/Create.
DOMAIN_SOURCE="${DOMAIN_SOURCE:-porkbun}"
MANUAL_DOMAINS=()

# Domain setup stages (persisted under domains/<domain>/status):
#   purchased      -> Domain/Create succeeded (money spent)
#   dns_configured -> A records pointed at this VM
#   ssl_issued     -> wildcard cert exists
#   active         -> nginx + API JSON live (fully successful)
DOMAIN_STATUS_PURCHASED="purchased"
DOMAIN_STATUS_DNS="dns_configured"
DOMAIN_STATUS_SSL="ssl_issued"
DOMAIN_STATUS_ACTIVE="active"

CDN_PREFIXES=(cdn lobby-prod-cdn)

DEFAULT_CLIENT_PREFIXES=(
  "__CLIENT__-gs-prod"
  "__CLIENT__-gs-prod-bgsp"
  "__CLIENT__-gs-demo-prod"
  "__CLIENT__-gs-demo-prod-bgsp"
  "__CLIENT__-lobby-prod"
  "__CLIENT__-lobby-prod-bgsp"
  "__CLIENT__-api-prod"
  "__CLIENT__-api-prod-bgsp"
  "__CLIENT__-gc-prod"
  "__CLIENT__-gc-prod-bgsp"
)

DEFAULT_SHARED_PREFIXES=(
  "lottery-api-instant"
  "lottery-api-instant-prod"
  "lottery-web-prod"
  "player-history-prod"
  "player-history-prod-bgsp"
  "tournaments-prod"
  "tournaments-prod-bgsp"
  "replays-ong-prod-ext"
)

# Populated by discover_clients / load_origin_prefixes
CLIENT_NAMES=()
ORIGIN_PREFIXES=()

log() {
  # Note: do not capture printf-with-trailing-\n in $(...); bash strips
  # trailing newlines from command substitutions, which flattened cron logs.
  if [[ -n "${CERTBOT_DOMAIN:-}" ]]; then
    # Certbot treats any hook stderr as "error output" and may fail the hook.
    local hook_log="${PROXIES_CERTBOT_HOOK_LOG:-/var/log/proxies-certbot-hooks.log}"
    printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >>"${hook_log}" 2>/dev/null || true
  else
    printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "This script must be run as root"
}

require_ubuntu_2604() {
  local version_id=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    version_id="${VERSION_ID:-}"
  fi
  if [[ "${version_id}" != "26.04" ]]; then
    die "This toolkit requires Ubuntu 26.04 (detected: ${ID:-unknown} ${version_id:-unknown})"
  fi
}

load_env_file() {
  local file="$1"
  [[ -f "${file}" ]] || die "Missing required config: ${file}"
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1090
  source "${file}"
  set +a
}

domain_source_is_manual() {
  [[ "${DOMAIN_SOURCE:-porkbun}" == "manual" ]]
}

porkbun_configured() {
  [[ -n "${PORKBUN_API_KEY:-}" && -n "${PORKBUN_SECRET_KEY:-}" ]]
}

internetbs_configured() {
  [[ -n "${INTERNETBS_API_KEY:-}" && -n "${INTERNETBS_PASSWORD:-}" ]]
}

# Old credentials.env had no DOMAIN_SOURCE: keep InternetBS if only those keys exist.
infer_domain_source() {
  if [[ -n "${DOMAIN_SOURCE:-}" ]]; then
    printf '%s\n' "${DOMAIN_SOURCE}"
    return 0
  fi
  if porkbun_configured; then
    printf 'porkbun\n'
  elif internetbs_configured; then
    printf 'internetbs\n'
  else
    printf 'porkbun\n'
  fi
}

load_credentials() {
  load_env_file "${CREDENTIALS_FILE}"
  PORKBUN_SECRET_KEY="${PORKBUN_SECRET_KEY:-${PORKBUN_SECRET_API_KEY:-}}"
  DOMAIN_SOURCE="$(infer_domain_source)"
  case "${DOMAIN_SOURCE}" in
    porkbun|internetbs|manual) ;;
    *)
      die "DOMAIN_SOURCE must be 'porkbun', 'internetbs', or 'manual' (got: ${DOMAIN_SOURCE})"
      ;;
  esac
  if [[ "${DOMAIN_SOURCE}" == "porkbun" ]]; then
    [[ -n "${PORKBUN_API_KEY:-}" ]] || die "PORKBUN_API_KEY is not set"
    [[ -n "${PORKBUN_SECRET_KEY:-}" ]] || die "PORKBUN_SECRET_KEY is not set"
  elif [[ "${DOMAIN_SOURCE}" == "internetbs" ]]; then
    [[ -n "${INTERNETBS_API_KEY:-}" ]] || die "INTERNETBS_API_KEY is not set"
    [[ -n "${INTERNETBS_PASSWORD:-}" ]] || die "INTERNETBS_PASSWORD is not set"
  fi
  [[ -n "${CDN_ORIGIN:-}" ]] || die "CDN_ORIGIN is not set"
  [[ -n "${BACKEND_ORIGIN:-}" ]] || die "BACKEND_ORIGIN is not set"
  [[ -n "${CERTBOT_EMAIL:-}" ]] || die "CERTBOT_EMAIL is not set (install with --email; used for Let's Encrypt)"
  ROTATION_INTERVAL_DAYS="${ROTATION_INTERVAL_DAYS:-1}"
  DOMAIN_RETENTION_DAYS="${DOMAIN_RETENTION_DAYS:-14}"
  # Normalize origins to hostnames (strip scheme/path if a URL was provided).
  CDN_ORIGIN="$(normalize_origin_host "${CDN_ORIGIN}")"
  BACKEND_ORIGIN="$(normalize_origin_host "${BACKEND_ORIGIN}")"
  assert_usable_origin_host "CDN_ORIGIN" "${CDN_ORIGIN}"
  assert_usable_origin_host "BACKEND_ORIGIN" "${BACKEND_ORIGIN}"
  export CERTBOT_EMAIL
  # Migrate legacy single CLIENT_NAME into clients/ if needed, then require ≥1 client.
  ensure_clients_migrated
  discover_clients
  if domain_source_is_manual; then
    load_manual_domains
  fi
}

# Accept "example.com" or "https://example.com/path" and return host[:port].
normalize_origin_host() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  [[ -n "${value}" ]] || die "Origin host is empty after normalization"
  printf '%s\n' "${value}"
}

# Reject placeholders like "cdn_backend" that make nginx fail DNS at startup
# when used in a literal proxy_pass (and are never valid public upstreams).
assert_usable_origin_host() {
  local name="$1"
  local host="$2"
  local bare="${host%%:*}"

  if [[ "${bare}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 0
  fi
  if [[ "${bare}" != *.* ]]; then
    die "${name}='${host}' is not a usable hostname (need a real FQDN or IP, e.g. cdn.example.com — not a placeholder like cdn_backend)"
  fi
  if command -v getent >/dev/null 2>&1; then
    if ! getent ahosts "${bare}" >/dev/null 2>&1; then
      log "WARNING: ${name}=${host} did not resolve now; nginx will retry DNS per-request"
    fi
  fi
}

load_registrant() {
  load_env_file "${REGISTRANT_FILE}"
  local required=(
    REGISTRANT_FIRSTNAME
    REGISTRANT_LASTNAME
    REGISTRANT_PHONE
    REGISTRANT_STREET
    REGISTRANT_CITY
    REGISTRANT_COUNTRYCODE
    REGISTRANT_POSTALCODE
  )
  local key
  for key in "${required[@]}"; do
    [[ -n "${!key:-}" ]] || die "${key} is not set in ${REGISTRANT_FILE}"
  done

  # InternetBS sends verification to this address; keep it identical to --email / Certbot.
  [[ -n "${CERTBOT_EMAIL:-}" ]] || die "CERTBOT_EMAIL must be set before load_registrant (credentials.env / --email)"
  if [[ -n "${REGISTRANT_EMAIL:-}" && "${REGISTRANT_EMAIL}" != "${CERTBOT_EMAIL}" ]]; then
    log "Using --email / CERTBOT_EMAIL for InternetBS contacts (was REGISTRANT_EMAIL=${REGISTRANT_EMAIL})"
  fi
  REGISTRANT_EMAIL="${CERTBOT_EMAIL}"
}

# Discover /etc/proxies/clients/*.env (basename = client id).
discover_clients() {
  CLIENT_NAMES=()
  mkdir -p "${CLIENTS_DIR}"
  local f name
  shopt -s nullglob
  for f in "${CLIENTS_DIR}"/*.env; do
    name="$(basename "${f}" .env)"
    [[ -n "${name}" && "${name}" != "*" ]] || continue
    if [[ ! "${name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
      die "Invalid client id '${name}' in ${f} (use letters, digits, _ or -)"
    fi
    CLIENT_NAMES+=("${name}")
  done
  shopt -u nullglob
  [[ ${#CLIENT_NAMES[@]} -gt 0 ]] || die "No clients configured under ${CLIENTS_DIR} (add <name>.env or re-run install with --client NAME)"
}

# Lowercase FQDN, strip scheme/path/trailing dot.
normalize_domain_name() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%.}"
  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  printf '%s\n' "${value}"
}

validate_domain_name() {
  local domain="$1"
  [[ -n "${domain}" ]] || die "Domain name is empty"
  if [[ ! "${domain}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    die "Invalid domain '${domain}' (need a real FQDN like example.com)"
  fi
}

load_manual_domains() {
  MANUAL_DOMAINS=()
  if [[ ! -f "${MANUAL_DOMAINS_FILE}" ]]; then
    return 0
  fi
  local line domain
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    domain="$(normalize_domain_name "${line}")"
    [[ -n "${domain}" ]] || continue
    validate_domain_name "${domain}"
    local existing found=0
    for existing in "${MANUAL_DOMAINS[@]+"${MANUAL_DOMAINS[@]}"}"; do
      if [[ "${existing}" == "${domain}" ]]; then
        found=1
        break
      fi
    done
    if [[ "${found}" -eq 0 ]]; then
      MANUAL_DOMAINS+=("${domain}")
    fi
  done <"${MANUAL_DOMAINS_FILE}"
}

manual_domain_in_list() {
  local needle="$1"
  local d
  for d in "${MANUAL_DOMAINS[@]+"${MANUAL_DOMAINS[@]}"}"; do
    if [[ "${d}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

append_manual_domain() {
  local domain="$1"
  domain="$(normalize_domain_name "${domain}")"
  validate_domain_name "${domain}"
  load_manual_domains
  if manual_domain_in_list "${domain}"; then
    return 0
  fi
  mkdir -p "$(dirname "${MANUAL_DOMAINS_FILE}")"
  if [[ ! -f "${MANUAL_DOMAINS_FILE}" ]]; then
    printf '# One FQDN per line. Used when DOMAIN_SOURCE=manual.\n' >"${MANUAL_DOMAINS_FILE}"
  fi
  printf '%s\n' "${domain}" >>"${MANUAL_DOMAINS_FILE}"
  chmod 644 "${MANUAL_DOMAINS_FILE}"
  MANUAL_DOMAINS+=("${domain}")
  log "Added ${domain} to ${MANUAL_DOMAINS_FILE}"
}

# First unused/incomplete listed domain, else empty.
find_unused_manual_domain() {
  local domain status
  load_manual_domains
  for domain in "${MANUAL_DOMAINS[@]+"${MANUAL_DOMAINS[@]}"}"; do
    status="$(get_domain_status "${domain}")"
    case "${status}" in
      ""|"${DOMAIN_STATUS_PURCHASED}"|"${DOMAIN_STATUS_DNS}"|"${DOMAIN_STATUS_SSL}")
        printf '%s\n' "${domain}"
        return 0
        ;;
    esac
  done
  return 1
}

# Next listed domain after current (wrap). Used by force-rotate when all are active.
next_manual_domain_after_current() {
  local current="" domain i
  load_manual_domains
  [[ ${#MANUAL_DOMAINS[@]} -gt 0 ]] || return 1
  if [[ -f "${CURRENT_DOMAIN_FILE}" ]]; then
    current="$(tr -d '[:space:]' <"${CURRENT_DOMAIN_FILE}")"
  fi
  if [[ -z "${current}" ]]; then
    printf '%s\n' "${MANUAL_DOMAINS[0]}"
    return 0
  fi
  for i in "${!MANUAL_DOMAINS[@]}"; do
    if [[ "${MANUAL_DOMAINS[$i]}" == "${current}" ]]; then
      printf '%s\n' "${MANUAL_DOMAINS[$(( (i + 1) % ${#MANUAL_DOMAINS[@]} ))]}"
      return 0
    fi
  done
  printf '%s\n' "${MANUAL_DOMAINS[0]}"
}

# Legacy installs stored CLIENT_NAME in credentials.env; create clients/<name>.env once.
ensure_clients_migrated() {
  mkdir -p "${CLIENTS_DIR}"
  shopt -s nullglob
  local existing=("${CLIENTS_DIR}"/*.env)
  shopt -u nullglob
  if [[ ${#existing[@]} -gt 0 ]]; then
    return 0
  fi
  if [[ -n "${CLIENT_NAME:-}" ]]; then
    local dest="${CLIENTS_DIR}/${CLIENT_NAME}.env"
    {
      printf '# Migrated from credentials.env CLIENT_NAME\n'
      if [[ -n "${CASINO_ID:-}" ]]; then
        printf 'CASINO_ID="%s"\n' "${CASINO_ID}"
      else
        printf '# CASINO_ID="%s"\n' "${CLIENT_NAME}"
      fi
    } >"${dest}"
    chmod 600 "${dest}"
    log "Migrated CLIENT_NAME=${CLIENT_NAME} to ${dest}"
  fi
}

# Load optional CASINO_ID (and other vars) from a client file into the environment.
load_client_env() {
  local client="$1"
  local file="${CLIENTS_DIR}/${client}.env"
  [[ -f "${file}" ]] || die "Missing client config: ${file}"
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1090
  source "${file}"
  set +a
  CASINO_ID="${CASINO_ID:-${client}}"
  CLIENT_NAME="${client}"
}

_read_prefix_lines() {
  local file="$1"
  shift
  local -a defaults=("$@")
  local line
  if [[ -f "${file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
      printf '%s\n' "${line}"
    done <"${file}"
  else
    local d
    for d in "${defaults[@]}"; do
      printf '%s\n' "${d}"
    done
  fi
}

_dedupe_list() {
  local -a input=("$@")
  local -a unique=()
  local item existing found
  for item in "${input[@]+"${input[@]}"}"; do
    found=0
    for existing in "${unique[@]+"${unique[@]}"}"; do
      if [[ "${existing}" == "${item}" ]]; then
        found=1
        break
      fi
    done
    if [[ "${found}" -eq 0 ]]; then
      unique+=("${item}")
    fi
  done
  printf '%s\n' "${unique[@]+"${unique[@]}"}"
}

# Expand client + shared prefix templates into ORIGIN_PREFIXES for all clients.
load_origin_prefixes() {
  ORIGIN_PREFIXES=()
  [[ ${#CLIENT_NAMES[@]} -gt 0 ]] || discover_clients

  local -a client_templates=()
  local -a shared=()
  local line prefix client

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    client_templates+=("${line}")
  done < <(_read_prefix_lines "${PREFIXES_CLIENT_FILE}" "${DEFAULT_CLIENT_PREFIXES[@]}")

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    shared+=("${line}")
  done < <(_read_prefix_lines "${PREFIXES_SHARED_FILE}" "${DEFAULT_SHARED_PREFIXES[@]}")

  for client in "${CLIENT_NAMES[@]}"; do
    for line in "${client_templates[@]+"${client_templates[@]}"}"; do
      prefix="${line//__CLIENT__/${client}}"
      [[ -n "${prefix}" ]] || continue
      ORIGIN_PREFIXES+=("${prefix}")
    done
  done
  for line in "${shared[@]+"${shared[@]}"}"; do
    [[ -n "${line}" ]] || continue
    ORIGIN_PREFIXES+=("${line}")
  done

  local -a unique=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    unique+=("${line}")
  done < <(_dedupe_list "${ORIGIN_PREFIXES[@]+"${ORIGIN_PREFIXES[@]}"}")
  ORIGIN_PREFIXES=("${unique[@]}")

  [[ ${#ORIGIN_PREFIXES[@]} -gt 0 ]] || die "ORIGIN_PREFIXES is empty"
}

# Prefixes for a single client (client templates expanded + shared) — for per-client JSON.
client_origin_prefixes() {
  local client="$1"
  local -a out=()
  local line prefix

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    out+=("${line}")
  done < <(client_only_origin_prefixes "${client}")

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    out+=("${line}")
  done < <(shared_origin_prefixes)

  _dedupe_list "${out[@]+"${out[@]}"}"
}

# Shared origin labels only (no client expansion).
shared_origin_prefixes() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    printf '%s\n' "${line}"
  done < <(_read_prefix_lines "${PREFIXES_SHARED_FILE}" "${DEFAULT_SHARED_PREFIXES[@]}")
}

# One client's expanded labels only (no shared).
client_only_origin_prefixes() {
  local client="$1"
  local line prefix
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    prefix="${line//__CLIENT__/${client}}"
    printf '%s\n' "${prefix}"
  done < <(_read_prefix_lines "${PREFIXES_CLIENT_FILE}" "${DEFAULT_CLIENT_PREFIXES[@]}")
}

# Append a prefix line if missing (idempotent migration for existing VMs).
_ensure_prefix_line() {
  local file="$1"
  local line="$2"
  [[ -f "${file}" ]] || return 0
  if ! grep -qx "${line}" "${file}" 2>/dev/null; then
    printf '%s\n' "${line}" >>"${file}"
    log "Added ${line} to ${file}"
  fi
}

# Legacy: shared hostnames that must exist with and without -bgsp.
_ensure_shared_bgsp_aliases() {
  local file="$1"
  _ensure_prefix_line "${file}" "player-history-prod-bgsp"
  _ensure_prefix_line "${file}" "tournaments-prod-bgsp"
}

# Legacy: every client-specific prefix must exist with and without -bgsp.
_ensure_client_bgsp_aliases() {
  local file="$1"
  local line base
  local -a existing=()
  [[ -f "${file}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    existing+=("${line}")
  done <"${file}"

  for line in "${existing[@]}"; do
    [[ "${line}" == *__CLIENT__* ]] || continue
    if [[ "${line}" == *-bgsp ]]; then
      base="${line%-bgsp}"
      _ensure_prefix_line "${file}" "${base}"
    else
      _ensure_prefix_line "${file}" "${line}-bgsp"
    fi
  done

  # Guarantee the standard set (both variants).
  local p
  for p in "${DEFAULT_CLIENT_PREFIXES[@]}"; do
    _ensure_prefix_line "${file}" "${p}"
  done
}

ensure_prefix_files() {
  mkdir -p "${PROXIES_ETC}"
  if [[ ! -f "${PREFIXES_CLIENT_FILE}" ]]; then
    if [[ -f "${PROXIES_ROOT}/config/prefixes-client.env.example" ]]; then
      cp "${PROXIES_ROOT}/config/prefixes-client.env.example" "${PREFIXES_CLIENT_FILE}"
    else
      printf '%s\n' "${DEFAULT_CLIENT_PREFIXES[@]}" >"${PREFIXES_CLIENT_FILE}"
    fi
    chmod 644 "${PREFIXES_CLIENT_FILE}"
    log "Wrote ${PREFIXES_CLIENT_FILE}"
  else
    _ensure_client_bgsp_aliases "${PREFIXES_CLIENT_FILE}"
  fi
  if [[ ! -f "${PREFIXES_SHARED_FILE}" ]]; then
    if [[ -f "${PROXIES_ROOT}/config/prefixes-shared.env.example" ]]; then
      cp "${PROXIES_ROOT}/config/prefixes-shared.env.example" "${PREFIXES_SHARED_FILE}"
    else
      printf '%s\n' "${DEFAULT_SHARED_PREFIXES[@]}" >"${PREFIXES_SHARED_FILE}"
    fi
    chmod 644 "${PREFIXES_SHARED_FILE}"
    log "Wrote ${PREFIXES_SHARED_FILE}"
  else
    _ensure_shared_bgsp_aliases "${PREFIXES_SHARED_FILE}"
  fi
}

# Backward-compatible name used by older call sites / tests.
load_url_prefix_map() {
  load_origin_prefixes
}

ensure_url_prefixes_file() {
  ensure_prefix_files
}

detect_public_ip() {
  local ip=""
  local endpoint
  for endpoint in \
    "https://ifconfig.me" \
    "https://api.ipify.org" \
    "https://icanhazip.com"; do
    if ip="$(curl -4 -fsS --max-time 10 "${endpoint}" 2>/dev/null | tr -d '[:space:]')"; then
      if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s\n' "${ip}"
        return 0
      fi
    fi
  done
  die "Unable to detect public IPv4 address"
}

random_label() {
  local length="${1:-20}"
  local result=""
  # LC_ALL=C avoids "Illegal byte sequence" on macOS when reading /dev/urandom.
  while [[ ${#result} -lt ${length} ]]; do
    result+="$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c "$((length * 2))" || true)"
  done
  printf '%s\n' "${result:0:${length}}"
}

ensure_runtime_dirs() {
  mkdir -p "${PROXIES_ETC}" "${PROXIES_STATE}" "${DOMAINS_DIR}" "${CLIENTS_DIR}" "${URLS_DIR}" \
    "${ACME_WEBROOT}/.well-known/acme-challenge"
  # Directory must be traversable by nginx (www-data) so it can read api.htpasswd.
  # Secret files inside stay mode 600.
  chmod 755 "${PROXIES_ETC}" "${PROXIES_STATE}" "${DOMAINS_DIR}" "${CLIENTS_DIR}" "${URLS_DIR}" \
    "${ACME_WEBROOT}" "${ACME_WEBROOT}/.well-known" "${ACME_WEBROOT}/.well-known/acme-challenge"
}

# Make Basic Auth + URL JSON files readable by the nginx worker (www-data).
ensure_api_nginx_permissions() {
  local nginx_user="www-data"
  if id "${nginx_user}" >/dev/null 2>&1; then
    :
  else
    nginx_user="nginx"
  fi

  chmod 755 "${PROXIES_ETC}" 2>/dev/null || true
  chmod 755 "${PROXIES_STATE}" 2>/dev/null || true

  if [[ -f "${API_HTPASSWD_FILE}" ]]; then
    chmod 640 "${API_HTPASSWD_FILE}"
    if id "${nginx_user}" >/dev/null 2>&1; then
      chown "root:${nginx_user}" "${API_HTPASSWD_FILE}" 2>/dev/null || chmod 644 "${API_HTPASSWD_FILE}"
    else
      chmod 644 "${API_HTPASSWD_FILE}"
    fi
  fi

  if [[ -f "${CURRENT_URLS_JSON}" ]]; then
    chmod 644 "${CURRENT_URLS_JSON}"
  fi
  if [[ -d "${URLS_DIR}" ]]; then
    chmod 755 "${URLS_DIR}"
    find "${URLS_DIR}" -type f -name '*.json' -exec chmod 644 {} \; 2>/dev/null || true
  fi
}


domain_stamp_dir() {
  local domain="$1"
  printf '%s/%s\n' "${DOMAINS_DIR}" "${domain}"
}

domain_status_file() {
  local domain="$1"
  printf '%s/status\n' "$(domain_stamp_dir "${domain}")"
}

get_domain_status() {
  local domain="$1"
  local status_file
  status_file="$(domain_status_file "${domain}")"
  if [[ -f "${status_file}" ]]; then
    tr -d '[:space:]' <"${status_file}"
  else
    printf '\n'
  fi
}

set_domain_status() {
  local domain="$1"
  local status="$2"
  local stamp_dir
  stamp_dir="$(domain_stamp_dir "${domain}")"
  mkdir -p "${stamp_dir}"
  if [[ ! -f "${stamp_dir}/created" ]]; then
    date -u +'%Y-%m-%dT%H:%M:%SZ' >"${stamp_dir}/created"
  fi
  date -u +'%Y-%m-%dT%H:%M:%SZ' >"${stamp_dir}/last_seen"
  printf '%s\n' "${status}" >"$(domain_status_file "${domain}")"
  log "Domain ${domain} status -> ${status}"
}

set_pending_domain() {
  local domain="$1"
  printf '%s\n' "${domain}" >"${PENDING_DOMAIN_FILE}"
}

clear_pending_domain() {
  rm -f "${PENDING_DOMAIN_FILE}"
}

get_pending_domain() {
  if [[ -f "${PENDING_DOMAIN_FILE}" ]]; then
    tr -d '[:space:]' <"${PENDING_DOMAIN_FILE}"
  else
    printf '\n'
  fi
}

# Find a purchased domain that is not fully active yet (resume candidate).
find_incomplete_domain() {
  local stamp_dir domain status
  shopt -s nullglob
  for stamp_dir in "${DOMAINS_DIR}"/*; do
    [[ -d "${stamp_dir}" ]] || continue
    domain="$(basename "${stamp_dir}")"
    status="$(get_domain_status "${domain}")"
    case "${status}" in
      purchased|dns_configured|ssl_issued)
        printf '%s\n' "${domain}"
        shopt -u nullglob
        return 0
        ;;
    esac
  done
  shopt -u nullglob

  domain="$(get_pending_domain)"
  if [[ -n "${domain}" ]]; then
    printf '%s\n' "${domain}"
    return 0
  fi
  return 1
}

mark_domain_purchased() {
  local domain="$1"
  set_domain_status "${domain}" "${DOMAIN_STATUS_PURCHASED}"
  set_pending_domain "${domain}"
}

mark_domain_dns_configured() {
  local domain="$1"
  set_domain_status "${domain}" "${DOMAIN_STATUS_DNS}"
  set_pending_domain "${domain}"
}

mark_domain_ssl_issued() {
  local domain="$1"
  set_domain_status "${domain}" "${DOMAIN_STATUS_SSL}"
  set_pending_domain "${domain}"
}

mark_domain_active() {
  local domain="$1"
  set_domain_status "${domain}" "${DOMAIN_STATUS_ACTIVE}"
  clear_pending_domain
  printf '%s\n' "${domain}" >"${CURRENT_DOMAIN_FILE}"
}

# Listed manual domains stay on the VM; retention only expires leftover/old names.
domain_is_protected() {
  local domain="$1"
  domain_source_is_manual || return 1
  load_manual_domains
  manual_domain_in_list "${domain}"
}

# Return 0 if stamp_dir is older than DOMAIN_RETENTION_DAYS (based on created file mtime).
domain_is_expired() {
  local stamp_dir="$1"
  local created_file="${stamp_dir}/created"
  [[ -f "${created_file}" ]] || return 1
  local age_seconds now created_epoch
  now="$(date +%s)"
  created_epoch="$(stat -c '%Y' "${created_file}" 2>/dev/null || stat -f '%m' "${created_file}")"
  age_seconds=$((now - created_epoch))
  [[ "${age_seconds}" -gt $((DOMAIN_RETENTION_DAYS * 86400)) ]]
}

# Return 0 when a scheduled purchase should wait (current domain still within interval).
rotation_interval_not_elapsed() {
  local interval="${ROTATION_INTERVAL_DAYS:-1}"
  if [[ ! "${interval}" =~ ^[1-9][0-9]*$ ]]; then
    interval=1
  fi
  # Daily (or invalid <=1): always allow scheduled rotation.
  if [[ "${interval}" -le 1 ]]; then
    return 1
  fi

  local domain=""
  [[ -f "${CURRENT_DOMAIN_FILE}" ]] || return 1
  domain="$(tr -d '[:space:]' <"${CURRENT_DOMAIN_FILE}")"
  [[ -n "${domain}" ]] || return 1

  local created_file
  created_file="$(domain_stamp_dir "${domain}")/created"
  [[ -f "${created_file}" ]] || return 1

  local now created_epoch age_seconds
  now="$(date +%s)"
  created_epoch="$(stat -c '%Y' "${created_file}" 2>/dev/null || stat -f '%m' "${created_file}")"
  age_seconds=$((now - created_epoch))
  [[ "${age_seconds}" -lt $((interval * 86400)) ]]
}

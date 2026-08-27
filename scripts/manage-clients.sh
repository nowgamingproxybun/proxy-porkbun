#!/usr/bin/env bash
# Add / remove / list clients on an already-installed proxies VM.
# Updates /etc/proxies/clients/, re-renders nginx origin sites for tracked domains,
# and regenerates /api/game/url-extended/<client> JSON for the current domain.
#
# Usage:
#   sudo /opt/proxies/scripts/manage-clients.sh list
#   sudo /opt/proxies/scripts/manage-clients.sh add NAME [--casino-id ID]
#   sudo /opt/proxies/scripts/manage-clients.sh remove NAME [--yes]
#   sudo /opt/proxies/scripts/manage-clients.sh sync
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
Usage: manage-clients.sh <command> [args]

Commands:
  list                          Show configured clients
  add NAME [--casino-id ID]     Add a client and apply nginx/JSON for live domains
  remove NAME [--yes]           Remove a client (refuses to remove the last one)
  sync                          Re-apply nginx + URL JSON from current clients/*.env

Examples:
  sudo /opt/proxies/scripts/manage-clients.sh add clientname42
  sudo /opt/proxies/scripts/manage-clients.sh add clientname42 --casino-id casino42
  sudo /opt/proxies/scripts/manage-clients.sh remove oldclient --yes
  sudo /opt/proxies/scripts/manage-clients.sh sync
EOF
}

validate_client_id() {
  local name="$1"
  [[ -n "${name}" ]] || die "Client name is empty"
  if [[ ! "${name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    die "Invalid client id '${name}' (use letters, digits, _ or -)"
  fi
}

list_tracked_domains() {
  local stamp_dir
  shopt -s nullglob
  for stamp_dir in "${DOMAINS_DIR}"/*; do
    [[ -d "${stamp_dir}" ]] || continue
    basename "${stamp_dir}"
  done
  shopt -u nullglob
}

# Re-render nginx for every tracked domain + URL JSON for the current domain.
apply_clients() {
  local domain current=""
  ensure_prefix_files
  install_websocket_map
  install_server_names_hash
  discover_clients

  local domains=()
  local d
  while IFS= read -r d || [[ -n "${d}" ]]; do
    [[ -n "${d}" ]] || continue
    domains+=("${d}")
  done < <(list_tracked_domains)

  if [[ ${#domains[@]} -eq 0 ]]; then
    log "No tracked domains under ${DOMAINS_DIR}; client files updated (nginx applies on next rotation)"
    return 0
  fi

  for domain in "${domains[@]}"; do
    log "Refreshing certificate + nginx sites for ${domain}"
    ensure_domain_certificate "${domain}"
    enable_domain_sites "${domain}"
  done

  if [[ -f "${CURRENT_DOMAIN_FILE}" ]]; then
    current="$(tr -d '[:space:]' <"${CURRENT_DOMAIN_FILE}")"
  fi
  if [[ -z "${current}" ]]; then
    current="${domains[0]}"
  fi

  write_current_urls_json "${current}"
  render_api_ip_vhost
  nginx_test_and_reload
  log "Clients applied: ${CLIENT_NAMES[*]} (URL API domain=${current})"
}

cmd_list() {
  mkdir -p "${CLIENTS_DIR}"
  local f name casino
  local found=0
  shopt -s nullglob
  for f in "${CLIENTS_DIR}"/*.env; do
    found=1
    name="$(basename "${f}" .env)"
    casino="$(
      CASINO_ID=""
      set -a
      # shellcheck disable=SC1090
      source "${f}"
      set +a
      printf '%s' "${CASINO_ID:-}"
    )"
    if [[ -n "${casino}" ]]; then
      printf '%s  (CASINO_ID=%s)\n' "${name}" "${casino}"
    else
      printf '%s\n' "${name}"
    fi
  done
  shopt -u nullglob
  if [[ "${found}" -eq 0 ]]; then
    log "No clients in ${CLIENTS_DIR}"
  fi
}

cmd_add() {
  local name="${1:-}"
  local casino_id=""
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --casino-id)
        casino_id="${2:-}"
        shift 2
        ;;
      *)
        die "Unknown option for add: $1"
        ;;
    esac
  done

  validate_client_id "${name}"
  mkdir -p "${CLIENTS_DIR}"
  local dest="${CLIENTS_DIR}/${name}.env"
  if [[ -f "${dest}" ]]; then
    die "Client already exists: ${dest}"
  fi

  if [[ -n "${casino_id}" ]]; then
    printf 'CASINO_ID="%s"\n' "${casino_id}" >"${dest}"
  elif [[ -f "${PROXIES_ROOT}/config/client.env.example" ]]; then
    cp "${PROXIES_ROOT}/config/client.env.example" "${dest}"
  else
    printf '# client %s\n' "${name}" >"${dest}"
  fi
  chmod 600 "${dest}"
  log "Created ${dest}"
  apply_clients
}

cmd_remove() {
  local name="${1:-}"
  local assume_yes=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y)
        assume_yes=1
        shift
        ;;
      *)
        die "Unknown option for remove: $1"
        ;;
    esac
  done

  validate_client_id "${name}"
  local dest="${CLIENTS_DIR}/${name}.env"
  [[ -f "${dest}" ]] || die "Client not found: ${dest}"

  local count=0
  local f
  shopt -s nullglob
  for f in "${CLIENTS_DIR}"/*.env; do
    count=$((count + 1))
  done
  shopt -u nullglob
  [[ "${count}" -gt 1 ]] || die "Refusing to remove the last client (${name})"

  if [[ "${assume_yes}" -eq 0 ]]; then
    printf 'Remove client %s? [y/N] ' "${name}" >&2
    local answer=""
    read -r answer || true
    [[ "${answer}" == "y" || "${answer}" == "Y" ]] || die "Aborted"
  fi

  rm -f "${dest}"
  rm -f "${URLS_DIR}/${name}.json"
  log "Removed ${dest}"

  # Drop per-client origin sites for this client on all domains (enable will recreate others).
  local domain
  while IFS= read -r domain || [[ -n "${domain}" ]]; do
    [[ -n "${domain}" ]] || continue
    rm -f \
      "${NGINX_SITES_ENABLED}/proxies-origin-${name}-${domain}.conf" \
      "${NGINX_SITES_AVAILABLE}/proxies-origin-${name}-${domain}.conf"
  done < <(list_tracked_domains)

  apply_clients
}

cmd_sync() {
  apply_clients
}

main() {
  local cmd="${1:-}"
  shift || true

  case "${cmd}" in
    ""|-h|--help|help)
      usage
      exit 0
      ;;
  esac

  require_root
  require_ubuntu_2604
  ensure_runtime_dirs
  load_credentials
  ensure_prefix_files

  case "${cmd}" in
    list)
      cmd_list
      ;;
    add)
      cmd_add "$@"
      ;;
    remove)
      cmd_remove "$@"
      ;;
    sync)
      cmd_sync
      ;;
    *)
      die "Unknown command: ${cmd} (use --help)"
      ;;
  esac
}

main "$@"

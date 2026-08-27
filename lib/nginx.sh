#!/usr/bin/env bash
# Nginx site rendering, enablement, reload, and aged-domain cleanup.

NGINX_SITES_AVAILABLE="${NGINX_SITES_AVAILABLE:-/etc/nginx/sites-available}"
NGINX_SITES_ENABLED="${NGINX_SITES_ENABLED:-/etc/nginx/sites-enabled}"
NGINX_CONF_D="${NGINX_CONF_D:-/etc/nginx/conf.d}"

install_websocket_map() {
  local src="${PROXIES_ROOT}/templates/websocket-map.conf"
  local dest="${NGINX_CONF_D}/proxies-websocket-map.conf"
  [[ -f "${src}" ]] || die "Missing template: ${src}"
  cp "${src}" "${dest}"
  log "Installed websocket map at ${dest}"
}

# Multi-client origin server_name lists need a larger hash bucket than Ubuntu's default (64).
install_server_names_hash() {
  local src="${PROXIES_ROOT}/templates/server-names-hash.conf"
  local dest="${NGINX_CONF_D}/proxies-server-names-hash.conf"
  if [[ -f "${src}" ]]; then
    cp "${src}" "${dest}"
  else
    cat >"${dest}" <<'EOF'
server_names_hash_bucket_size 128;
server_names_hash_max_size 2048;
EOF
  fi
  log "Installed server_names hash settings at ${dest}"
}

_render_template() {
  local template="$1"
  local domain="$2"
  sed "s|__DOMAIN__|${domain}|g" "${template}"
}

# Join prefix labels into "prefix.domain ..." for server_name.
_server_names_from_prefixes() {
  local domain="$1"
  shift
  local prefix
  local names=()
  for prefix in "$@"; do
    [[ -n "${prefix}" ]] || continue
    names+=("${prefix}.${domain}")
  done
  [[ ${#names[@]} -gt 0 ]] || return 1
  printf '%s\n' "${names[@]}" | paste -sd' ' -
}

render_cdn_vhost() {
  local domain="$1"
  local out="$2"
  local template="${PROXIES_ROOT}/templates/cdn.conf.tpl"
  [[ -f "${template}" ]] || die "Missing template: ${template}"
  [[ -n "${CDN_ORIGIN:-}" ]] || die "CDN_ORIGIN is not set"
  sed \
    -e "s|__DOMAIN__|${domain}|g" \
    -e "s|__CDN_ORIGIN__|${CDN_ORIGIN}|g" \
    "${template}" >"${out}"
}

# Render one origin server block with the given space-separated server_name list.
render_origin_vhost_names() {
  local domain="$1"
  local out="$2"
  local names="$3"
  local template="${PROXIES_ROOT}/templates/origin.conf.tpl"
  [[ -f "${template}" ]] || die "Missing template: ${template}"
  [[ -n "${BACKEND_ORIGIN:-}" ]] || die "BACKEND_ORIGIN is not set"
  [[ -n "${names}" ]] || die "origin server_name list is empty for ${out}"
  sed \
    -e "s|__DOMAIN__|${domain}|g" \
    -e "s|__ORIGIN_SERVER_NAMES__|${names}|g" \
    -e "s|__BACKEND_ORIGIN__|${BACKEND_ORIGIN}|g" \
    "${template}" >"${out}"
}

render_origin_shared_vhost() {
  local domain="$1"
  local out="$2"
  local -a prefixes=()
  local line names
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    prefixes+=("${line}")
  done < <(shared_origin_prefixes)
  names="$(_server_names_from_prefixes "${domain}" "${prefixes[@]+"${prefixes[@]}"}")" \
    || die "No shared origin prefixes configured"
  render_origin_vhost_names "${domain}" "${out}" "${names}"
}

render_origin_client_vhost() {
  local domain="$1"
  local client="$2"
  local out="$3"
  local -a prefixes=()
  local line names
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    prefixes+=("${line}")
  done < <(client_only_origin_prefixes "${client}")
  names="$(_server_names_from_prefixes "${domain}" "${prefixes[@]+"${prefixes[@]}"}")" \
    || die "No client origin prefixes for ${client}"
  render_origin_vhost_names "${domain}" "${out}" "${names}"
}

# Remove legacy monolithic origin site and any prior split sites for this domain.
_remove_origin_sites_for_domain() {
  local domain="$1"
  local f
  shopt -s nullglob
  for f in \
    "${NGINX_SITES_ENABLED}/proxies-origin-${domain}.conf" \
    "${NGINX_SITES_AVAILABLE}/proxies-origin-${domain}.conf" \
    "${NGINX_SITES_ENABLED}/proxies-origin-shared-${domain}.conf" \
    "${NGINX_SITES_AVAILABLE}/proxies-origin-shared-${domain}.conf" \
    "${NGINX_SITES_ENABLED}/proxies-origin-"*-"${domain}.conf" \
    "${NGINX_SITES_AVAILABLE}/proxies-origin-"*-"${domain}.conf"; do
    rm -f "${f}"
  done
  shopt -u nullglob
}

ensure_api_htpasswd() {
  [[ -f "${API_HTPASSWD_FILE}" ]] || die "Missing API htpasswd file: ${API_HTPASSWD_FILE} (re-run install with --api-user/--api-password)"
  ensure_api_nginx_permissions
}

render_api_ip_vhost() {
  local template="${PROXIES_ROOT}/templates/api-ip.conf.tpl"
  local out="${NGINX_SITES_AVAILABLE}/proxies-api-ip.conf"
  [[ -f "${template}" ]] || die "Missing template: ${template}"
  ensure_api_htpasswd
  mkdir -p "${URLS_DIR}"
  chmod 755 "${URLS_DIR}" 2>/dev/null || true
  # Drop Ubuntu default site so port 80 default_server is our API vhost.
  rm -f "${NGINX_SITES_ENABLED}/default"
  # Remove leftover self-signed API certs from older HTTPS installs.
  rm -f "${API_TLS_DIR}/api.crt" "${API_TLS_DIR}/api.key"
  mkdir -p "${ACME_WEBROOT}/.well-known/acme-challenge"
  chmod 755 "${ACME_WEBROOT}" "${ACME_WEBROOT}/.well-known" "${ACME_WEBROOT}/.well-known/acme-challenge" 2>/dev/null || true
  sed \
    -e "s|__API_HTPASSWD__|${API_HTPASSWD_FILE}|g" \
    -e "s|__URLS_ROOT__|${PROXIES_STATE}|g" \
    -e "s|__ACME_WEBROOT__|${ACME_WEBROOT}|g" \
    "${template}" >"${out}"
  ln -sfn "${out}" "${NGINX_SITES_ENABLED}/proxies-api-ip.conf"
  ensure_api_nginx_permissions
  log "Enabled IP API vhost (http /api/game/url-extended/<client> )"
}

enable_domain_sites() {
  local domain="$1"
  local cdn_avail="${NGINX_SITES_AVAILABLE}/proxies-cdn-${domain}.conf"
  local cdn_enabled="${NGINX_SITES_ENABLED}/proxies-cdn-${domain}.conf"
  local shared_avail="${NGINX_SITES_AVAILABLE}/proxies-origin-shared-${domain}.conf"
  local shared_enabled="${NGINX_SITES_ENABLED}/proxies-origin-shared-${domain}.conf"
  local client out_avail out_enabled
  local -a enabled_links=()
  local test_out=""

  [[ ${#CLIENT_NAMES[@]} -gt 0 ]] || discover_clients
  install_server_names_hash

  # Drop previous origin layout (monolithic or split) before rewriting.
  _remove_origin_sites_for_domain "${domain}"

  render_cdn_vhost "${domain}" "${cdn_avail}"
  render_origin_shared_vhost "${domain}" "${shared_avail}"

  ln -sfn "${cdn_avail}" "${cdn_enabled}"
  ln -sfn "${shared_avail}" "${shared_enabled}"
  enabled_links+=("${cdn_enabled}" "${shared_enabled}")

  for client in "${CLIENT_NAMES[@]}"; do
    out_avail="${NGINX_SITES_AVAILABLE}/proxies-origin-${client}-${domain}.conf"
    out_enabled="${NGINX_SITES_ENABLED}/proxies-origin-${client}-${domain}.conf"
    render_origin_client_vhost "${domain}" "${client}" "${out_avail}"
    ln -sfn "${out_avail}" "${out_enabled}"
    enabled_links+=("${out_enabled}")
  done

  # Drop Ubuntu default site so IP default_server is our API vhost.
  rm -f "${NGINX_SITES_ENABLED}/default"

  if ! test_out="$(nginx -t 2>&1)"; then
    log "ERROR: nginx -t failed after enabling ${domain}; rolling back site links"
    printf '%s\n' "${test_out}" >&2 || true
    local link
    for link in "${enabled_links[@]}"; do
      rm -f "${link}"
    done
    die "nginx config invalid for ${domain} (check CDN_ORIGIN=${CDN_ORIGIN:-?} BACKEND_ORIGIN=${BACKEND_ORIGIN:-?})"
  fi

  log "Enabled nginx sites for ${domain} (cdn + origin-shared + ${#CLIENT_NAMES[@]} client origin file(s))"
}

nginx_test_and_reload() {
  local test_out=""
  if ! test_out="$(nginx -t 2>&1)"; then
    log "ERROR: nginx -t failed; not reloading (process keeps prior config in memory)"
    printf '%s\n' "${test_out}" >&2 || true
    die "nginx configuration test failed"
  fi
  systemctl reload nginx
  log "nginx reloaded"
}

remove_domain_from_vm() {
  local domain="$1"
  local stamp_dir
  stamp_dir="$(domain_stamp_dir "${domain}")"

  log "Removing domain ${domain} from VM (older than ${DOMAIN_RETENTION_DAYS} days)"

  rm -f \
    "${NGINX_SITES_ENABLED}/proxies-cdn-${domain}.conf" \
    "${NGINX_SITES_AVAILABLE}/proxies-cdn-${domain}.conf"
  _remove_origin_sites_for_domain "${domain}"

  if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
    log "Deleting Let's Encrypt certificate for ${domain}"
    if certbot delete --non-interactive --cert-name "${domain}"; then
      log "Deleted Let's Encrypt certificate ${domain}"
    else
      log "WARNING: certbot delete failed for ${domain}; remove /etc/letsencrypt/{live,renewal}/${domain}* manually to stop renewals"
    fi
  fi

  rm -rf "${stamp_dir}"
}

# Keep all domains reachable until their stamp/created file is older than retention.
cleanup_expired_domains() {
  local stamp_dir domain removed=0
  shopt -s nullglob
  for stamp_dir in "${DOMAINS_DIR}"/*; do
    [[ -d "${stamp_dir}" ]] || continue
    domain="$(basename "${stamp_dir}")"
    if domain_is_protected "${domain}"; then
      log "Keeping domain ${domain} (listed in ${MANUAL_DOMAINS_FILE})"
    elif domain_is_expired "${stamp_dir}"; then
      remove_domain_from_vm "${domain}"
      removed=$((removed + 1))
    else
      log "Keeping domain ${domain} (within ${DOMAIN_RETENTION_DAYS}-day retention)"
    fi
  done
  shopt -u nullglob

  if [[ "${removed}" -gt 0 ]]; then
    nginx_test_and_reload
  fi
  log "Expired-domain cleanup complete (removed=${removed})"
}

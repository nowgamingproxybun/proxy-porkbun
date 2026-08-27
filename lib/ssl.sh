#!/usr/bin/env bash
# Certificate issuance: registrar DNS-01 wildcard, or HTTP-01 for manual domains.

DNS_PROPAGATION_SECONDS="${DNS_PROPAGATION_SECONDS:-120}"

# Hostnames that nginx serves for a domain (apex + CDN + origin prefixes).
domain_certificate_names() {
  local domain="$1"
  local line
  printf '%s\n' "${domain}"
  local prefix
  for prefix in "${CDN_PREFIXES[@]}"; do
    printf '%s.%s\n' "${prefix}" "${domain}"
  done
  [[ ${#CLIENT_NAMES[@]} -gt 0 ]] || discover_clients
  load_origin_prefixes
  for prefix in "${ORIGIN_PREFIXES[@]+"${ORIGIN_PREFIXES[@]}"}"; do
    [[ -n "${prefix}" ]] || continue
    printf '%s.%s\n' "${prefix}" "${domain}"
  done
}

cert_covers_names() {
  local domain="$1"
  local cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  [[ -f "${cert}" ]] || return 1
  local sans
  sans="$(openssl x509 -in "${cert}" -noout -ext subjectAltName 2>/dev/null || true)"
  if [[ -z "${sans}" ]]; then
    sans="$(openssl x509 -in "${cert}" -noout -text 2>/dev/null || true)"
  fi
  [[ -n "${sans}" ]] || return 1
  local name
  while IFS= read -r name || [[ -n "${name}" ]]; do
    [[ -n "${name}" ]] || continue
    if ! grep -Fq "DNS:${name}" <<<"${sans}"; then
      return 1
    fi
  done
}

issue_wildcard_certificate() {
  local domain="$1"
  local auth_hook="${PROXIES_ROOT}/hooks/certbot-auth.sh"
  local cleanup_hook="${PROXIES_ROOT}/hooks/certbot-cleanup.sh"

  [[ -x "${auth_hook}" ]] || die "Missing auth hook: ${auth_hook}"
  [[ -x "${cleanup_hook}" ]] || die "Missing cleanup hook: ${cleanup_hook}"
  [[ -n "${CERTBOT_EMAIL:-}" ]] || die "CERTBOT_EMAIL is required for Let's Encrypt registration"

  # Already issued (e.g. resume after later-stage failure).
  if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
    log "Certificate already present for ${domain}; skipping certbot issuance"
    return 0
  fi

  log "Requesting wildcard certificate for ${domain} and *.${domain} (email=${CERTBOT_EMAIL})"
  certbot certonly \
    --non-interactive \
    --agree-tos \
    --email "${CERTBOT_EMAIL}" \
    --manual \
    --preferred-challenges dns \
    --manual-auth-hook "${auth_hook}" \
    --manual-cleanup-hook "${cleanup_hook}" \
    --cert-name "${domain}" \
    -d "${domain}" \
    -d "*.${domain}"

  [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] \
    || die "Certificate files missing after certbot for ${domain}"
  log "Certificate issued for ${domain}"
}

issue_http_certificate() {
  local domain="$1"
  local -a names=()
  local name
  [[ -n "${CERTBOT_EMAIL:-}" ]] || die "CERTBOT_EMAIL is required for Let's Encrypt registration"

  while IFS= read -r name || [[ -n "${name}" ]]; do
    [[ -n "${name}" ]] || continue
    names+=("${name}")
  done < <(domain_certificate_names "${domain}")

  [[ ${#names[@]} -gt 0 ]] || die "No hostnames to certify for ${domain}"
  if [[ ${#names[@]} -gt 100 ]]; then
    die "Too many hostnames (${#names[@]}) for one Let's Encrypt cert (max 100). Reduce clients/prefixes or use Porkbun DNS-01 wildcards."
  fi

  if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && cert_covers_names "${domain}" < <(printf '%s\n' "${names[@]}"); then
    log "HTTP certificate already covers ${#names[@]} names for ${domain}; skipping certbot"
    return 0
  fi

  mkdir -p "${ACME_WEBROOT}/.well-known/acme-challenge"
  chmod 755 "${ACME_WEBROOT}" "${ACME_WEBROOT}/.well-known" "${ACME_WEBROOT}/.well-known/acme-challenge"
  render_api_ip_vhost
  nginx_test_and_reload

  log "Requesting HTTP-01 certificate for ${domain} (${#names[@]} names, email=${CERTBOT_EMAIL})"
  local -a certbot_args=(
    certonly
    --non-interactive
    --agree-tos
    --email "${CERTBOT_EMAIL}"
    --webroot
    -w "${ACME_WEBROOT}"
    --cert-name "${domain}"
    --expand
  )
  for name in "${names[@]}"; do
    certbot_args+=(-d "${name}")
  done
  certbot "${certbot_args[@]}"

  [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] \
    || die "Certificate files missing after certbot for ${domain}"
  log "HTTP-01 certificate issued for ${domain}"
}

# Wildcard via registrar DNS-01 when an API is configured; otherwise HTTP-01.
ensure_domain_certificate() {
  local domain="$1"
  ensure_certbot_renewal_hooks
  if dns_api_configured; then
    issue_wildcard_certificate "${domain}"
  else
    issue_http_certificate "${domain}"
  fi
}

ensure_certbot_renewal_hooks() {
  # Certbot renew reuses the auth/cleanup hooks stored in renewal config
  # when the certificate was issued with --manual-auth-hook.
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/usr/bin/env bash
systemctl reload nginx 2>/dev/null || true
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
}

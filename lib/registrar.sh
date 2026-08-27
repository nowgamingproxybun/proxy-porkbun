#!/usr/bin/env bash
# Dispatch domain purchase / DNS to the active registrar (Porkbun default).

active_dns_backend() {
  case "${DOMAIN_SOURCE:-porkbun}" in
    porkbun)
      if porkbun_configured; then
        printf 'porkbun\n'
      else
        printf 'none\n'
      fi
      ;;
    internetbs)
      if internetbs_configured; then
        printf 'internetbs\n'
      else
        printf 'none\n'
      fi
      ;;
    manual)
      if porkbun_configured; then
        printf 'porkbun\n'
      elif internetbs_configured; then
        printf 'internetbs\n'
      else
        printf 'none\n'
      fi
      ;;
    *)
      printf 'none\n'
      ;;
  esac
}

dns_api_configured() {
  [[ "$(active_dns_backend)" != "none" ]]
}

registrar_find_available_domain() {
  case "${DOMAIN_SOURCE:-porkbun}" in
    porkbun)
      porkbun_find_available_domain "$@"
      ;;
    internetbs)
      find_available_domain "$@"
      ;;
    *)
      die "Cannot auto-purchase with DOMAIN_SOURCE=${DOMAIN_SOURCE}"
      ;;
  esac
}

registrar_register_domain() {
  case "${DOMAIN_SOURCE:-porkbun}" in
    porkbun)
      porkbun_register_domain "$@"
      ;;
    internetbs)
      internetbs_register_domain "$@"
      ;;
    *)
      die "Cannot auto-purchase with DOMAIN_SOURCE=${DOMAIN_SOURCE}"
      ;;
  esac
}

# point_domain_to_ip DOMAIN IP
registrar_point_domain_to_ip() {
  local domain="$1"
  local ip="$2"
  case "$(active_dns_backend)" in
    porkbun)
      porkbun_point_domain_to_ip "${domain}" "${ip}"
      ;;
    internetbs)
      internetbs_point_domain_to_ip "${domain}" "${ip}"
      ;;
    *)
      die "No DNS API configured for ${domain}"
      ;;
  esac
}

# registrar_dns_add APEX SUBDOMAIN TYPE VALUE
# SUBDOMAIN is "" for apex, "*" for wildcard, "_acme-challenge" for ACME.
# InternetBS uses a full record name instead.
registrar_dns_add() {
  local domain="$1"
  local name="$2"
  local type="$3"
  local value="$4"
  case "$(active_dns_backend)" in
    porkbun)
      porkbun_dns_add "${domain}" "${name}" "${type}" "${value}"
      ;;
    internetbs)
      if [[ -n "${name}" ]]; then
        internetbs_dns_add "${name}.${domain}" "${type}" "${value}"
      else
        internetbs_dns_add "${domain}" "${type}" "${value}"
      fi
      ;;
    *)
      die "No DNS API configured"
      ;;
  esac
}

registrar_dns_remove() {
  local domain="$1"
  local name="$2"
  local type="$3"
  local value="${4:-}"
  case "$(active_dns_backend)" in
    porkbun)
      porkbun_dns_remove "${domain}" "${name}" "${type}" "${value}"
      ;;
    internetbs)
      if [[ -n "${name}" ]]; then
        internetbs_dns_remove "${name}.${domain}" "${type}" "${value}" || true
      else
        internetbs_dns_remove "${domain}" "${type}" "${value}" || true
      fi
      ;;
    *)
      return 0
      ;;
  esac
}

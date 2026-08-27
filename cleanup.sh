#!/usr/bin/env bash
# Remove proxies toolkit artifacts from the OS after install/rotation attempts.
#
# Example (from GitHub):
#   curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/cleanup.sh | sudo bash -s -- --yes
#
# Or locally after install:
#   sudo /opt/proxies/scripts/cleanup.sh --yes
#   sudo ./cleanup.sh --yes --purge-packages
set -euo pipefail

PROXIES_ROOT="${PROXIES_ROOT:-/opt/proxies}"
PROXIES_ETC="${PROXIES_ETC:-/etc/proxies}"
PROXIES_STATE="${PROXIES_STATE:-/var/lib/proxies}"
PREFIX=""
ASSUME_YES=0
PURGE_PACKAGES=0
KEEP_CERTS=0
KEEP_LOGS=0

NGINX_SITES_AVAILABLE="${NGINX_SITES_AVAILABLE:-/etc/nginx/sites-available}"
NGINX_SITES_ENABLED="${NGINX_SITES_ENABLED:-/etc/nginx/sites-enabled}"
NGINX_CONF_D="${NGINX_CONF_D:-/etc/nginx/conf.d}"

usage() {
  cat <<'EOF'
Usage: cleanup.sh [options]

Removes nginx proxies sites, cron, toolkit dirs, and optionally Let's Encrypt
certs created for rotated domains. Does NOT delete domains at Porkbun.

Options:
  --yes                 Do not prompt for confirmation
  --purge-packages      apt purge nginx certbot apache2-utils (keeps curl/jq/openssl)
  --keep-certs          Do not delete Let's Encrypt certs for known domains
  --keep-logs           Do not delete /var/log/proxies-rotate.log
  --prefix DIR          Cleanup under a test prefix (same as install.sh --prefix)
  --proxies-root PATH   Override package root (default: /opt/proxies)
  -h, --help            Show this help
EOF
}

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)
      ASSUME_YES=1
      shift
      ;;
    --purge-packages)
      PURGE_PACKAGES=1
      shift
      ;;
    --keep-certs)
      KEEP_CERTS=1
      shift
      ;;
    --keep-logs)
      KEEP_LOGS=1
      shift
      ;;
    --prefix)
      PREFIX="${2:-}"
      shift 2
      ;;
    --proxies-root)
      PROXIES_ROOT="${2:-}"
      shift 2
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

if [[ -n "${PREFIX}" ]]; then
  PREFIX="${PREFIX%/}"
  PROXIES_ROOT="${PREFIX}/opt/proxies"
  PROXIES_ETC="${PREFIX}/etc/proxies"
  PROXIES_STATE="${PREFIX}/var/lib/proxies"
  NGINX_SITES_AVAILABLE="${PREFIX}/etc/nginx/sites-available"
  NGINX_SITES_ENABLED="${PREFIX}/etc/nginx/sites-enabled"
  NGINX_CONF_D="${PREFIX}/etc/nginx/conf.d"
else
  require_root
fi

if [[ "${ASSUME_YES}" -ne 1 ]]; then
  cat <<EOF
This will remove proxies toolkit files from:
  ${PROXIES_ROOT}
  ${PROXIES_ETC}
  ${PROXIES_STATE}
  nginx proxies-* site configs
  /etc/cron.d/proxies-domain-rotation
EOF
  if [[ "${KEEP_CERTS}" -eq 0 ]]; then
    echo "  Let's Encrypt certs for domains listed under ${PROXIES_STATE}/domains/"
  fi
  if [[ "${PURGE_PACKAGES}" -eq 1 ]]; then
    echo "  apt packages: nginx certbot apache2-utils"
  fi
  echo
  read -r -p "Continue? [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES) ;;
    *)
      log "Aborted"
      exit 0
      ;;
  esac
fi

remove_nginx_sites() {
  log "Removing nginx proxies site configs"
  shopt -s nullglob
  local f
  for f in \
    "${NGINX_SITES_ENABLED}"/proxies-*.conf \
    "${NGINX_SITES_AVAILABLE}"/proxies-*.conf \
    "${NGINX_CONF_D}"/proxies-*.conf
  do
    rm -f "${f}"
    log "Removed ${f}"
  done
  shopt -u nullglob

  if [[ -z "${PREFIX}" ]] && command -v nginx >/dev/null 2>&1; then
    if nginx -t 2>/dev/null; then
      systemctl reload nginx 2>/dev/null || true
      log "Reloaded nginx"
    else
      log "WARNING: nginx -t failed after cleanup; check remaining configs"
    fi
  fi
}

remove_certs_for_tracked_domains() {
  [[ "${KEEP_CERTS}" -eq 0 ]] || return 0
  [[ -d "${PROXIES_STATE}/domains" ]] || return 0

  if ! command -v certbot >/dev/null 2>&1; then
    log "certbot not installed; skipping Let's Encrypt cleanup"
    return 0
  fi

  local stamp_dir domain
  shopt -s nullglob
  for stamp_dir in "${PROXIES_STATE}/domains"/*; do
    [[ -d "${stamp_dir}" ]] || continue
    domain="$(basename "${stamp_dir}")"
    if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
      log "Deleting Let's Encrypt cert for ${domain}"
      certbot delete --non-interactive --cert-name "${domain}" >/dev/null 2>&1 || \
        log "WARNING: could not delete cert ${domain}"
    fi
  done
  shopt -u nullglob

  rm -f /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh 2>/dev/null || true
}

remove_cron() {
  local cron_file="/etc/cron.d/proxies-domain-rotation"
  if [[ -n "${PREFIX}" ]]; then
    cron_file="${PREFIX}/etc/cron.d/proxies-domain-rotation"
  fi
  if [[ -f "${cron_file}" ]]; then
    rm -f "${cron_file}"
    log "Removed ${cron_file}"
  fi
}

remove_dirs() {
  local path
  for path in "${PROXIES_ROOT}" "${PROXIES_ETC}" "${PROXIES_STATE}"; do
    if [[ -e "${path}" ]]; then
      rm -rf "${path}"
      log "Removed ${path}"
    fi
  done
}

remove_logs() {
  [[ "${KEEP_LOGS}" -eq 0 ]] || return 0
  if [[ -f /var/log/proxies-rotate.log ]]; then
    rm -f /var/log/proxies-rotate.log
    log "Removed /var/log/proxies-rotate.log"
  fi
}

purge_packages() {
  [[ "${PURGE_PACKAGES}" -eq 1 ]] || return 0
  [[ -z "${PREFIX}" ]] || {
    log "Skipping apt purge under --prefix"
    return 0
  }
  export DEBIAN_FRONTEND=noninteractive
  log "Purging nginx certbot apache2-utils"
  apt-get purge -y nginx nginx-common certbot python3-certbot-nginx apache2-utils || true
  apt-get autoremove -y || true
}

main() {
  log "Starting proxies cleanup"
  remove_nginx_sites
  remove_certs_for_tracked_domains
  remove_cron
  remove_dirs
  remove_logs
  purge_packages
  log "Cleanup complete"
  log "Note: domains registered at Porkbun were NOT cancelled"
}

main

#!/usr/bin/env bash
# Build per-client URL JSON files for the current domain.
# Served at /api/game/url-extended/<client> (shared Basic Auth for all clients).

write_client_urls_json() {
  local client="$1"
  local domain="$2"
  local out="${URLS_DIR}/${client}.json"
  local casino_id json

  mkdir -p "${URLS_DIR}"
  chmod 755 "${URLS_DIR}" 2>/dev/null || true

  # Isolate client env (CASINO_ID) without leaking into other clients.
  CASINO_ID=""
  load_client_env "${client}"
  casino_id="${CASINO_ID:-${client}}"

  json="$(jq -n \
    --arg hostUrl "https://${client}-gc-prod.${domain}" \
    --arg apiServerUrl "https://${client}-api-prod.${domain}" \
    --arg casinoId "${casino_id}" \
    --arg campaignUrl "https://campaign-prod.${domain}" \
    --arg jackpotContributionUrl "https://timescale-service-prod.${domain}" \
    --arg reconciliationUrl "https://history-service-prod.${domain}" \
    --arg matchHistoryUrl "https://player-history-prod.${domain}" \
    --arg tournamentUrl "https://tournaments-prod.${domain}" \
    --arg status "OK" \
    '{
      hostUrl: $hostUrl,
      apiServerUrl: $apiServerUrl,
      casinoId: $casinoId,
      campaignUrl: $campaignUrl,
      jackpotContributionUrl: $jackpotContributionUrl,
      reconciliationUrl: $reconciliationUrl,
      matchHistoryUrl: $matchHistoryUrl,
      tournamentUrl: $tournamentUrl,
      status: $status
    }')"

  printf '%s\n' "${json}" >"${out}"
  chmod 644 "${out}"
  log "Wrote client URLs JSON: ${out}"
}

write_current_urls_json() {
  local domain="$1"
  local first=""

  ensure_prefix_files
  [[ ${#CLIENT_NAMES[@]} -gt 0 ]] || discover_clients

  local client
  for client in "${CLIENT_NAMES[@]}"; do
    write_client_urls_json "${client}" "${domain}"
    if [[ -z "${first}" ]]; then
      first="${client}"
    fi
  done

  [[ -n "${first}" ]] || die "No clients available to write URL JSON"

  # Keep current-urls.json as a copy of the first client.
  mkdir -p "$(dirname "${CURRENT_URLS_JSON}")"
  chmod 755 "${PROXIES_STATE}" 2>/dev/null || true
  cp "${URLS_DIR}/${first}.json" "${CURRENT_URLS_JSON}"
  chmod 644 "${CURRENT_URLS_JSON}"
  log "URL API paths: /api/game/url-extended/<client> (clients: ${CLIENT_NAMES[*]})"
}

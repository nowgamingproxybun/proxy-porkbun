#!/usr/bin/env bash
# Porkbun API v3 helpers.
# Requires: curl, jq, PORKBUN_API_KEY, PORKBUN_SECRET_KEY
#
# checkDomain is rate-limited (default 1 / 10s). Availability scans sleep between tries.

PORKBUN_API_BASE="${PORKBUN_API_BASE:-https://api.porkbun.com/api/json/v3}"
PORKBUN_CONNECT_TIMEOUT="${PORKBUN_CONNECT_TIMEOUT:-15}"
PORKBUN_MAX_TIME="${PORKBUN_MAX_TIME:-60}"
PORKBUN_CHECK_GAP_SECONDS="${PORKBUN_CHECK_GAP_SECONDS:-11}"

porkbun_payload() {
  local extra="${1-}"
  if [[ -z "${extra}" ]]; then
    extra='{}'
  fi
  jq -n --arg k "${PORKBUN_API_KEY}" --arg s "${PORKBUN_SECRET_KEY}" --argjson e "${extra}" \
    '{apikey:$k, secretapikey:$s} + $e'
}

porkbun_status() {
  jq -r '.status // empty' <<<"$1"
}

# POST path [extra_json] [allow_fail=0]
# Prints response body. Retries once on HTTP 429.
porkbun_post() {
  local path="$1"
  local extra="${2-}"
  local allow_fail="${3:-0}"
  if [[ -z "${extra}" ]]; then
    extra='{}'
  fi
  local url="${PORKBUN_API_BASE}${path}"
  local payload response http_code body status wait_s attempt

  payload="$(porkbun_payload "${extra}")" \
    || die "Porkbun: failed to build JSON payload for ${path}"

  for attempt in 1 2; do
    log "Porkbun request: ${url}"
    response="$(
      curl -sS -w '\n%{http_code}' \
        --connect-timeout "${PORKBUN_CONNECT_TIMEOUT}" \
        --max-time "${PORKBUN_MAX_TIME}" \
        -X POST "${url}" \
        -H 'Content-Type: application/json' \
        -d "${payload}"
    )" || {
      if [[ "${allow_fail}" -eq 1 ]]; then
        return 1
      fi
      die "Porkbun request failed: ${path}. Check API keys, outbound HTTPS to api.porkbun.com, and network/firewall."
    }

    http_code="$(printf '%s\n' "${response}" | tail -n1)"
    body="$(printf '%s\n' "${response}" | sed '$d')"

    if [[ "${http_code}" == "429" ]]; then
      wait_s="$(jq -r '.ttlRemaining // empty' <<<"${body}" 2>/dev/null || true)"
      [[ "${wait_s}" =~ ^[0-9]+$ ]] || wait_s="${PORKBUN_CHECK_GAP_SECONDS}"
      log "Porkbun rate-limited ${path}; waiting ${wait_s}s"
      sleep "${wait_s}"
      continue
    fi

    if [[ "${http_code}" != "200" ]]; then
      if [[ "${allow_fail}" -eq 1 ]]; then
        printf '%s\n' "${body}"
        return 1
      fi
      die "Porkbun HTTP ${http_code} for ${path}: ${body}"
    fi

    status="$(porkbun_status "${body}")"
    if [[ "${status}" != "SUCCESS" ]]; then
      if [[ "${allow_fail}" -eq 1 ]]; then
        printf '%s\n' "${body}"
        return 1
      fi
      die "Porkbun ${path} failed (status=${status:-empty}): ${body}"
    fi

    printf '%s\n' "${body}"
    return 0
  done

  if [[ "${allow_fail}" -eq 1 ]]; then
    return 1
  fi
  die "Porkbun still rate-limited after retry: ${path}"
}

# Prints "yes" or "no". Sets PORKBUN_LAST_PRICE_USD / PORKBUN_LAST_COST_CENTS.
porkbun_check_domain() {
  local domain="$1"
  local json avail price cost premium
  PORKBUN_LAST_PRICE_USD=""
  PORKBUN_LAST_COST_CENTS=""

  json="$(porkbun_post "/domain/checkDomain/${domain}" '{}' 1)" || {
    log "Porkbun check failed for ${domain}: ${json}"
    printf 'no\n'
    return 1
  }

  avail="$(jq -r '.avail // .response.avail // .response.available // empty' <<<"${json}")"
  premium="$(jq -r '.premium // .response.premium // "no"' <<<"${json}")"
  price="$(jq -r '.price // .response.price // .response.registration // empty' <<<"${json}")"
  cost="$(jq -r '.cost // .response.cost // empty' <<<"${json}")"

  case "$(printf '%s' "${premium}" | tr '[:upper:]' '[:lower:]')" in
    yes|true|1)
      log "Skipping premium domain ${domain}"
      printf 'no\n'
      return 1
      ;;
  esac

  if [[ "${cost}" =~ ^[0-9]+$ ]]; then
    PORKBUN_LAST_COST_CENTS="${cost}"
  elif [[ -n "${price}" && "${price}" != "null" ]]; then
    PORKBUN_LAST_PRICE_USD="${price}"
    PORKBUN_LAST_COST_CENTS="$(awk -v p="${price}" 'BEGIN { printf "%.0f", (p * 100) + 0.0001 }')"
  fi

  case "$(printf '%s' "${avail}" | tr '[:upper:]' '[:lower:]')" in
    yes|available|true|1)
      printf 'yes\n'
      return 0
      ;;
    *)
      printf 'no\n'
      return 1
      ;;
  esac
}

porkbun_domain_available() {
  local result
  result="$(porkbun_check_domain "$1")" || return 1
  [[ "${result}" == "yes" ]]
}

porkbun_register_domain() {
  local domain="$1"
  local json extra

  log "Verifying ${domain} is still available before Porkbun purchase"
  if ! porkbun_domain_available "${domain}"; then
    die "Refusing to purchase ${domain}: Porkbun checkDomain did not return available"
  fi
  [[ -n "${PORKBUN_LAST_COST_CENTS}" ]] \
    || die "Porkbun checkDomain did not return a price for ${domain}"

  log "Availability confirmed for ${domain} (cost=${PORKBUN_LAST_COST_CENTS} cents); proceeding with domain/create"
  extra="$(jq -n --argjson c "${PORKBUN_LAST_COST_CENTS}" \
    '{cost:$c, agreeToTerms:"yes", whoisPrivacy:true}')"
  json="$(porkbun_post "/domain/create/${domain}" "${extra}")"
  log "Registered domain ${domain} via Porkbun (order=$(jq -r '.orderId // empty' <<<"${json}"))"
}

# name = subdomain only ("" apex, "*" wildcard, "_acme-challenge" TXT).
porkbun_dns_add() {
  local domain="$1"
  local name="$2"
  local type="$3"
  local value="$4"
  local extra json

  extra="$(jq -n --arg n "${name}" --arg t "${type}" --arg v "${value}" \
    '{name:$n, type:$t, content:$v, ttl:600}')"
  if json="$(porkbun_post "/dns/create/${domain}" "${extra}" 1)"; then
    log "Porkbun DNS ${type} ${name:-@}.${domain} -> ${value}"
    return 0
  fi

  if [[ "${type}" == "A" || "${type}" == "AAAA" ]]; then
    log "Porkbun DNS create returned error for ${name:-@}.${domain} ${type}; trying editByNameType"
    porkbun_dns_edit_by_name "${domain}" "${name}" "${type}" "${value}" || \
      die "Porkbun DNS add/edit failed for ${name:-@}.${domain} ${type}: ${json}"
    log "Porkbun DNS ${type} ${name:-@}.${domain} -> ${value}"
    return 0
  fi

  die "Porkbun DNS add failed for ${name:-@}.${domain} ${type}: ${json}"
}

porkbun_dns_edit_by_name() {
  local domain="$1"
  local name="$2"
  local type="$3"
  local value="$4"
  local path extra
  if [[ -n "${name}" ]]; then
    path="/dns/editByNameType/${domain}/${type}/$(jq -nr --arg n "${name}" '$n|@uri')"
  else
    path="/dns/editByNameType/${domain}/${type}"
  fi
  extra="$(jq -n --arg v "${value}" '{content:$v, ttl:600}')"
  porkbun_post "${path}" "${extra}"
}

porkbun_dns_remove() {
  local domain="$1"
  local name="$2"
  local type="$3"
  local value="${4:-}"
  local path json id

  if [[ -n "${name}" ]]; then
    path="/dns/retrieveByNameType/${domain}/${type}/$(jq -nr --arg n "${name}" '$n|@uri')"
  else
    path="/dns/retrieveByNameType/${domain}/${type}"
  fi
  json="$(porkbun_post "${path}" '{}' 1)" || {
    log "Porkbun DNS retrieve for remove ${type} ${name:-@}.${domain}: ${json:-ok}"
    return 0
  }

  while IFS= read -r id || [[ -n "${id}" ]]; do
    [[ -n "${id}" ]] || continue
    porkbun_post "/dns/delete/${domain}/${id}" '{}' 1 >/dev/null || true
    log "Porkbun DNS remove ${type} ${name:-@}.${domain} id=${id}"
  done < <(
    if [[ -n "${value}" ]]; then
      jq -r --arg v "${value}" '.records[]? | select(.content == $v) | .id // empty' <<<"${json}"
    else
      jq -r '.records[]? | .id // empty' <<<"${json}"
    fi
  )
}

porkbun_point_domain_to_ip() {
  local domain="$1"
  local ip="$2"
  porkbun_dns_add "${domain}" "" "A" "${ip}"
  porkbun_dns_add "${domain}" "*" "A" "${ip}"
}

porkbun_find_available_domain() {
  local max_attempts="${1:-30}"
  local attempt label domain
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    label="$(random_label 20)"
    domain="${label}.com"
    log "Checking Porkbun availability for ${domain} (attempt ${attempt}/${max_attempts})"
    if porkbun_domain_available "${domain}"; then
      log "Domain available: ${domain} (cost=${PORKBUN_LAST_COST_CENTS:-?} cents)"
      printf '%s\n' "${domain}"
      return 0
    fi
    log "Domain not available: ${domain}"
    if [[ "${attempt}" -lt "${max_attempts}" ]]; then
      sleep "${PORKBUN_CHECK_GAP_SECONDS}"
    fi
  done
  die "Unable to find an available domain after ${max_attempts} Porkbun checks"
}

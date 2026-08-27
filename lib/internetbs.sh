#!/usr/bin/env bash
# InternetBS Reseller API helpers.
# Requires: curl, jq, INTERNETBS_API_KEY, INTERNETBS_PASSWORD
#
# Set INTERNETBS_TEST_MODE=1 (or call internetbs_enable_test_mode) to use
# https://testapi.internet.bs with ApiKey=testapi / Password=testpass.

INTERNETBS_API_BASE="${INTERNETBS_API_BASE:-https://api.internet.bs}"
INTERNETBS_CURL_INSECURE="${INTERNETBS_CURL_INSECURE:-0}"
INTERNETBS_CONNECT_TIMEOUT="${INTERNETBS_CONNECT_TIMEOUT:-15}"
INTERNETBS_MAX_TIME="${INTERNETBS_MAX_TIME:-60}"

internetbs_enable_test_mode() {
  INTERNETBS_TEST_MODE=1
  INTERNETBS_API_BASE="https://testapi.internet.bs"
  INTERNETBS_API_KEY="testapi"
  INTERNETBS_PASSWORD="testpass"
  # Test endpoint may present a cert that stock CAs reject.
  INTERNETBS_CURL_INSECURE=1
  log "InternetBS TEST mode enabled (${INTERNETBS_API_BASE})"
}

internetbs_curl_args() {
  local args=(
    -sS
    --connect-timeout "${INTERNETBS_CONNECT_TIMEOUT}"
    --max-time "${INTERNETBS_MAX_TIME}"
  )
  if [[ "${INTERNETBS_CURL_INSECURE}" == "1" ]]; then
    args+=(-k)
  fi
  printf '%s\n' "${args[@]}"
}

internetbs_request() {
  local path="$1"
  shift
  local response http_code body
  local curl_opts=()
  mapfile -t curl_opts < <(internetbs_curl_args)

  log "InternetBS request: ${INTERNETBS_API_BASE}${path}"
  response="$(
    curl -f "${curl_opts[@]}" -w '\n%{http_code}' \
      --get "${INTERNETBS_API_BASE}${path}" \
      --data-urlencode "ApiKey=${INTERNETBS_API_KEY}" \
      --data-urlencode "Password=${INTERNETBS_PASSWORD}" \
      --data-urlencode "ResponseFormat=JSON" \
      "$@"
  )" || die "InternetBS request failed: ${path} (base=${INTERNETBS_API_BASE}). Check API key/password, outbound HTTPS to api.internet.bs, and network/firewall."

  http_code="$(printf '%s\n' "${response}" | tail -n1)"
  body="$(printf '%s\n' "${response}" | sed '$d')"

  if [[ "${http_code}" != "200" ]]; then
    die "InternetBS HTTP ${http_code} for ${path}: ${body}"
  fi

  printf '%s\n' "${body}"
}

internetbs_status() {
  local json="$1"
  jq -r '.status // .Status // empty' <<<"${json}"
}

internetbs_domain_available() {
  local domain="$1"
  local json status status_uc
  json="$(internetbs_request "/Domain/Check" --data-urlencode "Domain=${domain}")"
  status="$(internetbs_status "${json}")"
  status_uc="$(printf '%s' "${status}" | tr '[:lower:]' '[:upper:]')"

  # Docs: Domain/Check returns STATUS=AVAILABLE | UNAVAILABLE | FAILURE
  case "${status_uc}" in
    AVAILABLE)
      return 0
      ;;
    UNAVAILABLE)
      return 1
      ;;
    FAILURE)
      log "Domain check FAILURE for ${domain}: ${json}"
      return 1
      ;;
    *)
      log "Domain check unexpected status='${status}' for ${domain}: ${json}"
      return 1
      ;;
  esac
}

# Docs phone format: +1.23456789 (plus, country code, dot, subscriber number)
normalize_phone_number() {
  local phone="$1"
  phone="$(printf '%s' "${phone}" | tr -d '[:space:]-()')"
  if [[ "${phone}" =~ ^\+[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "${phone}"
    return 0
  fi
  if [[ "${phone}" =~ ^\+([0-9]{1,3})([0-9]{4,})$ ]]; then
    printf '+%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  die "Invalid phone '${phone}'. Use InternetBS format +CC.NUMBER (e.g. +1.5555555555)"
}

internetbs_register_domain() {
  local domain="$1"
  local json status
  local phone

  log "Verifying ${domain} is still available before purchase"
  if ! internetbs_domain_available "${domain}"; then
    die "Refusing to purchase ${domain}: Domain/Check did not return AVAILABLE"
  fi
  log "Availability confirmed for ${domain}; proceeding with Domain/Create"

  phone="$(normalize_phone_number "${REGISTRANT_PHONE}")"

  # Docs: .com requires Registrant, Admin, Technical, Billing with
  # FirstName, LastName, Email, PhoneNumber, Street, City, CountryCode, PostalCode.
  # privateWhois: FULL | PARTIAL | DISABLE
  local common_args=(
    --data-urlencode "Domain=${domain}"
    --data-urlencode "Period=1Y"
    --data-urlencode "privateWhois=FULL"
  )

  local role
  for role in Registrant Admin Technical Billing; do
    common_args+=(
      --data-urlencode "${role}_FirstName=${REGISTRANT_FIRSTNAME}"
      --data-urlencode "${role}_LastName=${REGISTRANT_LASTNAME}"
      --data-urlencode "${role}_Email=${REGISTRANT_EMAIL}"
      --data-urlencode "${role}_PhoneNumber=${phone}"
      --data-urlencode "${role}_Street=${REGISTRANT_STREET}"
      --data-urlencode "${role}_City=${REGISTRANT_CITY}"
      --data-urlencode "${role}_CountryCode=${REGISTRANT_COUNTRYCODE}"
      --data-urlencode "${role}_PostalCode=${REGISTRANT_POSTALCODE}"
    )
    if [[ -n "${REGISTRANT_ORGANIZATION:-}" ]]; then
      common_args+=(--data-urlencode "${role}_Organization=${REGISTRANT_ORGANIZATION}")
    fi
  done

  json="$(internetbs_request "/Domain/Create" "${common_args[@]}")"
  status="$(internetbs_status "${json}")"
  # Docs: Domain/Create returns STATUS=SUCCESS | PENDING | FAILURE
  case "$(printf '%s' "${status}" | tr '[:lower:]' '[:upper:]')" in
    SUCCESS|PENDING)
      log "Registered domain ${domain} (status=${status})"
      ;;
    *)
      die "Domain registration failed for ${domain}: ${json}"
      ;;
  esac
}

internetbs_dns_add() {
  local full_name="$1"
  local type="$2"
  local value="$3"
  local json status
  json="$(
    internetbs_request "/Domain/DnsRecord/Add" \
      --data-urlencode "FullRecordName=${full_name}" \
      --data-urlencode "Type=${type}" \
      --data-urlencode "Value=${value}"
  )"
  status="$(internetbs_status "${json}")"
  if [[ "${status}" == "SUCCESS" ]]; then
    log "DNS ${type} ${full_name} -> ${value}"
    return 0
  fi

  # For A records, replace any existing value. For TXT (ACME), keep siblings.
  if [[ "${type}" == "A" || "${type}" == "AAAA" ]]; then
    log "DNS add returned ${status} for ${full_name} ${type}; attempting remove+add"
    internetbs_dns_remove "${full_name}" "${type}" || true
    json="$(
      internetbs_request "/Domain/DnsRecord/Add" \
        --data-urlencode "FullRecordName=${full_name}" \
        --data-urlencode "Type=${type}" \
        --data-urlencode "Value=${value}"
    )"
    status="$(internetbs_status "${json}")"
  fi

  [[ "${status}" == "SUCCESS" ]] || die "DNS add failed for ${full_name} ${type}: ${json}"
  log "DNS ${type} ${full_name} -> ${value}"
}

internetbs_dns_remove() {
  local full_name="$1"
  local type="$2"
  local value="${3:-}"
  local body
  local args=(
    --data-urlencode "ApiKey=${INTERNETBS_API_KEY}"
    --data-urlencode "Password=${INTERNETBS_PASSWORD}"
    --data-urlencode "ResponseFormat=JSON"
    --data-urlencode "FullRecordName=${full_name}"
    --data-urlencode "Type=${type}"
  )
  if [[ -n "${value}" ]]; then
    args+=(--data-urlencode "Value=${value}")
  fi
  local curl_opts=()
  mapfile -t curl_opts < <(internetbs_curl_args)
  # Soft-fail: missing records during cleanup are fine.
  body="$(
    curl "${curl_opts[@]}" --get "${INTERNETBS_API_BASE}/Domain/DnsRecord/Remove" "${args[@]}" || true
  )"
  log "DNS remove ${type} ${full_name}: ${body:-ok}"
}

internetbs_point_domain_to_ip() {
  local domain="$1"
  local ip="$2"
  internetbs_dns_add "${domain}" "A" "${ip}"
  internetbs_dns_add "*.${domain}" "A" "${ip}"
}

find_available_domain() {
  local max_attempts="${1:-30}"
  local attempt label domain
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    label="$(random_label 20)"
    domain="${label}.com"
    log "Checking availability for ${domain} (attempt ${attempt}/${max_attempts})"
    if internetbs_domain_available "${domain}"; then
      log "Domain available: ${domain}"
      printf '%s\n' "${domain}"
      return 0
    fi
    log "Domain not available: ${domain}"
  done
  die "Unable to find an available domain after ${max_attempts} attempts"
}

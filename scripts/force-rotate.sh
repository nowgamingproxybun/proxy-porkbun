#!/usr/bin/env bash
# Force an immediate domain change, or resume an incomplete setup.
# Bypasses ROTATION_INTERVAL_DAYS (scheduled cron still honors the interval).
#
# Usage:
#   sudo /opt/proxies/scripts/force-rotate.sh
#   sudo /opt/proxies/scripts/force-rotate.sh --use-domain already-owned.com
#   sudo /opt/proxies/scripts/force-rotate.sh --resume-domain already-bought.com
#   sudo /opt/proxies/scripts/force-rotate.sh --force-new
set -euo pipefail

PROXIES_ROOT="${PROXIES_ROOT:-/opt/proxies}"
ROTATE="${PROXIES_ROOT}/scripts/rotate-domain.sh"

if [[ ! -x "${ROTATE}" ]]; then
  echo "ERROR: Missing rotation script: ${ROTATE}" >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run as root (sudo)" >&2
  exit 1
fi

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Forcing domain rotation (ignores ROTATION_INTERVAL_DAYS; resumes incomplete purchases by default)..." >&2
export FORCE_ROTATION=1
exec "${ROTATE}" "$@"

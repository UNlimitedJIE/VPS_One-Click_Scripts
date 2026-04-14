#!/usr/bin/env bash
set -euo pipefail

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_raw() {
  local level="$1"
  local message="$2"
  local line
  line="$(timestamp) [${level}] ${message}"

  if [[ -n "${LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "${LOG_FILE}")"
    printf '%s\n' "$line" | tee -a "${LOG_FILE}"
  else
    printf '%s\n' "$line"
  fi
}

log() {
  local level="$1"
  shift
  log_raw "$level" "$*"
}

die() {
  log_raw "ERROR" "$*"
  exit 1
}

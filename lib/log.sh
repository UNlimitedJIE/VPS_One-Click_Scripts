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

  printf '%s\n' "$line"

  if [[ -n "${LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
    printf '%s\n' "$line" >>"${LOG_FILE}" 2>/dev/null || true
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

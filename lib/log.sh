#!/usr/bin/env bash
set -euo pipefail

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_file_append_allowed() {
  [[ -n "${LOG_FILE:-}" ]] || return 1
  [[ "${LOG_FILE_WRITE_DISABLED:-false}" != "true" ]]
}

log_raw() {
  local level="$1"
  local message="$2"
  local line=""
  local log_dir=""
  line="$(timestamp) [${level}] ${message}"

  printf '%s\n' "$line"

  if log_file_append_allowed; then
    log_dir="$(dirname "${LOG_FILE}")"
    if ! mkdir -p "${log_dir}" 2>/dev/null; then
      LOG_FILE_WRITE_DISABLED="true"
      export LOG_FILE_WRITE_DISABLED
      return 0
    fi

    if ! printf '%s\n' "$line" >>"${LOG_FILE}" 2>/dev/null; then
      LOG_FILE_WRITE_DISABLED="true"
      export LOG_FILE_WRITE_DISABLED
    fi
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

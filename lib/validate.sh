#!/usr/bin/env bash
set -euo pipefail

is_true() {
  case "${1:-false}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

is_false() {
  ! is_true "${1:-false}"
}

require_root() {
  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    log info "Plan/Dry-run mode: skipping root requirement."
    return 0
  fi
  [[ "${EUID}" -eq 0 ]] || die "This script must run as root."
}

require_debian12() {
  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    if ! is_debian12; then
      log warn "Plan/Dry-run mode: skipping strict Debian 12 requirement. Current: $(pretty_os_name 2>/dev/null || echo unknown)"
    fi
    return 0
  fi
  is_debian12 || die "Target system must be Debian 12. Current: $(pretty_os_name)"
}

validate_ssh_port() {
  [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || die "SSH_PORT must be a number."
  (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "SSH_PORT must be between 1 and 65535."
}

validate_config() {
  validate_ssh_port

  if [[ -n "${ADMIN_USER}" && "${ADMIN_USER}" == "root" ]]; then
    die "ADMIN_USER must not be root."
  fi

  if [[ -n "${AUTHORIZED_KEYS_FILE}" && ! -f "${AUTHORIZED_KEYS_FILE}" ]]; then
    log warn "AUTHORIZED_KEYS_FILE does not exist yet: ${AUTHORIZED_KEYS_FILE}"
  fi
}

validate_authorized_keys_file() {
  local file="$1"
  [[ -f "$file" ]] || die "Authorized keys file not found: ${file}"
  [[ "$(count_valid_ssh_keys_in_file "$file")" -gt 0 ]] || die "No valid public keys found in ${file}"
}

can_disable_password_login() {
  local user="${1:-${ADMIN_USER:-}}"
  [[ -n "$user" ]] || return 1
  id -u "$user" >/dev/null 2>&1 || return 1
  authorized_keys_present_for_user "$user"
}

validate_sshd_config() {
  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    log info "Plan/Dry-run mode: skipping live sshd syntax validation."
    return 0
  fi
  if ! command_exists sshd; then
    die "sshd command not found."
  fi
  sshd -t
}

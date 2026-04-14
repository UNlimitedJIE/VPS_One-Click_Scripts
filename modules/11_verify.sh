#!/usr/bin/env bash
set -euo pipefail

# Module: 11_verify
# Purpose: 对初始化后的关键状态做验证检查。
# Preconditions: root；Debian 12。
# Steps:
#   1. 检查系统版本、用户、公钥、sshd 配置
#   2. 检查关键服务状态
#   3. 输出通过项与警告项
# Idempotency:
#   - 纯验证模块，可反复执行

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

verify_ok() {
  log info "[OK] $*"
}

verify_warn() {
  log warn "[WARN] $*"
  warnings=$((warnings + 1))
}

verify_fail() {
  log_raw "ERROR" "[FAIL] $*"
  failures=$((failures + 1))
}

shortcut_target_path() {
  printf '/usr/local/bin/j\n'
}

verify_shortcut_wrapper() {
  local target=""
  target="$(shortcut_target_path)"

  if [[ ! -e "${target}" ]]; then
    verify_warn "Shortcut j not installed: ${target}"
    return 0
  fi

  if [[ ! -x "${target}" ]]; then
    verify_fail "Shortcut exists but is not executable: ${target}"
    return 0
  fi
  verify_ok "Shortcut exists and is executable: ${target}"

  if grep -Fq 'config/local.conf' "${target}" && grep -Fq '/opt/VPS_One-Click_Scripts' "${target}" && grep -Fq '/root/VPS_One-Click_Scripts' "${target}"; then
    verify_ok "Shortcut wrapper includes runtime project discovery and local.conf logic"
  else
    verify_fail "Shortcut wrapper is missing runtime project discovery or local.conf logic"
  fi
}

verify_admin_can_read_project_bootstrap() {
  if [[ -z "${ADMIN_USER}" ]]; then
    verify_warn "ADMIN_USER is empty; skip project readability check"
    return 0
  fi

  if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    verify_warn "Admin user missing; skip project readability check: ${ADMIN_USER}"
    return 0
  fi

  if sudo -u "${ADMIN_USER}" test -r "${PROJECT_ROOT}/bootstrap.sh"; then
    verify_ok "Admin user can read project bootstrap.sh: ${PROJECT_ROOT}/bootstrap.sh"
  else
    verify_warn "Admin user cannot read project bootstrap.sh: ${PROJECT_ROOT}/bootstrap.sh"
  fi
}

detect_admin_sudo_mode() {
  local dropin_path=""
  dropin_path="/etc/sudoers.d/90-${ADMIN_USER}"

  if [[ -f "${dropin_path}" ]]; then
    if grep -Fqx "${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD: ALL" "${dropin_path}"; then
      printf '%s\n' "nopasswd"
      return 0
    fi
    printf '%s\n' "unknown"
    return 0
  fi

  printf '%s\n' "password"
}

verify_admin_sudo_behavior() {
  local sudo_mode=""
  local sudo_output=""
  local sudo_status=0

  if [[ -z "${ADMIN_USER}" ]]; then
    verify_warn "ADMIN_USER is empty; skip sudo behavior check"
    return 0
  fi

  if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    verify_warn "Admin user missing; skip sudo behavior check: ${ADMIN_USER}"
    return 0
  fi

  if ! command_exists sudo; then
    verify_fail "sudo command not found"
    return 0
  fi

  sudo_mode="$(detect_admin_sudo_mode)"
  case "${sudo_mode}" in
    nopasswd|password)
      verify_ok "Detected admin sudo mode: ${sudo_mode}"
      ;;
    *)
      verify_fail "Unable to determine admin sudo mode from /etc/sudoers.d/90-${ADMIN_USER}"
      return 0
      ;;
  esac

  sudo_output="$(
    env LC_ALL=C LANG=C sudo -u "${ADMIN_USER}" sudo -n true 2>&1
  )" || sudo_status=$?

  case "${sudo_mode}" in
    nopasswd)
      if [[ "${sudo_status}" -eq 0 ]]; then
        verify_ok "sudo -n works for ${ADMIN_USER} in nopasswd mode"
      else
        verify_fail "Expected nopasswd sudo for ${ADMIN_USER}, but sudo -n failed: ${sudo_output:-<no output>}"
      fi
      ;;
    password)
      if [[ "${sudo_status}" -eq 0 ]]; then
        verify_fail "Expected password-required sudo for ${ADMIN_USER}, but sudo -n succeeded"
      elif [[ "${sudo_output}" == *"password is required"* ]]; then
        verify_ok "sudo for ${ADMIN_USER} requires a password as expected"
      else
        verify_fail "Expected password-required sudo for ${ADMIN_USER}, but got: ${sudo_output:-<no output>}"
      fi
      ;;
  esac
}

sshd_effective_value() {
  local key="$1"
  local sshd_output="$2"
  printf '%s\n' "${sshd_output}" | awk -v key="${key}" '$1 == key { print $2; exit }'
}

verify_sshd_effective_settings() {
  local sshd_output=""
  local password_auth=""
  local pubkey_auth=""
  local permit_root_login=""

  if ! command_exists sshd; then
    verify_fail "sshd command not found"
    return 0
  fi

  sshd_output="$(sshd -T 2>&1)" || {
    verify_fail "sshd -T failed: ${sshd_output:-<no output>}"
    return 0
  }

  password_auth="$(sshd_effective_value "passwordauthentication" "${sshd_output}")"
  pubkey_auth="$(sshd_effective_value "pubkeyauthentication" "${sshd_output}")"
  permit_root_login="$(sshd_effective_value "permitrootlogin" "${sshd_output}")"

  if [[ -n "${password_auth}" ]]; then
    if [[ "${password_auth}" == "no" ]]; then
      verify_ok "sshd -T passwordauthentication=${password_auth}"
    else
      verify_warn "sshd -T passwordauthentication=${password_auth}"
    fi
  else
    verify_fail "Unable to read passwordauthentication from sshd -T"
  fi

  if [[ "${pubkey_auth}" == "yes" ]]; then
    verify_ok "sshd -T pubkeyauthentication=${pubkey_auth}"
  elif [[ -n "${pubkey_auth}" ]]; then
    verify_fail "sshd -T pubkeyauthentication=${pubkey_auth}"
  else
    verify_fail "Unable to read pubkeyauthentication from sshd -T"
  fi

  if [[ -n "${permit_root_login}" ]]; then
    if [[ "${permit_root_login}" == "no" ]]; then
      verify_ok "sshd -T permitrootlogin=${permit_root_login}"
    else
      verify_warn "sshd -T permitrootlogin=${permit_root_login}"
    fi
  else
    verify_fail "Unable to read permitrootlogin from sshd -T"
  fi

  log info "[INFO] sshd -T only verifies effective local SSH settings; external SSH connectivity still needs a separate manual login test."
}

verify_admin_ssh_permissions() {
  local home_dir=""
  local ssh_dir=""
  local auth_file=""
  local ssh_owner_mode=""
  local auth_owner_mode=""

  if [[ -z "${ADMIN_USER}" ]]; then
    verify_warn "ADMIN_USER is empty; skip .ssh permission checks"
    return 0
  fi

  if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    verify_warn "Admin user missing; skip .ssh permission checks: ${ADMIN_USER}"
    return 0
  fi

  home_dir="$(home_dir_for_user "${ADMIN_USER}")"
  [[ -n "${home_dir}" ]] || {
    verify_fail "Unable to determine home directory for ${ADMIN_USER}"
    return 0
  }

  ssh_dir="${home_dir}/.ssh"
  auth_file="${ssh_dir}/authorized_keys"

  if [[ ! -d "${ssh_dir}" ]]; then
    verify_warn "SSH directory missing: ${ssh_dir}"
    return 0
  fi

  ssh_owner_mode="$(stat -c '%U:%G %a' "${ssh_dir}" 2>/dev/null || true)"
  if [[ "${ssh_owner_mode}" == "${ADMIN_USER}:${ADMIN_USER} 700" ]]; then
    verify_ok "SSH directory ownership and mode are correct: ${ssh_dir}"
  else
    verify_fail "SSH directory ownership/mode mismatch for ${ssh_dir}: ${ssh_owner_mode:-<unknown>}"
  fi

  if [[ ! -f "${auth_file}" ]]; then
    verify_warn "authorized_keys missing: ${auth_file}"
    return 0
  fi

  auth_owner_mode="$(stat -c '%U:%G %a' "${auth_file}" 2>/dev/null || true)"
  if [[ "${auth_owner_mode}" == "${ADMIN_USER}:${ADMIN_USER} 600" ]]; then
    verify_ok "authorized_keys ownership and mode are correct: ${auth_file}"
  else
    verify_fail "authorized_keys ownership/mode mismatch for ${auth_file}: ${auth_owner_mode:-<unknown>}"
  fi
}

main() {
  load_config
  init_runtime
  module_banner "11_verify" "初始化后的验证检查"
  require_root

  local warnings=0
  local failures=0

  if is_debian12; then
    verify_ok "Debian 12 detected"
  else
    verify_fail "Expected Debian 12, got $(pretty_os_name)"
  fi

  if [[ -n "${ADMIN_USER}" ]] && id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    verify_ok "Admin user exists: ${ADMIN_USER}"
  else
    verify_warn "Admin user missing: ${ADMIN_USER}"
  fi

  if [[ -n "${ADMIN_USER}" ]] && authorized_keys_present_for_user "${ADMIN_USER}"; then
    verify_ok "authorized_keys detected for ${ADMIN_USER}"
  else
    verify_warn "No valid authorized_keys detected for ${ADMIN_USER:-<unset>}"
  fi

  if command_exists sshd && sshd -t >/dev/null 2>&1; then
    verify_ok "sshd configuration test passed"
  else
    verify_fail "sshd configuration test failed"
  fi

  if root_ssh_login_disabled; then
    verify_ok "Root remote SSH login is disabled"
  else
    verify_warn "Root remote SSH login is still allowed"
  fi

  if ssh_port_change_pending_confirmation; then
    verify_warn "SSH port is configured as ${SSH_PORT}, but confirmation is still missing."
    log warn "[WARN] Current effective SSH port remains $(effective_ssh_port_for_changes). Confirm cloud firewall/security-group and rerun the merged admin-access stage plus the nftables step."
  fi

  if service_enabled "nftables" && service_active "nftables"; then
    verify_ok "nftables enabled and active"
  else
    verify_warn "nftables not enabled/active"
  fi

  if service_enabled "systemd-timesyncd" && service_active "systemd-timesyncd"; then
    verify_ok "systemd-timesyncd enabled and active"
  else
    verify_warn "systemd-timesyncd not enabled/active"
  fi

  if service_exists "fail2ban"; then
    if service_enabled "fail2ban" && service_active "fail2ban"; then
      verify_ok "fail2ban enabled and active"
    else
      verify_warn "fail2ban installed but not enabled/active"
    fi
  fi

  if has_active_swap; then
    verify_ok "swap is active"
  else
    verify_warn "swap is not active"
  fi

  verify_shortcut_wrapper
  verify_admin_can_read_project_bootstrap
  verify_admin_sudo_behavior
  verify_sshd_effective_settings
  verify_admin_ssh_permissions

  set_state "VERIFY_WARNINGS" "${warnings}"
  set_state "VERIFY_FAILURES" "${failures}"

  if (( failures > 0 )); then
    log warn "Verification finished with ${failures} failure(s) and ${warnings} warning(s)."
  else
    log info "Verification finished with ${warnings} warning(s)."
  fi
}

main "$@"

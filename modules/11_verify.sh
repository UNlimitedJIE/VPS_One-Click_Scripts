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

verify_pending() {
  log info "[PENDING] $*"
  pending=$((pending + 1))
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

  if grep -Fq '/opt/VPS_One-Click_Scripts' "${target}" && grep -Fq 'current_home="${HOME:-}"' "${target}" && grep -Fq '/root/VPS_One-Click_Scripts' "${target}" && grep -Fq 'config/local.conf' "${target}" && grep -Fq '[j] Runtime project root:' "${target}" && grep -Fq 'Multiple project copies detected' "${target}"; then
    verify_ok "Shortcut wrapper includes runtime project discovery, copy warning and local.conf logic"
  else
    verify_fail "Shortcut wrapper is missing /opt, \$HOME, /root, copy warning or local.conf discovery logic"
  fi
}

verify_project_copy_layout() {
  local runtime_root=""
  local current_dir=""
  local active_root=""
  local copy=""
  local -a copies=()

  runtime_root="$(discover_runtime_project_root || true)"
  current_dir="$(pwd -P 2>/dev/null || pwd)"
  active_root="${runtime_root:-${PROJECT_ROOT}}"

  verify_ok "Current PROJECT_ROOT=${PROJECT_ROOT}"
  verify_ok "Current shell directory=${current_dir}"

  if [[ -n "${runtime_root}" ]]; then
    verify_ok "Preferred runtime project root=${runtime_root}"
  else
    verify_pending "No readable runtime project root detected in /opt, \$HOME or /root"
  fi

  mapfile -t copies < <(list_detected_project_copies)
  if ((${#copies[@]} == 0)); then
    verify_pending "No project copies detected in /opt, \$HOME or /root"
  else
    verify_ok "Detected project copies: ${copies[*]}"
  fi

  if [[ -n "${runtime_root}" && "${PROJECT_ROOT}" != "${runtime_root}" ]]; then
    verify_warn "Current execution root differs from the preferred runtime root: PROJECT_ROOT=${PROJECT_ROOT}, runtime=${runtime_root}"
  fi

  if [[ -n "${runtime_root}" && "${current_dir}" != "${runtime_root}" ]]; then
    verify_warn "Current shell directory differs from the shortcut runtime root: cwd=${current_dir}, runtime=${runtime_root}"
  fi

  if ((${#copies[@]} > 1)); then
    verify_warn "Multiple project copies detected. Active runtime copy: ${active_root}"
    for copy in "${copies[@]}"; do
      [[ "${copy}" == "${active_root}" ]] || verify_warn "Other project copy: ${copy}"
    done
    verify_warn "更新目录与运行目录可能不一致。"
    if selection_contains "$(shared_project_root)" "${copies[@]}" && selection_contains "/root/VPS_One-Click_Scripts" "${copies[@]}"; then
      verify_warn "Both /opt and /root project copies exist; keep $(shared_project_root) as the only runtime and maintenance directory."
    fi
  fi

  if [[ "${active_root}" == "$(shared_project_root)" ]]; then
    log info "[INFO] If the system has switched to /opt runtime, future git/grep/code edits should be done in $(shared_project_root)."
  fi
}

verify_active_config_chain() {
  local local_config=""
  local_config="${PROJECT_ROOT}/config/local.conf"

  if [[ -n "${ACTIVE_CONFIG_CHAIN:-}" ]]; then
    verify_ok "ACTIVE_CONFIG_CHAIN=${ACTIVE_CONFIG_CHAIN}"
  else
    verify_warn "ACTIVE_CONFIG_CHAIN is empty"
  fi

  if [[ -f "${local_config}" && "${ACTIVE_CONFIG_CHAIN:-}" != *"${local_config}"* ]]; then
    verify_warn "config/local.conf exists but is missing from ACTIVE_CONFIG_CHAIN: ${local_config}"
  fi
}

verify_dependency_chain_state() {
  local dependency=""
  local assessment=""

  while IFS= read -r dependency; do
    [[ -n "${dependency}" ]] || continue
    [[ "${dependency}" == "11_verify" ]] && continue

    assessment="$(dependency_assessment_status "${dependency}")"
    case "${assessment}" in
      completion_state_found)
        verify_ok "Dependency ${dependency}: completion state found"
        ;;
      state_missing_but_conditions_satisfied)
        verify_pending "Dependency ${dependency}: completion state missing, but prerequisite conditions appear satisfied"
        ;;
      *)
        verify_warn "Dependency ${dependency}: completion state missing and prerequisite conditions are not satisfied"
        ;;
    esac
  done < <(registry_unique_dependencies "init")
}

verify_configured_runtime_values() {
  local target_keys_ready="no"

  if [[ -n "${ADMIN_USER:-}" ]] && admin_authorized_keys_ready_for_user "${ADMIN_USER}"; then
    target_keys_ready="yes"
  fi

  if [[ -n "${ADMIN_USER:-}" ]]; then
    verify_ok "Configured ADMIN_USER=${ADMIN_USER}"
  else
    verify_pending "Configured ADMIN_USER is empty"
  fi

  if [[ -n "${AUTHORIZED_KEYS_FILE:-}" ]]; then
    if [[ -f "${AUTHORIZED_KEYS_FILE}" ]]; then
      if [[ "$(count_valid_ssh_keys_in_file "${AUTHORIZED_KEYS_FILE}")" -gt 0 ]]; then
        verify_ok "Configured AUTHORIZED_KEYS_FILE=${AUTHORIZED_KEYS_FILE}"
      else
        verify_pending "Configured AUTHORIZED_KEYS_FILE has no valid public key yet: ${AUTHORIZED_KEYS_FILE}"
      fi
    elif [[ "${target_keys_ready}" == "yes" ]]; then
      if authorized_keys_source_is_root_only_path "${AUTHORIZED_KEYS_FILE}"; then
        log info "[INFO] AUTHORIZED_KEYS_FILE 当前指向 /root 下路径；若目标账户 authorized_keys 已安装，可忽略此提示。"
        log info "[INFO] Suggestion: future source path can be moved to $(preferred_authorized_keys_source_path)."
      else
        log info "[INFO] AUTHORIZED_KEYS_FILE 源文件当前不可访问或不存在，但目标账户 authorized_keys 已安装完成。"
      fi
    elif authorized_keys_source_is_root_only_path "${AUTHORIZED_KEYS_FILE}"; then
      verify_pending "Configured AUTHORIZED_KEYS_FILE points to /root and is not ready yet: ${AUTHORIZED_KEYS_FILE}. Normal flow should use $(preferred_authorized_keys_source_path)."
    else
      verify_pending "Configured AUTHORIZED_KEYS_FILE is not ready yet: ${AUTHORIZED_KEYS_FILE}"
    fi
  else
    verify_pending "Configured AUTHORIZED_KEYS_FILE is empty"
  fi
}

verify_admin_can_read_project_bootstrap() {
  local runtime_root=""
  local target_root=""

  if [[ -z "${ADMIN_USER}" ]]; then
    verify_pending "ADMIN_USER is empty; skip project readability check"
    return 0
  fi

  if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    verify_pending "Admin user missing; skip project readability check: ${ADMIN_USER}"
    return 0
  fi

  runtime_root="$(discover_runtime_project_root || true)"
  target_root="${runtime_root:-${PROJECT_ROOT}}"

  if sudo -u "${ADMIN_USER}" test -r "${target_root}/bootstrap.sh"; then
    verify_ok "Admin user can read runtime bootstrap.sh: ${target_root}/bootstrap.sh"
  else
    verify_warn "Admin user cannot read runtime bootstrap.sh: ${target_root}/bootstrap.sh"
    if [[ "${target_root}" == /root/* ]]; then
      verify_warn "当前运行目录位于 /root，下次切换到管理用户后无法直接使用 j；应先迁移到 /opt/VPS_One-Click_Scripts 并重装 shortcut。"
    fi
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
    verify_pending "ADMIN_USER is empty; skip sudo behavior check"
    return 0
  fi

  if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    verify_pending "Admin user missing; skip sudo behavior check: ${ADMIN_USER}"
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
  local port=""
  local runtime_port=""
  local safe_gate_state=""
  local cutover_state=""

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
  port="$(sshd_effective_value "port" "${sshd_output}")"
  runtime_port="$(current_ssh_port)"
  safe_gate_state="$(get_state "SSH_SAFE_GATE_PASSED" || true)"
  cutover_state="$(get_state "ADMIN_LOGIN_CUTOVER" || true)"

  if [[ -n "${password_auth}" ]]; then
    if [[ "${password_auth}" == "no" ]]; then
      verify_ok "sshd -T passwordauthentication=${password_auth}"
    elif is_false "${DISABLE_PASSWORD_LOGIN}" ; then
      verify_ok "sshd -T passwordauthentication=${password_auth} (intentionally left enabled)"
    elif is_true "${DISABLE_PASSWORD_LOGIN}" && [[ "${safe_gate_state}" != "yes" ]]; then
      verify_pending "sshd -T passwordauthentication=${password_auth}; safe gate not passed yet, so password login still remains enabled during preparation"
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
    elif [[ "${cutover_state}" != "yes" ]]; then
      verify_pending "sshd -T permitrootlogin=${permit_root_login}; final cutover has not been completed yet"
    else
      verify_warn "sshd -T permitrootlogin=${permit_root_login}"
    fi
  else
    verify_fail "Unable to read permitrootlogin from sshd -T"
  fi

  if [[ -n "${port}" ]]; then
    verify_ok "sshd -T port=${port}"
    log info "[INFO] Current effective SSH port: ${port}"
    if ssh_port_is_listening_locally "${port}"; then
      verify_ok "Local listening check passed for SSH port ${port}"
    else
      verify_fail "Local listening check failed for SSH port ${port}"
    fi
  else
    verify_fail "Unable to read port from sshd -T"
  fi

  if [[ -n "${runtime_port}" && -n "${port}" && "${runtime_port}" != "${port}" ]]; then
    verify_warn "current_ssh_port reports ${runtime_port}, while sshd -T reports ${port}"
  fi

  log info "[INFO] sshd -T only verifies effective local SSH settings; external SSH connectivity still needs a separate manual login test."
}

verify_admin_authorized_keys_target() {
  local home_dir=""
  local ssh_dir=""
  local auth_file=""
  local ssh_owner_mode=""
  local auth_owner_mode=""
  local key_count="0"
  local safe_gate_state=""
  local fallback_source=""

  if [[ -z "${ADMIN_USER}" ]]; then
    verify_pending "ADMIN_USER is empty; skip .ssh permission checks"
    return 0
  fi

  if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    verify_pending "Admin user missing; skip .ssh permission checks: ${ADMIN_USER}"
    return 0
  fi

  home_dir="$(home_dir_for_user "${ADMIN_USER}")"
  [[ -n "${home_dir}" ]] || {
    verify_fail "Unable to determine home directory for ${ADMIN_USER}"
    return 0
  }

  ssh_dir="${home_dir}/.ssh"
  auth_file="${ssh_dir}/authorized_keys"
  safe_gate_state="$(get_state "SSH_SAFE_GATE_PASSED" || true)"
  verify_ok "Target authorized_keys path=${auth_file}"

  if [[ ! -d "${ssh_dir}" ]]; then
    if [[ "${safe_gate_state}" == "yes" ]]; then
      verify_fail "SSH directory missing even though SSH_SAFE_GATE_PASSED=yes: ${ssh_dir}"
    else
      verify_pending "SSH directory missing: ${ssh_dir}"
    fi
  else
    ssh_owner_mode="$(stat -c '%U:%G %a' "${ssh_dir}" 2>/dev/null || true)"
    if [[ "${ssh_owner_mode}" == "${ADMIN_USER}:${ADMIN_USER} 700" ]]; then
      verify_ok "SSH directory ownership and mode are correct: ${ssh_dir}"
    else
      verify_fail "SSH directory ownership/mode mismatch for ${ssh_dir}: ${ssh_owner_mode:-<unknown>}"
    fi
  fi

  if [[ -f "${auth_file}" ]]; then
    verify_ok "authorized_keys exists: ${auth_file}"
    auth_owner_mode="$(stat -c '%U:%G %a' "${auth_file}" 2>/dev/null || true)"
    if [[ "${auth_owner_mode}" == "${ADMIN_USER}:${ADMIN_USER} 600" ]]; then
      verify_ok "authorized_keys ownership and mode are correct: ${auth_file}"
    else
      verify_fail "authorized_keys ownership/mode mismatch for ${auth_file}: ${auth_owner_mode:-<unknown>}"
    fi
  else
    if [[ "${safe_gate_state}" == "yes" ]]; then
      verify_fail "authorized_keys missing even though SSH_SAFE_GATE_PASSED=yes: ${auth_file}"
    else
      verify_pending "authorized_keys missing: ${auth_file}"
    fi
  fi

  key_count="$(count_valid_ssh_keys_in_file "${auth_file}")"
  if [[ "${key_count}" -gt 0 ]]; then
    verify_ok "Valid authorized_keys count for ${ADMIN_USER}: ${key_count}"
  else
    if [[ "${safe_gate_state}" == "yes" ]]; then
      verify_fail "Valid authorized_keys count for ${ADMIN_USER} is 0 even though SSH_SAFE_GATE_PASSED=yes"
    else
      verify_pending "Valid authorized_keys count for ${ADMIN_USER}: ${key_count}"
    fi
  fi

  if [[ "${safe_gate_state}" == "yes" ]]; then
    verify_ok "SSH_SAFE_GATE_PASSED=${safe_gate_state}"
  else
    verify_pending "SSH_SAFE_GATE_PASSED=${safe_gate_state:-<unset>}"
  fi

  if [[ -n "${AUTHORIZED_KEYS_FILE:-}" && -f "${AUTHORIZED_KEYS_FILE}" && ! -f "${auth_file}" ]]; then
    if [[ "${safe_gate_state}" == "yes" ]]; then
      verify_warn "Configured AUTHORIZED_KEYS_FILE exists, but target authorized_keys is missing: ${AUTHORIZED_KEYS_FILE} -> ${auth_file}"
    else
      verify_pending "Configured AUTHORIZED_KEYS_FILE exists, but target authorized_keys is missing: ${AUTHORIZED_KEYS_FILE} -> ${auth_file}"
    fi
  fi

  fallback_source="$(bootstrap_authorized_keys_fallback_path)"
  if [[ -z "${AUTHORIZED_KEYS_FILE:-}" && -f "${fallback_source}" && ! -f "${auth_file}" ]]; then
    if [[ "${safe_gate_state}" == "yes" ]]; then
      verify_warn "Fallback authorized_keys source exists, but target authorized_keys is missing: ${fallback_source} -> ${auth_file}"
    else
      verify_pending "Fallback authorized_keys source exists, but target authorized_keys is missing: ${fallback_source} -> ${auth_file}"
    fi
  fi
}

main() {
  load_config
  init_runtime
  module_banner "11_verify" "初始化后的验证检查"
  require_root

  local warnings=0
  local failures=0
  local pending=0
  local cutover_state=""

  verify_active_config_chain
  verify_dependency_chain_state
  verify_project_copy_layout
  verify_configured_runtime_values

  if is_debian12; then
    verify_ok "Debian 12 detected"
  else
    verify_fail "Expected Debian 12, got $(pretty_os_name)"
  fi

  if [[ -n "${ADMIN_USER}" ]] && id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    verify_ok "Admin user exists: ${ADMIN_USER}"
  else
    verify_pending "Admin user missing: ${ADMIN_USER}"
  fi

  if [[ -n "${ADMIN_USER}" ]] && authorized_keys_present_for_user "${ADMIN_USER}"; then
    verify_ok "authorized_keys detected for ${ADMIN_USER}"
  else
    verify_pending "No valid authorized_keys detected for ${ADMIN_USER:-<unset>}"
  fi

  if command_exists sshd && sshd -t >/dev/null 2>&1; then
    verify_ok "sshd configuration test passed"
  else
    verify_fail "sshd configuration test failed"
  fi

  cutover_state="$(get_state "ADMIN_LOGIN_CUTOVER" || true)"
  if root_ssh_login_disabled; then
    verify_ok "Root remote SSH login is disabled"
  elif [[ "${cutover_state}" == "yes" ]]; then
    verify_warn "Root remote SSH login is still allowed"
  else
    verify_pending "Root remote SSH login is still allowed; final cutover has not been completed yet"
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
  verify_admin_authorized_keys_target

  set_state "VERIFY_WARNINGS" "${warnings}"
  set_state "VERIFY_FAILURES" "${failures}"
  set_state "VERIFY_PENDING" "${pending}"

  if (( failures > 0 )); then
    log warn "Verification finished with ${failures} failure(s), ${warnings} warning(s), and ${pending} pending item(s)."
  else
    log info "Verification finished with ${warnings} warning(s) and ${pending} pending item(s)."
  fi
}

main "$@"

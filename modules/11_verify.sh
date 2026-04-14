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

main() {
  load_config
  init_runtime
  module_banner "11_verify" "初始化后的验证检查"
  require_root

  local warnings=0
  local failures=0

  if is_debian12; then
    log info "[OK] Debian 12 detected"
  else
    log_raw "ERROR" "[FAIL] Expected Debian 12, got $(pretty_os_name)"
    failures=$((failures + 1))
  fi

  if [[ -n "${ADMIN_USER}" ]] && id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    log info "[OK] Admin user exists: ${ADMIN_USER}"
  else
    log warn "[WARN] Admin user missing: ${ADMIN_USER}"
    warnings=$((warnings + 1))
  fi

  if [[ -n "${ADMIN_USER}" ]] && authorized_keys_present_for_user "${ADMIN_USER}"; then
    log info "[OK] authorized_keys detected for ${ADMIN_USER}"
  else
    log warn "[WARN] No valid authorized_keys detected for ${ADMIN_USER:-<unset>}"
    warnings=$((warnings + 1))
  fi

  if command_exists sshd && sshd -t >/dev/null 2>&1; then
    log info "[OK] sshd configuration test passed"
  else
    log_raw "ERROR" "[FAIL] sshd configuration test failed"
    failures=$((failures + 1))
  fi

  if ssh_port_change_pending_confirmation; then
    log warn "[WARN] SSH port is configured as ${SSH_PORT}, but confirmation is still missing."
    log warn "[WARN] Current effective SSH port remains $(effective_ssh_port_for_changes). Confirm cloud firewall/security-group and rerun step 6 and step 7."
    warnings=$((warnings + 1))
  fi

  if service_enabled "nftables" && service_active "nftables"; then
    log info "[OK] nftables enabled and active"
  else
    log warn "[WARN] nftables not enabled/active"
    warnings=$((warnings + 1))
  fi

  if service_enabled "systemd-timesyncd" && service_active "systemd-timesyncd"; then
    log info "[OK] systemd-timesyncd enabled and active"
  else
    log warn "[WARN] systemd-timesyncd not enabled/active"
    warnings=$((warnings + 1))
  fi

  if service_exists "fail2ban"; then
    if service_enabled "fail2ban" && service_active "fail2ban"; then
      log info "[OK] fail2ban enabled and active"
    else
      log warn "[WARN] fail2ban installed but not enabled/active"
      warnings=$((warnings + 1))
    fi
  fi

  if has_active_swap; then
    log info "[OK] swap is active"
  else
    log warn "[WARN] swap is not active"
    warnings=$((warnings + 1))
  fi

  set_state "VERIFY_WARNINGS" "${warnings}"
  set_state "VERIFY_FAILURES" "${failures}"

  if (( failures > 0 )); then
    log warn "Verification finished with ${failures} failure(s) and ${warnings} warning(s)."
  else
    log info "Verification finished with ${warnings} warning(s)."
  fi
}

main "$@"

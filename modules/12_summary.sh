#!/usr/bin/env bash
set -euo pipefail

# Module: 12_summary
# Purpose: 输出初始化结果摘要与后续建议。
# Preconditions: 无严格依赖，建议在初始化末尾执行。
# Steps:
#   1. 汇总系统与关键服务状态
#   2. 输出 SSH、用户、公钥、防火墙、时间同步、更新、swap 摘要
#   3. 给出下一步手动操作提醒
# Idempotency:
#   - 纯汇总模块，可反复执行

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "12_summary" "输出初始化结果摘要"
  require_root

  if is_false "${ENABLE_SUMMARY}"; then
    log info "ENABLE_SUMMARY=false, skip."
    return 0
  fi

  local admin_state auth_state root_ssh_state nft_state ts_state f2b_state au_state swap_state
  local requested_ssh_port effective_ssh_port port_confirm_state
  admin_state="no"
  auth_state="no"
  root_ssh_state="unknown"
  nft_state="no"
  ts_state="no"
  f2b_state="no"
  au_state="no"
  swap_state="disabled"

  if [[ -n "${ADMIN_USER}" ]] && id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    admin_state="yes (${ADMIN_USER})"
  fi

  if [[ -n "${ADMIN_USER}" ]] && authorized_keys_present_for_user "${ADMIN_USER}"; then
    auth_state="yes"
  fi

  if root_ssh_login_disabled; then
    root_ssh_state="disabled"
  else
    root_ssh_state="enabled"
  fi

  if service_enabled "nftables" && service_active "nftables"; then
    nft_state="yes"
  fi

  if service_enabled "systemd-timesyncd" && service_active "systemd-timesyncd"; then
    ts_state="yes"
  fi

  if service_exists "fail2ban" && service_enabled "fail2ban" && service_active "fail2ban"; then
    f2b_state="yes"
  fi

  if service_exists "unattended-upgrades" && service_enabled "unattended-upgrades"; then
    au_state="yes"
  fi

  if has_active_swap; then
    swap_state="$(swapon --show --noheadings | awk '{print $1 " (" $3 ")"}' | paste -sd ',' -)"
  fi

  requested_ssh_port="${SSH_PORT}"
  effective_ssh_port="$(effective_ssh_port_for_changes)"
  if ssh_port_change_pending_confirmation; then
    port_confirm_state="未确认，当前仍保持 ${effective_ssh_port}"
  else
    port_confirm_state="已确认"
  fi

  local summary
  summary="$(cat <<EOF
=== Debian 12 VPS Init Summary ===
System version: $(pretty_os_name)
Hostname: $(hostnamectl --static 2>/dev/null || hostname)
Requested SSH port: ${requested_ssh_port}
Effective SSH port: ${effective_ssh_port}
SSH port change confirmation: ${port_confirm_state}
Admin user detected: ${admin_state}
authorized_keys detected: ${auth_state}
Root remote SSH login: ${root_ssh_state}
nftables enabled: ${nft_state}
timesyncd enabled: ${ts_state}
fail2ban enabled: ${f2b_state}
unattended-upgrades enabled: ${au_state}
Swap status: ${swap_state}

Recommended next steps:
1. Keep the current root session open and test a fresh admin-user login on port ${effective_ssh_port}.
2. Confirm cloud firewall/security-group matches the SSH port you actually want to use.
3. Review /etc/ssh/sshd_config.d/99-vps-bootstrap.conf, /etc/ssh/sshd_config.d/999-vps-root-login-cutover.conf and /etc/nftables.conf.
4. If you plan to move away from port 22, set CONFIRM_SSH_PORT_CHANGE="true" only after external access is verified.
5. After verification, create a provider snapshot or backup.
6. Add business ports later through dedicated role/module scripts, not by editing core baseline blindly.

Reminder:
${SNAPSHOT_REMINDER}
完整机内验证以 11_verify 为准，SSH 外部连通性仍需在新窗口手动验收。
EOF
)"

  log info "${summary}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${summary}" >"${STATE_DIR}/init-summary.txt"
  fi

  set_state "SUMMARY_WRITTEN" "yes"
}

main "$@"

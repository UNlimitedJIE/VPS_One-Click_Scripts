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

summary_service_state() {
  local unit="${1:-}"
  local absent_label="${2:-not installed}"

  if ! service_exists "${unit}"; then
    printf '%s\n' "${absent_label}"
    return 0
  fi

  if service_enabled "${unit}" && service_active "${unit}"; then
    printf '%s\n' "enabled and active"
  elif service_enabled "${unit}"; then
    printf '%s\n' "enabled"
  else
    printf '%s\n' "not enabled"
  fi
}

summary_root_login_state() {
  if root_ssh_login_disabled; then
    printf '%s\n' "disabled"
  elif [[ "$(get_state "ADMIN_LOGIN_CUTOVER" || true)" == "yes" ]]; then
    printf '%s\n' "still allowed after cutover"
  else
    printf '%s\n' "still allowed (cutover pending)"
  fi
}

summary_authorized_keys_state() {
  if [[ -n "${ADMIN_USER:-}" ]] && admin_authorized_keys_ready_for_user "${ADMIN_USER}"; then
    printf '%s\n' "ready ($(admin_authorized_keys_count_for_user "${ADMIN_USER}") key(s))"
  else
    printf '%s\n' "not ready"
  fi
}

summary_swap_state() {
  local swap_state=""
  local swap_show=""

  if has_active_swap; then
    swap_show="$(swapon --show --noheadings --output NAME,SIZE,USED,PRIO 2>/dev/null || true)"
    [[ -n "${swap_show}" ]] || swap_show="$(swapon --show --noheadings 2>/dev/null || true)"
    printf '%s\n' "active (${swap_show})"
    return 0
  fi

  swap_state="$(get_state "SWAP_STATUS" || true)"
  case "${swap_state}" in
    skipped)
      printf '%s\n' "not enabled (user skipped)"
      ;;
    existing-kept)
      printf '%s\n' "existing swap kept unchanged"
      ;;
    created-*|replaced-*)
      printf '%s\n' "expected active after ${swap_state}, but no active swap is currently visible"
      ;;
    manual-review)
      printf '%s\n' "manual review required"
      ;;
    *)
      printf '%s\n' "not active"
      ;;
  esac
}

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
  local next_login_target=""
  admin_state="not configured"
  auth_state="not ready"
  root_ssh_state="unknown"
  nft_state="disabled"
  ts_state="disabled"
  f2b_state="not installed"
  au_state="disabled"
  swap_state="not active"

  if [[ -n "${ADMIN_USER}" ]] && id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    admin_state="${ADMIN_USER}"
  fi

  if [[ -n "${ADMIN_USER:-}" ]]; then
    next_login_target="${ADMIN_USER}"
  else
    next_login_target="<先完成管理用户配置>"
  fi

  auth_state="$(summary_authorized_keys_state)"
  root_ssh_state="$(summary_root_login_state)"
  nft_state="$(summary_service_state "nftables" "not installed")"
  ts_state="$(summary_service_state "systemd-timesyncd" "not installed")"
  f2b_state="$(summary_service_state "fail2ban" "not installed")"
  au_state="$(summary_service_state "unattended-upgrades" "not installed")"
  swap_state="$(summary_swap_state)"

  requested_ssh_port="${SSH_PORT}"
  effective_ssh_port="$(effective_ssh_port_for_changes)"
  if ssh_port_change_pending_confirmation; then
    port_confirm_state="未确认，当前仍保持 ${effective_ssh_port}"
  else
    port_confirm_state="已确认"
  fi

  local summary
  summary="$(cat <<EOF
=== VPS Summary ===
System version: $(pretty_os_name)
Hostname: $(hostnamectl --static 2>/dev/null || hostname)
Admin user: ${admin_state}
Effective SSH port: ${effective_ssh_port}
SSH port confirmation: ${port_confirm_state}
Root remote login: ${root_ssh_state}
authorized_keys: ${auth_state}
nftables: ${nft_state}
time sync: ${ts_state}
auto updates: ${au_state}
fail2ban: ${f2b_state}
swap: ${swap_state}

Next steps:
1. 保持当前 root 会话不断开，并在新窗口测试 ${next_login_target} 的 SSH 登录。
2. 下一次 SSH 连接请使用端口 ${effective_ssh_port}。
3. 确认云厂商安全组/外部防火墙与当前 SSH 端口一致。
4. 完整机内验证以 11_verify 为准，SSH 外部连通性仍需在新窗口手动验收。
5. 验证完成后再创建快照或备份。

Reminder:
${SNAPSHOT_REMINDER}
EOF
)"

  printf '\n%s\n' "${summary}"
  log info "Summary printed to terminal."

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${summary}" >"${STATE_DIR}/init-summary.txt"
    log info "Summary file updated: ${STATE_DIR}/init-summary.txt"
  fi

  set_state "SUMMARY_WRITTEN" "yes"
}

main "$@"

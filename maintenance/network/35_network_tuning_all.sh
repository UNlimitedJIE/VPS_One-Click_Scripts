#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/ui.sh
source "${SCRIPT_DIR}/../../lib/ui.sh"

render_overview() {
  cat <<'EOF'
将按顺序执行：
1. 安装/更新 XanMod 内核 + BBR v3
2. BBR 直连/落地优化
3. DNS 净化
4. Realm 转发 timeout 修复
5. IPv6 管理

说明：
- 会逐步进入各子项自己的交互
- 某一步失败即停止
- 不会自动猜测需要你确认的输入
EOF
}

NETWORK_TUNING_ALL_SUMMARY="${NETWORK_TUNING_ALL_SUMMARY:-}"

append_network_tuning_all_result() {
  local label="$1"
  local result="$2"

  if [[ -n "${NETWORK_TUNING_ALL_SUMMARY}" ]]; then
    NETWORK_TUNING_ALL_SUMMARY+="; "
  fi
  NETWORK_TUNING_ALL_SUMMARY+="${label}=${result}"
}

network_tuning_all_report() {
  local current="$1"
  local passed="$2"
  local report=""

  report="$(readonly_status_block \
    "一键执行 1-5" \
    "${current}" \
    "${NETWORK_TUNING_ALL_SUMMARY:-no steps recorded}" \
    "${passed}")"
  log info "${report}"
}

run_step_script() {
  local label="$1"
  local path="$2"
  local status=0

  log info "Running network tuning step ${label}: $(basename "${path}")"
  bash "${path}" || status=$?
  if (( status == 0 )); then
    append_network_tuning_all_result "${label}" "yes"
    return 0
  fi

  append_network_tuning_all_result "${label}" "failed(exit=${status})"
  return "${status}"
}

main() {
  load_config
  init_runtime
  module_banner "35_network_tuning_all" "一键执行 1-5"
  require_root
  require_debian12

  ui_confirm_with_back "确认一键执行 1-5" "$(render_overview)" || return 0

  if ! run_step_script "1" "${PROJECT_ROOT}/maintenance/network/30_xanmod_bbr3.sh"; then
    network_tuning_all_report "step=1 failed" "no"
    return 1
  fi
  if ! run_step_script "2" "${PROJECT_ROOT}/maintenance/network/31_bbr_landing_optimization.sh"; then
    network_tuning_all_report "step=2 failed" "no"
    return 1
  fi
  if ! run_step_script "3" "${PROJECT_ROOT}/maintenance/network/32_dns_purification.sh"; then
    network_tuning_all_report "step=3 failed" "no"
    return 1
  fi
  if ! run_step_script "4" "${PROJECT_ROOT}/maintenance/network/33_realm_timeout_fix.sh"; then
    network_tuning_all_report "step=4 failed" "no"
    return 1
  fi
  if ! run_step_script "5" "${PROJECT_ROOT}/maintenance/network/34_ipv6_management.sh"; then
    network_tuning_all_report "step=5 failed" "no"
    return 1
  fi

  network_tuning_all_report "steps=1-5 completed" "yes"

  set_state "NETWORK_TUNING_ALL_DONE" "yes"
}

main "$@"

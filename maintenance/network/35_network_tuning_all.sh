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
3.1 安装/更新 XanMod 内核 + BBR v3
3.2 BBR 直连/落地优化
3.3 DNS 净化
3.4 Realm 转发 timeout 修复
3.5 IPv6 管理

说明：
- 会逐步进入各子项自己的交互
- 某一步失败即停止
- 不会自动猜测需要你确认的输入
EOF
}

run_step_script() {
  local path="$1"
  local status=0

  log info "Running network tuning step: $(basename "${path}")"
  bash "${path}" || status=$?
  (( status == 0 )) || return "${status}"
}

main() {
  load_config
  init_runtime
  module_banner "35_network_tuning_all" "一键执行 3.1–3.5"
  require_root
  require_debian12

  ui_confirm_with_back "确认一键执行 3.1–3.5" "$(render_overview)" || return 0

  run_step_script "${PROJECT_ROOT}/maintenance/network/30_xanmod_bbr3.sh"
  run_step_script "${PROJECT_ROOT}/maintenance/network/31_bbr_landing_optimization.sh"
  run_step_script "${PROJECT_ROOT}/maintenance/network/32_dns_purification.sh"
  run_step_script "${PROJECT_ROOT}/maintenance/network/33_realm_timeout_fix.sh"
  run_step_script "${PROJECT_ROOT}/maintenance/network/34_ipv6_management.sh"

  set_state "NETWORK_TUNING_ALL_DONE" "yes"
}

main "$@"

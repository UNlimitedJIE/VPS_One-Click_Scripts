#!/usr/bin/env bash
set -euo pipefail

# Module: 00_nodequality
# Purpose: 执行固定的 NodeQuality 基线脚本。
# Preconditions: root；系统具备 curl；网络可访问 run.NodeQuality.com。
# Steps:
#   1. 检查是否启用该模块
#   2. 检查是否已经执行过
#   3. 按固定命令执行基线脚本
# Idempotency:
#   - 通过 state 记录避免重复执行
#   - 若需重复执行，可将 NODEQUALITY_FORCE=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "00_nodequality" "执行固定的 NodeQuality 基线脚本"
  require_root

  if is_false "${ENABLE_NODEQUALITY}"; then
    log info "ENABLE_NODEQUALITY=false, skip."
    set_state "NODEQUALITY_DONE" "skipped"
    return 0
  fi

  if [[ "$(get_state NODEQUALITY_DONE 2>/dev/null || true)" == "done" ]] && is_false "${NODEQUALITY_FORCE}"; then
    log info "NodeQuality already executed in previous run. Skip."
    return 0
  fi

  if ! command_exists curl; then
    die "curl is required for the fixed first action. Install curl manually or set ENABLE_NODEQUALITY=false."
  fi

  run_shell "Running fixed action: bash <(curl -sL https://run.NodeQuality.com)" \
    'bash <(curl -sL https://run.NodeQuality.com)'

  set_state "NODEQUALITY_DONE" "done"
  set_state "NODEQUALITY_LAST_RUN" "$(date -Iseconds)"
}

main "$@"

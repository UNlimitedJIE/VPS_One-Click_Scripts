#!/usr/bin/env bash
set -euo pipefail

# Module: 20_update_system
# Purpose: 定期执行系统更新。
# Preconditions: root；Debian 12。
# Steps:
#   1. 更新索引
#   2. 安装可升级包
#   3. autoremove 清理孤儿包
# Idempotency:
#   - 重复执行只应用新增更新

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "20_update_system" "定期系统更新"
  require_root
  require_debian12

  apt_update_once
  run_cmd "Upgrading installed packages" apt-get upgrade -y
  run_cmd "Removing unused packages" apt-get autoremove -y

  set_state "MAINT_LAST_UPDATE" "$(date -Iseconds)"
}

main "$@"

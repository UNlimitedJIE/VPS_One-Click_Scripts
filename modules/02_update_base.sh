#!/usr/bin/env bash
set -euo pipefail

# Module: 02_update_base
# Purpose: 更新系统并安装初始化所需基础工具。
# Preconditions: root；Debian 12。
# Steps:
#   1. apt-get update
#   2. 执行保守型系统升级
#   3. 安装基础工具包
# Idempotency:
#   - 已安装包会自动跳过
#   - apt upgrade 重复执行只应用新更新

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "02_update_base" "系统更新与基础工具安装"
  require_root
  require_debian12

  apt_conservative_upgrade

  # shellcheck disable=SC2206
  local packages=( ${BASE_PACKAGES} )
  apt_install_packages "${packages[@]}"

  set_state "BASE_UPDATED" "$(date -Iseconds)"
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

# Module: 07_time_sync
# Purpose: 配置时区并启用 systemd-timesyncd。
# Preconditions: root；Debian 12。
# Steps:
#   1. 安装/确认 systemd-timesyncd
#   2. 设置时区
#   3. 启用 NTP 与 timesyncd
# Idempotency:
#   - 重复执行只会收敛到目标状态

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "07_time_sync" "时间同步与时区配置"
  require_root
  require_debian12

  if is_false "${ENABLE_TIME_SYNC}"; then
    log info "ENABLE_TIME_SYNC=false, skip."
    set_state "TIMESYNCD_ENABLED" "no"
    return 0
  fi

  apt_install_packages systemd-timesyncd tzdata

  if [[ -n "${TIMEZONE}" ]]; then
    run_cmd "Setting timezone to ${TIMEZONE}" timedatectl set-timezone "${TIMEZONE}"
  fi

  run_cmd "Enabling NTP sync via timedatectl" timedatectl set-ntp true
  enable_and_start_service "systemd-timesyncd"

  set_state "TIMESYNCD_ENABLED" "yes"
  set_state "TIMEZONE" "${TIMEZONE}"
}

main "$@"

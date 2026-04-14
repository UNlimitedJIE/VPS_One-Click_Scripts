#!/usr/bin/env bash
set -euo pipefail

# Module: 01_detect_system
# Purpose: 检测 Debian 12 基础环境与主机信息。
# Preconditions: root。
# Steps:
#   1. 校验系统版本
#   2. 输出主机、内核、CPU、内存、磁盘等信息
#   3. 写入 state 供后续模块与摘要使用
# Idempotency:
#   - 纯检测模块，可重复执行

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "01_detect_system" "核对系统与机器基础信息"
  require_root
  require_debian12

  local hostname kernel arch mem root_fs
  hostname="$(hostnamectl --static 2>/dev/null || hostname)"
  kernel="$(uname -r)"
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  mem="$(memory_mb)"
  root_fs="$(df -h / | awk 'NR==2 {print $2 " total / " $4 " free"}')"

  log info "OS: $(pretty_os_name)"
  log info "Hostname: ${hostname}"
  log info "Kernel: ${kernel}"
  log info "Architecture: ${arch}"
  log info "CPU cores: $(cpu_cores)"
  log info "Memory: ${mem} MB"
  log info "Root filesystem: ${root_fs}"

  set_state "OS_PRETTY_NAME" "$(pretty_os_name)"
  set_state "HOSTNAME" "${hostname}"
  set_state "KERNEL" "${kernel}"
  set_state "ARCH" "${arch}"
  set_state "MEMORY_MB" "${mem}"
}

main "$@"

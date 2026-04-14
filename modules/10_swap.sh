#!/usr/bin/env bash
set -euo pipefail

# Module: 10_swap
# Purpose: 按机器规格决定是否启用 swap。
# Preconditions: root；Debian 12。
# Steps:
#   1. 检查当前是否已存在 swap
#   2. 根据 ENABLE_SWAP 与内存大小决定是否创建
#   3. 创建 /swapfile、写入 fstab、启用 swap
# Idempotency:
#   - 已存在有效 swap 时直接跳过
#   - fstab 写入采用去重方式

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

determine_swap_size() {
  if [[ -n "${SWAP_SIZE}" ]]; then
    printf '%s\n' "${SWAP_SIZE}"
    return 0
  fi

  local mem
  mem="$(memory_mb)"
  if (( mem < 1024 )); then
    echo "1G"
  elif (( mem < 4096 )); then
    echo "2G"
  else
    echo ""
  fi
}

should_create_swap() {
  case "${ENABLE_SWAP}" in
    true|TRUE|yes|YES|on|ON|1)
      return 0
      ;;
    false|FALSE|no|NO|off|OFF|0)
      return 1
      ;;
    auto|AUTO)
      (( "$(memory_mb)" < SWAP_AUTO_THRESHOLD_MB ))
      ;;
    *)
      return 1
      ;;
  esac
}

main() {
  load_config
  init_runtime
  module_banner "10_swap" "按机器规格决定是否启用 swap"
  require_root
  require_debian12

  if has_active_swap; then
    log info "Active swap already exists:"
    swapon --show || true
    set_state "SWAP_ENABLED" "yes"
    set_state "SWAP_STATUS" "existing"
    return 0
  fi

  if ! should_create_swap; then
    log info "Swap policy says no action for current host."
    set_state "SWAP_ENABLED" "no"
    set_state "SWAP_STATUS" "skipped"
    return 0
  fi

  local target_size
  target_size="$(determine_swap_size)"
  if [[ -z "${target_size}" ]]; then
    log info "No swap size determined. Skip."
    set_state "SWAP_ENABLED" "no"
    set_state "SWAP_STATUS" "skipped"
    return 0
  fi

  if [[ -f /swapfile ]]; then
    log warn "/swapfile already exists but no active swap detected. Review manually."
    set_state "SWAP_ENABLED" "unknown"
    set_state "SWAP_STATUS" "manual-review"
    return 0
  fi

  run_cmd "Allocating swapfile ${target_size}" fallocate -l "${target_size}" /swapfile
  run_cmd "Setting swapfile permissions" chmod 600 /swapfile
  run_cmd "Formatting swapfile" mkswap /swapfile
  run_cmd "Enabling swapfile" swapon /swapfile
  ensure_line_in_file "/etc/fstab" "/swapfile none swap sw 0 0"

  set_state "SWAP_ENABLED" "yes"
  set_state "SWAP_STATUS" "${target_size}"
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

# Module: 22_audit_firewall
# Purpose: 作为长期维护中的端口管理入口，查看监听端口和 nftables 规则。
# Preconditions: root。
# Steps:
#   1. 检查 nftables 是否启用
#   2. 列出监听 TCP 端口
#   3. 对照当前 SSH 端口给出提醒
# Idempotency:
#   - 纯审查模块，可重复执行

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "22_audit_firewall" "端口管理与防火墙检查"
  require_root

  local report=""
  local nft_state="no"
  local ssh_port=""
  local listening_ports=""
  local current=""
  local evidence=""
  local passed="no"

  if service_enabled "nftables" && service_active "nftables"; then
    nft_state="yes"
  fi

  ssh_port="$(current_ssh_port)"
  listening_ports="$(listening_tcp_ports | paste -sd ',' - || true)"
  [[ -n "${listening_ports}" ]] || listening_ports="none"

  if [[ "${nft_state}" == "yes" ]]; then
    passed="yes"
  fi

  current="nftables=${nft_state}; ssh_port=${ssh_port}; listening_ports=${listening_ports}"
  evidence="systemctl is-enabled/is-active nftables; ss -ltn; nft list ruleset"
  report="$(readonly_status_block "防火墙与监听端口检查" "${current}" "${evidence}" "${passed}")"

  log info "${report}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${report}" >"${STATE_DIR}/reports/firewall-$(date '+%Y%m%d-%H%M%S').txt"
  fi
}

main "$@"

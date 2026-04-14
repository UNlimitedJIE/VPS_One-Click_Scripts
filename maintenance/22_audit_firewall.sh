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
  report+="Audit time: $(date -Iseconds)"$'\n'
  report+="Warning: this view only reflects the server itself."$'\n'
  report+="If your cloud provider also has security-group / cloud-firewall rules, you must keep them in sync manually."$'\n'
  report+=$'\n'
  report+="nftables enabled: "
  if service_enabled "nftables" && service_active "nftables"; then
    report+="yes"$'\n'
  else
    report+="no"$'\n'
  fi

  report+="Configured SSH port: $(current_ssh_port)"$'\n'
  report+=$'\n'
  report+="Listening TCP ports:"$'\n'

  local port
  while IFS= read -r port; do
    [[ -n "${port}" ]] || continue
    report+="- ${port}"$'\n'
    if [[ "${port}" != "$(current_ssh_port)" ]]; then
      report+="  review: service is listening on ${port}; ensure nftables/security-group policy matches intent."$'\n'
    fi
  done < <(listening_tcp_ports)

  report+=$'\n'
  report+="Current nftables ruleset:"$'\n'
  if command_exists nft; then
    report+="$(nft list ruleset 2>/dev/null || echo "nft list ruleset failed")"$'\n'
  else
    report+="nft command not found"$'\n'
  fi

  log info "${report}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${report}" >"${STATE_DIR}/reports/firewall-$(date '+%Y%m%d-%H%M%S').txt"
  fi
}

main "$@"

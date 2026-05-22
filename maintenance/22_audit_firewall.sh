#!/usr/bin/env bash
set -euo pipefail

# Module: 22_audit_firewall
# Purpose: 作为长期维护中的只读审查入口，查看监听端口和 nftables 规则。
# Preconditions: 无需 root；非 root 运行时部分进程信息可能不可见。
# Steps:
#   1. 检查 nftables 是否启用
#   2. 列出监听 TCP 端口
#   3. 对照当前 SSH 端口给出提醒
# Idempotency:
#   - 纯审查模块，可重复执行

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

format_firewall_list_block() {
  local prefix="${1:-  - }"
  shift || true

  if (($# == 0)); then
    printf '%s%s\n' "${prefix}" "none"
    return 0
  fi

  local item=""
  for item in "$@"; do
    printf '%s%s\n' "${prefix}" "${item}"
  done
}

join_ports_for_display() {
  if (($# == 0)); then
    printf '%s\n' "none"
    return 0
  fi

  local joined=""
  local item=""
  for item in "$@"; do
    if [[ -z "${joined}" ]]; then
      joined="${item}"
    else
      joined="${joined}, ${item}"
    fi
  done

  printf '%s\n' "${joined}"
}

main() {
  load_config
  init_runtime
  module_banner "22_audit_firewall" "防火墙与端口审查"

  local report=""
  local nft_state="inactive"
  local ssh_port=""
  local ssh_port_allowed="no"
  local ssh_port_listening="no"
  local current=""
  local evidence=""
  local passed="no"
  local listening_port_lines=()
  local nft_tcp_ports=()
  local nft_udp_ports=()
  local listening_block=""
  local nft_tcp_display=""
  local nft_udp_display=""

  if service_enabled "nftables" && service_active "nftables"; then
    nft_state="enabled and active"
  elif service_enabled "nftables"; then
    nft_state="enabled"
  elif service_active "nftables"; then
    nft_state="active"
  fi

  ssh_port="$(current_ssh_port)"
  while IFS= read -r port_line; do
    listening_port_lines+=("${port_line}")
  done < <(listening_socket_details || true)
  while IFS= read -r port_line; do
    nft_tcp_ports+=("${port_line}")
  done < <(nftables_runtime_allowed_tcp_ports || true)
  while IFS= read -r port_line; do
    nft_udp_ports+=("${port_line}")
  done < <(nftables_runtime_allowed_udp_ports || true)

  if ssh_port_is_listening_locally "${ssh_port}"; then
    ssh_port_listening="yes"
  fi

  if ((${#nft_tcp_ports[@]} > 0)) && selection_contains "${ssh_port}" "${nft_tcp_ports[@]}"; then
    ssh_port_allowed="yes"
  fi

  if ((${#listening_port_lines[@]} > 0)); then
    listening_block="$(format_firewall_list_block "  - " "${listening_port_lines[@]}")"
  else
    listening_block="$(format_firewall_list_block "  - ")"
  fi
  if ((${#nft_tcp_ports[@]} > 0)); then
    nft_tcp_display="$(join_ports_for_display "${nft_tcp_ports[@]}")"
  else
    nft_tcp_display="$(join_ports_for_display)"
  fi
  if ((${#nft_udp_ports[@]} > 0)); then
    nft_udp_display="$(join_ports_for_display "${nft_udp_ports[@]}")"
  else
    nft_udp_display="$(join_ports_for_display)"
  fi

  if [[ "${nft_state}" == "enabled and active" && "${ssh_port_allowed}" == "yes" ]]; then
    passed="yes"
  fi

  current="$(cat <<EOF

- nftables：${nft_state}
- nftables 配置文件：$(if [[ -f "$(nftables_config_path)" ]]; then printf 'present'; else printf 'missing'; fi)
- SSH 端口：${ssh_port}
- SSH 端口当前是否放行：${ssh_port_allowed}
- SSH 端口当前是否有服务监听：${ssh_port_listening}
- 当前监听端口：
${listening_block}
- 当前 nftables 放行端口：
  - tcp: ${nft_tcp_display}
  - udp: ${nft_udp_display}
EOF
)"
  evidence="$(cat <<EOF

- systemctl is-enabled/is-active nftables
- ss -lntup
- nft list ruleset
EOF
)"
  report="$(readonly_status_block "防火墙与监听端口检查" "${current}" "${evidence}" "${passed}")"

  log info "${report}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${report}" >"${STATE_DIR}/reports/firewall-$(date '+%Y%m%d-%H%M%S').txt"
  fi
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

# Module: 22_audit_firewall
# Purpose: 作为长期维护中的防火墙入口，审查监听端口并按需打开/关闭受控入站端口。
# Preconditions: 审查无需 root；打开/关闭端口需要 root。
# Steps:
#   1. 检查 nftables 是否启用
#   2. 列出监听 TCP 端口
#   3. 对照当前 SSH 端口给出提醒
#   4. 在交互菜单中打开/关闭 VPS EXTRA PORTS 受控区块里的入站端口
# Idempotency:
#   - 审查可重复执行
#   - 端口管理只改写 /etc/nftables.conf 中的 VPS EXTRA PORTS 受控区块

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/ui.sh
source "${SCRIPT_DIR}/../lib/ui.sh"

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

build_firewall_report() {
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
  readonly_status_block "防火墙与监听端口检查" "${current}" "${evidence}" "${passed}"
}

write_firewall_report() {
  local report="$1"

  log info "${report}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${report}" >"${STATE_DIR}/reports/firewall-$(date '+%Y%m%d-%H%M%S').txt"
  fi
}

show_firewall_report() {
  local report=""
  report="$(build_firewall_report)"
  write_firewall_report "${report}"
}

render_firewall_port_menu_prompt() {
  cat <<'EOF'
可执行项目：
1. 查看防火墙与端口审查
   只读查看 nftables、监听端口、SSH 端口和当前显式放行端口。
2. 开放 TCP 入站端口
   写入 VPS EXTRA PORTS 受控区块并重新加载 nftables。
3. 关闭 TCP 入站端口
   只从 VPS EXTRA PORTS 受控区块移除端口；拒绝关闭当前 SSH 端口。
4. 开放 UDP 入站端口
   写入 VPS EXTRA PORTS 受控区块并重新加载 nftables。
5. 关闭 UDP 入站端口
   只从 VPS EXTRA PORTS 受控区块移除端口。

快捷操作：
0. 返回上一级菜单

99. 退出脚本

输入规则：
- 输入单个数字直接执行对应项目
- 端口支持单个或多个，例如 80 或 80,443
EOF
}

parse_firewall_ports_input() {
  local raw="${1:-}"
  local token=""
  local validation_error=""
  PARSED_FIREWALL_PORTS=()

  while IFS= read -r token; do
    token="$(ui_trim_value "${token}")"
    [[ -n "${token}" ]] || continue

    validation_error="$(port_validation_error_zh "${token}")"
    if [[ -n "${validation_error}" ]]; then
      printf '%s\n' "${validation_error}"
      return 1
    fi
    if ! selection_contains "${token}" "${PARSED_FIREWALL_PORTS[@]}"; then
      PARSED_FIREWALL_PORTS+=("${token}")
    fi
  done < <(printf '%s\n' "${raw}" | tr ',，;； ' '\n\n\n\n\n')

  ((${#PARSED_FIREWALL_PORTS[@]} > 0)) || {
    printf '%s\n' "端口不能为空。"
    return 1
  }

  return 0
}

prompt_firewall_ports() {
  local title="$1"
  local raw=""
  local validation_error=""

  while true; do
    ui_prompt_input "${title}" "请输入端口，支持逗号或空格分隔。\n输入 0 返回上一级菜单。\n输入 99 退出脚本：" || return 1
    raw="$(ui_trim_value "${UI_LAST_INPUT}")"
    [[ "${raw}" != "0" ]] || return 1

    validation_error="$(parse_firewall_ports_input "${raw}" || true)"
    if [[ -z "${validation_error}" ]]; then
      return 0
    fi

    ui_warn_message "端口无效" "${validation_error}"
  done
}

confirm_firewall_port_change() {
  local action_label="$1"
  local proto="$2"
  shift 2 || true
  local ports_display=""

  ports_display="$(join_ports_for_display "$@")"
  ui_confirm_with_back \
    "确认${action_label}端口" \
    "协议：${proto}\n端口：${ports_display}\n\n本操作只修改 /etc/nftables.conf 的 VPS EXTRA PORTS 受控区块，然后执行 nft 语法检查并加载规则。\n不会创建 DNAT、SNAT、MASQUERADE、端口转发或 NAT 规则。\n如果云厂商还有安全组/云防火墙，也需要在云控制台同步调整。"
}

run_firewall_port_change() {
  local action="$1"
  local proto="$2"
  local action_label=""

  case "${action}" in
    open) action_label="开放" ;;
    close) action_label="关闭" ;;
    *) die "Unsupported firewall action: ${action}" ;;
  esac

  prompt_firewall_ports "${action_label} ${proto^^} 入站端口" || return 0
  confirm_firewall_port_change "${action_label}" "${proto}" "${PARSED_FIREWALL_PORTS[@]}" || return 0

  require_root
  if [[ "${action}" == "open" ]]; then
    nftables_open_ports_by_proto "${proto}" "${PARSED_FIREWALL_PORTS[@]}"
  else
    nftables_close_ports_by_proto "${proto}" "${PARSED_FIREWALL_PORTS[@]}"
  fi

  ui_show_plain_and_wait \
    "端口${action_label}完成" \
    "$(build_firewall_report)" \
    "按回车返回防火墙菜单："
}

firewall_port_management_menu() {
  local raw_input=""

  while true; do
    ui_clear_screen || true
    ui_prompt_input "防火墙与端口管理" "$(render_firewall_port_menu_prompt)" || return 0
    raw_input="$(ui_trim_value "${UI_LAST_INPUT}")"

    case "${raw_input}" in
      0)
        return 0
        ;;
      99)
        ui_exit_script
        ;;
      1)
        ui_show_plain_and_wait \
          "防火墙与端口审查" \
          "$(build_firewall_report)" \
          "按回车返回防火墙菜单："
        ;;
      2)
        run_firewall_port_change "open" "tcp"
        ;;
      3)
        run_firewall_port_change "close" "tcp"
        ;;
      4)
        run_firewall_port_change "open" "udp"
        ;;
      5)
        run_firewall_port_change "close" "udp"
        ;;
      "")
        ui_warn_message "输入为空" "请输入 1、2、3、4、5、0 或 99。"
        ;;
      *)
        ui_warn_message "输入无效" "防火墙菜单只支持 1、2、3、4、5、0 或 99。"
        ;;
    esac
  done
}

main() {
  load_config
  init_runtime
  module_banner "22_audit_firewall" "防火墙与端口管理"

  if is_true "${PLAN_ONLY:-false}" || is_true "${DRY_RUN:-false}"; then
    show_firewall_report
    log info "[plan] 交互执行时可在该入口开放或关闭 VPS EXTRA PORTS 受控区块中的 TCP/UDP 入站端口。"
    return 0
  fi

  if ui_require_interactive; then
    firewall_port_management_menu
    return 0
  fi

  show_firewall_report
}

main "$@"

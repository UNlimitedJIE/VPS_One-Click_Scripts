#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/ui.sh
source "${SCRIPT_DIR}/../../lib/ui.sh"

detect_bandwidth_mbps() {
  local output=""
  local iface=""
  local speed=""

  if command_exists speedtest; then
    output="$(speedtest --accept-license --accept-gdpr --format=json 2>/dev/null || true)"
    speed="$(printf '%s\n' "${output}" | jq -r '.download.bandwidth // empty' 2>/dev/null || true)"
    if [[ -n "${speed}" && "${speed}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      awk -v value="${speed}" 'BEGIN { printf "%.0f\n", (value * 8) / 1000000 }'
      return 0
    fi
  fi

  if command_exists speedtest-cli; then
    output="$(speedtest-cli --simple 2>/dev/null || true)"
    speed="$(printf '%s\n' "${output}" | awk '/^Download:/ {print int($2 + 0.5); exit}')"
    if [[ -n "${speed}" && "${speed}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "${speed}"
      return 0
    fi
  fi

  while IFS= read -r iface; do
    [[ -n "${iface}" ]] || continue
    if [[ -r "/sys/class/net/${iface}/speed" ]]; then
      speed="$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || true)"
      if [[ -n "${speed}" && "${speed}" =~ ^[0-9]+$ && "${speed}" -gt 0 ]]; then
        printf '%s\n' "${speed}"
        return 0
      fi
    fi
  done < <(network_tuning_default_route_interfaces)

  return 1
}

prompt_bandwidth_mbps() {
  local choice=""
  local custom=""
  local speed=""

  while true; do
    if ! ui_prompt_input "2. BBR 直连/落地优化" $'请选择带宽档位：\n1. 自动测速\n2. 500M\n3. 700M\n4. 1G\n5. 自定义\n0. 返回'; then
      return 1
    fi

    choice="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${choice}" in
      0)
        return 1
        ;;
      1)
        speed="$(detect_bandwidth_mbps || true)"
        [[ -n "${speed}" ]] || die "自动测速失败，当前系统未检测到可用测速/链路速率来源。"
        log info "自动检测到带宽档位: ${speed} Mbps"
        printf '%s\n' "${speed}"
        return 0
        ;;
      2)
        printf '%s\n' "500"
        return 0
        ;;
      3)
        printf '%s\n' "700"
        return 0
        ;;
      4)
        printf '%s\n' "1000"
        return 0
        ;;
      5)
        if ! ui_prompt_input "自定义带宽" "请输入自定义带宽，单位 Mbps。\n0 = 返回" ; then
          return 1
        fi
        custom="$(ui_trim_value "${UI_LAST_INPUT}")"
        [[ "${custom}" == "0" ]] && return 1
        if [[ "${custom}" =~ ^[0-9]+$ && "${custom}" -gt 0 ]]; then
          printf '%s\n' "${custom}"
          return 0
        fi
        ui_warn_message "输入无效" "带宽必须是正整数 Mbps。"
        ;;
      *)
        ui_warn_message "输入无效" "只支持输入 1、2、3、4、5 或 0。"
        ;;
    esac
  done
}

prompt_region_profile() {
  local choice=""

  while true; do
    if ! ui_prompt_input "地区选择" $'请选择链路地区：\n1. 亚太\n2. 美欧\n0. 返回'; then
      return 1
    fi

    choice="$(ui_trim_value "${UI_LAST_INPUT}")"
    case "${choice}" in
      0)
        return 1
        ;;
      1)
        printf '%s\n' "apac"
        return 0
        ;;
      2)
        printf '%s\n' "eu-us"
        return 0
        ;;
      *)
        ui_warn_message "输入无效" "只支持输入 1、2 或 0。"
        ;;
    esac
  done
}

region_rtt_ms() {
  case "${1:-}" in
    apac) printf '%s\n' "180" ;;
    eu-us) printf '%s\n' "90" ;;
    *) printf '%s\n' "120" ;;
  esac
}

render_bbr_sysctl_content() {
  local bandwidth_mbps="$1"
  local region="$2"
  local rtt_ms=""
  local max_buffer=""
  local default_rmem=""
  local default_wmem=""

  rtt_ms="$(region_rtt_ms "${region}")"
  max_buffer="$(awk -v mbps="${bandwidth_mbps}" -v rtt="${rtt_ms}" '
    BEGIN {
      bytes = int((mbps * 1000000 / 8) * (rtt / 1000.0) * 4)
      if (bytes < 4194304) {
        bytes = 4194304
      }
      if (bytes > 67108864) {
        bytes = 67108864
      }
      print bytes
    }
  ')"
  default_rmem="$((max_buffer / 2))"
  default_wmem="$((max_buffer / 4))"

  cat <<EOF
# Managed by VPS network tuning 3.2.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = ${max_buffer}
net.core.wmem_max = ${max_buffer}
net.ipv4.tcp_rmem = 4096 ${default_rmem} ${max_buffer}
net.ipv4.tcp_wmem = 4096 ${default_wmem} ${max_buffer}
EOF
}

render_fq_apply_script() {
  cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ip route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}' | awk 'NF && !seen[$0]++' | while IFS= read -r iface; do
  [[ -n "${iface}" ]] || continue
  tc qdisc replace dev "${iface}" root fq >/dev/null 2>&1 || true
done
EOF
}

render_fq_service() {
  cat <<EOF
[Unit]
Description=Restore fq qdisc on default interfaces
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$(network_tuning_fq_script_path)
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

main() {
  load_config
  init_runtime
  module_banner "31_bbr_landing_optimization" "BBR 直连/落地优化"
  require_root
  require_debian12

  local bandwidth_mbps=""
  local region=""
  local iface=""
  local service_name=""
  local tc_summary=""

  network_tuning_kernel_supports_bbr || die "当前内核不支持 bbr，不能继续执行 2。"

  bandwidth_mbps="$(prompt_bandwidth_mbps)" || return 0
  region="$(prompt_region_profile)" || return 0

  apply_managed_file "$(network_tuning_bbr_sysctl_file)" "0644" "$(render_bbr_sysctl_content "${bandwidth_mbps}" "${region}")" "true"
  run_cmd "Applying BBR sysctl profile" sysctl --system

  apply_managed_file "$(network_tuning_fq_script_path)" "0755" "$(render_fq_apply_script)" "true"
  apply_managed_file "$(network_tuning_fq_service_path)" "0644" "$(render_fq_service)" "true"
  run_cmd "Reloading systemd daemon" systemctl daemon-reload
  service_name="$(network_tuning_fq_service_name)"
  run_cmd "Enabling fq restore service" systemctl enable "${service_name}"
  run_cmd "Running fq restore service now" systemctl start "${service_name}"

  while IFS= read -r iface; do
    [[ -n "${iface}" ]] || continue
    run_cmd "Applying fq qdisc to ${iface}" tc qdisc replace dev "${iface}" root fq
  done < <(network_tuning_default_route_interfaces)

  tc_summary="$(network_tuning_tc_qdisc_summary | tr '\n' ';' | sed 's/;$/ /')"

  log info "当前 default_qdisc: $(network_tuning_default_qdisc)"
  log info "当前 tcp_congestion_control: $(network_tuning_tcp_congestion_control)"
  log info "当前 tcp_rmem: $(network_tuning_sysctl_value net.ipv4.tcp_rmem)"
  log info "当前 tcp_wmem: $(network_tuning_sysctl_value net.ipv4.tcp_wmem)"
  log info "当前 tc qdisc show: ${tc_summary}"
  log info "持久化 fq 服务: ${service_name} (enabled=$(network_tuning_service_enabled_state "${service_name}"))"

  set_state "NETWORK_BBR_TUNED" "yes"
  set_state "NETWORK_BBR_BANDWIDTH_MBPS" "${bandwidth_mbps}"
  set_state "NETWORK_BBR_REGION" "${region}"
}

main "$@"

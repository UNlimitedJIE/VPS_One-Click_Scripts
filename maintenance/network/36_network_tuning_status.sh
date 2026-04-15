#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

print_status_section() {
  local title="$1"
  local current="$2"
  local evidence="$3"
  local passed="$4"

  cat <<EOF
[${title}]
当前状态：${current}
依据：${evidence}
是否通过：${passed}

EOF
}

realm_status_values() {
  local config_path="$1"
  local config_format="$2"

  case "${config_format}" in
    toml)
      awk '
        /^\[network\]/ { in_network = 1; next }
        in_network && /^\[/ { in_network = 0 }
        in_network && $1 ~ /^(tcp_timeout|tcp_keepalive|tcp_keepalive_probe)$/ {
          print $1 "=" $3
        }
      ' "${config_path}" 2>/dev/null | paste -sd ',' -
      ;;
    json)
      jq -r '.network | "tcp_timeout=\(.tcp_timeout // "unset"),tcp_keepalive=\(.tcp_keepalive // "unset"),tcp_keepalive_probe=\(.tcp_keepalive_probe // "unset")"' "${config_path}" 2>/dev/null || printf 'unknown'
      ;;
    *)
      printf 'unknown'
      ;;
  esac
}

main() {
  load_config
  init_runtime
  require_debian12

  local kernel=""
  local xanmod="no"
  local bbr="no"
  local bbr3="no"
  local available_cc=""
  local current_cc=""
  local kernel_pass="no"

  local default_qdisc=""
  local tcp_rmem=""
  local tcp_wmem=""
  local bbr_file_state="absent"
  local tc_qdisc=""
  local fq_service_name=""
  local fq_service_state="absent"
  local bbr_tuning_pass="no"

  local dns_mode=""
  local dns_servers=""
  local dns_dot=""
  local dns_effective="no"
  local dns_pass="no"

  local realm_service=""
  local realm_config=""
  local realm_format=""
  local realm_state="not detected"
  local realm_values="n/a"
  local realm_pass="未适用"

  local ipv6_enabled="yes"
  local ipv6_state=""
  local ipv6_pass="no"

  kernel="$(network_tuning_current_kernel)"
  available_cc="$(network_tuning_tcp_available_congestion_control)"
  current_cc="$(network_tuning_tcp_congestion_control)"
  network_tuning_kernel_is_xanmod && xanmod="yes"
  network_tuning_kernel_supports_bbr && bbr="yes"
  network_tuning_kernel_supports_bbr3 && bbr3="yes"
  [[ "${bbr}" == "yes" ]] && kernel_pass="yes"

  default_qdisc="$(network_tuning_default_qdisc)"
  tcp_rmem="$(network_tuning_sysctl_value net.ipv4.tcp_rmem)"
  tcp_wmem="$(network_tuning_sysctl_value net.ipv4.tcp_wmem)"
  [[ -f "$(network_tuning_bbr_sysctl_file)" ]] && bbr_file_state="present"
  tc_qdisc="$(network_tuning_tc_qdisc_summary | tr '\n' ';' | sed 's/;$/ /')"
  fq_service_name="$(network_tuning_fq_service_name)"
  if service_exists "${fq_service_name}"; then
    fq_service_state="$(network_tuning_service_state "${fq_service_name}")/$(network_tuning_service_enabled_state "${fq_service_name}")"
  fi
  if [[ "${bbr_file_state}" == "present" && "${current_cc}" == "bbr" && "${default_qdisc}" == "fq" ]]; then
    bbr_tuning_pass="yes"
  fi

  dns_mode="$(network_tuning_dns_mode_label)"
  dns_servers="$(network_tuning_dns_current_servers)"
  dns_dot="$(network_tuning_dns_dot_state)"
  [[ -f "$(network_tuning_dns_dropin_path)" ]] && dns_effective="yes"
  case "${dns_mode}" in
    国外)
      [[ "${dns_effective}" == "yes" && "${dns_dot}" == "yes" ]] && dns_pass="yes"
      ;;
    国内)
      [[ "${dns_effective}" == "yes" && "${dns_dot}" == "no" ]] && dns_pass="yes"
      ;;
  esac

  realm_service="$(network_tuning_realm_service_name || true)"
  realm_config="$(network_tuning_realm_config_path || true)"
  realm_format="$(network_tuning_realm_config_format "${realm_config}")"
  if [[ -n "${realm_service}" || -n "${realm_config}" ]]; then
    realm_state="service=${realm_service:-unknown}, config=${realm_config:-unknown}"
    realm_pass="no"
    if [[ -n "${realm_config}" && -f "${realm_config}" ]]; then
      realm_values="$(realm_status_values "${realm_config}" "${realm_format}")"
    fi
    if [[ -n "${realm_service}" && "$(network_tuning_service_state "${realm_service}")" == "active" ]] && printf '%s\n' "${realm_values}" | grep -q 'tcp_timeout=30'; then
      realm_pass="yes"
    fi
  fi

  if [[ "$(network_tuning_ipv6_disable_all)" == "1" || "$(network_tuning_ipv6_disable_default)" == "1" ]]; then
    ipv6_enabled="no"
  fi
  ipv6_state="$(network_tuning_ipv6_state_label)"
  if [[ "${ipv6_state}" == "永久禁用" || "${ipv6_state}" == "临时禁用" || "${ipv6_state}" == "恢复" ]]; then
    ipv6_pass="yes"
  fi

  print_status_section \
    "内核 / BBR 能力" \
    "kernel=${kernel}; xanmod=${xanmod}; bbr=${bbr}; bbr3=${bbr3}; available=${available_cc}; active=${current_cc}" \
    "uname -r; sysctl net.ipv4.tcp_available_congestion_control; sysctl net.ipv4.tcp_congestion_control" \
    "${kernel_pass}"

  print_status_section \
    "BBR 调优状态" \
    "default_qdisc=${default_qdisc}; tcp_rmem=${tcp_rmem}; tcp_wmem=${tcp_wmem}; managed_file=${bbr_file_state}; fq_service=${fq_service_state}" \
    "sysctl net.core.default_qdisc; sysctl net.ipv4.tcp_rmem; sysctl net.ipv4.tcp_wmem; $(network_tuning_bbr_sysctl_file); tc qdisc show" \
    "${bbr_tuning_pass}"

  print_status_section \
    "DNS 净化状态" \
    "mode=${dns_mode}; servers=${dns_servers}; dot=${dns_dot}; config_effective=${dns_effective}" \
    "$(network_tuning_dns_dropin_path); resolvectl dns / /etc/resolv.conf" \
    "${dns_pass}"

  print_status_section \
    "Realm timeout 修复状态" \
    "${realm_state}; service_state=$( [[ -n "${realm_service}" ]] && network_tuning_service_state "${realm_service}" || echo not-found ); values=${realm_values}" \
    "systemctl status ${realm_service:-realm}; ${realm_config:-no-config}" \
    "${realm_pass}"

  print_status_section \
    "IPv6 状态" \
    "enabled=${ipv6_enabled}; all=$(network_tuning_ipv6_disable_all); default=$(network_tuning_ipv6_disable_default); lo=$(network_tuning_ipv6_disable_lo); mode=${ipv6_state}" \
    "sysctl net.ipv6.conf.all/default/lo.disable_ipv6; $(network_tuning_ipv6_sysctl_file)" \
    "${ipv6_pass}"

  set_state "NETWORK_TUNING_STATUS_REVIEWED" "yes"
}

main "$@"

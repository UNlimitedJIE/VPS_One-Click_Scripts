#!/usr/bin/env bash
set -euo pipefail

# Module: 38_status_review
# Purpose: 只读展示谨慎操作相关配置、当前状态、风险说明与建议。
# Preconditions: 无强制写权限要求；建议在 Debian 12 上执行。
# Steps:
#   1. 读取 SSH、sysctl 和受控文件状态
#   2. 输出风险说明与建议
#   3. 写入一份只读报告到 state/reports
# Idempotency:
#   - 纯读取，不修改系统

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

sysctl_value() {
  local key="$1"
  sysctl -n "${key}" 2>/dev/null || echo "unknown"
}

main() {
  load_config
  init_runtime
  module_banner "38_status_review" "查看谨慎操作说明与当前状态"
  require_debian12

  local ssh_usedns="unknown"
  local ssh_ciphers="unknown"
  if command_exists sshd; then
    ssh_usedns="$(sshd -T 2>/dev/null | awk '/^usedns / {print $2; exit}' || true)"
    ssh_ciphers="$(sshd -T 2>/dev/null | awk '/^ciphers / {print $2; exit}' || true)"
    [[ -n "${ssh_usedns}" ]] || ssh_usedns="unknown"
    [[ -n "${ssh_ciphers}" ]] || ssh_ciphers="unknown"
  fi

  local report=""
  report="$(cat <<EOF
=== Cautious Operations Status Review ===
System: $(pretty_os_name)
SAFE_TUNING_PROFILE: ${SAFE_TUNING_PROFILE}

10.1 保守型 sysctl / 网络调优入口:
  managed file: $( [[ -f /etc/sysctl.d/99-vps-safe-tuning.conf ]] && echo present || echo absent )

10.2 SSH 连接加速：关闭 DNS 反向解析:
  sshd UseDNS: ${ssh_usedns}
  managed file: $( [[ -f /etc/ssh/sshd_config.d/60-vps-cautious-usedns.conf ]] && echo present || echo absent )

10.3 SSH 加密算法配置:
  sshd Ciphers: ${ssh_ciphers}
  managed file: $( [[ -f /etc/ssh/sshd_config.d/61-vps-cautious-ciphers.conf ]] && echo present || echo absent )

10.4 ICMP / Ping 控制:
  net.ipv4.icmp_echo_ignore_all: $(sysctl_value net.ipv4.icmp_echo_ignore_all)
  note: 禁 ping 不等于真正安全，只是降低可见性。

10.5 网络转发相关开关:
  net.ipv4.ip_forward: $(sysctl_value net.ipv4.ip_forward)
  net.ipv6.conf.all.forwarding: $(sysctl_value net.ipv6.conf.all.forwarding)
  net.ipv6.conf.default.forwarding: $(sysctl_value net.ipv6.conf.default.forwarding)
  note: 普通单机 VPS 默认不建议随意开启转发。

10.6 拥塞控制与队列调优:
  net.core.default_qdisc: $(sysctl_value net.core.default_qdisc)
  net.ipv4.tcp_congestion_control: $(sysctl_value net.ipv4.tcp_congestion_control)
  available congestion control: $(sysctl_value net.ipv4.tcp_available_congestion_control)

10.7 TCP 缓冲与连接队列参数:
  net.core.somaxconn: $(sysctl_value net.core.somaxconn)
  net.ipv4.tcp_max_syn_backlog: $(sysctl_value net.ipv4.tcp_max_syn_backlog)
  net.ipv4.tcp_rmem: $(sysctl_value net.ipv4.tcp_rmem)
  net.ipv4.tcp_wmem: $(sysctl_value net.ipv4.tcp_wmem)

10.8 TCP 高级特性参数:
  net.ipv4.tcp_fastopen: $(sysctl_value net.ipv4.tcp_fastopen)
  net.ipv4.tcp_timestamps: $(sysctl_value net.ipv4.tcp_timestamps)
  net.ipv4.tcp_sack: $(sysctl_value net.ipv4.tcp_sack)
  net.ipv4.tcp_window_scaling: $(sysctl_value net.ipv4.tcp_window_scaling)

10.9 内核与内存行为参数:
  kernel.panic: $(sysctl_value kernel.panic)
  kernel.panic_on_oops: $(sysctl_value kernel.panic_on_oops)
  vm.swappiness: $(sysctl_value vm.swappiness)

Recommendations:
1. SSH 登录策略、密码登录与 root 登录策略，请回到初始化 SSH 模块统一管理。
2. 这些谨慎项不等于“越多越好”，请结合内核版本、业务负载、虚拟化环境和上游网络设备一起评估。
3. 如果你无法明确说明某项参数为什么要改，优先保持默认值。
EOF
)"

  log info "${report}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${report}" >"${STATE_DIR}/reports/cautious-status-${RUN_ID}.txt"
  fi

  set_state "CAUTIOUS_STATUS_REVIEWED" "yes"
}

main "$@"

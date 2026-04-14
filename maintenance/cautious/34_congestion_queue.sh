#!/usr/bin/env bash
set -euo pipefail

# Module: 34_congestion_queue
# Purpose: 为网络层设置 BBR 和 fq，作为偏保守的吞吐/排队调优入口。
# Preconditions: root；Debian 12；内核支持 BBR。
# Steps:
#   1. 检查当前内核是否支持 BBR
#   2. 写入 sysctl drop-in
#   3. 应用 sysctl
# Idempotency:
#   - 使用受控 drop-in 文件
#   - 配置未变化时不会重复改动

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "34_congestion_queue" "拥塞控制与队列调优"
  require_root
  require_debian12

  local available=""
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
  printf '%s\n' "${available}" | grep -qw "bbr" || die "BBR is not available on this kernel. Skipping cautious congestion-control tuning."

  log warn "This change sets net.core.default_qdisc=fq and net.ipv4.tcp_congestion_control=bbr."
  log warn "Risk: these values are common, but they are still workload- and kernel-dependent."

  local content=""
  content="$(cat <<'EOF'
# Managed by VPS bootstrap cautious menu.
# Conservative congestion-control baseline when BBR is available.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
)"

  apply_sysctl_dropin \
    "/etc/sysctl.d/72-vps-cautious-congestion.conf" \
    "${content}" \
    "Applying congestion-control and queue settings"

  set_state "CAUTIOUS_TCP_CONGESTION_CONTROL" "bbr"
}

main "$@"

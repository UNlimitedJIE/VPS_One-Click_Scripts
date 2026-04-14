#!/usr/bin/env bash
set -euo pipefail

# Module: 32_icmp_ping_control
# Purpose: 通过 sysctl 关闭 IPv4 ping 回应，降低主机可见性。
# Preconditions: root；Debian 12。
# Steps:
#   1. 写入 sysctl drop-in
#   2. 应用 sysctl
# Idempotency:
#   - 使用受控 drop-in 文件
#   - 配置未变化时不会重复改动

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "32_icmp_ping_control" "ICMP / Ping 控制"
  require_root
  require_debian12

  log warn "This change disables IPv4 ICMP echo replies."
  log warn "Risk: ping-based monitoring and troubleshooting will be affected."
  log warn "Disabling ping does not make a host truly secure; it only reduces visibility."

  local content=""
  content="$(cat <<'EOF'
# Managed by VPS bootstrap cautious menu.
# Reduce host visibility. This does not replace real access control.
net.ipv4.icmp_echo_ignore_all = 1
EOF
)"

  apply_sysctl_dropin \
    "/etc/sysctl.d/70-vps-cautious-icmp.conf" \
    "${content}" \
    "Applying ICMP / ping control settings"

  set_state "CAUTIOUS_ICMP_ECHO_IGNORE_ALL" "1"
}

main "$@"

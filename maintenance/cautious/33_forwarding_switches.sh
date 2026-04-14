#!/usr/bin/env bash
set -euo pipefail

# Module: 33_forwarding_switches
# Purpose: 明确关闭 IPv4/IPv6 转发，适合作为普通单机 VPS 的保守默认值。
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
  module_banner "33_forwarding_switches" "网络转发相关开关"
  require_root
  require_debian12

  log warn "This change explicitly disables IPv4 and IPv6 forwarding."
  log warn "Risk: do not apply this if the VPS is acting as a router, VPN gateway, proxy transit node, or container host that requires forwarding."
  log warn "For a normal single-node VPS, forwarding should usually remain disabled."

  local content=""
  content="$(cat <<'EOF'
# Managed by VPS bootstrap cautious menu.
# Safe default for a normal single-node VPS.
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0
EOF
)"

  apply_sysctl_dropin \
    "/etc/sysctl.d/71-vps-cautious-forwarding.conf" \
    "${content}" \
    "Applying forwarding safety defaults"

  set_state "CAUTIOUS_IP_FORWARD" "0"
}

main "$@"

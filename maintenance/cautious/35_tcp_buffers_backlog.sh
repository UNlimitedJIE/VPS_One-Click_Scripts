#!/usr/bin/env bash
set -euo pipefail

# Module: 35_tcp_buffers_backlog
# Purpose: 为 TCP 缓冲和连接队列设置一组保守的建议值。
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
  module_banner "35_tcp_buffers_backlog" "TCP 缓冲与连接队列参数"
  require_root
  require_debian12

  log warn "This change sets conservative values for socket buffer ceilings and listen backlog."
  log warn "Risk: these values are not universally optimal. Review together with real traffic shape and application backlog settings."

  local content=""
  content="$(cat <<'EOF'
# Managed by VPS bootstrap cautious menu.
# Conservative buffer and queue tuning. Review with workload metrics.
net.core.somaxconn = 1024
net.core.netdev_max_backlog = 4096
net.core.rmem_max = 6291456
net.core.wmem_max = 6291456
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_rmem = 4096 131072 6291456
net.ipv4.tcp_wmem = 4096 65536 6291456
EOF
)"

  apply_sysctl_dropin \
    "/etc/sysctl.d/73-vps-cautious-buffers.conf" \
    "${content}" \
    "Applying TCP buffer and backlog settings"

  set_state "CAUTIOUS_TCP_BUFFERS" "managed"
}

main "$@"

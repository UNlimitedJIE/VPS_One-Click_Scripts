#!/usr/bin/env bash
set -euo pipefail

# Module: 36_tcp_advanced_features
# Purpose: 管理一组常见 TCP 高级特性参数。
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
  module_banner "36_tcp_advanced_features" "TCP 高级特性参数"
  require_root
  require_debian12

  log warn "This change manages tcp_fastopen, timestamps, sack, and window scaling."
  log warn "Risk: compatibility varies across kernels, middleboxes, and very old clients."

  local content=""
  content="$(cat <<'EOF'
# Managed by VPS bootstrap cautious menu.
# Review these values if you serve unusual legacy networks.
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
EOF
)"

  apply_sysctl_dropin \
    "/etc/sysctl.d/74-vps-cautious-tcp-advanced.conf" \
    "${content}" \
    "Applying advanced TCP feature settings"

  set_state "CAUTIOUS_TCP_ADVANCED" "managed"
}

main "$@"

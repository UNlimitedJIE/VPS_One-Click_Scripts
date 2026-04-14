#!/usr/bin/env bash
set -euo pipefail

# Module: 31_ssh_ciphers
# Purpose: 为 SSH 设置一组偏现代的加密算法，兼顾常见兼容性与安全性。
# Preconditions: root；Debian 12；openssh-server 已安装或可安装。
# Steps:
#   1. 写入独立的 sshd drop-in
#   2. 做 sshd 语法检查
#   3. reload SSH 服务
# Idempotency:
#   - 仅管理本项目自己的 drop-in 文件
#   - 配置未变化时不会重复改动

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "31_ssh_ciphers" "SSH 加密算法配置"
  require_root
  require_debian12

  log warn "This change sets an explicit Ciphers list for sshd."
  log warn "Risk: older SSH clients may fail to connect after this change."

  local content=""
  content="$(cat <<'EOF'
# Managed by VPS bootstrap cautious menu.
# Compatibility and security tradeoff: modern ciphers first.
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
EOF
)"

  apply_sshd_dropin \
    "/etc/ssh/sshd_config.d/61-vps-cautious-ciphers.conf" \
    "${content}" \
    "Applying SSH cipher policy"

  set_state "CAUTIOUS_SSH_CIPHERS" "managed"
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

# Module: 30_ssh_usedns_no
# Purpose: 关闭 SSH 的 DNS 反向解析，减少部分环境中的连接等待时间。
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
  module_banner "30_ssh_usedns_no" "SSH 连接加速：关闭 DNS 反向解析"
  require_root
  require_debian12

  log warn "This change sets UseDNS no for sshd."
  log warn "Risk: if your environment relies on reverse-DNS-based auditing or host policy, review before applying."

  local content=""
  content="$(cat <<'EOF'
# Managed by VPS bootstrap cautious menu.
# Reduce SSH login latency by skipping reverse DNS lookups.
UseDNS no
EOF
)"

  apply_sshd_dropin \
    "/etc/ssh/sshd_config.d/60-vps-cautious-usedns.conf" \
    "${content}" \
    "Applying SSH UseDNS setting"

  set_state "CAUTIOUS_SSH_USEDNS" "no"
}

main "$@"

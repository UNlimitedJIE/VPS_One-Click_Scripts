#!/usr/bin/env bash
set -euo pipefail

# Module: 27_tuning_entry
# Purpose: 作为保守型 sysctl / 网络调优入口，默认不激进修改。
# Preconditions: root；Debian 12。
# Steps:
#   1. 检查 SAFE_TUNING_PROFILE
#   2. 默认仅提示，不改系统
#   3. baseline 模式下写入保守网络硬化配置
# Idempotency:
#   - 使用受控 sysctl drop-in
#   - 默认 none 时不执行任何变更

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "27_tuning_entry" "保守型 sysctl / 网络调优入口"
  require_root
  require_debian12

  if [[ "${SAFE_TUNING_PROFILE}" == "none" ]]; then
    log info "SAFE_TUNING_PROFILE=none. No sysctl changes will be applied."
    log info "Use baseline only after reviewing workload, virtualization type, and network topology."
    return 0
  fi

  if [[ "${SAFE_TUNING_PROFILE}" != "baseline" ]]; then
    die "Unsupported SAFE_TUNING_PROFILE: ${SAFE_TUNING_PROFILE}"
  fi

  local content
  content="$(cat <<'EOF'
# Managed by VPS bootstrap project.
# Conservative network hardening only.
# Do not place aggressive throughput/latency tuning here without host-specific review.

net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
EOF
)"

  apply_sysctl_dropin \
    "/etc/sysctl.d/99-vps-safe-tuning.conf" \
    "${content}" \
    "Applying conservative sysctl hardening profile"

  set_state "CAUTIOUS_TUNING_PROFILE" "${SAFE_TUNING_PROFILE}"
}

main "$@"

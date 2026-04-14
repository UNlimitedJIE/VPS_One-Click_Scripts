#!/usr/bin/env bash
set -euo pipefail

# Module: 37_kernel_memory_behavior
# Purpose: 管理一组保守的内核与内存行为参数。
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
  module_banner "37_kernel_memory_behavior" "内核与内存行为参数"
  require_root
  require_debian12

  log warn "This change manages kernel.panic, kernel.panic_on_oops, and vm.swappiness."
  log warn "Risk: reboot behavior and swap behavior are workload-dependent. Review before applying on stateful nodes."

  local content=""
  content="$(cat <<'EOF'
# Managed by VPS bootstrap cautious menu.
# Conservative kernel and VM behavior settings.
kernel.panic = 10
kernel.panic_on_oops = 1
vm.swappiness = 10
EOF
)"

  apply_sysctl_dropin \
    "/etc/sysctl.d/75-vps-cautious-kernel-memory.conf" \
    "${content}" \
    "Applying kernel and memory behavior settings"

  set_state "CAUTIOUS_KERNEL_MEMORY" "managed"
}

main "$@"

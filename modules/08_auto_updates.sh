#!/usr/bin/env bash
set -euo pipefail

# Module: 08_auto_updates
# Purpose: 配置 unattended-upgrades 自动安全更新。
# Preconditions: root；Debian 12。
# Steps:
#   1. 安装 unattended-upgrades 与 apt-listchanges
#   2. 写入 20auto-upgrades
#   3. 启用 unattended-upgrades 服务
# Idempotency:
#   - 采用受控配置文件，重复执行只覆盖本工程管理内容

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

main() {
  load_config
  init_runtime
  module_banner "08_auto_updates" "自动安全更新"
  require_root
  require_debian12

  if is_false "${INSTALL_UNATTENDED_UPGRADES}"; then
    log info "INSTALL_UNATTENDED_UPGRADES=false, skip."
    set_state "AUTO_UPDATES_ENABLED" "no"
    return 0
  fi

  apt_install_packages unattended-upgrades apt-listchanges

  local content
  content="$(cat <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
)"

  apply_managed_file "/etc/apt/apt.conf.d/20auto-upgrades" "0644" "${content}" "true"
  enable_and_start_service "unattended-upgrades"

  set_state "AUTO_UPDATES_ENABLED" "yes"
}

main "$@"

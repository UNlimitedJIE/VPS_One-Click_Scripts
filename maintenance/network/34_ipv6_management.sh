#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/ui.sh
source "${SCRIPT_DIR}/../../lib/ui.sh"

render_ipv6_status_text() {
  cat <<EOF
当前 IPv6 是否启用: $( [[ "$(network_tuning_ipv6_disable_all)" == "0" && "$(network_tuning_ipv6_disable_default)" == "0" ]] && echo "yes" || echo "no" )
当前 sysctl 值:
  net.ipv6.conf.all.disable_ipv6 = $(network_tuning_ipv6_disable_all)
  net.ipv6.conf.default.disable_ipv6 = $(network_tuning_ipv6_disable_default)
  net.ipv6.conf.lo.disable_ipv6 = $(network_tuning_ipv6_disable_lo)
当前状态: $(network_tuning_ipv6_state_label)
EOF
}

disable_ipv6_temporarily() {
  require_root
  require_debian12

  run_cmd "Temporarily disabling IPv6 (all)" sysctl -w net.ipv6.conf.all.disable_ipv6=1
  run_cmd "Temporarily disabling IPv6 (default)" sysctl -w net.ipv6.conf.default.disable_ipv6=1
  run_cmd "Temporarily disabling IPv6 (lo)" sysctl -w net.ipv6.conf.lo.disable_ipv6=1
  log info "IPv6 当前状态: $(network_tuning_ipv6_state_label)"
  set_state "NETWORK_IPV6_MANAGED" "temporary-disabled"
}

disable_ipv6_permanently() {
  local content=""

  require_root
  require_debian12

  content="$(cat <<'EOF'
# Managed by VPS network tuning 3.5.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
)"

  apply_sysctl_dropin "$(network_tuning_ipv6_sysctl_file)" "${content}" "Applying persistent IPv6 disable profile"
  log info "IPv6 当前状态: $(network_tuning_ipv6_state_label)"
  set_state "NETWORK_IPV6_MANAGED" "persistent-disabled"
}

restore_ipv6() {
  require_root
  require_debian12

  remove_file_if_exists "$(network_tuning_ipv6_sysctl_file)"
  run_cmd "Re-enabling IPv6 (all)" sysctl -w net.ipv6.conf.all.disable_ipv6=0
  run_cmd "Re-enabling IPv6 (default)" sysctl -w net.ipv6.conf.default.disable_ipv6=0
  run_cmd "Re-enabling IPv6 (lo)" sysctl -w net.ipv6.conf.lo.disable_ipv6=0
  log info "IPv6 当前状态: $(network_tuning_ipv6_state_label)"
  set_state "NETWORK_IPV6_MANAGED" "restored"
}

main() {
  load_config
  init_runtime

  while true; do
    if ! ui_prompt_input "5. IPv6 管理" $'1. 临时禁用 IPv6\n2. 永久禁用 IPv6\n3. 恢复 IPv6\n4. 查看当前 IPv6 状态\n0. 返回'; then
      return 0
    fi

    case "$(ui_trim_value "${UI_LAST_INPUT}")" in
      0)
        return 0
        ;;
      1)
        ui_confirm_with_back "确认临时禁用 IPv6" "$(render_ipv6_status_text)\n\n即将仅修改运行时 sysctl，不写永久配置。" || continue
        disable_ipv6_temporarily
        ui_wait_for_enter "按回车继续：" || true
        ;;
      2)
        ui_confirm_with_back "确认永久禁用 IPv6" "$(render_ipv6_status_text)\n\n即将写入受控 sysctl 文件。" || continue
        disable_ipv6_permanently
        ui_wait_for_enter "按回车继续：" || true
        ;;
      3)
        ui_confirm_with_back "确认恢复 IPv6" "$(render_ipv6_status_text)\n\n即将移除受控 sysctl 文件并恢复运行时值。" || continue
        restore_ipv6
        ui_wait_for_enter "按回车继续：" || true
        ;;
      4)
        ui_show_plain_and_wait "当前 IPv6 状态" "$(render_ipv6_status_text)" "按回车返回："
        ;;
      *)
        ui_warn_message "输入无效" "只支持输入 1、2、3、4 或 0。"
        ;;
    esac
  done
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "${needle}" "${file}" || fail "${file} does not contain: ${needle}"
}

assert_file_absent() {
  local file="$1"
  [[ ! -e "${file}" ]] || fail "${file} should be removed"
}

assert_repo_has_no_fixed_string() {
  local needle="$1"
  if grep -R --exclude-dir=.git --exclude-dir=.code-review-graph -F -- "${needle}" "${ROOT_DIR}" >/dev/null 2>&1; then
    fail "repository still contains: ${needle}"
  fi
}

assert_bootstrap_run_rejects_unregistered() {
  local module_id="$1"
  local output=""
  local status=0

  set +e
  output="$(bash "${ROOT_DIR}/bootstrap.sh" run "${module_id}" 2>&1)"
  status=$?
  set -e

  [[ "${status}" -ne 0 ]] || fail "bootstrap run should reject unregistered module: ${module_id}"
  grep -Fq -- "is not registered. Refusing to run unregistered module." <<< "${output}" \
    || fail "bootstrap run rejection message missing for: ${module_id}"
}

test_debian13_builtin_bbr3_is_detected() {
  is_debian13() { return 0; }
  network_tuning_kernel_supports_bbr() { return 0; }
  network_tuning_kernel_is_xanmod() { return 1; }

  network_tuning_debian13_bbr3_builtin_available || fail "Debian 13 with bbr should expose built-in BBRv3 availability"
  network_tuning_kernel_supports_bbr3 || fail "Debian 13 built-in BBRv3 should satisfy bbr3 support"
}

test_submenus_advertise_exit_option() {
  assert_file_contains "${ROOT_DIR}/bootstrap.sh" "99. 退出脚本"
  assert_file_contains "${ROOT_DIR}/maintenance/network/31_bbr_landing_optimization.sh" "99. 退出脚本"
  assert_file_contains "${ROOT_DIR}/maintenance/network/32_dns_purification.sh" "99. 退出脚本"
  assert_file_contains "${ROOT_DIR}/maintenance/network/34_ipv6_management.sh" "99. 退出脚本"
  assert_file_contains "${ROOT_DIR}/modules/07_time_sync.sh" "99. 退出脚本"
  assert_file_contains "${ROOT_DIR}/modules/10_swap.sh" "99. 退出脚本"
}

test_debian13_avoids_whiptail_by_default() {
  assert_file_contains "${ROOT_DIR}/lib/ui.sh" "ui_running_on_debian13"
  assert_file_contains "${ROOT_DIR}/lib/ui.sh" "VPS_UI_FORCE_WHIPTAIL"
}

test_debian13_xanmod_module_is_annotated() {
  assert_file_contains "${ROOT_DIR}/maintenance/network/30_xanmod_bbr3.sh" "Debian 13"
  assert_file_contains "${ROOT_DIR}/config/module-registry.tsv" "Debian 13"
}

test_removed_external_script_modules_stay_removed() {
  local removed_init_module="${ROOT_DIR}/modules/00_""node""quality.sh"
  local removed_maint_module="${ROOT_DIR}/maintenance/27_common""_scripts.sh"
  local product_name="Node""Quality"
  local product_lower="node""quality"
  local removed_maint_id="27_common""_scripts"
  local removed_env_a=""
  local removed_env_b=""
  local removed_env_c="COMMON""_SCRIPTS_MENU_MODE"

  removed_env_a="$(printf 'ENABLE_%s' "NODE""QUALITY")"
  removed_env_b="$(printf '%s_FORCE' "NODE""QUALITY")"

  assert_file_absent "${removed_init_module}"
  assert_file_absent "${removed_maint_module}"
  assert_repo_has_no_fixed_string "${product_name}"
  assert_repo_has_no_fixed_string "${product_lower}"
  assert_repo_has_no_fixed_string "${removed_maint_id}"
  assert_repo_has_no_fixed_string "${removed_env_a}"
  assert_repo_has_no_fixed_string "${removed_env_b}"
  assert_repo_has_no_fixed_string "${removed_env_c}"
}

test_bootstrap_run_rejects_removed_modules_by_default() {
  local removed_init_id="00_""node""quality"
  local removed_maint_id="27_common""_scripts"

  assert_bootstrap_run_rejects_unregistered "${removed_init_id}"
  assert_bootstrap_run_rejects_unregistered "${removed_maint_id}"
}

test_port_mutation_menu_stays_removed() {
  local open_ports_fn="nftables_open_ports_by_""proto"
  local close_ports_fn="nftables_close_ports_by_""proto"
  local reload_fn="nftables_reload_and_""validate"
  local port_menu_label="端口""管理"
  local open_label="开放""端口"
  local close_label="关闭""端口"

  assert_repo_has_no_fixed_string "${open_ports_fn}"
  assert_repo_has_no_fixed_string "${close_ports_fn}"
  assert_repo_has_no_fixed_string "${reload_fn}"
  assert_repo_has_no_fixed_string "${port_menu_label}"
  assert_repo_has_no_fixed_string "${open_label}"
  assert_repo_has_no_fixed_string "${close_label}"
}

test_nftables_readonly_port_parser_handles_simple_rules() {
  local ruleset=""
  local tcp_output=""
  local udp_output=""

  ruleset=$'table inet filter {\n  chain input {\n    type filter hook input priority 0; policy drop;\n    ct state established,related accept\n    tcp dport { 22, 80, 443 } accept\n    udp dport 53 accept\n  }\n}'

  tcp_output="$(printf '%s\n' "${ruleset}" \
    | nftables_input_chain_lines_from_stream \
    | nftables_allowed_ports_from_input_chain_by_proto tcp)"
  udp_output="$(printf '%s\n' "${ruleset}" \
    | nftables_input_chain_lines_from_stream \
    | nftables_allowed_ports_from_input_chain_by_proto udp)"

  [[ "${tcp_output}" == $'22\n80\n443' ]] || fail "unexpected parsed tcp ports: ${tcp_output}"
  [[ "${udp_output}" == "53" ]] || fail "unexpected parsed udp ports: ${udp_output}"
}

test_debian13_builtin_bbr3_is_detected
test_submenus_advertise_exit_option
test_debian13_avoids_whiptail_by_default
test_debian13_xanmod_module_is_annotated
test_removed_external_script_modules_stay_removed
test_bootstrap_run_rejects_removed_modules_by_default
test_port_mutation_menu_stays_removed
test_nftables_readonly_port_parser_handles_simple_rules

printf 'shell behavior tests passed\n'

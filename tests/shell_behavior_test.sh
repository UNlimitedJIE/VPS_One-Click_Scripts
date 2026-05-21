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

test_debian13_builtin_bbr3_is_detected
test_submenus_advertise_exit_option
test_debian13_avoids_whiptail_by_default
test_debian13_xanmod_module_is_annotated
test_removed_external_script_modules_stay_removed

printf 'shell behavior tests passed\n'

#!/usr/bin/env bash
set -euo pipefail

# Module: 27_common_scripts
# Purpose: 提供常用测试/测速/回程/安装脚本清单，并在交互模式下直接执行对应脚本。
# Preconditions: 建议在 Debian 12/13 上使用；大多数脚本依赖公网访问。
# Steps:
#   1. 默认输出常用脚本清单，供 show/plan/顺序执行查看
#   2. 维护菜单输入 4 时进入交互子菜单
#   3. 选择具体脚本后立即执行对应命令
# Idempotency:
#   - 清单模式为只读
#   - 交互模式会执行第三方脚本，实际改动取决于所选命令

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/ui.sh
source "${SCRIPT_DIR}/../lib/ui.sh"

common_scripts_workspace() {
  printf '%s\n' "/tmp/vps-common-scripts"
}

common_scripts_catalog_text() {
  cat <<'EOF'
1. 综合测试脚本
   - bench.sh
   - LemonBench
   - 融合怪
   - NodeBench
2. 性能测试
   - yabs
   - 跳过网络，测 GB5
   - 跳过网络和磁盘，测 GB5
   - 改测 GB5，不测 GB6
3. 流媒体及 IP 质量测试
   - 最常用版本
   - 原生检测脚本
   - 准确度最高
   - IP 质量体检脚本
   - 一键修改解锁 DNS
4. 测速脚本
   - Speedtest
   - Taier
   - hyperspeed
   - 全球测速
   - 区域速度测试
   - Ping 和路由测试
5. 回程测试
   - 直接显示回程（小白用这个）
   - 回程详细测试（推荐）
   - testrace
6. 一键安装常用环境及软件
   - docker
   - Python
   - iperf3
   - realm
   - gost
   - 极光面板
   - 哪吒监控
   - WARP
   - Aria2
   - 宝塔
   - PVE 虚拟化
   - Argox
EOF
}

common_scripts_catalog_report() {
  local current=""
  local evidence=""

  current="$(common_scripts_catalog_text)"
  evidence="维护菜单输入 4 时进入交互子菜单；顺序执行时这里只显示清单，不会自动运行任何外部脚本。"
  readonly_status_block "常用脚本检测清单" "${current}" "${evidence}" "yes"
}

show_common_scripts_catalog() {
  local report=""

  report="$(common_scripts_catalog_report)"
  log info "${report}"

  if is_false "${PLAN_ONLY}" && is_false "${DRY_RUN}"; then
    printf '%s\n' "${report}" >"${STATE_DIR}/reports/common-scripts-$(date '+%Y%m%d-%H%M%S').txt"
  fi
}

common_scripts_wrap_command() {
  local raw_command="$1"
  local workspace=""
  local wrapped_command=""

  workspace="$(common_scripts_workspace)"
  printf -v wrapped_command 'mkdir -p %q && cd %q && %s' "${workspace}" "${workspace}" "${raw_command}"
  printf '%s\n' "${wrapped_command}"
}

run_common_script_command() {
  local title="$1"
  local raw_command="$2"
  local wrapped_command=""
  local status=0

  ui_clear_screen || true
  module_banner "27_common_scripts" "${title}"
  log warn "即将执行第三方脚本，请自行确认来源可信。"
  log info "Workspace: $(common_scripts_workspace)"
  log info "Command: ${raw_command}"

  wrapped_command="$(common_scripts_wrap_command "${raw_command}")"

  set +e
  run_shell "Running ${title}" "${wrapped_command}"
  status=$?
  set -e

  if (( status == 0 )); then
    ui_wait_for_enter "脚本执行完成，按回车返回上一层菜单：" || true
    return 0
  fi

  ui_warn_message "执行失败" "${title} 退出码：${status}。"
  ui_wait_for_enter "按回车返回上一层菜单：" || true
  return "${status}"
}

prompt_common_scripts_region() {
  local title="$1"
  local prompt="$2"
  local region=""

  while true; do
    if ! ui_prompt_input "${title}" "${prompt}\n0 = 返回上一步"; then
      return 1
    fi

    region="$(ui_trim_value "${UI_LAST_INPUT}")"
    if [[ "${region}" == "0" ]]; then
      return 1
    fi

    if [[ -z "${region}" ]]; then
      ui_warn_message "输入为空" "请输入地区标识，例如 asia、hk、jp。"
      continue
    fi

    printf '%s\n' "${region}"
    return 0
  done
}

quote_shell_value() {
  local value="${1:-}"
  printf '%q\n' "${value}"
}

menu_common_scripts_benchmark_phase() {
  while true; do
    if ! ui_prompt_input "常用脚本检测 / 综合测试脚本" $'1. bench.sh\n2. LemonBench\n3. 融合怪\n4. NodeBench\n0. 返回上一级菜单'; then
      return 0
    fi

    case "$(ui_trim_value "${UI_LAST_INPUT}")" in
      0)
        return 0
        ;;
      1)
        run_common_script_command "综合测试 - bench.sh" "wget -qO- bench.sh | bash" || true
        ;;
      2)
        run_common_script_command "综合测试 - LemonBench" "wget -qO- https://raw.githubusercontent.com/LemonBench/LemonBench/main/LemonBench.sh | bash -s -- --fast" || true
        ;;
      3)
        run_common_script_command "综合测试 - 融合怪" "bash <(wget -qO- --no-check-certificate https://gitlab.com/spiritysdx/za/-/raw/main/ecs.sh)" || true
        ;;
      4)
        run_common_script_command "综合测试 - NodeBench" "bash <(curl -sL https://raw.githubusercontent.com/LloydAsp/NodeBench/main/NodeBench.sh)" || true
        ;;
      *)
        ui_warn_message "输入无效" "只支持输入 1、2、3、4 或 0。"
        ;;
    esac
  done
}

menu_common_scripts_performance_phase() {
  while true; do
    if ! ui_prompt_input "常用脚本检测 / 性能测试" $'1. yabs\n2. 跳过网络，测 GB5\n3. 跳过网络和磁盘，测 GB5\n4. 改测 GB5，不测 GB6\n0. 返回上一级菜单'; then
      return 0
    fi

    case "$(ui_trim_value "${UI_LAST_INPUT}")" in
      0)
        return 0
        ;;
      1)
        run_common_script_command "性能测试 - yabs" "curl -sL yabs.sh | bash" || true
        ;;
      2)
        run_common_script_command "性能测试 - 跳过网络，测 GB5" "curl -sL yabs.sh | bash -s -- -i5" || true
        ;;
      3)
        run_common_script_command "性能测试 - 跳过网络和磁盘，测 GB5" "curl -sL yabs.sh | bash -s -- -if5" || true
        ;;
      4)
        run_common_script_command "性能测试 - 改测 GB5，不测 GB6" "curl -sL yabs.sh | bash -s -- -5" || true
        ;;
      *)
        ui_warn_message "输入无效" "只支持输入 1、2、3、4 或 0。"
        ;;
    esac
  done
}

menu_common_scripts_media_phase() {
  while true; do
    if ! ui_prompt_input "常用脚本检测 / 流媒体及 IP 质量测试" $'1. 最常用版本\n2. 原生检测脚本\n3. 准确度最高\n4. IP 质量体检脚本\n5. 一键修改解锁 DNS\n0. 返回上一级菜单'; then
      return 0
    fi

    case "$(ui_trim_value "${UI_LAST_INPUT}")" in
      0)
        return 0
        ;;
      1)
        run_common_script_command "流媒体及 IP 质量测试 - 最常用版本" "bash <(curl -L -s check.unlock.media)" || true
        ;;
      2)
        run_common_script_command "流媒体及 IP 质量测试 - 原生检测脚本" "bash <(curl -sL Media.Check.Place)" || true
        ;;
      3)
        run_common_script_command "流媒体及 IP 质量测试 - 准确度最高" "bash <(curl -L -s https://github.com/1-stream/RegionRestrictionCheck/raw/main/check.sh)" || true
        ;;
      4)
        run_common_script_command "流媒体及 IP 质量测试 - IP 质量体检脚本" "bash <(curl -sL IP.Check.Place)" || true
        ;;
      5)
        run_common_script_command "流媒体及 IP 质量测试 - 一键修改解锁 DNS" "wget https://raw.githubusercontent.com/Jimmyzxk/DNS-Alice-Unlock/refs/heads/main/dns-unlock.sh && bash dns-unlock.sh" || true
        ;;
      *)
        ui_warn_message "输入无效" "只支持输入 1、2、3、4、5 或 0。"
        ;;
    esac
  done
}

menu_common_scripts_speed_phase() {
  local region=""
  local quoted_region=""

  while true; do
    if ! ui_prompt_input "常用脚本检测 / 测速脚本" $'1. Speedtest\n2. Taier\n3. hyperspeed\n4. 全球测速\n5. 区域速度测试\n6. Ping 和路由测试\n0. 返回上一级菜单'; then
      return 0
    fi

    case "$(ui_trim_value "${UI_LAST_INPUT}")" in
      0)
        return 0
        ;;
      1)
        run_common_script_command "测速脚本 - Speedtest" "bash <(curl -sL bash.icu/speedtest)" || true
        ;;
      2)
        run_common_script_command "测速脚本 - Taier" "bash <(curl -sL res.yserver.ink/taier.sh)" || true
        ;;
      3)
        run_common_script_command "测速脚本 - hyperspeed" "bash <(curl -Lso- https://bench.im/hyperspeed)" || true
        ;;
      4)
        run_common_script_command "测速脚本 - 全球测速" "wget -qO- nws.sh | bash" || true
        ;;
      5)
        region="$(prompt_common_scripts_region "区域速度测试" "请输入 region_name，例如 asia、jp、hk：" || true)"
        [[ -n "${region}" ]] || continue
        quoted_region="$(quote_shell_value "${region}")"
        run_common_script_command "测速脚本 - 区域速度测试 (${region})" "wget -qO- nws.sh | bash -s -- -r ${quoted_region}" || true
        ;;
      6)
        region="$(prompt_common_scripts_region "Ping 和路由测试" "请输入 region，例如 cn、hk、us：" || true)"
        [[ -n "${region}" ]] || continue
        quoted_region="$(quote_shell_value "${region}")"
        run_common_script_command "测速脚本 - Ping 和路由测试 (${region})" "wget -qO- nws.sh | bash -s -- -rt ${quoted_region}" || true
        ;;
      *)
        ui_warn_message "输入无效" "只支持输入 1、2、3、4、5、6 或 0。"
        ;;
    esac
  done
}

menu_common_scripts_backtrace_phase() {
  while true; do
    if ! ui_prompt_input "常用脚本检测 / 回程测试" $'1. 直接显示回程（小白用这个）\n2. 回程详细测试（推荐）\n3. testrace\n0. 返回上一级菜单'; then
      return 0
    fi

    case "$(ui_trim_value "${UI_LAST_INPUT}")" in
      0)
        return 0
        ;;
      1)
        run_common_script_command "回程测试 - 直接显示回程" "curl https://raw.githubusercontent.com/ludashi2020/backtrace/main/install.sh -sSf | sh" || true
        ;;
      2)
        run_common_script_command "回程测试 - AutoTrace" "wget -N --no-check-certificate https://raw.githubusercontent.com/Chennhaoo/Shell_Bash/master/AutoTrace.sh && chmod +x AutoTrace.sh && bash AutoTrace.sh" || true
        ;;
      3)
        run_common_script_command "回程测试 - testrace" "wget https://ghproxy.com/https://raw.githubusercontent.com/vpsxb/testrace/main/testrace.sh -O testrace.sh && bash testrace.sh" || true
        ;;
      *)
        ui_warn_message "输入无效" "只支持输入 1、2、3 或 0。"
        ;;
    esac
  done
}

menu_common_scripts_install_phase() {
  while true; do
    if ! ui_prompt_input "常用脚本检测 / 一键安装常用环境及软件" $'1. docker\n2. Python\n3. iperf3\n4. realm\n5. gost\n6. 极光面板\n7. 哪吒监控\n8. WARP\n9. Aria2\n10. 宝塔\n11. PVE 虚拟化\n12. Argox\n0. 返回上一级菜单'; then
      return 0
    fi

    case "$(ui_trim_value "${UI_LAST_INPUT}")" in
      0)
        return 0
        ;;
      1)
        run_common_script_command "一键安装常用环境及软件 - docker" "bash <(curl -sL 'https://get.docker.com')" || true
        ;;
      2)
        run_common_script_command "一键安装常用环境及软件 - Python" "curl -O https://raw.githubusercontent.com/lx969788249/lxspacepy/master/pyinstall.sh && chmod +x pyinstall.sh && ./pyinstall.sh" || true
        ;;
      3)
        run_common_script_command "一键安装常用环境及软件 - iperf3" "apt install iperf3" || true
        ;;
      4)
        run_common_script_command "一键安装常用环境及软件 - realm" "bash <(curl -L https://raw.githubusercontent.com/zhouh047/realm-oneclick-install/main/realm.sh) -i" || true
        ;;
      5)
        run_common_script_command "一键安装常用环境及软件 - gost" "wget --no-check-certificate -O gost.sh https://raw.githubusercontent.com/qqrrooty/EZgost/main/gost.sh && chmod +x gost.sh && ./gost.sh" || true
        ;;
      6)
        run_common_script_command "一键安装常用环境及软件 - 极光面板" "bash <(curl -fsSL https://raw.githubusercontent.com/Aurora-Admin-Panel/deploy/main/install.sh)" || true
        ;;
      7)
        run_common_script_command "一键安装常用环境及软件 - 哪吒监控" "curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o nezha.sh && chmod +x nezha.sh && sudo ./nezha.sh" || true
        ;;
      8)
        run_common_script_command "一键安装常用环境及软件 - WARP" "wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh" || true
        ;;
      9)
        run_common_script_command "一键安装常用环境及软件 - Aria2" "wget -N git.io/aria2.sh && chmod +x aria2.sh && ./aria2.sh" || true
        ;;
      10)
        run_common_script_command "一键安装常用环境及软件 - 宝塔" "wget -O install.sh http://v7.hostcli.com/install/install-ubuntu_6.0.sh && sudo bash install.sh" || true
        ;;
      11)
        run_common_script_command "一键安装常用环境及软件 - PVE 虚拟化" "bash <(wget -qO- --no-check-certificate https://raw.githubusercontent.com/oneclickvirt/pve/main/scripts/build_backend.sh)" || true
        ;;
      12)
        run_common_script_command "一键安装常用环境及软件 - Argox" "bash <(wget -qO- https://raw.githubusercontent.com/fscarmen/argox/main/argox.sh)" || true
        ;;
      *)
        ui_warn_message "输入无效" "只支持输入 1 到 12 或 0。"
        ;;
    esac
  done
}

interactive_common_scripts_menu() {
  while true; do
    if ! ui_prompt_input "常用脚本检测" "$(cat <<'EOF'
1. 综合测试脚本
2. 性能测试
3. 流媒体及 IP 质量测试
4. 测速脚本
5. 回程测试
6. 一键安装常用环境及软件
0. 返回上一级菜单

说明：
- 进入具体分类后，输入对应编号会立即执行脚本
- 这些脚本大多会从公网下载内容，请自行确认来源可信
- 下载到本地的临时文件统一放在 /tmp/vps-common-scripts
EOF
)"; then
      return 0
    fi

    case "$(ui_trim_value "${UI_LAST_INPUT}")" in
      0)
        return 0
        ;;
      1)
        menu_common_scripts_benchmark_phase
        ;;
      2)
        menu_common_scripts_performance_phase
        ;;
      3)
        menu_common_scripts_media_phase
        ;;
      4)
        menu_common_scripts_speed_phase
        ;;
      5)
        menu_common_scripts_backtrace_phase
        ;;
      6)
        menu_common_scripts_install_phase
        ;;
      *)
        ui_warn_message "输入无效" "只支持输入 1、2、3、4、5、6 或 0。"
        ;;
    esac
  done
}

main() {
  load_config
  init_runtime

  if [[ "${COMMON_SCRIPTS_MENU_MODE:-catalog}" == "interactive" ]]; then
    interactive_common_scripts_menu
    return 0
  fi

  module_banner "27_common_scripts" "常用脚本检测清单"
  show_common_scripts_catalog
}

main "$@"

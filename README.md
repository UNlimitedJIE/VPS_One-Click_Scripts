# Debian 12 VPS 初始化、维护与网络调优脚本工程

这是一个面向 Debian 12 的模块化 Bash 工程，统一入口为 `bootstrap.sh`，分为三类菜单：

1. 初始化
2. 长期维护
3. 网络调优

当前版本的初始化流程收口为 11 步；原第 12 步 summary 已并入第 11 步验收。  
原长期维护中的 `10.x` 谨慎操作入口已删除，改为根菜单独立的 `3. 网络调优` 子菜单。

## Quick Start

```bash
git clone https://github.com/UNlimitedJIE/VPS_One-Click_Scripts.git
cd VPS_One-Click_Scripts
bash bootstrap.sh show init
bash bootstrap.sh show network
sudo bash bootstrap.sh init
```

## 设计目标

- 统一入口：`bootstrap.sh`
- 模块化：每个功能尽量独立成单脚本
- 可审查：配置、日志、公共函数、模块职责清晰
- 幂等：重复执行尽量只做必要改动
- 安全优先：SSH、防火墙、DNS、内核和网络调优都要求显式确认
- 支持 `show` / `plan` / `menu` / `dry-run`

## 目录结构

```text
project-root/
  README.md
  bootstrap.sh
  config/
    default.conf
    module-registry.tsv
  lib/
    common.sh
    log.sh
    detect.sh
    validate.sh
    ui.sh
  modules/
    00_nodequality.sh
    01_detect_system.sh
    02_update_base.sh
    03_admin_access_stage.sh
    03_admin_user.sh
    04_ssh_keys.sh
    05_ssh_hardening.sh
    06_nftables.sh
    07_switch_admin_login.sh
    07_time_sync.sh
    08_auto_updates.sh
    09_fail2ban.sh
    10_swap.sh
    11_verify.sh
  maintenance/
    20_update_system.sh
    21_audit_users_ssh.sh
    22_audit_firewall.sh
    23_audit_fail2ban_logs.sh
    24_monitor_basic.sh
    25_cleanup.sh
    26_backup_check.sh
    28_change_log.sh
    network/
      30_xanmod_bbr3.sh
      31_bbr_landing_optimization.sh
      32_dns_purification.sh
      33_realm_timeout_fix.sh
      34_ipv6_management.sh
      35_network_tuning_all.sh
      36_network_tuning_status.sh
  roles/
    docker.sh
    web.sh
    proxy.sh
    dev.sh
  state/
  logs/
  docs/
```

## 初始化流程总览

初始化阶段按注册表顺序展示和执行：

1. 运行 NodeQuality 基线检测
2. 检查当前系统和机器基础信息
3. 更新系统并安装基础工具
4. 管理用户接入阶段
5. 关闭 root 远程登录并切换为管理用户登录
6. 启用 nftables 防火墙并只放行必要端口
7. 配置时区和自动时间同步
8. 启用自动安全更新
9. 启用 Fail2Ban 防暴力破解
10. 显式选择并配置 swap
11. 验收第 2 到第 10 步的实际结果

其中第 4 步内部固定拆分为：

1. 确认或输入管理用户名
2. 单独配置 sudo 行为
3. 单独配置本地账户密码
4. 配置并强校验 SSH 公钥安装

## 长期维护主菜单

长期维护主菜单固定为：

1. 定期更新系统软件
2. 审查用户、sudo 和 SSH 密钥
3. 检查防火墙规则与实际服务
4. 检查 Fail2Ban 与登录日志
5. 查看基础资源与服务健康
6. 清理日志和缓存
7. 检查备份与恢复准备情况
8. 记录本次维护状态
9. 顺序执行 1 到 8
0. 返回上一级菜单

说明：

- `1` 到 `8` 对应实际维护模块
- `9` 是快捷模式：确认后按顺序执行 `1` 到 `8`
- 端口管理仍通过长期维护第 `3` 项进入

## 网络调优子菜单

根菜单第 `3` 项为独立的网络调优入口，子菜单固定为：

1. 安装/更新 XanMod 内核 + BBR v3  
2. BBR 直连/落地优化  
3. DNS 净化  
4. Realm 转发 timeout 修复  
5. IPv6 管理  
6. 一键执行 1–5  
7. 查看当前网络调优状态  
0. 返回上一级菜单

说明：

- `1` 检测当前内核、XanMod 状态、BBR 能力，并在需要时安装或更新 XanMod
- `2` 按测速/手动带宽和地区档位计算缓冲区，写入独立 sysctl，并持久化恢复 fq
- `3` 识别当前 DNS 栈并按国外/国内模式配置 DNS，关键步骤失败时自动回滚
- `4` 检测 Realm 后修正 timeout/keepalive 相关项，失败时自动回滚
- `5` 区分临时禁用、永久禁用、恢复和只读查看 IPv6 状态
- `6` 先展示总览，再顺序执行 `1 -> 2 -> 3 -> 4 -> 5`
- `7` 为只读检测入口，只输出当前状态、依据与是否通过

## 常用命令

查看总览：

```bash
bash bootstrap.sh show init
bash bootstrap.sh show maintain
bash bootstrap.sh show network
```

计划预览：

```bash
bash bootstrap.sh plan init
bash bootstrap.sh plan maintain
bash bootstrap.sh plan network
```

交互菜单：

```bash
bash bootstrap.sh menu
bash bootstrap.sh menu init
bash bootstrap.sh menu maintain
bash bootstrap.sh menu network
```

真正执行：

```bash
sudo bash bootstrap.sh init
sudo bash bootstrap.sh maintain
sudo bash bootstrap.sh network
sudo bash bootstrap.sh run 30_xanmod_bbr3
sudo bash bootstrap.sh run 31_bbr_landing_optimization
```

仅模拟输出，不改系统：

```bash
sudo bash bootstrap.sh init --dry-run
sudo bash bootstrap.sh menu network --dry-run
sudo bash bootstrap.sh plan network
```

## 菜单规则

- 根菜单中：`0 = 退出程序`
- 任何子菜单中：`0 = 返回上一级菜单`
- `menu` 模式只负责快速直接执行
- `show` 模式负责详细查看
- `plan` 模式负责预演输出

## 初始化菜单快捷模式

- 初始化菜单支持“从第 2 步顺序执行到指定步骤”的快捷模式
- 在 `bash bootstrap.sh menu init` 中输入 `99`
- 再输入目标步骤号，例如 `7`
- 程序会按顺序执行 `2,3,4,5,6,7`

## 长期维护菜单快捷模式

- 在 `bash bootstrap.sh menu maintain` 中输入 `9`
- 程序会先展示将执行的维护清单
- 只有输入 `yes` 才会继续执行

## 网络调优状态入口

`7` 只做只读检测，不做改动。输出项包括：

- 内核版本 / XanMod / BBR 能力
- BBR 调优实际状态与持久化 fq 状态
- DNS 净化模式 / 上游 DNS / DoT 状态
- Realm timeout 修复状态
- IPv6 当前状态

## 开发与检查

建议至少执行：

```bash
bash -n bootstrap.sh lib/*.sh modules/*.sh maintenance/*.sh maintenance/network/*.sh roles/*.sh
bash bootstrap.sh show init
bash bootstrap.sh show maintain
bash bootstrap.sh show network
```

# VPS_One-Click_Scripts

## 项目简介

这是一个面向 Debian 12/13 的菜单式 Bash 脚本项目，用于 VPS 初始化、日常维护和可选的网络调优。

统一入口是 `bootstrap.sh`。根菜单分为三部分：

- 初始化
- 长期维护
- 网络调优

它不是单一命令的一次性部署器。部分步骤需要交互确认，尤其是管理用户、SSH、公钥、防火墙、root 登录切换和 swap 选择。

## 适用范围

适合：

- 新装或刚接手的 Debian 12/13 VPS
- 需要按步骤完成基础初始化、SSH 接入收敛和长期维护的场景
- 希望通过菜单执行，而不是手写一串系统命令的场景

不适合：

- 非 Debian 12/13 系统
- 完全无人值守的一次性自动化交付场景
- 没有可用控制台、VNC 或云厂商应急入口时直接做 SSH / 防火墙高风险变更

## 功能概览

- 初始化 / 基础更新：NodeQuality 基线检测、系统识别、APT 更新、基础工具安装
- 管理用户接入：创建管理用户、选择 sudo 模式、安装并校验 SSH 公钥
- SSH 加固：按 safe gate 收敛为公钥优先接入，后续再关闭 root 远程登录
- 防火墙：启用 `nftables`，只保留必要端口
- 自动时间同步：设置时区并启用 `systemd-timesyncd`
- 自动更新：安装并配置 `unattended-upgrades`
- Fail2Ban：为 SSH 提供基础暴力破解防护
- Swap：交互选择 `skip / 1G / 2G / 4G / custom`
- 验证 / 审查：初始化验收、用户与 SSH 审查、防火墙与端口检查、Fail2Ban 日志检查、资源健康检查、备份检查、变更记录
- 常用脚本检测：综合测试、性能测试、流媒体/IP 质量、测速、回程、常用环境安装子菜单
- 网络调优子菜单：XanMod + BBR v3、BBR 调优、DNS 净化、Realm timeout 修复、IPv6 管理、状态查看

## 快速开始

克隆项目并进入目录：

```bash
git clone https://github.com/UNlimitedJIE/VPS_One-Click_Scripts.git
cd VPS_One-Click_Scripts
```

安装快捷命令 `j`，然后进入菜单：

```bash
sudo bash bootstrap.sh install-shortcut
j
```

如果不安装快捷命令，也可以直接运行：

```bash
bash bootstrap.sh menu
```

常用入口：

```bash
bash bootstrap.sh show init
bash bootstrap.sh plan init
bash bootstrap.sh preflight
sudo bash bootstrap.sh init
```

说明：

- `menu`：交互菜单，适合日常使用
- `show`：只看模块说明和顺序
- `plan`：预演，不改系统
- `preflight`：在正式执行前检查基础条件

## 初始化流程概览

当前初始化流程固定为 11 步：

1. `00_nodequality`：运行 NodeQuality 基线检测
2. `01_detect_system`：检查当前系统和机器基础信息
3. `02_update_base`：更新系统并安装基础工具
4. `03_admin_access_stage`：管理用户接入阶段
5. `07_switch_admin_login`：关闭 root 远程登录并切换为管理用户登录
6. `06_nftables`：启用 `nftables` 防火墙并只放行必要端口
7. `07_time_sync`：配置时区和自动时间同步
8. `08_auto_updates`：启用自动安全更新
9. `09_fail2ban`：启用 Fail2Ban
10. `10_swap`：显式选择并配置 swap
11. `11_verify`：验收第 2 到第 10 步的实际结果

其中第 4 步内部现在固定为：

1. `4.1` 确认管理用户名
2. `4.2` 配置 sudo 行为
3. `4.3` 配置并验证 SSH 公钥
4. SSH 接入准备

## 推荐使用顺序

建议顺序：

1. 先看 `bash bootstrap.sh show init` 或执行 `bash bootstrap.sh preflight`
2. 再执行 `sudo bash bootstrap.sh init`
3. 第 4 步完成后，先在新窗口验证“管理用户 + SSH 公钥登录”是否真实可用
4. 确认新连接没问题后，再继续第 5 步 root 登录切换和第 6 步防火墙
5. 初始化结束后再看第 11 步验收输出
6. 后续日常巡检再使用 `maintain` 菜单

高风险重点：

- 第 5 步：关闭 root 远程 SSH 登录
- 第 6 步：收紧 `nftables` 入站规则
- SSH 端口改动：只有 `CONFIRM_SSH_PORT_CHANGE=true` 才会真正切换

## 网络调优说明

网络调优是独立子菜单，不属于基础初始化必做项。当前包含：

1. 安装 / 更新 XanMod 内核 + BBR v3
2. BBR 直连 / 落地优化
3. DNS 净化
4. Realm 转发 timeout 修复
5. IPv6 管理
6. 查看当前网络调优状态

说明：

- `1` 安装或更新内核后，通常需要重启才能真正切换到新内核
- `2` 依赖当前内核具备 BBR 能力
- `3`、`4`、`5` 都是可选项，会直接改变网络行为
- `6` 是只读状态查看，不改系统

常用命令：

```bash
bash bootstrap.sh show network
sudo bash bootstrap.sh network
```

## 风险提示

以下操作存在锁死 SSH 的风险：

- SSH 端口变更
- root 远程登录切换
- 防火墙规则收紧
- 公钥未验证就提前关闭密码类登录

建议：

- 保留当前 root 会话，不要先退出
- 先在新窗口验证管理用户登录成功，再继续高风险步骤
- 最好在可用控制台 / VNC / 云厂商应急入口条件下进行 SSH 和防火墙调整

## 项目结构

```text
config/       默认配置与模块注册表
lib/          公共函数、检测、校验、UI
modules/      初始化阶段脚本
maintenance/  长期维护脚本
maintenance/network/  网络调优脚本
roles/        预留角色脚本
scripts/      辅助脚本（如运行残留清理）
logs/         运行日志目录
state/        运行状态、变更记录、报告目录
```

## 配置文件说明

- `config/default.conf`：项目默认配置
- `config/local.conf`：本机覆盖配置，用于覆盖默认值

典型覆盖项包括：

- `TIMEZONE`
- `SSH_PORT`
- `ADMIN_USER`
- `ADMIN_SUDO_MODE_DEFAULT`
- `AUTHORIZED_KEYS_FILE`

说明：

- `local.conf` 适合放主机私有配置
- `local.conf` 已被 `.gitignore` 忽略，不建议提交到仓库

## 开发与维护说明

保留 git 更新能力的原则很简单：

- 保留 `.git/`、源码文件和配置模板
- 不要把 `logs/`、`state/` 这类运行产物提交到仓库
- 不要把机器私有配置写进受版本控制的默认配置里

如果你使用了运行副本同步：

```bash
sudo bash bootstrap.sh sync-runtime-copy
```

项目会把运行副本同步到 `/opt/VPS_One-Click_Scripts`，并刷新 `j` 快捷命令。此后如果实际运行目录已经切到 `/opt/VPS_One-Click_Scripts`，后续 `git pull`、代码修改和排查也建议在该目录进行，避免“更新目录”和“运行目录”分离。

运行残留清理脚本：

```bash
bash scripts/clean_runtime_artifacts.sh
```

它会清空：

- `logs/`
- `state/`
- `.DS_Store`
- `__MACOSX`
- `*.bak`
- `*.tmp`

但不会删除：

- `.git/`
- 源码目录
- README
- 配置模板

## License

本项目使用 [MIT License](LICENSE)。

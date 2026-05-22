# VPS_One-Click_Scripts

## 项目定位

这是一个面向 Debian 12 / Debian 13 的 VPS 初期安全初始化、SSH 收敛、防火墙收敛和系统维护脚本项目。

统一入口是 `bootstrap.sh`。根菜单分为三部分：

- 初始化
- 长期维护
- 网络调优

它不是跑分合集，不是测试合集，不是媒体解锁检测合集，也不是第三方软件一键安装器。

## 适用范围

适合：

- 新装或刚接手的 Debian 12 / Debian 13 VPS
- 需要按步骤完成基础初始化、SSH 接入收敛和长期维护的场景
- 希望通过菜单执行，而不是手写一串系统命令的场景

不适合：

- 非 Debian 12 / Debian 13 系统
- 完全无人值守的一次性自动化交付场景
- 没有可用控制台、VNC 或云厂商应急入口时直接做 SSH / 防火墙高风险变更

## 功能概览

- 系统识别：确认 Debian 版本、内核、资源和基础环境
- APT 更新和基础工具安装：安装后续初始化所需的 Debian 软件包
- 管理用户创建：创建或复用管理用户并配置基础权限
- sudo 行为配置：选择 `nopasswd` 或 `password`
- SSH 公钥配置和验证：写入 `authorized_keys` 并检查可用性
- SSH 收敛：收紧密码登录和 root 远程登录
- nftables 入站收敛：初始化阶段只放行必要 SSH / ICMP / IPv6 ICMP 等基础流量
- 时间同步：设置时区并启用 `systemd-timesyncd`
- unattended-upgrades：启用 Debian 安全更新机制
- Fail2Ban：为 SSH 提供基础暴力破解防护
- Swap：交互选择 `skip / 1G / 2G / 4G / custom`
- 验收 / 审查 / 维护：初始化验收、用户与 SSH 审查、防火墙与端口检查、Fail2Ban 日志、资源健康、备份检查、变更记录、日志与 apt cache 清理
- 可选网络调优：XanMod / Debian 13 内置 BBRv3 开关、BBR 参数、DNS、IPv6、状态查看

## 推荐安装方式

生产环境更建议先克隆、审查，再执行计划和初始化：

```bash
git clone https://github.com/UNlimitedJIE/VPS_One-Click_Scripts.git
cd VPS_One-Click_Scripts
bash bootstrap.sh show init
bash bootstrap.sh plan init
sudo bash bootstrap.sh preflight
sudo bash bootstrap.sh init
```

说明：

- `show init`：查看初始化模块和顺序
- `plan init`：预演初始化步骤，不改系统
- `preflight`：以 root 权限检查正式执行前的基础条件
- `init`：按注册表顺序执行初始化

## 便捷安装方式

便捷方式会下载并执行仓库中的 `install.sh`，它会安装 `git`、拉取或更新项目到 `/opt/VPS_One-Click_Scripts`、安装 `j` 快捷命令并进入菜单。

生产环境注意：

- 更建议固定 tag / release 后再执行
- 直接使用 `main` 分支不可复现
- 执行前应先审查 `install.sh`
- 不应在未知环境中盲目执行远程脚本

示例：

```bash
curl -fsSL https://raw.githubusercontent.com/UNlimitedJIE/VPS_One-Click_Scripts/main/install.sh -o /tmp/vps-install.sh
less /tmp/vps-install.sh
sudo bash /tmp/vps-install.sh
```

`install.sh` 支持指定来源并跳过自动进入菜单：

```bash
sudo bash /tmp/vps-install.sh --branch main --no-launch
sudo bash /tmp/vps-install.sh --version v1.0.0 --no-launch
sudo bash /tmp/vps-install.sh --commit <commit_sha> --no-launch
```

如果系统没有 `curl`，可以先安装：

```bash
sudo apt update
sudo apt install -y curl
```

## 常用入口

```bash
bash bootstrap.sh show init
bash bootstrap.sh plan init
bash bootstrap.sh preflight
sudo bash bootstrap.sh init
bash bootstrap.sh show maintain
bash bootstrap.sh plan maintain
```

说明：

- `menu`：交互菜单，适合日常使用
- 主界面输入 `0` 退出；各子菜单输入 `0` 返回上一级，输入 `99` 直接退出脚本
- Debian 13 默认使用纯终端确认界面，避免 `whiptail` 中文显示乱码；如确需强制使用可设置 `VPS_UI_FORCE_WHIPTAIL=true`
- `show`：只看模块说明和顺序
- `plan`：预演，不改系统
- `preflight`：正式执行前检查基础条件

## 模块执行边界

默认情况下，`bootstrap.sh run` 只允许运行 `config/module-registry.tsv` 中注册过的模块。未注册模块需要显式添加 `--allow-unregistered`，该开关仅用于本地开发或调试；生产环境不建议执行未注册模块。

历史上的第三方检测、评测、线路审查和服务安装合集入口已经移除，初始化与长期维护流程只保留本项目内部的安全初始化和审查能力。

## 初始化流程概览

当前初始化流程固定为 11 步：

1. `01_detect_system`：检查当前系统和机器基础信息
2. `02_update_base`：更新系统并安装基础工具
3. `025_change_ssh_port`：更改 SSH 端口
4. `03_admin_access_stage`：管理用户接入阶段
5. `07_switch_admin_login`：关闭 root 远程登录并切换为管理用户登录
6. `06_nftables`：启用 `nftables` 防火墙并只放行必要端口
7. `07_time_sync`：配置时区和自动时间同步
8. `08_auto_updates`：启用自动安全更新
9. `09_fail2ban`：启用 Fail2Ban
10. `10_swap`：显式选择并配置 swap
11. `11_verify`：验收第 1 到第 10 步的实际结果

其中第 4 步内部固定为：

1. `4.1` 确认管理用户名
2. `4.2` 配置 sudo 行为
3. `4.3` 配置并验证 SSH 公钥
4. SSH 接入准备

## 长期维护菜单

长期维护只保留本项目内部维护能力：

1. 定期更新系统软件
2. 审查用户、sudo 和 SSH 密钥
3. 防火墙与端口审查
4. 检查 Fail2Ban 与登录日志
5. 查看基础资源与服务健康
6. 检查备份与恢复准备情况
7. 清理日志和缓存
8. 记录本次维护状态

维护菜单中的防火墙相关项目只做只读审查，不提供开放、关闭或批量修改端口的交互入口。

## 推荐使用顺序

建议顺序：

1. 先看 `bash bootstrap.sh show init` 或执行 `bash bootstrap.sh preflight`
2. 再执行 `sudo bash bootstrap.sh init`
3. 管理用户接入阶段完成后，先在新窗口验证“管理用户 + SSH 公钥登录”是否真实可用
4. 确认新连接没问题后，再继续 root 登录切换和防火墙收敛
5. 初始化结束后查看验收输出
6. 后续日常巡检再使用 `maintain` 菜单

高风险重点：

- SSH 端口变更
- 关闭 root 远程 SSH 登录
- 收紧 `nftables` 入站规则
- 公钥未验证就提前关闭密码类登录

建议：

- 保留当前 root 会话，不要先退出
- 先在新窗口验证管理用户登录成功，再继续高风险步骤
- 最好在可用控制台 / VNC / 云厂商应急入口条件下进行 SSH 和防火墙调整

## 网络调优说明

网络调优是独立可选菜单，不属于基础初始化必做项。当前包含：

1. XanMod 内核 / Debian 13 BBRv3 开关
2. BBR 直连 / 落地优化
3. DNS 净化
4. IPv6 管理
5. 查看当前网络调优状态

说明：

- `1` 在 Debian 13 且当前内核已支持 `bbr` 时，会标注内置 BBRv3 并默认跳过 XanMod
- 只有手动选择安装 XanMod 时，才会配置 XanMod 官方源并安装内核包；这是可选高风险项
- `2` 依赖当前内核具备 BBR 能力，带宽档位来自网卡链路速率或手动输入，不调用外部测试脚本
- `3`、`4` 都是可选项，会直接改变网络行为
- `5` 是只读状态查看，不改系统

常用命令：

```bash
bash bootstrap.sh show network
sudo bash bootstrap.sh network
```

## nftables 定位

`modules/06_nftables.sh` 用于初始化阶段的安全入站收敛。

它的目标是关闭不必要入站端口，只保留必要 SSH、ICMP、IPv6 ICMP 等基础流量。它不是端口转发脚本，不提供 DNAT、SNAT、MASQUERADE、端口中转或 NAT 转发能力。

## 项目结构

```text
config/       默认配置与模块注册表
lib/          公共函数、检测、校验、UI
modules/      初始化阶段脚本
maintenance/  长期维护脚本
maintenance/network/  网络调优脚本
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

- `local.conf` 适合放主机私有配置，但它会被 Bash `source` 读取，等价于以当前运行身份执行本地配置内容
- 不要加载不可信的 config 文件
- `local.conf` 已被 `.gitignore` 忽略，不建议提交到仓库
- 不要把真实 IP、SSH key、WireGuard key、token、节点配置或其他私密运维配置提交到 GitHub

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

但不会删除：

- `.git/`
- 源码目录
- README
- 配置模板

## License

本项目使用 [MIT License](LICENSE)。

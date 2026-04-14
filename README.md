# Debian 12 VPS 初始化与维护脚本工程

这是一个面向 Debian 12 的模块化 Bash 工程，用于完成两类工作：

1. 新拿到 VPS 时的初始化
2. 后续长期维护与审查

这一版继续保持模块化结构不变，但把菜单层做了两类增强：

- 初始化流程继续按第 1 步到第 13 步展示和执行
- 长期维护菜单重构为固定的 1 到 10 结构
- 第 10 项不再是笼统入口，而是展开为 10.1 到 10.10 的谨慎操作子菜单
- 根菜单与子菜单的 `0` 行为已统一

## Quick Start

```bash
git clone https://github.com/UNlimitedJIE/VPS_One-Click_Scripts.git
cd VPS_One-Click_Scripts
bash bootstrap.sh show init
bash bootstrap.sh plan init
sudo bash bootstrap.sh init

## 设计目标

- 统一入口：`bootstrap.sh`
- 模块化：每个功能尽量独立成单脚本
- 可审查：配置、日志、公共函数、模块职责清晰
- 幂等：重复执行尽量只做必要改动
- 安全优先：尤其是 SSH、防火墙和 sysctl 调优，默认避免把自己锁死
- 支持 `plan` / `dry-run` / `show` / `menu`

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
    03_admin_user.sh
    04_ssh_keys.sh
    05_ssh_hardening.sh
    06_nftables.sh
    07_time_sync.sh
    08_auto_updates.sh
    09_fail2ban.sh
    10_swap.sh
    11_verify.sh
    12_summary.sh
  maintenance/
    20_update_system.sh
    21_audit_users_ssh.sh
    22_audit_firewall.sh
    23_audit_fail2ban_logs.sh
    24_monitor_basic.sh
    25_cleanup.sh
    26_backup_check.sh
    27_tuning_entry.sh
    28_change_log.sh
    cautious/
      30_ssh_usedns_no.sh
      31_ssh_ciphers.sh
      32_icmp_ping_control.sh
      33_forwarding_switches.sh
      34_congestion_queue.sh
      35_tcp_buffers_backlog.sh
      36_tcp_advanced_features.sh
      37_kernel_memory_behavior.sh
      38_status_review.sh
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

初始化阶段会按注册表中的顺序展示并执行：

1. 运行 NodeQuality 基线检测
2. 检查当前系统和机器基础信息
3. 更新系统并安装基础工具
4. 创建日常管理账号并授予 sudo 权限
5. 为管理账号配置 SSH 公钥登录
6. 加固 SSH 登录方式和连接规则
7. 启用 nftables 防火墙并只放行必要端口
8. 配置时区和自动时间同步
9. 启用自动安全更新
10. 启用 Fail2Ban 防暴力破解
11. 根据机器配置决定是否启用 swap
12. 执行初始化结果检查
13. 输出初始化摘要和后续提醒

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
10. 谨慎操作入口
0. 返回上一级菜单

说明：

- `1` 到 `8` 对应实际维护模块
- `9` 是快捷模式：确认后按顺序执行 `1` 到 `8`
- `10` 是谨慎操作子菜单

## 谨慎操作子菜单

进入长期维护第 `10` 项后，会看到这些分点：

10.1 保守型 sysctl / 网络调优入口
10.2 SSH 连接加速：关闭 DNS 反向解析
10.3 SSH 加密算法配置
10.4 ICMP / Ping 控制
10.5 网络转发相关开关
10.6 拥塞控制与队列调优
10.7 TCP 缓冲与连接队列参数
10.8 TCP 高级特性参数
10.9 内核与内存行为参数
10.10 查看谨慎操作说明与当前状态
0. 返回上一级菜单

说明：

- `10.1` 复用当前已有的保守调优逻辑
- `10.2` 到 `10.9` 属于可能修改系统的谨慎项，执行前会再次确认
- `10.10` 为只读检查入口，不修改系统
- SSH 密码登录、root 登录策略、端口等 SSH 基线策略，仍应回到初始化 SSH 模块统一管理

## 常用命令

先修改配置文件：

```bash
vim config/default.conf
```

建议先查看总览：

```bash
bash bootstrap.sh show init
bash bootstrap.sh show maintain
```

再做计划预览：

```bash
bash bootstrap.sh plan init
bash bootstrap.sh plan maintain
```

交互式菜单：

```bash
bash bootstrap.sh menu
bash bootstrap.sh menu init
bash bootstrap.sh menu maintain
```

真正执行：

```bash
sudo bash bootstrap.sh init
sudo bash bootstrap.sh maintain
sudo bash bootstrap.sh run 05_ssh_hardening
sudo bash bootstrap.sh run 27_tuning_entry
```

仅模拟输出，不改系统：

```bash
sudo bash bootstrap.sh init --dry-run
sudo bash bootstrap.sh menu init --dry-run
sudo bash bootstrap.sh menu maintain --dry-run
```

## 菜单规则

- 根菜单中：`0 = 退出程序`
- 任何子菜单中：`0 = 返回上一级菜单`
- 这个规则同时适用于 `whiptail` 分支和纯文本回退菜单
- `menu` 模式只负责快速直接执行
- `show` 模式负责详细查看
- `plan` 模式负责预演输出

补充说明：

- 如果你从根菜单进入 `maintain` 菜单，按 `0` 会回到根菜单
- 如果你在 `maintain` 菜单中进入第 `10` 项，按 `0` 会回到 `maintain` 主菜单
- 只有在根菜单中按 `0`，程序才真正退出

## 初始化菜单快捷模式

- 初始化菜单支持“从第 2 步顺序执行到指定步骤”的快捷模式
- 在 `bash bootstrap.sh menu init` 中输入 `99`，即可进入该模式
- 进入后需要再次输入目标步骤号
- 例如输入 `7`，就会按顺序执行第 `2,3,4,5,6,7` 步
- 输入 `0` 会返回上一级菜单，不执行任何步骤
- 正式执行前，程序会先展示将要顺序执行的步骤列表，并要求再次确认

## 长期维护菜单快捷模式

- 在 `bash bootstrap.sh menu maintain` 中输入 `9`，会进入“顺序执行 1 到 8”的确认界面
- 确认界面会列出这次将要执行的维护清单
- 在该确认界面中输入 `yes` 才会继续执行
- 在该确认界面中输入 `0` 会返回长期维护主菜单

## 谨慎操作说明

这些项目的设计原则是“默认保守，显式确认后再改”：

- `10.1` 只在 `SAFE_TUNING_PROFILE=baseline` 时真正写入保守 sysctl 配置；默认 `none` 不改系统
- `10.2` 设置 `UseDNS no`，可能改善 SSH 登录等待，但不适合依赖反向 DNS 审计或策略的环境
- `10.3` 设置 SSH `Ciphers` 列表，是安全性与兼容性的折中项，可能影响过旧客户端
- `10.4` 禁 ping 不等于真正安全，只是降低可见性，也会影响基于 ping 的监控与排障
- `10.5` 普通单机 VPS 默认不建议乱开网络转发
- `10.6` 到 `10.9` 都属于内核参数调优项，不是“改了就更快”，必须结合负载验证
- `10.10` 是只读检查入口，适合作为执行前的状态审查

## 建议自检

修改后建议先做这些无破坏检查：

```bash
bash -n bootstrap.sh lib/*.sh modules/*.sh maintenance/*.sh maintenance/cautious/*.sh roles/*.sh
bash bootstrap.sh show init
bash bootstrap.sh show maintain
```

当前环境如果没有交互式 TTY，则无法真正进入 `menu` 做手工点选测试；这时至少应完成上面的静态语法检查和 `show` 检查。

## 模块注册表

`config/module-registry.tsv` 是展示层与菜单层的元数据来源，定义了：

- 初始化步骤编号
- 模块 ID
- 所属阶段
- 中文标题
- 中文说明
- 风险级别
- 是否默认勾选
- 依赖关系
- 对应脚本路径

这一版中，注册表除了 `init` 和 `maintain` 外，还增加了 `cautious` 阶段，用来承载长期维护第 `10` 项内部的 10.1 到 10.10 子项元数据。

## 重要安全说明

- `00_nodequality.sh` 会按要求执行固定动作：`bash <(curl -sL https://run.NodeQuality.com)`。
- SSH 加固遵循“安全门”：
  - 先有管理用户
  - 先有有效 `authorized_keys`
  - 通过检测后才允许关闭密码登录
- 当 `SSH_PORT` 不等于 `22` 时，必须显式设置 `CONFIRM_SSH_PORT_CHANGE="true"` 才会真正切换端口。
- 如果未确认非 `22` 端口：
  - 初始化第 `6` 步不会真的把 SSH 切换到新端口
  - 初始化第 `7` 步不会只放行新端口
  - 会明确提示你先确认云防火墙/安全组已同步
- 默认只放行 SSH 端口，不会自动开放 `80/443`
- 不会实现任何重装系统、覆盖磁盘或破坏块设备的逻辑
- 谨慎操作子菜单中的系统修改项，都会在执行前再次确认

## 日志与状态

- 每次入口执行会生成独立日志文件：`logs/<run-id>-<mode>.log`
- 正常执行时状态会写入：`state/runtime.state`
- `plan` / `dry-run` 会使用临时 state 文件，不污染真实 `runtime.state`
- 长期维护的审查报告写入：`state/reports/`
- 变更记录写入：`state/change-log.tsv`

## 后续扩展建议

- 在 `roles/` 中加入角色级功能，例如 `docker`、`web`、`proxy`
- 在 `maintenance/` 或 `maintenance/cautious/` 中继续追加新的可审查脚本
- 需要额外配置时，优先通过 `config/default.conf` 加变量，不要把常量硬编码到模块内部

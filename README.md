# 麒麟 V10 操作系统安全基线自动检测工具

本仓库提供一个 Bash 自动检测脚本，用于对麒麟/Kylin V10 主机执行安全基线核查并生成审计证据。检测项覆盖用户提供的 01-01 到 15-03 检查点，包括系统版本、补丁、终端安全、服务端口、SSH、账号与 sudo、口令策略、登录失败锁定、审计日志、防火墙、文件权限、USB、无线/蓝牙、磁盘加密备份、TPM/Secure Boot/可信组件等。

## 下载后在麒麟主机上手工运行

本工具只提供可下载的脚本代码，不包含 GitHub Actions、定时任务、后台守护进程或任何云端自动执行逻辑。下载仓库或单独下载 `kylin_v10_os_check.sh` 后，把脚本复制到需要检查的麒麟 V10 主机上，由管理员手工执行即可。

```bash
chmod +x kylin_v10_os_check.sh
sudo ./kylin_v10_os_check.sh
```

如需先查看用法而不执行检测：

```bash
./kylin_v10_os_check.sh --help
```

脚本默认在当前目录生成如下目录：

```text
kylin_v10_os_check_<hostname>_<YYYYmmdd_HHMMSS>/
├── evidence/      # 每类检查的原始命令输出
├── report.md      # Markdown 检测报告
├── summary.csv    # CSV 明细
└── summary.jsonl  # JSON Lines 明细
```

也可以指定输出目录，两种写法等价：

```bash
sudo ./kylin_v10_os_check.sh /tmp/kylin_check_result
sudo ./kylin_v10_os_check.sh -o /tmp/kylin_check_result
```

## 输出结果含义

| 结果 | 含义 |
|---|---|
| PASS | 脚本根据本机命令输出自动判定符合要求 |
| FAIL | 脚本根据本机命令输出自动判定不符合要求 |
| WARN | 存在风险或证据不足，但不一定直接违规 |
| MANUAL | 必须结合业务用途、资产台账、管理平台、网络区域、BIOS/UEFI 或其他人工证据确认 |

## 可配置阈值

可以通过环境变量调整部分阈值：

| 环境变量 | 默认值 | 用途 |
|---|---:|---|
| `PATCH_THRESHOLD_DAYS` | 30 | 最近安装/升级记录最大允许天数 |
| `AUDIT_RETENTION_DAYS` | 60 | audit 日志最小保留天数 |
| `PASSWORD_MAX_DAYS` | 30 | 口令最大更换周期 |
| `PASSWORD_MIN_LENGTH` | 10 | 口令最小长度 |
| `SHELL_TIMEOUT_SECONDS` | 600 | 命令行会话自动退出时间 |
| `GUI_LOCK_SECONDS` | 600 | 图形界面锁屏时间 |

示例：

```bash
sudo PATCH_THRESHOLD_DAYS=15 AUDIT_RETENTION_DAYS=90 ./kylin_v10_os_check.sh
```

## 检查项覆盖

脚本当前覆盖以下检查域：

1. 系统信息与时间同步
2. 补丁更新与 apt 软件源
3. 防病毒/EDR/终端安全软件
4. 端口、明文远程服务与服务最小化
5. SSH root 登录、空闲断开与来源 IP 限制人工项
6. UID=0、空口令、sudo 免密与账号实名人工项
7. 口令周期、长度、PAM 复杂度与现有用户周期
8. 登录失败锁定、命令行超时和图形锁屏
9. auditd、audit 规则和审计日志保留
10. 主机防火墙与默认路由
11. `/root`、`/tmp`、无主无组文件、完整性工具和 SUID/SGID 人工项
12. USB 存储和 USBGuard/外设管控
13. Wi-Fi、蓝牙服务和无线/蓝牙硬件人工项
14. LUKS 磁盘加密和备份痕迹
15. TPM、Secure Boot 和 IMA/完整性/麒麟可信组件

## 注意事项

- 本仓库只是生成/保存检测代码；不会替你在云端或当前开发环境自动检查真实麒麟主机。
- 建议使用 `root` 或 `sudo` 运行，否则 `/etc/shadow`、audit、iptables/nft、部分硬件和日志证据可能无法完整采集。
- 脚本以采集和判定为主，不会主动修改系统配置。
- `MANUAL` 项不是脚本缺陷，而是因为对应检查依赖人工台账、管理制度、网络边界、终端管控平台或 BIOS/UEFI 状态。
- 对 `FAIL` 项可参考报告中的“整改建议”列进行加固，整改后重新运行脚本复核。

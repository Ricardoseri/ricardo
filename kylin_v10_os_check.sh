#!/usr/bin/env bash
set -uo pipefail

# Kylin V10 operating system baseline auto-check tool.
# The script is read-mostly: it collects evidence and generates a Markdown report.
# Some checks still require manual validation because the answer depends on asset
# ownership, business purpose, network zoning, or out-of-band controls.

VERSION="1.0.0"
PATCH_THRESHOLD_DAYS="${PATCH_THRESHOLD_DAYS:-30}"
AUDIT_RETENTION_DAYS="${AUDIT_RETENTION_DAYS:-60}"
PASSWORD_MAX_DAYS="${PASSWORD_MAX_DAYS:-30}"
PASSWORD_MIN_LENGTH="${PASSWORD_MIN_LENGTH:-10}"
SHELL_TIMEOUT_SECONDS="${SHELL_TIMEOUT_SECONDS:-600}"
GUI_LOCK_SECONDS="${GUI_LOCK_SECONDS:-600}"

HOSTNAME_SAFE="$(hostname 2>/dev/null | tr -c 'A-Za-z0-9._-' '_' | sed 's/_$//' || echo unknown-host)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DEFAULT_OUT_DIR="./kylin_v10_os_check_${HOSTNAME_SAFE}_${TIMESTAMP}"
OUT_DIR=""
EVIDENCE_DIR=""
REPORT_FILE=""
SUMMARY_CSV=""
SUMMARY_JSONL=""

REPORT_ROWS=()
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
MANUAL_COUNT=0

usage() {
  cat <<'USAGE'
麒麟 V10 操作系统安全基线自动检测工具

用法:
  ./kylin_v10_os_check.sh [输出目录]
  ./kylin_v10_os_check.sh -o /path/to/output

选项:
  -o, --output DIR   指定检测结果输出目录
  -h, --help         显示帮助信息，不执行检测
  -V, --version      显示版本号，不执行检测

说明:
  - 本脚本不会自动在云端或后台运行；只有在麒麟主机上手工执行本文件时才会开始检测。
  - 建议使用 root 或 sudo 执行，以便完整采集 /etc/shadow、audit、nft/iptables 等证据。
USAGE
}

parse_args() {
  OUT_DIR="$DEFAULT_OUT_DIR"
  while (($# > 0)); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -V|--version)
        printf '%s\n' "$VERSION"
        exit 0
        ;;
      -o|--output)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then
          printf '错误：%s 需要指定输出目录。\n' "$1" >&2
          exit 2
        fi
        OUT_DIR="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      -*)
        printf '错误：未知选项 %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
      *)
        if [[ "$OUT_DIR" != "$DEFAULT_OUT_DIR" ]]; then
          printf '错误：只能指定一个输出目录。\n' >&2
          usage >&2
          exit 2
        fi
        OUT_DIR="$1"
        shift
        ;;
    esac
  done
  if (($# > 0)); then
    if [[ "$OUT_DIR" != "$DEFAULT_OUT_DIR" ]]; then
      printf '错误：只能指定一个输出目录。\n' >&2
      usage >&2
      exit 2
    fi
    OUT_DIR="$1"
  fi
}

init_output() {
  EVIDENCE_DIR="${OUT_DIR}/evidence"
  REPORT_FILE="${OUT_DIR}/report.md"
  SUMMARY_CSV="${OUT_DIR}/summary.csv"
  SUMMARY_JSONL="${OUT_DIR}/summary.jsonl"

  mkdir -p "$EVIDENCE_DIR"
  : > "$SUMMARY_CSV"
  : > "$SUMMARY_JSONL"
  printf '编号,检查点,结果,判定依据,证据文件,整改建议\n' > "$SUMMARY_CSV"
}

escape_md() {
  local s="${1//$'\n'/ }"
  s="${s//|/\\|}"
  printf '%s' "$s"
}

escape_csv() {
  local s="${1//$'\n'/ }"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

json_escape() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

run_cmd() {
  local title="$1"; shift
  {
    printf '\n===== %s =====\n' "$title"
    printf '$'
    for arg in "$@"; do printf ' %q' "$arg"; done
    printf '\n'
    "$@" 2>&1
    local rc=$?
    printf '[exit_code=%s]\n' "$rc"
  } >> "$CURRENT_EVIDENCE"
}

append_cmd() {
  local title="$1"; shift
  {
    printf '\n===== %s =====\n' "$title"
    printf '$'
    for arg in "$@"; do printf ' %q' "$arg"; done
    printf '\n'
    "$@" 2>&1
    local rc=$?
    printf '[exit_code=%s]\n' "$rc"
  } >> "$CURRENT_EVIDENCE"
}

append_shell() {
  local title="$1"
  local cmd="$2"
  {
    printf '\n===== %s =====\n' "$title"
    printf '$ %s\n' "$cmd"
    bash -c "$cmd" 2>&1
    local rc=$?
    printf '[exit_code=%s]\n' "$rc"
  } >> "$CURRENT_EVIDENCE"
}

add_result() {
  local id="$1" check="$2" result="$3" basis="$4" evidence="$5" suggestion="$6"
  case "$result" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
    MANUAL) MANUAL_COUNT=$((MANUAL_COUNT + 1)) ;;
  esac
  REPORT_ROWS+=("| $(escape_md "$id") | $(escape_md "$check") | $(escape_md "$result") | $(escape_md "$basis") | $(escape_md "$evidence") | $(escape_md "$suggestion") |")
  {
    escape_csv "$id"; printf ','
    escape_csv "$check"; printf ','
    escape_csv "$result"; printf ','
    escape_csv "$basis"; printf ','
    escape_csv "$evidence"; printf ','
    escape_csv "$suggestion"; printf '\n'
  } >> "$SUMMARY_CSV"
  printf '{"id":"%s","check":"%s","result":"%s","basis":"%s","evidence":"%s","suggestion":"%s"}\n' \
    "$(json_escape "$id")" "$(json_escape "$check")" "$(json_escape "$result")" \
    "$(json_escape "$basis")" "$(json_escape "$evidence")" "$(json_escape "$suggestion")" >> "$SUMMARY_JSONL"
}

set_evidence() {
  CURRENT_EVIDENCE="$EVIDENCE_DIR/$1"
  : > "$CURRENT_EVIDENCE"
  printf '# %s\n生成时间: %s\n主机: %s\n脚本版本: %s\n' "$1" "$(date -Is 2>/dev/null || date)" "$(hostname 2>/dev/null || echo unknown)" "$VERSION" >> "$CURRENT_EVIDENCE"
}

file_ref() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf './%s' "$1" ;;
  esac
}

contains_any_file() {
  local pattern="$1"; shift
  local file
  for file in "$@"; do
    [[ -r "$file" ]] && grep -Eiq "$pattern" "$file" && return 0
  done
  return 1
}

get_listen_ports() {
  if have_cmd ss; then
    ss -lntup 2>/dev/null || ss -lntu 2>/dev/null || true
  elif have_cmd netstat; then
    netstat -lntup 2>/dev/null || netstat -lntu 2>/dev/null || true
  else
    true
  fi
}

is_service_active() {
  local svc="$1"
  have_cmd systemctl && systemctl is-active --quiet "$svc" 2>/dev/null
}

is_service_enabled() {
  local svc="$1"
  have_cmd systemctl && systemctl is-enabled --quiet "$svc" 2>/dev/null
}

service_exists() {
  local svc="$1"
  have_cmd systemctl && systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$svc"
}

collect_01_system_info() {
  set_evidence "01_system_info.txt"
  append_shell "os-release" 'cat /etc/os-release 2>/dev/null || true; cat /etc/.kyinfo 2>/dev/null || true; cat /etc/kylin-release 2>/dev/null || true; lsb_release -a 2>/dev/null || true'
  append_shell "kernel-host-time" 'uname -a; hostname; date -Is 2>/dev/null || date; timedatectl 2>/dev/null || true'
  local os_blob synced
  os_blob="$(cat /etc/os-release /etc/.kyinfo /etc/kylin-release 2>/dev/null | tr '\n' ' ')"
  if printf '%s' "$os_blob" | grep -Eiq 'kylin|麒麟' && printf '%s' "$os_blob" | grep -Eiq 'V10|version_id="?10|release.?10| 10'; then
    add_result "01-01" "操作系统是否为麒麟 V10" "PASS" "检测到麒麟/Kylin 且版本包含 V10/10" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "01-01" "操作系统是否为麒麟 V10" "FAIL" "未检测到明确的麒麟 V10 版本标识" "$(file_ref "$CURRENT_EVIDENCE")" "确认系统版本或补充 /etc/os-release、/etc/.kyinfo 证据"
  fi
  synced="$(timedatectl 2>/dev/null | awk -F: '/System clock synchronized|NTP synchronized/{gsub(/^[ \t]+/,"",$2); print tolower($2); exit}')"
  if [[ "$synced" =~ ^(yes|true)$ ]]; then
    add_result "01-02" "系统时间是否同步" "PASS" "timedatectl 显示系统时间已同步" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "01-02" "系统时间是否同步" "FAIL" "未检测到 timedatectl 时间同步状态为 yes/true" "$(file_ref "$CURRENT_EVIDENCE")" "启用 chrony/ntp/systemd-timesyncd 并确认时间源"
  fi
}

collect_02_patch_update() {
  set_evidence "02_patch_update.txt"
  append_shell "apt-sources" 'find /etc/apt -maxdepth 3 -type f \( -name "*.list" -o -name "*.sources" \) -print -exec sed -n "1,160p" {} \; 2>/dev/null || true'
  append_shell "dpkg-history" 'zgrep -hE "^(Start-Date:|Commandline:|Upgrade:|Install:)" /var/log/apt/history.log* 2>/dev/null | tail -200 || true; zgrep -hE " (install|upgrade) " /var/log/dpkg.log* 2>/dev/null | tail -200 || true'
  local latest epoch now diff_days source_count
  latest="$(zgrep -hE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} (install|upgrade) ' /var/log/dpkg.log* 2>/dev/null | awk '{print $1" "$2}' | sort | tail -1)"
  if [[ -n "$latest" ]] && epoch="$(date -d "$latest" +%s 2>/dev/null)"; then
    now="$(date +%s)"; diff_days=$(( (now - epoch) / 86400 ))
    if (( diff_days <= PATCH_THRESHOLD_DAYS )); then
      add_result "02-01" "补丁更新记录是否在阈值内" "PASS" "最近 dpkg 安装/升级记录为 ${latest}，距今约 ${diff_days} 天" "$(file_ref "$CURRENT_EVIDENCE")" "无"
    else
      add_result "02-01" "补丁更新记录是否在阈值内" "FAIL" "最近 dpkg 安装/升级记录为 ${latest}，距今约 ${diff_days} 天，超过 ${PATCH_THRESHOLD_DAYS} 天" "$(file_ref "$CURRENT_EVIDENCE")" "执行补丁更新或提供集中补丁平台证明"
    fi
  else
    add_result "02-01" "补丁更新记录是否在阈值内" "WARN" "未找到可解析的 dpkg 安装/升级记录" "$(file_ref "$CURRENT_EVIDENCE")" "人工核对补丁平台或离线补丁记录"
  fi
  source_count="$(find /etc/apt -maxdepth 3 -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null | wc -l | awk '{print $1}')"
  if [[ "${source_count:-0}" -gt 0 ]]; then
    add_result "02-02" "是否配置 apt 软件源" "PASS" "检测到 apt 软件源配置文件" "$(file_ref "$CURRENT_EVIDENCE")" "人工确认是否为官方源或单位内部可信源"
  else
    add_result "02-02" "是否配置 apt 软件源" "FAIL" "未检测到 apt 软件源配置文件" "$(file_ref "$CURRENT_EVIDENCE")" "配置官方源或单位内部可信源"
  fi
}

collect_03_antivirus_edr() {
  set_evidence "03_antivirus_edr.txt"
  append_shell "security-software-process-service-package" 'ps -ef | grep -Ei "(360|qax|qianxin|edr|antivirus|clam|avast|sophos|eset|kaspersky|symantec|mcafee|trend|huorong|火绒|天擎|终端安全|北信源|vrv|奇安信)" | grep -v grep || true; systemctl list-units --type=service --all 2>/dev/null | grep -Ei "(360|qax|qianxin|edr|antivirus|clam|avast|sophos|eset|kaspersky|symantec|mcafee|trend|huorong|vrv)" || true; dpkg -l 2>/dev/null | grep -Ei "(360|qax|qianxin|edr|antivirus|clam|avast|sophos|eset|kaspersky|symantec|mcafee|trend|huorong|vrv)" || true'
  local security_hits
  security_hits="$( { ps -ef 2>/dev/null; systemctl list-units --type=service --all 2>/dev/null; dpkg -l 2>/dev/null; } | grep -Ei '(360|qax|qianxin|edr|antivirus|clam|avast|sophos|eset|kaspersky|symantec|mcafee|trend|huorong|火绒|天擎|终端安全|北信源|vrv|奇安信)' | grep -Ev 'grep -Ei|kylin_v10_os_check' || true)"
  if [[ -n "$security_hits" ]]; then
    add_result "03-01" "是否安装并运行防病毒/终端安全软件" "PASS" "发现明确的防病毒/EDR/终端管控软件、服务或日志痕迹" "$(file_ref "$CURRENT_EVIDENCE")" "人工补充病毒库更新时间、策略状态或平台截图"
  else
    add_result "03-01" "是否安装并运行防病毒/终端安全软件" "FAIL" "未发现明确的防病毒/EDR/终端管控软件痕迹" "$(file_ref "$CURRENT_EVIDENCE")" "安装并启用单位认可的终端安全软件"
  fi
}

collect_04_ports_services() {
  set_evidence "04_ports_services.txt"
  append_shell "listening-ports" 'ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null || true'
  append_shell "running-enabled-services" 'systemctl list-units --type=service --state=running --no-pager 2>/dev/null || true; systemctl list-unit-files --type=service --state=enabled --no-pager 2>/dev/null || true'
  local ports
  ports="$(get_listen_ports)"
  if printf '%s\n' "$ports" | grep -Eq ':(23|513|514)\b'; then
    add_result "04-01" "是否存在 Telnet/RSH/Rlogin 等明文远程服务" "FAIL" "检测到 23/513/514 等明文远程服务监听" "$(file_ref "$CURRENT_EVIDENCE")" "关闭 Telnet/RSH/Rlogin，改用受控 SSH/堡垒机"
  else
    add_result "04-01" "是否存在 Telnet/RSH/Rlogin 等明文远程服务" "PASS" "未检测到 Telnet/RSH/Rlogin 明文远程服务" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  fi
  if printf '%s\n' "$ports" | grep -Eq ':(21|111|139|445|2049)\b'; then
    add_result "04-02" "是否开放 FTP/RPC/SMB/NFS 等高风险端口" "FAIL" "检测到 21/111/139/445/2049 监听" "$(file_ref "$CURRENT_EVIDENCE")" "关闭不必要服务或限制访问来源"
  else
    add_result "04-02" "是否开放 FTP/RPC/SMB/NFS 等高风险端口" "PASS" "未检测到 21/111/139/445/2049 监听" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  fi
  add_result "04-03" "运行服务和自启动服务是否最小化" "MANUAL" "服务是否必要需结合主机用途判断" "$(file_ref "$CURRENT_EVIDENCE")" "人工核对 running/enabled 服务清单"
}

collect_05_ssh_security() {
  set_evidence "05_ssh_security.txt"
  append_shell "ssh-status-config" 'systemctl status ssh sshd --no-pager 2>/dev/null || true; ss -lntup 2>/dev/null | grep -E ":22\b" || true; sshd -T 2>/dev/null | sort || true; sed -n "1,240p" /etc/ssh/sshd_config 2>/dev/null || true; find /etc/ssh/sshd_config.d -type f -maxdepth 1 -print -exec sed -n "1,200p" {} \; 2>/dev/null || true'
  local ssh_open permit_root client_alive interval countmax
  ssh_open="$(get_listen_ports | grep -E ':22\b' || true)"
  if [[ -z "$ssh_open" ]]; then
    add_result "05-01" "SSH 是否禁止 root 远程登录" "PASS" "未检测到 SSH 服务开放" "$(file_ref "$CURRENT_EVIDENCE")" "如后续开启 SSH，应禁止 root 远程登录"
    add_result "05-02" "SSH 空闲会话是否自动断开" "PASS" "未检测到 SSH 服务开放" "$(file_ref "$CURRENT_EVIDENCE")" "如后续开启 SSH，应配置空闲断开"
  else
    permit_root="$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2; exit}')"
    if [[ "$permit_root" == "no" || "$permit_root" == "prohibit-password" || "$permit_root" == "forced-commands-only" ]]; then
      add_result "05-01" "SSH 是否禁止 root 远程登录" "PASS" "sshd 有效配置 permitrootlogin=${permit_root}" "$(file_ref "$CURRENT_EVIDENCE")" "无"
    else
      add_result "05-01" "SSH 是否禁止 root 远程登录" "FAIL" "SSH 开放且 permitrootlogin=${permit_root:-未获取}" "$(file_ref "$CURRENT_EVIDENCE")" "设置 PermitRootLogin no 并重载 sshd"
    fi
    interval="$(sshd -T 2>/dev/null | awk '/^clientaliveinterval /{print $2; exit}')"
    countmax="$(sshd -T 2>/dev/null | awk '/^clientalivecountmax /{print $2; exit}')"
    client_alive=$(( ${interval:-0} * ${countmax:-0} ))
    if [[ "${interval:-0}" -gt 0 && "$client_alive" -le "$SHELL_TIMEOUT_SECONDS" ]]; then
      add_result "05-02" "SSH 空闲会话是否自动断开" "PASS" "ClientAliveInterval=${interval}, ClientAliveCountMax=${countmax}, 约 ${client_alive} 秒" "$(file_ref "$CURRENT_EVIDENCE")" "无"
    else
      add_result "05-02" "SSH 空闲会话是否自动断开" "FAIL" "未检测到 SSH 空闲会话在 ${SHELL_TIMEOUT_SECONDS} 秒内自动断开" "$(file_ref "$CURRENT_EVIDENCE")" "配置 ClientAliveInterval/ClientAliveCountMax"
    fi
  fi
  add_result "05-03" "SSH 是否限制指定管理终端 IP 访问" "MANUAL" "仅凭 sshd_config 不能完整判断来源 IP 限制" "$(file_ref "$CURRENT_EVIDENCE")" "人工核对防火墙、堡垒机或准入策略"
}

collect_06_users_sudo() {
  set_evidence "06_users_sudo.txt"
  append_shell "users-shadow-sudo" 'awk -F: "{print}" /etc/passwd 2>/dev/null || true; awk -F: "{print \$1\":\"\$2\":\"\$3\":\"\$4\":\"\$5}" /etc/shadow 2>/dev/null || true; getent group sudo wheel admin 2>/dev/null || true; grep -RIn --exclude="*.dpkg-*" "NOPASSWD\|ALL" /etc/sudoers /etc/sudoers.d 2>/dev/null || true'
  local uid0 empty nopass
  uid0="$(awk -F: '$3==0{print $1}' /etc/passwd 2>/dev/null | paste -sd, -)"
  if [[ "$uid0" == "root" ]]; then
    add_result "06-01" "UID=0 超级权限账号是否仅 root 一个" "PASS" "UID=0 账号数量为 1，账号为 root" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "06-01" "UID=0 超级权限账号是否仅 root 一个" "FAIL" "UID=0 账号为 ${uid0:-未获取}" "$(file_ref "$CURRENT_EVIDENCE")" "保留 root，清理其他 UID=0 账号"
  fi
  empty="$(awk -F: '($2==""){print $1}' /etc/shadow 2>/dev/null | paste -sd, -)"
  if [[ -z "$empty" ]]; then
    add_result "06-02" "是否存在空口令账号" "PASS" "未发现 /etc/shadow 空口令账号" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "06-02" "是否存在空口令账号" "FAIL" "发现空口令账号: $empty" "$(file_ref "$CURRENT_EVIDENCE")" "立即锁定或设置强口令"
  fi
  nopass="$(grep -RIn --exclude='*.dpkg-*' 'NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null || true)"
  if [[ -z "$nopass" ]]; then
    add_result "06-03" "sudo 是否存在免密提权配置" "PASS" "未发现 NOPASSWD 配置" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "06-03" "sudo 是否存在免密提权配置" "FAIL" "发现 NOPASSWD 配置" "$(file_ref "$CURRENT_EVIDENCE")" "移除免密 sudo 或提供审批证明"
  fi
  add_result "06-04" "账号是否实名、是否存在多人共用账号" "MANUAL" "账号实名和共用情况无法仅凭系统命令判断" "$(file_ref "$CURRENT_EVIDENCE")" "人工核对账号台账和人员授权记录"
}

get_login_defs_value() { awk -v key="$1" '$1==key && $0 !~ /^[[:space:]]*#/ {print $2; exit}' /etc/login.defs 2>/dev/null; }
get_pwquality_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 ~ "^[[:space:]]*"key"[[:space:]]*$" {gsub(/[[:space:]]/,"",$2); print $2; exit}' /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf 2>/dev/null
}

collect_07_password_policy() {
  set_evidence "07_password_policy.txt"
  append_shell "password-policy" 'grep -En "^\s*PASS_(MAX|MIN|WARN)_DAYS|^\s*ENCRYPT_METHOD" /etc/login.defs 2>/dev/null || true; grep -RInE "pam_pwquality|pam_cracklib|minlen|minclass|[uld o]credit|dcredit|ocredit|retry" /etc/pam.d /etc/security/pwquality.conf /etc/security/pwquality.conf.d 2>/dev/null || true; chage -l root 2>/dev/null || true; awk -F: "\$3>=1000 && \$1!=\"nobody\" {print \$1\":\"\$5\":max=\"\$5}" /etc/shadow 2>/dev/null || true'
  local max_days minlen has_complexity over_users
  max_days="$(get_login_defs_value PASS_MAX_DAYS)"
  if [[ "$max_days" =~ ^[0-9]+$ && "$max_days" -le "$PASSWORD_MAX_DAYS" ]]; then
    add_result "07-01" "默认口令更换周期是否不超过 30 天" "PASS" "PASS_MAX_DAYS=${max_days}" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "07-01" "默认口令更换周期是否不超过 30 天" "FAIL" "PASS_MAX_DAYS=${max_days:-未配置}" "$(file_ref "$CURRENT_EVIDENCE")" "在 /etc/login.defs 中设置 PASS_MAX_DAYS ${PASSWORD_MAX_DAYS}"
  fi
  minlen="$(get_pwquality_value minlen)"
  if [[ ! "$minlen" =~ ^[0-9]+$ ]]; then
    minlen="$(grep -RhoE 'minlen[ =]+[0-9]+' /etc/pam.d /etc/security/pwquality.conf /etc/security/pwquality.conf.d 2>/dev/null | grep -Eo '[0-9]+' | sort -nr | head -1)"
  fi
  if [[ "$minlen" =~ ^[0-9]+$ && "$minlen" -ge "$PASSWORD_MIN_LENGTH" ]]; then
    add_result "07-02" "口令最小长度是否不少于 10 位" "PASS" "最小长度配置为 ${minlen}" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "07-02" "口令最小长度是否不少于 10 位" "FAIL" "最小长度配置为 ${minlen:-未配置}" "$(file_ref "$CURRENT_EVIDENCE")" "设置 pwquality minlen >= ${PASSWORD_MIN_LENGTH}"
  fi
  if grep -RIEiq 'pam_pwquality|pam_cracklib' /etc/pam.d 2>/dev/null; then
    add_result "07-03" "是否启用 PAM 口令复杂度模块" "PASS" "检测到 pam_pwquality 或 pam_cracklib" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "07-03" "是否启用 PAM 口令复杂度模块" "FAIL" "未检测到 pam_pwquality 或 pam_cracklib" "$(file_ref "$CURRENT_EVIDENCE")" "在 PAM password 栈启用 pam_pwquality"
  fi
  has_complexity="no"
  if grep -RIEq 'minclass[ =]+4' /etc/pam.d /etc/security/pwquality.conf /etc/security/pwquality.conf.d 2>/dev/null; then
    has_complexity="yes"
  elif grep -RIEq 'ucredit[ =]+-1' /etc/pam.d /etc/security/pwquality.conf /etc/security/pwquality.conf.d 2>/dev/null \
    && grep -RIEq 'lcredit[ =]+-1' /etc/pam.d /etc/security/pwquality.conf /etc/security/pwquality.conf.d 2>/dev/null \
    && grep -RIEq 'dcredit[ =]+-1' /etc/pam.d /etc/security/pwquality.conf /etc/security/pwquality.conf.d 2>/dev/null \
    && grep -RIEq 'ocredit[ =]+-1' /etc/pam.d /etc/security/pwquality.conf /etc/security/pwquality.conf.d 2>/dev/null; then
    has_complexity="yes"
  fi
  if [[ "$has_complexity" == "yes" ]]; then
    add_result "07-04" "口令是否要求大小写、数字、特殊字符混合" "PASS" "检测到四类字符复杂度配置" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "07-04" "口令是否要求大小写、数字、特殊字符混合" "FAIL" "未检测到完整的四类字符复杂度配置" "$(file_ref "$CURRENT_EVIDENCE")" "配置 ucredit/lcredit/dcredit/ocredit 或 minclass=4"
  fi
  over_users="$(awk -F: -v max="$PASSWORD_MAX_DAYS" 'NR==FNR {uid[$1]=$3; next} uid[$1]>=1000 && $1!="nobody" && $5!="" && $5>max {print $1":"$5}' /etc/passwd /etc/shadow 2>/dev/null | paste -sd, -)"
  if [[ -z "$over_users" ]]; then
    add_result "07-05" "现有普通用户口令周期是否不超过 30 天" "PASS" "未发现普通用户 shadow 最大周期超过要求" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "07-05" "现有普通用户口令周期是否不超过 30 天" "FAIL" "发现超过 ${PASSWORD_MAX_DAYS} 天的普通用户: ${over_users}" "$(file_ref "$CURRENT_EVIDENCE")" "使用 chage -M ${PASSWORD_MAX_DAYS} 调整现有用户"
  fi
}

collect_08_login_lock_timeout() {
  set_evidence "08_login_lock_timeout.txt"
  append_shell "login-lock-timeout" 'grep -RInE "pam_faillock|pam_tally2|deny=|unlock_time=|fail_interval=" /etc/pam.d 2>/dev/null || true; grep -RInE "(^|[^A-Z_])TMOUT=|readonly TMOUT" /etc/profile /etc/bash.bashrc /etc/profile.d /etc/bashrc 2>/dev/null || true; gsettings get org.gnome.desktop.session idle-delay 2>/dev/null || true; gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null || true; gsettings get org.gnome.desktop.screensaver lock-delay 2>/dev/null || true'
  if grep -RIEq 'pam_faillock|pam_tally2' /etc/pam.d 2>/dev/null; then
    add_result "08-01" "是否配置登录失败次数限制" "PASS" "检测到 pam_faillock 或 pam_tally2" "$(file_ref "$CURRENT_EVIDENCE")" "人工确认 deny/unlock_time 参数符合要求"
  else
    add_result "08-01" "是否配置登录失败次数限制" "FAIL" "未检测到 pam_faillock 或 pam_tally2" "$(file_ref "$CURRENT_EVIDENCE")" "配置登录失败锁定策略"
  fi
  local tmout
  tmout="$(grep -RhoE '(^|[^A-Z_])TMOUT=[0-9]+' /etc/profile /etc/bash.bashrc /etc/profile.d /etc/bashrc 2>/dev/null | grep -Eo '[0-9]+' | sort -n | head -1)"
  if [[ "$tmout" =~ ^[0-9]+$ && "$tmout" -gt 0 && "$tmout" -le "$SHELL_TIMEOUT_SECONDS" ]]; then
    add_result "08-02" "命令行会话是否 600 秒内自动退出" "PASS" "TMOUT=${tmout}" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "08-02" "命令行会话是否 600 秒内自动退出" "FAIL" "TMOUT=${tmout:-未配置}" "$(file_ref "$CURRENT_EVIDENCE")" "配置 TMOUT<=${SHELL_TIMEOUT_SECONDS}"
  fi
  local idle lock
  idle="$(gsettings get org.gnome.desktop.session idle-delay 2>/dev/null | grep -Eo '[0-9]+' | head -1)"
  lock="$(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null | tr -d "'")"
  if [[ "$idle" =~ ^[0-9]+$ && "$idle" -gt 0 && "$idle" -le "$GUI_LOCK_SECONDS" && "$lock" == "true" ]]; then
    add_result "08-03" "图形界面锁屏是否启用且不超过 10 分钟" "PASS" "idle-delay=${idle}，lock-enabled=true" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "08-03" "图形界面锁屏是否启用且不超过 10 分钟" "FAIL" "idle-delay=${idle:-未获取}，lock-enabled=${lock:-未获取}" "$(file_ref "$CURRENT_EVIDENCE")" "启用锁屏并设置 idle-delay<=${GUI_LOCK_SECONDS}"
  fi
}

collect_09_audit_logs() {
  set_evidence "09_audit_logs.txt"
  append_shell "audit-status-rules-logs" 'systemctl is-active auditd 2>/dev/null || true; auditctl -s 2>/dev/null || true; auditctl -l 2>/dev/null || true; find /etc/audit -maxdepth 3 -type f -print -exec sed -n "1,220p" {} \; 2>/dev/null || true; ls -l --time-style=long-iso /var/log/audit 2>/dev/null || true'
  if is_service_active auditd.service || [[ "$(systemctl is-active auditd 2>/dev/null || true)" == "active" ]]; then
    add_result "09-01" "auditd 审计服务是否运行" "PASS" "auditd 为 active" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "09-01" "auditd 审计服务是否运行" "FAIL" "auditd 未处于 active 状态" "$(file_ref "$CURRENT_EVIDENCE")" "启用并启动 auditd"
  fi
  local rule_count earliest now earliest_epoch diff_days
  rule_count="$(auditctl -l 2>/dev/null | sed '/^No rules/d;/^$/d' | wc -l | awk '{print $1}')"
  if [[ "${rule_count:-0}" -gt 0 ]] || find /etc/audit/rules.d -type f -name '*.rules' -size +0c 2>/dev/null | grep -q .; then
    add_result "09-02" "是否配置 audit 审计规则" "PASS" "发现 audit 规则或规则文件" "$(file_ref "$CURRENT_EVIDENCE")" "人工确认覆盖登录、权限变更、关键文件修改等事件"
  else
    add_result "09-02" "是否配置 audit 审计规则" "FAIL" "未发现有效 audit 规则" "$(file_ref "$CURRENT_EVIDENCE")" "配置登录、权限变更、关键文件修改等审计规则"
  fi
  earliest="$(find /var/log/audit -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -1 | awk '{print $1}')"
  if [[ -n "$earliest" ]]; then
    earliest_epoch="${earliest%.*}"; now="$(date +%s)"; diff_days=$(( (now - earliest_epoch) / 86400 ))
    if (( diff_days >= AUDIT_RETENTION_DAYS )); then
      add_result "09-03" "审计日志是否至少保留 60 天" "PASS" "最早 audit 日志距今约 ${diff_days} 天" "$(file_ref "$CURRENT_EVIDENCE")" "无"
    else
      add_result "09-03" "审计日志是否至少保留 60 天" "FAIL" "最早 audit 日志距今约 ${diff_days} 天，不足 ${AUDIT_RETENTION_DAYS} 天" "$(file_ref "$CURRENT_EVIDENCE")" "调整日志轮转策略或提供集中日志平台证明"
    fi
  else
    add_result "09-03" "审计日志是否至少保留 60 天" "FAIL" "未发现 /var/log/audit 审计日志文件" "$(file_ref "$CURRENT_EVIDENCE")" "启用审计日志并配置保留策略"
  fi
}

collect_10_firewall_network() {
  set_evidence "10_firewall_network.txt"
  append_shell "firewall-network" 'systemctl is-active firewalld ufw nftables iptables 2>/dev/null || true; firewall-cmd --state 2>/dev/null || true; ufw status verbose 2>/dev/null || true; nft list ruleset 2>/dev/null || true; iptables -S 2>/dev/null || true; ip route 2>/dev/null || true'
  local nft_rules ipt_rules
  nft_rules="$(nft list ruleset 2>/dev/null | sed '/^$/d' | wc -l | awk '{print $1}')"
  ipt_rules="$(iptables -S 2>/dev/null | grep -Ev '^-P (INPUT|FORWARD|OUTPUT) ACCEPT$' | wc -l | awk '{print $1}')"
  if is_service_active firewalld.service || is_service_active ufw.service || is_service_active nftables.service || [[ "${nft_rules:-0}" -gt 0 || "${ipt_rules:-0}" -gt 0 ]]; then
    add_result "10-01" "主机防火墙/包过滤是否启用" "PASS" "检测到防火墙服务 active 或存在 nft/iptables 规则" "$(file_ref "$CURRENT_EVIDENCE")" "人工确认规则符合最小开放原则"
  else
    add_result "10-01" "主机防火墙/包过滤是否启用" "FAIL" "未检测到有效防火墙服务或 nft/iptables 规则" "$(file_ref "$CURRENT_EVIDENCE")" "启用 firewalld/ufw/nftables"
  fi
  if ip route 2>/dev/null | grep -q '^default '; then
    add_result "10-02" "是否存在默认路由" "WARN" "检测到默认路由，说明主机具备外联路径" "$(file_ref "$CURRENT_EVIDENCE")" "人工确认该路由是否符合网络区域要求"
  else
    add_result "10-02" "是否存在默认路由" "PASS" "未检测到默认路由" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  fi
}

collect_11_file_permission_integrity() {
  set_evidence "11_file_permission_integrity.txt"
  append_shell "file-permission-integrity" 'stat -c "%A %a %U %G %n" /root /tmp 2>/dev/null || true; find / -xdev \( -nouser -o -nogroup \) -print 2>/dev/null | head -200 || true; command -v aide || true; command -v tripwire || true; dpkg -l 2>/dev/null | grep -Ei "^(ii)\s+(aide|tripwire)" || true; find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf "%m %u %g %p\n" 2>/dev/null | sort | head -500 || true'
  local root_perm tmp_perm orphan_count
  root_perm="$(stat -c '%a' /root 2>/dev/null || echo '')"
  if [[ -n "$root_perm" && $(( 8#$root_perm & 077 )) -eq 0 ]]; then
    add_result "11-01" "/root 目录是否禁止普通用户访问" "PASS" "/root 未发现 group/other 权限" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "11-01" "/root 目录是否禁止普通用户访问" "FAIL" "/root 权限为 ${root_perm:-未获取}" "$(file_ref "$CURRENT_EVIDENCE")" "设置 /root 权限为 700 或更严格"
  fi
  tmp_perm="$(stat -c '%a' /tmp 2>/dev/null || echo '')"
  if [[ -n "$tmp_perm" && $(( 8#$tmp_perm & 01000 )) -ne 0 ]]; then
    add_result "11-02" "/tmp 是否设置 sticky bit" "PASS" "/tmp 已设置 sticky bit" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "11-02" "/tmp 是否设置 sticky bit" "FAIL" "/tmp 权限为 ${tmp_perm:-未获取}" "$(file_ref "$CURRENT_EVIDENCE")" "执行 chmod 1777 /tmp"
  fi
  orphan_count="$(find / -xdev \( -nouser -o -nogroup \) -print 2>/dev/null | wc -l | awk '{print $1}')"
  if [[ "${orphan_count:-0}" -eq 0 ]]; then
    add_result "11-03" "是否存在无主/无组文件" "PASS" "当前根文件系统未发现无主/无组文件" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "11-03" "是否存在无主/无组文件" "FAIL" "发现 ${orphan_count} 个无主/无组文件" "$(file_ref "$CURRENT_EVIDENCE")" "核对并修复文件属主属组"
  fi
  if have_cmd aide || have_cmd tripwire || dpkg -l 2>/dev/null | grep -Eiq '^(ii)\s+(aide|tripwire)'; then
    add_result "11-04" "系统文件完整性校验工具是否存在" "PASS" "检测到 AIDE/Tripwire 相关工具" "$(file_ref "$CURRENT_EVIDENCE")" "人工补充完整性校验报告"
  else
    add_result "11-04" "系统文件完整性校验工具是否存在" "FAIL" "未检测到 AIDE/Tripwire 工具" "$(file_ref "$CURRENT_EVIDENCE")" "安装并初始化文件完整性校验工具"
  fi
  add_result "11-05" "SUID/SGID 文件是否均为业务必要" "MANUAL" "SUID/SGID 是否异常需要结合基线判断" "$(file_ref "$CURRENT_EVIDENCE")" "人工核对 SUID/SGID 文件清单"
}

collect_12_usb_control() {
  set_evidence "12_usb_control.txt"
  append_shell "usb-control" 'lsmod 2>/dev/null | grep -E "^usb_storage\b" || true; modprobe -n -v usb-storage 2>/dev/null || true; grep -RInE "usb-storage|usb_storage|install usb-storage /bin/(true|false)|blacklist usb-storage" /etc/modprobe.d /usr/lib/modprobe.d 2>/dev/null || true; systemctl is-active usbguard 2>/dev/null || true; usbguard list-devices 2>/dev/null || true'
  local loaded disabled
  loaded="$(lsmod 2>/dev/null | awk '$1=="usb_storage"{print $1}')"
  disabled="$(grep -RIE 'install usb-storage /bin/(true|false)|blacklist usb-storage|blacklist usb_storage' /etc/modprobe.d /usr/lib/modprobe.d 2>/dev/null || true)"
  if [[ -z "$loaded" && -n "$disabled" ]]; then
    add_result "12-01" "USB 存储是否被禁用" "PASS" "usb_storage 未加载且检测到永久禁用配置" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  elif [[ -z "$loaded" ]]; then
    add_result "12-01" "USB 存储是否被禁用" "WARN" "usb_storage 未加载，但未发现永久禁用配置" "$(file_ref "$CURRENT_EVIDENCE")" "增加 modprobe 禁用配置或使用终端管控"
  else
    add_result "12-01" "USB 存储是否被禁用" "FAIL" "usb_storage 模块已加载" "$(file_ref "$CURRENT_EVIDENCE")" "卸载并永久禁用 usb-storage，或通过终端管控限制"
  fi
  if is_service_active usbguard.service || [[ "$(systemctl is-active usbguard 2>/dev/null || true)" == "active" ]]; then
    add_result "12-02" "是否启用 USBGuard 外设管控" "PASS" "USBGuard 服务 active" "$(file_ref "$CURRENT_EVIDENCE")" "人工确认策略覆盖 USB 存储和外设"
  else
    add_result "12-02" "是否启用 USBGuard 外设管控" "MANUAL" "未检测到 USBGuard 运行，可能使用其他终端管控产品" "$(file_ref "$CURRENT_EVIDENCE")" "人工确认外设管控平台和策略截图"
  fi
}

collect_13_wireless_bluetooth() {
  set_evidence "13_wireless_bluetooth.txt"
  append_shell "wireless-bluetooth" 'nmcli radio all 2>/dev/null || true; rfkill list 2>/dev/null || true; systemctl is-active bluetooth 2>/dev/null || true; bluetoothctl show 2>/dev/null || true; lspci 2>/dev/null | grep -Ei "wireless|wifi|bluetooth|802\.11" || true; lsusb 2>/dev/null | grep -Ei "wireless|wifi|bluetooth|802\.11" || true; ip link 2>/dev/null || true'
  local wifi bluetooth_active hw
  wifi="$(nmcli radio wifi 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  if [[ "$wifi" == "disabled" ]]; then
    add_result "13-01" "Wi-Fi 是否关闭" "PASS" "nmcli radio wifi=disabled" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "13-01" "Wi-Fi 是否关闭" "FAIL" "nmcli radio wifi=${wifi:-未获取/可能启用}" "$(file_ref "$CURRENT_EVIDENCE")" "关闭 Wi-Fi，并按要求 BIOS 禁用或物理拆除"
  fi
  bluetooth_active="$(systemctl is-active bluetooth 2>/dev/null || true)"
  if [[ "$bluetooth_active" == "inactive" || "$bluetooth_active" == "failed" || "$bluetooth_active" == "unknown" || -z "$bluetooth_active" ]]; then
    add_result "13-02" "蓝牙服务是否关闭" "PASS" "bluetooth 服务未 active" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "13-02" "蓝牙服务是否关闭" "FAIL" "bluetooth 服务 ${bluetooth_active}" "$(file_ref "$CURRENT_EVIDENCE")" "关闭并禁用 bluetooth 服务"
  fi
  hw="$( (lspci 2>/dev/null; lsusb 2>/dev/null; ip link 2>/dev/null) | grep -Ei 'wireless|wifi|bluetooth|802\.11|wlan|wl[[:alnum:]]+' || true)"
  if [[ -n "$hw" ]]; then
    add_result "13-03" "是否存在无线/蓝牙硬件" "MANUAL" "系统检测到无线/蓝牙硬件痕迹" "$(file_ref "$CURRENT_EVIDENCE")" "人工确认是否 BIOS 禁用或物理拆除"
  else
    add_result "13-03" "是否存在无线/蓝牙硬件" "PASS" "未检测到明显无线/蓝牙硬件痕迹" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  fi
}

collect_14_disk_encrypt_backup() {
  set_evidence "14_disk_encrypt_backup.txt"
  append_shell "disk-encrypt-backup" 'lsblk -f 2>/dev/null || true; blkid 2>/dev/null || true; dmsetup ls --target crypt 2>/dev/null || true; cryptsetup status --all 2>/dev/null || true; systemctl list-timers --all 2>/dev/null | grep -Ei "backup|rsync|borg|restic|tar|dump" || true; crontab -l 2>/dev/null | grep -Ei "backup|rsync|borg|restic|tar|dump" || true; grep -RInEi "backup|rsync|borg|restic|tar|dump" /etc/cron* /etc/systemd/system 2>/dev/null | head -200 || true; find / -xdev -iname "*backup*" -o -iname "*.bak" 2>/dev/null | head -200 || true'
  if lsblk -f 2>/dev/null | grep -Eiq 'crypto_LUKS|LUKS' || blkid 2>/dev/null | grep -Eiq 'crypto_LUKS|LUKS'; then
    add_result "14-01" "磁盘/分区是否使用 LUKS 加密" "PASS" "检测到 LUKS/crypto_LUKS 分区" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "14-01" "磁盘/分区是否使用 LUKS 加密" "MANUAL" "未检测到 LUKS 加密分区；是否必须加密取决于本机数据性质" "$(file_ref "$CURRENT_EVIDENCE")" "人工确认是否存储敏感数据"
  fi
  local backup_hits
  backup_hits="$( { systemctl list-timers --all 2>/dev/null; crontab -l 2>/dev/null; grep -RInEi 'backup|rsync|borg|restic|tar|dump' /etc/cron* /etc/systemd/system 2>/dev/null | head -200; find / -xdev -iname '*backup*' -o -iname '*.bak' 2>/dev/null | head -200; } | grep -Eiv 'kylin_v10_os_check' || true)"
  if [[ -n "$backup_hits" ]]; then
    add_result "14-02" "是否存在备份任务或备份文件痕迹" "PASS" "发现备份任务或备份文件痕迹" "$(file_ref "$CURRENT_EVIDENCE")" "人工补充备份策略和恢复演练记录"
  else
    add_result "14-02" "是否存在备份任务或备份文件痕迹" "FAIL" "未发现备份任务或备份文件痕迹" "$(file_ref "$CURRENT_EVIDENCE")" "配置定期备份并保存恢复演练记录"
  fi
}

collect_15_trusted_boot() {
  set_evidence "15_trusted_boot.txt"
  append_shell "trusted-boot" 'ls -l /dev/tpm* 2>/dev/null || true; dmesg 2>/dev/null | grep -Ei "tpm|secure boot|ima|integrity|kysec|trusted" | tail -200 || true; mokutil --sb-state 2>/dev/null || true; bootctl status 2>/dev/null || true; grep -RInEi "ima|integrity|kysec|trusted" /etc /sys/kernel/security 2>/dev/null | head -300 || true; lsmod 2>/dev/null | grep -Ei "tpm|trusted|integrity" || true'
  if compgen -G '/dev/tpm*' >/dev/null; then
    add_result "15-01" "是否识别到 TPM 可信模块" "PASS" "检测到 /dev/tpm* 设备" "$(file_ref "$CURRENT_EVIDENCE")" "无"
  else
    add_result "15-01" "是否识别到 TPM 可信模块" "FAIL" "未检测到 TPM 设备" "$(file_ref "$CURRENT_EVIDENCE")" "确认硬件是否支持 TPM，必要时在 BIOS 中开启"
  fi
  if have_cmd mokutil; then
    local sb
    sb="$(mokutil --sb-state 2>/dev/null || true)"
    if printf '%s' "$sb" | grep -Eiq 'enabled'; then
      add_result "15-02" "Secure Boot 是否启用" "PASS" "mokutil 显示 Secure Boot enabled" "$(file_ref "$CURRENT_EVIDENCE")" "无"
    elif printf '%s' "$sb" | grep -Eiq 'disabled'; then
      add_result "15-02" "Secure Boot 是否启用" "FAIL" "mokutil 显示 Secure Boot disabled" "$(file_ref "$CURRENT_EVIDENCE")" "在 BIOS/UEFI 中启用 Secure Boot"
    else
      add_result "15-02" "Secure Boot 是否启用" "MANUAL" "mokutil 未返回明确 Secure Boot 状态" "$(file_ref "$CURRENT_EVIDENCE")" "人工进 BIOS/UEFI 确认"
    fi
  else
    add_result "15-02" "Secure Boot 是否启用" "MANUAL" "系统未安装 mokutil，无法读取 Secure Boot 状态" "$(file_ref "$CURRENT_EVIDENCE")" "人工进 BIOS/UEFI 或安装 mokutil 后确认"
  fi
  if grep -Eiq 'ima|integrity|kysec|trusted' "$CURRENT_EVIDENCE"; then
    add_result "15-03" "是否存在 IMA/完整性/麒麟可信相关组件或日志" "PASS" "检测到 IMA/integrity/kysec/trusted 相关痕迹" "$(file_ref "$CURRENT_EVIDENCE")" "人工确认可信策略是否生效"
  else
    add_result "15-03" "是否存在 IMA/完整性/麒麟可信相关组件或日志" "FAIL" "未检测到 IMA/完整性/麒麟可信相关痕迹" "$(file_ref "$CURRENT_EVIDENCE")" "启用可信计算/完整性度量组件或补充平台证明"
  fi
}

write_report() {
  {
    printf '# 麒麟 V10 操作系统安全基线自动检测报告\n\n'
    printf -- '- 生成时间：%s\n' "$(date -Is 2>/dev/null || date)"
    printf -- '- 主机名：%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf -- '- 脚本版本：%s\n' "$VERSION"
    printf -- '- 输出目录：%s\n' "$OUT_DIR"
    printf -- '- 阈值：补丁 %s 天；审计日志 %s 天；口令周期 %s 天；口令长度 %s；命令行超时 %s 秒；图形锁屏 %s 秒。\n\n' \
      "$PATCH_THRESHOLD_DAYS" "$AUDIT_RETENTION_DAYS" "$PASSWORD_MAX_DAYS" "$PASSWORD_MIN_LENGTH" "$SHELL_TIMEOUT_SECONDS" "$GUI_LOCK_SECONDS"
    printf '## 结果汇总\n\n'
    printf '| PASS | FAIL | WARN | MANUAL |\n|---:|---:|---:|---:|\n| %s | %s | %s | %s |\n\n' "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT" "$MANUAL_COUNT"
    printf '## 检查明细\n\n'
    printf '| 编号 | 检查点 | 结果 | 判定依据 | 证据文件 | 整改建议 |\n'
    printf '|---|---|---|---|---|---|\n'
    printf '%s\n' "${REPORT_ROWS[@]}"
    printf '\n## 说明\n\n'
    printf -- '- PASS/FAIL/WARN 为脚本根据本机命令输出自动判定；MANUAL 表示必须结合业务用途、资产台账、管理平台或 BIOS/UEFI 状态人工确认。\n'
    printf -- '- evidence 目录保存每类检查的原始命令输出，便于复核和审计留痕。\n'
  } > "$REPORT_FILE"
}

main() {
  parse_args "$@"
  init_output
  collect_01_system_info
  collect_02_patch_update
  collect_03_antivirus_edr
  collect_04_ports_services
  collect_05_ssh_security
  collect_06_users_sudo
  collect_07_password_policy
  collect_08_login_lock_timeout
  collect_09_audit_logs
  collect_10_firewall_network
  collect_11_file_permission_integrity
  collect_12_usb_control
  collect_13_wireless_bluetooth
  collect_14_disk_encrypt_backup
  collect_15_trusted_boot
  write_report
  printf '检测完成：%s\n' "$REPORT_FILE"
  printf '汇总 CSV：%s\n' "$SUMMARY_CSV"
  printf '汇总 JSONL：%s\n' "$SUMMARY_JSONL"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

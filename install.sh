#!/usr/bin/env bash
set -euo pipefail

# ================= 配置区 =================
MTG_VERSION=""          # 留空则自动获取最新版；也可手动填写如 "2.3.0"
FAKE_DOMAIN="www.cloudflare.com"
BIND_PORT="443"
# ==========================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "请使用 root 权限运行此脚本"

# ---------- 识别系统与服务管理器 ----------
HAS_SYSTEMD=0
HAS_OPENRC=0
if command -v systemctl >/dev/null 2>&1; then HAS_SYSTEMD=1; fi
if command -v rc-update >/dev/null 2>&1 && [ -d /etc/init.d ]; then HAS_OPENRC=1; fi
if [[ $HAS_SYSTEMD -eq 0 && $HAS_OPENRC -eq 0 ]]; then
    die "未检测到 systemd 或 OpenRC，无法配置开机自启"
fi
log "服务管理器: $( [[ $HAS_SYSTEMD -eq 1 ]] && echo systemd || echo openrc )"

# ---------- 安装基础依赖 ----------
log "检查并安装基础依赖..."
if command -v apt-get >/dev/null; then
    apt-get update -qq && apt-get install -y -qq curl wget tar ca-certificates >/dev/null 2>&1
elif command -v yum >/dev/null; then
    yum install -y -q curl wget tar ca-certificates >/dev/null 2>&1
elif command -v apk >/dev/null; then
    apk add --no-cache curl wget tar ca-certificates >/dev/null 2>&1
else
    warn "未识别包管理器，请确保 curl/wget/tar 已安装"
fi

# ---------- 获取版本号（兼容无 PCRE 的 grep）----------
if [[ -z "$MTG_VERSION" ]]; then
    log "正在查询 mtg 最新版本..."
    MTG_VERSION=$(curl -s --max-time 10 https://api.github.com/repos/9seconds/mtg/releases/latest \
        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n1 || true)
    if [[ -z "$MTG_VERSION" ]]; then
        warn "自动获取版本失败，回退到 v2.3.0"
        MTG_VERSION="2.3.0"
    else
        log "获取到最新版本: v${MTG_VERSION}"
    fi
else
    log "使用指定版本: v${MTG_VERSION}"
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)        MTG_ARCH="amd64" ;;
    aarch64|arm64) MTG_ARCH="arm64" ;;
    *) die "不支持的架构: $ARCH" ;;
esac
log "检测到架构: $ARCH -> mtg-${MTG_VERSION}-linux-${MTG_ARCH}"

TARBALL="mtg-${MTG_VERSION}-linux-${MTG_ARCH}.tar.gz"
URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/${TARBALL}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log "正在下载 mtg v${MTG_VERSION}..."
wget -q -O "${TMPDIR}/${TARBALL}" "$URL" || die "下载失败，请检查网络或版本号"

log "安装 mtg 二进制文件..."
tar -xzf "${TMPDIR}/${TARBALL}" -C "$TMPDIR"

MTG_BIN="${TMPDIR}/mtg-${MTG_VERSION}-linux-${MTG_ARCH}/mtg"
if [ ! -f "$MTG_BIN" ]; then
    MTG_BIN=$(find "$TMPDIR" -type f -name "mtg" | head -n 1)
    [ -z "$MTG_BIN" ] && die "解压后依然找不到 mtg 二进制文件"
fi

install -m 755 "$MTG_BIN" /usr/local/bin/mtg
log "mtg 已安装: $(/usr/local/bin/mtg --version | head -n1)"

log "生成 FakeTLS 密钥 (伪装域名: ${FAKE_DOMAIN})..."
SECRET=$(/usr/local/bin/mtg generate-secret --hex "$FAKE_DOMAIN")
[[ "$SECRET" == ee* ]] || die "密钥生成异常"
log "密钥生成成功: ${SECRET}"

log "生成配置文件 /etc/mtg.toml ..."
cat > /etc/mtg.toml <<EOF
secret = "${SECRET}"
bind-to = "0.0.0.0:${BIND_PORT}"
EOF
chmod 600 /etc/mtg.toml

# ---------- 配置服务 ----------
if [[ $HAS_SYSTEMD -eq 1 ]]; then
    log "配置 systemd 服务..."
    cat > /etc/systemd/system/mtg.service <<EOF
[Unit]
Description=mtg MTProto proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mtg run /etc/mtg.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mtg >/dev/null 2>&1
    systemctl restart mtg
else
    log "配置 OpenRC 服务 (Alpine)..."
    cat > /etc/init.d/mtg <<'EOF'
#!/sbin/openrc-run
description="mtg MTProto proxy"
command="/usr/local/bin/mtg"
command_args="run /etc/mtg.toml"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/mtg.log"
error_log="/var/log/mtg.log"
respawn_delay=3

depend() {
    need net
    after firewall
}
EOF
    chmod 755 /etc/init.d/mtg
    rc-update add mtg default >/dev/null 2>&1 || true
    rc-service mtg restart >/dev/null 2>&1 || rc-service mtg start
fi

sleep 2

# ---------- 健康检查 ----------
RUNNING=0
if [[ $HAS_SYSTEMD -eq 1 ]]; then
    systemctl is-active --quiet mtg && RUNNING=1
else
    rc-service mtg status >/dev/null 2>&1 && RUNNING=1
fi

if [[ $RUNNING -eq 1 ]]; then
    log "mtg 服务已成功启动！"
else
    if [[ $HAS_SYSTEMD -eq 1 ]]; then
        journalctl -u mtg -n 10 --no-pager
    else
        tail -n 10 /var/log/mtg.log 2>/dev/null || true
    fi
    die "mtg 启动失败，请查看上面的日志"
fi

# ---------- 输出连接信息 ----------
log "正在获取公网 IP..."
IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || curl -4 -s --max-time 5 icanhazip.com 2>/dev/null || echo "YOUR_VPS_IP")

echo -e "\n${GREEN}================= 搭建完成 =================${NC}"
echo -e "服务器 IP : ${IP}"
echo -e "端口      : ${BIND_PORT}"
echo -e "密钥      : ${SECRET}"
echo -e "\n${YELLOW}Telegram 快捷连接链接:${NC}"
echo -e "tg://proxy?server=${IP}&port=${BIND_PORT}&secret=${SECRET}"
echo -e "${GREEN}============================================${NC}"
warn "如果无法连接，请务必检查云服务商的安全组/防火墙是否放行了 TCP ${BIND_PORT} 端口！"

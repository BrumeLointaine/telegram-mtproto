#!/usr/bin/env bash
set -euo pipefail

# ================= 配置区 =================
MTG_VERSION="2.3.0"
FAKE_DOMAIN="mt.0m.de5.net"
BIND_PORT="443"
# ==========================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "请使用 root 权限运行此脚本"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  MTG_ARCH="amd64" ;;
    aarch64|arm64) MTG_ARCH="arm64" ;;
    *) die "不支持的架构: $ARCH" ;;
esac
log "检测到架构: $ARCH -> mtg-${MTG_VERSION}-linux-${MTG_ARCH}"

log "检查并安装基础依赖..."
if command -v apt-get >/dev/null; then
    apt-get update -qq && apt-get install -y -qq curl wget tar >/dev/null 2>&1
elif command -v yum >/dev/null; then
    yum install -y -q curl wget tar >/dev/null 2>&1
fi

TARBALL="mtg-${MTG_VERSION}-linux-${MTG_ARCH}.tar.gz"
URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/${TARBALL}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log "正在下载 mtg v${MTG_VERSION}..."
wget -q -O "${TMPDIR}/${TARBALL}" "$URL" || die "下载失败，请检查网络或版本号"

log "安装 mtg 二进制文件..."
tar -xzf "${TMPDIR}/${TARBALL}" -C "$TMPDIR"

# 写死官方压缩包内的准确路径
MTG_BIN="${TMPDIR}/mtg-${MTG_VERSION}-linux-${MTG_ARCH}/mtg"
if [ ! -f "$MTG_BIN" ]; then
    # 万一官方未来又改了外层目录名，再用 find 兜底一次
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
sleep 2

if systemctl is-active --quiet mtg; then
    log "mtg 服务已成功启动！"
else
    journalctl -u mtg -n 10 --no-pager
    die "mtg 启动失败，请查看上面的日志"
fi

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

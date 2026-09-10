#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
#  一键部署脚本: HAProxy + ocserv (OpenConnect VPN) + Nginx
#  目标系统: Rocky Linux 8 minimal (同样适用 RHEL / CentOS / Alma / Oracle 8)
#  版本: 1.0.0
#
#  架构:
#
#    客户端 --TCP/443(带SNI)--> HAProxy --+-- SNI = vpn.domain --> ocserv 127.0.0.1:4443 (TLS, 自签名证书, 仅TCP)
#                                        +-- 其它 / 无 SNI ----> nginx  127.0.0.1:8443 (TLS)
#    客户端 --TCP/80--------> HAProxy ------- 301 跳转到 https
#
#  设计说明:
#    * HAProxy 工作在 mode tcp, 只读取 TLS ClientHello 中的 SNI 做四层透传(不解密),
#      因此 HAProxy 上不需要安装任何证书。
#    * ocserv / nginx 各自终结 TLS, 证书由脚本自动创建的本地 CA(自签名体系)签发;
#      客户端信任 ca.crt 即可, 也可以用 openconnect 的 --servercert pin-sha256:... 方式。
#    * ocserv 强制关闭 UDP/DTLS: 配置 udp-port = 0, 防火墙不放行任何 UDP 端口;
#      脚本启动后还会实际检查是否有 UDP 监听。
#    * HAProxy 用 PROXY protocol v2 把真实客户端 IP 透传给 ocserv / nginx,
#      否则后端只能看到 127.0.0.1 (影响 ocserv 的封禁策略与日志)。
#    * 幂等: 可重复执行, 旧配置自动备份为 *.bak.<时间戳>。
#
#  用法:
#    ./deploy-haproxy-ocserv-nginx.sh --vpn-domain vpn.test.com --web-domain www.test.com
#    ./deploy-haproxy-ocserv-nginx.sh -h
#===============================================================================

set -Eeuo pipefail

VERSION="1.0.0"

#-------------------------------------------------------------------------------
# 默认参数 (均可用命令行参数覆盖)
#-------------------------------------------------------------------------------
VPN_DOMAIN="vpn.example.com"        # VPN(ocserv) 域名, 客户端必须用它连接
WEB_DOMAIN="www.example.com"        # 网站(nginx) 域名
SERVER_IP=""                        # 本机对外 IP, 留空自动探测
OCSERV_PORT="4443"                  # ocserv 监听端口 (仅 127.0.0.1)
NGINX_PORT="8443"                   # nginx  监听端口 (仅 127.0.0.1)

VPN_NETWORK="10.10.10.0"            # VPN 客户端地址池
VPN_NETMASK="255.255.255.0"
VPN_DNS1="8.8.8.8"                  # 推送给客户端的 DNS
VPN_DNS2="1.1.1.1"

VPN_USER="vpnuser"                  # 初始 VPN 账号
VPN_PASSWORD=""                     # 留空 = 自动生成随机密码
WITH_USER_CERT=0                    # 1=额外签发客户端证书并在 ocserv 启用证书认证
NO_ROUTE=""                         # 不下发到隧道的网段, 例如 192.168.0.0/16
FULL_TUNNEL=1                       # 1=所有流量走 VPN  0=只有 VPN 网段走隧道
SETUP_FIREWALL=1                    # 1=自动配置 firewalld
SELINUX_PERMISSIVE=0                # 1=把 SELinux 永久设为 permissive (排错用)
CA_DAYS=3650
CERT_DAYS=3650
ORG="Self-Signed VPN"

OCSERV_PROXY=1                      # 1=ocserv 启用 listen-proxy-proto
VPN_PASSWORD_AUTO=0
USER_CERT_READY=0
SERVER_PIN=""

#-------------------------------------------------------------------------------
# 固定路径
#-------------------------------------------------------------------------------
OCSERV_CONF="/etc/ocserv/ocserv.conf"
OCSERV_PASSWD="/etc/ocserv/ocpasswd"
OCSERV_PKI_PUB="/etc/pki/ocserv/public"     # EL8 软件包默认的证书目录
OCSERV_PKI_PRIV="/etc/pki/ocserv/private"
OCSERV_CERT="${OCSERV_PKI_PUB}/server.crt"
OCSERV_KEY="${OCSERV_PKI_PRIV}/server.key"
OCSERV_CA="/etc/ocserv/ca.pem"
NGINX_CONF="/etc/nginx/nginx.conf"
NGINX_SITE="/etc/nginx/conf.d/vpn-web.conf"
NGINX_SSL_DIR="/etc/nginx/ssl"
HAPROXY_CONF="/etc/haproxy/haproxy.cfg"
RSYSLOG_CONF="/etc/rsyslog.d/haproxy.conf"
WEB_ROOT="/usr/share/nginx/html"            # EL8 nginx 默认站点目录
CA_KEY_DIR="/root/pki"
INFO_FILE="/root/vpn-deploy-info.txt"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMPDIR_WORK=""

#-------------------------------------------------------------------------------
# 日志 / 错误处理
#-------------------------------------------------------------------------------
msg()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() { if [ -n "${TMPDIR_WORK}" ]; then rm -rf "$TMPDIR_WORK"; fi; return 0; }
on_err()  { die "脚本在第 $1 行执行失败, 部署中断(已完成的步骤不会回滚)"; }
trap cleanup EXIT
trap 'on_err $LINENO' ERR

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

域名与地址:
  --vpn-domain <域名>     VPN 域名 (默认 ${VPN_DOMAIN})
  --web-domain <域名>     网站域名 (默认 ${WEB_DOMAIN})
  --server-ip <IP>        本机对外 IP, 留空自动探测

端口:
  --ocserv-port <端口>    ocserv 后端端口, 仅监听 127.0.0.1 (默认 ${OCSERV_PORT})
  --nginx-port <端口>     nginx  后端端口, 仅监听 127.0.0.1 (默认 ${NGINX_PORT})

VPN 账号与网络:
  --user <用户名>         VPN 用户名 (默认 ${VPN_USER})
  --password <密码>       VPN 密码, 不填则自动生成随机密码
  --vpn-net <网段>        VPN 客户端网段 (默认 ${VPN_NETWORK})
  --vpn-mask <掩码>       子网掩码 (默认 ${VPN_NETMASK})
  --dns <DNS1[,DNS2]>     下发给客户端的 DNS (默认 ${VPN_DNS1},${VPN_DNS2})
  --split-tunnel          仅 VPN 网段走隧道 (默认全局路由)
  --no-route <网段>       不下发到隧道的网段, 例如 192.168.0.0/16
  --user-cert             额外签发客户端证书 user.p12 (放到站点根目录供下载),
                          并在 ocserv 上同时启用证书认证 (证书或密码都能登录)

其它:
  --no-firewall           不改动 firewalld
  --selinux-permissive    将 SELinux 永久设为 permissive (排错用, 不推荐生产)
  -h, --help              显示帮助
  -V, --version           显示版本

示例:
  $(basename "$0") --vpn-domain vpn.test.com --web-domain www.test.com \\
      --user tom --password 'Passw0rd!x' --dns 223.5.5.5,114.114.114.114
EOF
}

#-------------------------------------------------------------------------------
# 参数解析
#-------------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --vpn-domain)         VPN_DOMAIN="${2:?缺少参数值}"; shift 2 ;;
            --web-domain)         WEB_DOMAIN="${2:?缺少参数值}"; shift 2 ;;
            --server-ip)          SERVER_IP="${2:?缺少参数值}"; shift 2 ;;
            --ocserv-port)        OCSERV_PORT="${2:?缺少参数值}"; shift 2 ;;
            --nginx-port)         NGINX_PORT="${2:?缺少参数值}"; shift 2 ;;
            --user)               VPN_USER="${2:?缺少参数值}"; shift 2 ;;
            --password)           VPN_PASSWORD="${2:?缺少参数值}"; shift 2 ;;
            --vpn-net)            VPN_NETWORK="${2:?缺少参数值}"; shift 2 ;;
            --vpn-mask)           VPN_NETMASK="${2:?缺少参数值}"; shift 2 ;;
            --dns)
                VPN_DNS1="${2%%,*}"
                if [ "${2}" != "${2#*,}" ]; then
                    VPN_DNS2="${2#*,}"
                fi
                shift 2 ;;
            --split-tunnel)       FULL_TUNNEL=0; shift ;;
            --no-route)           NO_ROUTE="${2:?缺少参数值}"; shift ;;
            --user-cert)          WITH_USER_CERT=1; shift ;;
            --no-firewall)        SETUP_FIREWALL=0; shift ;;
            --selinux-permissive) SELINUX_PERMISSIVE=1; shift ;;
            -h|--help)            usage; exit 0 ;;
            -V|--version)         echo "$(basename "$0") ${VERSION}"; exit 0 ;;
            *)                    usage; die "未知参数: $1" ;;
        esac
    done

    case "${OCSERV_PORT}${NGINX_PORT}" in
        *[!0-9]*) die "端口必须是纯数字" ;;
    esac
    if [ "$OCSERV_PORT" -eq "$NGINX_PORT" ]; then
        die "ocserv 与 nginx 的后端端口不能相同"
    fi
}

#-------------------------------------------------------------------------------
# 0. 环境检查
#-------------------------------------------------------------------------------
preflight() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行 (sudo -i 后再执行)"
    [ -r /etc/os-release ] || die "无法读取 /etc/os-release, 系统不受支持"

    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-unknown}" in
        rocky|rhel|centos|almalinux|oracle) ;;
        *) warn "当前系统为 ${ID:-unknown} ${VERSION_ID:-}, 脚本按 Rocky Linux 8 编写" ;;
    esac
    if [ "${VERSION_ID%%.*}" != "8" ]; then
        warn "当前版本为 ${VERSION_ID:-未知}, 脚本针对 EL8 系列验证"
    fi

    command -v dnf >/dev/null 2>&1 || die "未找到 dnf, 本脚本仅支持 EL8 系列"

    if [ "$OCSERV_PORT" = "443" ] || [ "$NGINX_PORT" = "443" ]; then
        die "后端端口不能使用 443 (443 由 HAProxy 占用)"
    fi

    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    fi
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="127.0.0.1"
        warn "未能自动探测本机 IP, 使用 127.0.0.1, 请用 --server-ip 指定"
    fi

    TMPDIR_WORK="$(mktemp -d /tmp/vpn-deploy.XXXXXX)"

    info "VPN 域名   : ${VPN_DOMAIN}"
    info "网站域名   : ${WEB_DOMAIN}"
    info "本机 IP    : ${SERVER_IP}"
    info "后端监听   : ocserv=127.0.0.1:${OCSERV_PORT}  nginx=127.0.0.1:${NGINX_PORT}"
    info "UDP        : 全部禁用 (ocserv 只用 TCP)"
    info "隧道模式   : $([ "$FULL_TUNNEL" -eq 1 ] && echo '全局路由(所有流量走 VPN)' || echo '分离隧道(仅 VPN 网段)')"
}

#-------------------------------------------------------------------------------
# 1. 安装软件包
#-------------------------------------------------------------------------------
install_packages() {
    info "安装软件包 (haproxy / nginx / ocserv / firewalld ...) ..."

    if ! rpm -q epel-release >/dev/null 2>&1; then
        dnf -y install epel-release >/dev/null 2>&1 \
            || dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm >/dev/null 2>&1 \
            || warn "EPEL 源安装失败; 若 ocserv 装不上请手动配置 EPEL"
    fi
    dnf -y makecache >/dev/null 2>&1 || true

    # 有 1.20 模块流就用它, 没有则用默认流
    dnf -y module enable nginx:1.20 >/dev/null 2>&1 || true

    if ! dnf -y install haproxy nginx ocserv openssl firewalld rsyslog \
            policycoreutils-python-utils iproute util-linux >/dev/null 2>&1; then
        warn "首次安装失败, 去掉可选包重试 ..."
        dnf -y install haproxy nginx ocserv openssl firewalld rsyslog iproute util-linux \
            || die "软件包安装失败, 请自行执行: dnf install haproxy nginx ocserv"
    fi

    rpm -q haproxy nginx ocserv 2>/dev/null | sed 's/^/    /' || true
    command -v ocserv  >/dev/null 2>&1 || die "ocserv 未安装成功, 请确认 EPEL 源可用"
    command -v ocpasswd >/dev/null 2>&1 || die "ocpasswd 未找到, ocserv 安装异常"

    # 兜底: 确保运行账号存在
    if ! id ocserv >/dev/null 2>&1; then
        warn "系统缺少 ocserv 用户, 自动创建"
        groupadd -r ocserv >/dev/null 2>&1 || true
        useradd -r -g ocserv -s /sbin/nologin -d / -M ocserv >/dev/null 2>&1 || true
    fi
    if ! id nginx >/dev/null 2>&1; then
        warn "系统缺少 nginx 用户, 自动创建"
        useradd -r -s /sbin/nologin -d /var/lib/nginx -M nginx >/dev/null 2>&1 || true
    fi
}

#-------------------------------------------------------------------------------
# 2. 内核转发
#-------------------------------------------------------------------------------
config_kernel() {
    info "开启 IPv4 转发 (VPN 客户端上网必需) ..."
    cat > /etc/sysctl.d/99-ocserv-forward.conf <<'EOF'
# 由 deploy-haproxy-ocserv-nginx.sh 添加
net.ipv4.ip_forward = 1
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-ocserv-forward.conf >/dev/null 2>&1 || true
    info "当前 net.ipv4.ip_forward = $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 未知)"
}

#-------------------------------------------------------------------------------
# 3. 自签名证书 (本地 CA + 服务器证书, SAN 同时包含两个域名)
#-------------------------------------------------------------------------------
openssl_run() { # 只在失败时输出 openssl 的报错
    local log="${TMPDIR_WORK}/openssl.log"
    : > "$log"
    if ! "$@" >"$log" 2>&1; then
        cat "$log" >&2
        die "openssl 执行失败: $1 $2"
    fi
}

gen_certs() {
    info "生成自签名 CA 与服务器证书 (CN=${VPN_DOMAIN}; SAN: ${VPN_DOMAIN} / ${WEB_DOMAIN} / ${SERVER_IP}) ..."

    local work="${TMPDIR_WORK}/pki"
    mkdir -p "$work"

    cat > "$work/ca.cnf" <<EOF
[ req ]
default_bits       = 4096
prompt             = no
distinguished_name = dn
x509_extensions    = v3_ca

[ dn ]
C  = CN
O  = ${ORG}
CN = ${ORG} Root CA

[ v3_ca ]
basicConstraints     = critical, CA:true
keyUsage             = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

    openssl_run openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days "$CA_DAYS" \
        -keyout "$work/ca.key" -out "$work/ca.crt" -config "$work/ca.cnf"

    local alt="DNS.1 = ${VPN_DOMAIN}
DNS.2 = ${WEB_DOMAIN}
DNS.3 = localhost
IP.1  = 127.0.0.1"
    if [ "$SERVER_IP" != "127.0.0.1" ]; then
        alt="${alt}
IP.2  = ${SERVER_IP}"
    fi

    cat > "$work/server.cnf" <<EOF
[ req ]
default_bits       = 2048
prompt             = no
distinguished_name = dn
req_extensions     = v3_req

[ dn ]
C  = CN
O  = ${ORG}
CN = ${VPN_DOMAIN}

[ v3_req ]
basicConstraints = critical, CA:false
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[ alt_names ]
${alt}
EOF

    openssl_run openssl req -new -newkey rsa:2048 -sha256 -nodes \
        -keyout "$work/server.key" -out "$work/server.csr" -config "$work/server.cnf"

    openssl_run openssl x509 -req -in "$work/server.csr" -CA "$work/ca.crt" -CAkey "$work/ca.key" \
        -CAcreateserial -days "$CERT_DAYS" -sha256 \
        -extfile "$work/server.cnf" -extensions v3_req -out "$work/server.crt"

    [ -s "$work/server.crt" ] || die "证书生成失败"
    [ -s "$work/server.key" ] || die "私钥生成失败"

    # CA 私钥只留在 root 目录 (以后签发/吊销证书用)
    install -d -m 0700 "$CA_KEY_DIR"
    install -m 0600 "$work/ca.key" "${CA_KEY_DIR}/vpn-ca.key"
    install -m 0644 "$work/ca.crt" "${CA_KEY_DIR}/vpn-ca.crt"

    # ocserv 使用 (沿用 EL8 软件包的默认证书路径)
    [ -d "$OCSERV_PKI_PUB" ]  || install -d -m 0755 "$OCSERV_PKI_PUB"
    [ -d "$OCSERV_PKI_PRIV" ] || install -d -m 0750 "$OCSERV_PKI_PRIV"
    install -m 0644 "$work/server.crt" "$OCSERV_CERT"
    install -m 0640 "$work/server.key" "$OCSERV_KEY"
    install -m 0644 "$work/ca.crt"     "$OCSERV_CA"
    chown root:ocserv "$OCSERV_KEY" 2>/dev/null || true

    # nginx 使用
    install -d -m 0750 "$NGINX_SSL_DIR"
    install -m 0644 "$work/server.crt" "${NGINX_SSL_DIR}/server.crt"
    install -m 0640 "$work/server.key" "${NGINX_SSL_DIR}/server.key"
    chown root:nginx "${NGINX_SSL_DIR}/server.key" 2>/dev/null || true

    # 站点根目录放一份 CA, 方便客户端下载 (不需要可以删除)
    install -d -m 0755 "$WEB_ROOT"
    install -m 0644 "$work/ca.crt" "${WEB_ROOT}/ca.crt"

    # 可选: 客户端证书 (证书认证用), 打包成 p12 供下载导入
    USER_CERT_READY=0
    if [ "$WITH_USER_CERT" -eq 1 ]; then
        info "生成客户端证书 ${VPN_USER} (user.p12) ..."
        cat > "$work/user.cnf" <<EOF
[ req ]
default_bits       = 2048
prompt             = no
distinguished_name = dn

[ dn ]
C  = CN
O  = ${ORG}
CN = ${VPN_USER}

[ v3_user ]
basicConstraints = critical, CA:false
keyUsage         = critical, digitalSignature
extendedKeyUsage = clientAuth
EOF

        openssl_run openssl req -new -newkey rsa:2048 -sha256 -nodes \
            -keyout "$work/user.key" -out "$work/user.csr" -config "$work/user.cnf"
        openssl_run openssl x509 -req -in "$work/user.csr" -CA "$work/ca.crt" -CAkey "$work/ca.key" \
            -CAcreateserial -days "$CERT_DAYS" -sha256 \
            -extfile "$work/user.cnf" -extensions v3_user -out "$work/user.crt"

        if [ -z "$VPN_PASSWORD" ]; then
            VPN_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
            VPN_PASSWORD_AUTO=1
        fi

        # 优先用兼容性最好的 3DES 加密 p12 (老 iOS/安卓/AnyConnect 都能导入)
        if ! openssl pkcs12 -export -out "$work/user.p12" -inkey "$work/user.key" \
                -in "$work/user.crt" -certfile "$work/ca.crt" -name "$VPN_USER" \
                -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
                -passout "pass:${VPN_PASSWORD}" >/dev/null 2>&1; then
            openssl_run openssl pkcs12 -export -out "$work/user.p12" -inkey "$work/user.key" \
                -in "$work/user.crt" -certfile "$work/ca.crt" -name "$VPN_USER" \
                -passout "pass:${VPN_PASSWORD}"
        fi

        install -m 0644 "$work/user.p12" "${WEB_ROOT}/user.p12"
        chmod 0600 "$work/user.key"
        USER_CERT_READY=1
        msg "客户端证书已生成: https://${WEB_DOMAIN}/user.p12  (导入密码: ${VPN_PASSWORD})"
    fi

    SERVER_PIN="$(openssl x509 -in "$work/server.crt" -noout -pubkey 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null \
        | openssl enc -base64 -A 2>/dev/null || true)"

    info "证书到期时间: $(openssl x509 -in "$work/server.crt" -noout -enddate | cut -d= -f2)"
}

#-------------------------------------------------------------------------------
# 4. ocserv 配置 (仅 TCP, 关闭 UDP)
#-------------------------------------------------------------------------------
ocserv_test_config() { ocserv -t -c "$OCSERV_CONF" >/dev/null 2>&1; }

config_ocserv() {
    info "写入 ocserv 配置 ${OCSERV_CONF} ..."
    if [ -f "$OCSERV_CONF" ]; then
        cp -a "$OCSERV_CONF" "${OCSERV_CONF}.bak.${STAMP}"
    fi

    local route_line="# 分离隧道: 只有 VPN 网段走隧道"
    if [ "$FULL_TUNNEL" -eq 1 ]; then
        route_line="route = default"
    fi

    local dns2_line=""
    if [ -n "$VPN_DNS2" ]; then
        dns2_line="dns = ${VPN_DNS2}"
    fi

    local no_route_line=""
    if [ -n "$NO_ROUTE" ]; then
        no_route_line="no-route = ${NO_ROUTE}"
    fi

    # 可选: 证书认证 (与密码认证并存, 任一通过即可登录)
    local usercert_lines=""
    if [ "$WITH_USER_CERT" -eq 1 ]; then
        usercert_lines='enable-auth = "certificate"
# 客户端证书里用 CN 作为用户名
cert-user-oid = 2.5.4.3'
    fi

    cat > "$OCSERV_CONF" <<EOF
# =============================================================================
# ocserv 配置 - 由 deploy-haproxy-ocserv-nginx.sh 生成 (${STAMP})
# 只监听 127.0.0.1:${OCSERV_PORT}, TLS 由 ocserv 自己终结, 前置 HAProxy 按 SNI 分流
# 关键: udp-port = 0 -> 关闭 UDP/DTLS, 全部流量走 TCP
# =============================================================================

# ------------------------------ 监听与进程 -----------------------------------
auth = "plain[passwd=${OCSERV_PASSWD}]"
tcp-port = ${OCSERV_PORT}
udp-port = 0
udp-listen-host = 127.0.0.1
listen-host = 127.0.0.1
# 前置 HAProxy 时用 PROXY protocol v2 取得真实客户端 IP
listen-proxy-proto = true
run-as-user = ocserv
run-as-group = ocserv
socket-file = /var/run/ocserv-socket
pid-file = /var/run/ocserv.pid
use-occtl = true
log-level = 2
isolate-workers = true

# -------------------------------- 证书 ---------------------------------------
server-cert = ${OCSERV_CERT}
server-key = ${OCSERV_KEY}
ca-cert = ${OCSERV_CA}
${usercert_lines}

# ------------------------------ 会话与安全 -----------------------------------
max-clients = 128
max-same-clients = 2
rate-limit-ms = 100
keepalive = 1800
dpd = 90
mobile-dpd = 1800
try-mtu-discovery = true
mtu = 1400
auth-timeout = 240
cookie-timeout = 300
deny-roaming = false
rekey-time = 172800
rekey-method = ssl
max-ban-score = 80
ban-time = 300
ban-reset-time = 1200
tls-priorities = "NORMAL:%SERVER_PRECEDENCE:%COMPAT:-VERS-SSL3.0:-VERS-TLS1.0:-VERS-TLS1.1"
cisco-client-compat = true

# -------------------------------- 网络 ---------------------------------------
device = vpns
predictable-ips = true
default-domain = ${VPN_DOMAIN}
ipv4-network = ${VPN_NETWORK}
ipv4-netmask = ${VPN_NETMASK}
dns = ${VPN_DNS1}
${dns2_line}
ping-leases = false

# 客户端路由
${route_line}
${no_route_line}
EOF

    chown root:ocserv "$OCSERV_CONF" 2>/dev/null || true

    # ------------------------- 配置自检 + 兼容性回退 -------------------------
    local test_out=""
    OCSERV_PROXY=1
    if ! ocserv_test_config; then
        test_out="$(ocserv -t -c "$OCSERV_CONF" 2>&1 || true)"

        if printf '%s' "$test_out" | grep -qiE 'unrecognized option|invalid option|unknown option|Usage:'; then
            warn "当前 ocserv 版本不支持 -t 自检, 跳过配置检查 (${test_out%%$'\n'*})"
        else
            warn "ocserv 配置自检未通过, 逐项回退不兼容指令 ..."

            # 回退 1: 老版本可能没有 listen-proxy-proto
            sed -i -E 's|^([[:space:]]*)listen-proxy-proto = true|\1#listen-proxy-proto = true            # 自动禁用: 当前版本不支持|' "$OCSERV_CONF"
            OCSERV_PROXY=0
            if ocserv_test_config; then
                warn "已回退: 不使用 PROXY protocol (ocserv 侧只会看到 127.0.0.1)"
            else
                # 回退 2: 老版本可能没有 udp-listen-host
                sed -i -E 's|^([[:space:]]*)(udp-listen-host = .*)$|\1#\2   # 自动注释: 当前版本不支持|' "$OCSERV_CONF"
                if ocserv_test_config; then
                    warn "已回退: 去掉 udp-listen-host"
                else
                    # 回退 3: 如果连 udp-port = 0 都不支持, 则让 UDP 只监听回环,
                    #         外部依旧无法访问 UDP (HAProxy 不转发 UDP, 防火墙也不放行 UDP)
                    sed -i -E "s|^udp-port = 0$|udp-port = ${OCSERV_PORT}|" "$OCSERV_CONF"
                    if ocserv_test_config; then
                        warn "当前 ocserv 不支持 udp-port = 0, 已改为 UDP 仅监听 127.0.0.1 (外网不可达)"
                    else
                        printf '%s\n' "$test_out" >&2
                        printf '%s\n' "$(ocserv -t -c "$OCSERV_CONF" 2>&1 || true)" >&2
                        die "ocserv 配置检查失败, 请根据上面的报错调整后重试"
                    fi
                fi
            fi
        fi
    fi
    msg "ocserv 配置检查通过 (PROXY protocol: $([ "$OCSERV_PROXY" -eq 1 ] && echo 启用 || echo 关闭))"

    # ------------------------------ VPN 账号 ---------------------------------
    if ! id ocserv >/dev/null 2>&1; then
        die "ocserv 运行用户不存在, 无法继续"
    fi

    touch "$OCSERV_PASSWD"
    chown root:ocserv "$OCSERV_PASSWD" 2>/dev/null || true
    chmod 0640 "$OCSERV_PASSWD"

    if grep -q "^${VPN_USER}:" "$OCSERV_PASSWD" 2>/dev/null; then
        info "账号 ${VPN_USER} 已存在, 未修改密码"
    else
        if [ -z "$VPN_PASSWORD" ]; then
            VPN_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
            VPN_PASSWORD_AUTO=1
        fi
        # setsid 脱离控制终端, 让 ocpasswd 从标准输入读取密码
        printf '%s\n%s\n' "$VPN_PASSWORD" "$VPN_PASSWORD" \
            | setsid ocpasswd -c "$OCSERV_PASSWD" "$VPN_USER" >/dev/null 2>&1 || true
        sleep 1
        if grep -q "^${VPN_USER}:" "$OCSERV_PASSWD" 2>/dev/null; then
            msg "已创建 VPN 账号: ${VPN_USER}"
        else
            warn "自动写入账号失败, 请手动执行: ocpasswd -c ${OCSERV_PASSWD} ${VPN_USER}"
        fi
    fi
}

#-------------------------------------------------------------------------------
# 5. nginx 配置 (仅监听 127.0.0.1:8443, TLS 终结)
#-------------------------------------------------------------------------------
config_nginx() {
    info "写入 nginx 配置 (127.0.0.1:${NGINX_PORT} ssl, 接收 PROXY protocol) ..."

    if [ -f "$NGINX_CONF" ]; then
        cp -a "$NGINX_CONF" "${NGINX_CONF}.bak.${STAMP}"
    fi

    # 发行版自带的 80 端口 default server 必须让给 HAProxy
    local f
    for f in /etc/nginx/conf.d/*.conf; do
        [ -e "$f" ] || continue
        if [ "$f" != "$NGINX_SITE" ]; then
            mv "$f" "${f}.bak.${STAMP}"
            info "已停用原有的 ${f}"
        fi
    done

    cat > "$NGINX_CONF" <<'NGINX_EOF'
# 由 deploy-haproxy-ocserv-nginx.sh 生成
user  nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid       /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;
    sendfile   on;
    keepalive_timeout 65;
    server_tokens off;

    include /etc/nginx/conf.d/*.conf;
}
NGINX_EOF

    cat > "$NGINX_SITE" <<'NGINX_SITE_EOF'
# 由 deploy-haproxy-ocserv-nginx.sh 生成
# 只监听回环地址: 外部流量统一由 HAProxy 443 按 SNI 分流进来
server {
    listen      127.0.0.1:__NGINX_PORT__ ssl http2 proxy_protocol;
    server_name __WEB_DOMAIN__ __VPN_DOMAIN__ __SERVER_IP__;

    ssl_certificate     __NGINX_SSL_DIR__/server.crt;
    ssl_certificate_key __NGINX_SSL_DIR__/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1h;

    # 真实客户端 IP 来自 HAProxy 的 PROXY protocol
    set_real_ip_from 127.0.0.1;
    real_ip_header   proxy_protocol;

    root  __WEB_ROOT__;
    index index.html;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;

    location / {
        try_files $uri $uri/ =404;
    }

    # 供客户端下载自签名 CA 证书
    location = /ca.crt {
        default_type application/x-x509-ca-cert;
        add_header Content-Disposition 'attachment; filename="vpn-ca.crt"';
    }
}
NGINX_SITE_EOF

    sed -i \
        -e "s|__NGINX_PORT__|${NGINX_PORT}|g" \
        -e "s|__WEB_DOMAIN__|${WEB_DOMAIN}|g" \
        -e "s|__VPN_DOMAIN__|${VPN_DOMAIN}|g" \
        -e "s|__SERVER_IP__|${SERVER_IP}|g" \
        -e "s|__NGINX_SSL_DIR__|${NGINX_SSL_DIR}|g" \
        -e "s|__WEB_ROOT__|${WEB_ROOT}|g" \
        "$NGINX_SITE"

    if [ ! -f "${WEB_ROOT}/index.html" ]; then
        cat > "${WEB_ROOT}/index.html" <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>${WEB_DOMAIN}</title></head>
<body>
<h1>HAProxy + Nginx + ocserv 部署成功</h1>
<p>网站域名: ${WEB_DOMAIN}</p>
<p>VPN 域名 : ${VPN_DOMAIN} (OpenConnect / AnyConnect 客户端使用)</p>
<p>自签名 CA: <a href="/ca.crt">ca.crt</a></p>
</body>
</html>
EOF
    fi

    nginx -t >/dev/null 2>&1 || { nginx -t || true; die "nginx 配置检查失败"; }
    msg "nginx 配置检查通过"
}

#-------------------------------------------------------------------------------
# 6. HAProxy 配置 (mode tcp + SNI 分流)
#-------------------------------------------------------------------------------
config_haproxy() {
    info "写入 HAProxy 配置 ${HAPROXY_CONF} (mode tcp, 按 SNI 分流) ..."

    if [ -f "$HAPROXY_CONF" ]; then
        cp -a "$HAPROXY_CONF" "${HAPROXY_CONF}.bak.${STAMP}"
    fi
    if [ -f "$RSYSLOG_CONF" ]; then
        cp -a "$RSYSLOG_CONF" "${RSYSLOG_CONF}.bak.${STAMP}"
    fi

    local ocserv_proxy_opt=""
    if [ "$OCSERV_PROXY" -eq 1 ]; then
        ocserv_proxy_opt="send-proxy-v2"
    fi

    cat > "$HAPROXY_CONF" <<EOF
# =============================================================================
# HAProxy 配置 - 由 deploy-haproxy-ocserv-nginx.sh 生成 (${STAMP})
#
# 443/tcp: 读取 TLS ClientHello 的 SNI 后做四层透传 (不解密, HAProxy 无证书)
#   SNI = ${VPN_DOMAIN}   -> ocserv 127.0.0.1:${OCSERV_PORT}
#   其它 / 无 SNI         -> nginx  127.0.0.1:${NGINX_PORT}
# 80/tcp : 301 跳转到 https
# =============================================================================
global
    # 直接写本机 syslog 的 unix socket (不经过 UDP)
    log         /dev/log local0
    stats socket /var/lib/haproxy/stats mode 660 level admin
    stats timeout 30s
    pidfile     /var/run/haproxy.pid
    user        haproxy
    group       haproxy
    daemon
    maxconn     20000

defaults
    log     global
    mode    tcp
    timeout connect 10s
    timeout client  1h
    timeout server  1h

# ------------------------------- 80 -> https ---------------------------------
frontend fe_http
    bind *:80
    mode http
    option httplog
    timeout client 30s
    http-request redirect scheme https code 301

# ------------------------------ 443 SNI 分流 ---------------------------------
frontend fe_https
    bind *:443
    mode tcp
    option tcplog
    # 等待 TLS ClientHello, 以便读取 SNI
    tcp-request inspect-delay 10s
    tcp-request content accept if { req_ssl_hello_type 1 }
    acl is_vpn req_ssl_sni -i ${VPN_DOMAIN}
    use_backend be_ocserv if is_vpn
    default_backend be_nginx

# --------------------------------- 后端 ---------------------------------------
backend be_ocserv
    mode tcp
    option tcplog
    # VPN 长连接, 超时放宽
    server ocserv 127.0.0.1:${OCSERV_PORT} ${ocserv_proxy_opt}

backend be_nginx
    mode tcp
    option tcplog
    server nginx 127.0.0.1:${NGINX_PORT} send-proxy-v2
EOF

    cat > "$RSYSLOG_CONF" <<'EOF'
# HAProxy 日志 (facility local0)
if ($syslogfacility-text == 'local0') then -/var/log/haproxy.log
EOF

    if ! haproxy -c -f "$HAPROXY_CONF" >/dev/null 2>&1; then
        haproxy -c -f "$HAPROXY_CONF" || true
        die "HAProxy 配置检查失败"
    fi
    msg "HAProxy 配置检查通过"
}

#-------------------------------------------------------------------------------
# 7. 防火墙: 只放行 TCP 80/443, 不放行任何 UDP
#-------------------------------------------------------------------------------
config_firewall() {
    if [ "$SETUP_FIREWALL" -ne 1 ]; then
        warn "已跳过 firewalld 配置, 请自行放行 TCP 80/443 (不要放行 UDP)"
        return 0
    fi
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        warn "未安装 firewalld, 请自行确保 TCP 80/443 可访问且不放行 UDP"
        return 0
    fi

    systemctl enable --now firewalld >/dev/null 2>&1 || warn "firewalld 启动失败"

    local default_zone="" iface="" zone=""
    default_zone="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"
    iface="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
    if [ -n "$iface" ]; then
        zone="$(firewall-cmd --get-zone-of-interface="$iface" 2>/dev/null || true)"
    fi
    if [ -z "$zone" ] || [ "$zone" = "no zone" ]; then
        zone="$default_zone"
    fi

    info "对外网卡: ${iface:-未知}; 使用 firewalld 区域: ${zone}"
    firewall-cmd --permanent --zone="$zone" --add-service=http  >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone="$zone" --add-service=https >/dev/null 2>&1 || true
    # VPN 客户端访问外网需要 NAT
    firewall-cmd --permanent --zone="$zone" --add-masquerade >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true

    msg "已放行服务: $(firewall-cmd --zone="$zone" --list-services 2>/dev/null | tr -s ' ') (仅 TCP)"
    info "NAT 伪装: $(firewall-cmd --zone="$zone" --query-masquerade 2>/dev/null || echo no); 本脚本不会放行任何 UDP 端口"
}

#-------------------------------------------------------------------------------
# 8. SELinux
#-------------------------------------------------------------------------------
config_selinux() {
    command -v getenforce >/dev/null 2>&1 || return 0
    local mode
    mode="$(getenforce 2>/dev/null || echo Disabled)"
    if [ "$mode" = "Disabled" ]; then
        info "SELinux 已禁用, 跳过"
        return 0
    fi

    if [ "$SELINUX_PERMISSIVE" -eq 1 ]; then
        warn "按要求把 SELinux 设为 permissive (重启后生效)"
        setenforce 0 >/dev/null 2>&1 || true
        sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
        return 0
    fi

    info "SELinux 当前为 ${mode}, 添加必要策略 ..."
    setsebool -P haproxy_connect_any 1 >/dev/null 2>&1 \
        || warn "setsebool haproxy_connect_any 失败, haproxy 可能连不上后端"

    if command -v semanage >/dev/null 2>&1; then
        semanage port -a -t ocserv_port_t -p tcp "$OCSERV_PORT" >/dev/null 2>&1 \
            || semanage port -m -t ocserv_port_t -p tcp "$OCSERV_PORT" >/dev/null 2>&1 \
            || warn "无法给端口 ${OCSERV_PORT} 打 ocserv_port_t 标签 (通常不影响, ocserv 进程多为 unconfined)"

        if ! semanage port -l 2>/dev/null | grep -E '^http_port_t' | grep -qw "$NGINX_PORT"; then
            semanage port -m -t http_port_t -p tcp "$NGINX_PORT" >/dev/null 2>&1 \
                || { semanage port -d -p tcp "$NGINX_PORT" >/dev/null 2>&1 || true
                     semanage port -a -t http_port_t -p tcp "$NGINX_PORT" >/dev/null 2>&1; } \
                || warn "无法给端口 ${NGINX_PORT} 打 http_port_t 标签"
        fi
    else
        warn "未找到 semanage, 建议安装 policycoreutils-python-utils"
    fi

    restorecon -RF /etc/ocserv "$NGINX_SSL_DIR" "$WEB_ROOT" /var/lib/haproxy >/dev/null 2>&1 || true
    restorecon -RF /etc/pki/ocserv >/dev/null 2>&1 || true
}

#-------------------------------------------------------------------------------
# 9. 启动服务
#-------------------------------------------------------------------------------
start_services() {
    info "启动服务并设置开机自启 ..."
    systemctl enable rsyslog >/dev/null 2>&1 || true
    systemctl restart rsyslog >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true

    local failed=0 svc
    for svc in ocserv nginx haproxy; do
        systemctl enable "$svc" >/dev/null 2>&1 || true
        if systemctl restart "$svc" >/dev/null 2>&1; then
            sleep 1
            if systemctl is-active --quiet "$svc"; then
                msg "${svc} 已启动并开机自启"
            else
                warn "${svc} 未能进入运行状态"
                failed=1
            fi
        else
            warn "${svc} 启动失败"
            failed=1
        fi
    done

    if [ "$failed" -ne 0 ]; then
        echo "--------- 服务日志 ---------" >&2
        journalctl -u ocserv -u nginx -u haproxy -n 40 --no-pager >&2 || true
        if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null || echo Disabled)" = "Enforcing" ]; then
            echo "--------- SELinux 拒绝记录 ---------" >&2
            ausearch -m avc -ts recent 2>/dev/null | tail -n 20 >&2 || true
            warn "若确认为 SELinux 拦截, 可执行: ausearch -m avc -ts recent | audit2allow -M vpnfix && semodule -i vpnfix.pp"
            warn "或重新执行本脚本并加上 --selinux-permissive"
        fi
        die "有服务启动失败, 请根据上面的日志排查"
    fi
}

#-------------------------------------------------------------------------------
# 10. 自检
#-------------------------------------------------------------------------------
probe() { # 输出 HTTP 状态码, 失败输出 ERR
    local out=""
    if out="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null)"; then
        echo "$out"
    else
        echo "ERR"
    fi
}

verify() {
    info "开始自检 ..."
    sleep 1

    info "监听端口:"
    ss -lntp 2>/dev/null | awk 'NR==1 || /:(80|443|'"${OCSERV_PORT}"'|'"${NGINX_PORT}"')[[:space:]]/' | sed 's/^/    /' || true

    if ss -lunp 2>/dev/null | grep -q 'ocserv'; then
        warn "检测到 ocserv 在监听 UDP 端口, 请检查 ocserv.conf 的 udp-port 设置:"
        ss -lunp 2>/dev/null | grep 'ocserv' | sed 's/^/    /' || true
    else
        msg "ocserv 未监听任何 UDP 端口 (符合'不使用 UDP'要求)"
    fi

    local vpn_code="" web_code="" http_code=""
    vpn_code="$(probe --cacert "${OCSERV_CA}" --resolve "${VPN_DOMAIN}:443:127.0.0.1" "https://${VPN_DOMAIN}/")"
    web_code="$(probe --cacert "${OCSERV_CA}" --resolve "${WEB_DOMAIN}:443:127.0.0.1" "https://${WEB_DOMAIN}/")"
    http_code="$(probe --resolve "${WEB_DOMAIN}:80:127.0.0.1" "http://${WEB_DOMAIN}/")"

    # VPN 路径失败时, 最常见的坑就是 PROXY protocol, 这里自动回退一次
    if [ "$vpn_code" = "ERR" ] && [ "$OCSERV_PROXY" -eq 1 ]; then
        warn "VPN 路径 TLS 握手失败, 尝试关闭 PROXY protocol 后重试 ..."
        sed -i -E 's|^([[:space:]]*server ocserv[[:space:]].*)[[:space:]]send-proxy-v2[[:space:]]*$|\1|' "$HAPROXY_CONF"
        sed -i -E 's|^([[:space:]]*)listen-proxy-proto = true|\1#listen-proxy-proto = true            # 自动禁用: 兼容性回退|' "$OCSERV_CONF"
        if haproxy -c -f "$HAPROXY_CONF" >/dev/null 2>&1 && ocserv -t -c "$OCSERV_CONF" >/dev/null 2>&1; then
            OCSERV_PROXY=0
            systemctl restart ocserv >/dev/null 2>&1 || true
            sleep 1
            systemctl restart haproxy >/dev/null 2>&1 || true
            sleep 2
            vpn_code="$(probe --cacert "${OCSERV_CA}" --resolve "${VPN_DOMAIN}:443:127.0.0.1" "https://${VPN_DOMAIN}/")"
            if [ "$vpn_code" != "ERR" ]; then
                msg "回退成功: VPN 路径已可用 (后端只能看到 127.0.0.1)"
            fi
        fi
    fi

    if [ "$vpn_code" = "ERR" ]; then
        printf '    SNI=%s -> ocserv : \033[1;31m失败\033[0m\n' "$VPN_DOMAIN"
    else
        printf '    SNI=%s -> ocserv : 成功 (HTTP %s, ocserv 返回 404 属正常)\n' "$VPN_DOMAIN" "$vpn_code"
    fi
    if [ "$web_code" = "ERR" ]; then
        printf '    SNI=%s -> nginx  : \033[1;31m失败\033[0m\n' "$WEB_DOMAIN"
    else
        printf '    SNI=%s -> nginx  : 成功 (HTTP %s)\n' "$WEB_DOMAIN" "$web_code"
    fi
    printf '    80 端口跳转      : HTTP %s (期望 301)\n' "$http_code"

    if [ "$vpn_code" = "ERR" ] || [ "$web_code" = "ERR" ]; then
        warn "自检未全部通过; 常见原因: 域名未解析/SNI 不匹配 / SELinux / 后端未启动"
        warn "排查: journalctl -u haproxy -u ocserv -u nginx -n 50 --no-pager"
    else
        msg "自检通过: HAProxy SNI 分流正常, ocserv 与 nginx 都能从 443 访问"
    fi
}

#-------------------------------------------------------------------------------
# 11. 汇总
#-------------------------------------------------------------------------------
summary() {
    {
        echo "================ 部署信息 (${STAMP}) ================"
        echo "VPN 域名        : ${VPN_DOMAIN}"
        echo "网站域名        : ${WEB_DOMAIN}"
        echo "服务器 IP       : ${SERVER_IP}"
        echo "HAProxy         : *:80 (301 -> https)  *:443 (TCP SNI 分流, 无证书)"
        echo "ocserv          : 127.0.0.1:${OCSERV_PORT} (TLS 终结, UDP 已关闭)"
        echo "nginx           : 127.0.0.1:${NGINX_PORT} (TLS 终结, 接收 PROXY protocol)"
        echo "PROXY protocol  : $([ "$OCSERV_PROXY" -eq 1 ] && echo 'ocserv/nginx 均已启用' || echo 'ocserv 已关闭(兼容模式), nginx 启用')"
        echo "VPN 客户端网段  : ${VPN_NETWORK}/${VPN_NETMASK}"
        echo "VPN 账号        : ${VPN_USER}"
        if [ "$VPN_PASSWORD_AUTO" -eq 1 ]; then
            echo "VPN 密码        : ${VPN_PASSWORD}   <== 随机生成, 请立即保存"
        fi
        echo "CA 证书         : ${OCSERV_CA}   (客户端下载: https://${WEB_DOMAIN}/ca.crt)"
        echo "CA 私钥(务必保管): ${CA_KEY_DIR}/vpn-ca.key"
        echo "服务器证书      : ${OCSERV_CERT}  SAN: ${VPN_DOMAIN}, ${WEB_DOMAIN}, ${SERVER_IP}"
        echo "认证方式        : $([ "$USER_CERT_READY" -eq 1 ] && echo '密码 或 客户端证书' || echo '用户名 + 密码 (plain)')"
        echo "客户端路由      : $([ "$FULL_TUNNEL" -eq 1 ] && echo '全局路由' || echo '仅 VPN 网段')${NO_ROUTE:+   排除: ${NO_ROUTE}}"
        if [ "$USER_CERT_READY" -eq 1 ]; then
            echo "客户端证书      : https://${WEB_DOMAIN}/user.p12   导入密码: ${VPN_PASSWORD}"
        fi
        echo "openconnect pin : pin-sha256:${SERVER_PIN:-未知}"
        echo
        echo "客户端使用示例:"
        echo "  # 方式一: 信任自签名 CA (推荐, 把 ca.crt 拷到客户端)"
        echo "  openconnect --protocol=anyconnect --cafile=ca.crt ${VPN_DOMAIN}"
        echo "  # 方式二: 直接固定公钥指纹"
        echo "  openconnect --protocol=anyconnect --servercert=pin-sha256:${SERVER_PIN:-xxxx} ${VPN_DOMAIN}"
        echo "  # 图形客户端 (AnyConnect/OpenConnect-GUI): 服务器填 https://${VPN_DOMAIN}"
        if [ "$USER_CERT_READY" -eq 1 ]; then
            echo "  # 证书认证: 把 user.p12 导入客户端即可 (无需再输密码)"
        fi
        echo
        echo "常用管理命令:"
        echo "  systemctl status haproxy ocserv nginx"
        echo "  systemctl restart haproxy ocserv nginx"
        echo "  ocpasswd -c ${OCSERV_PASSWD} <用户名>          # 新增用户 / 改密码"
        echo "  ocpasswd -c ${OCSERV_PASSWD} -d <用户名>       # 删除用户"
        echo "  occtl show users                              # 在线用户"
        echo "  tail -f /var/log/haproxy.log /var/log/nginx/access.log"
        echo
        echo "必须注意:"
        echo "  1) ${VPN_DOMAIN} 和 ${WEB_DOMAIN} 都要解析到 ${SERVER_IP};"
        echo "     客户端连接 VPN 必须用域名(不能用 IP), 因为 HAProxy 靠 SNI 分流;"
        echo "     没有 SNI 的连接会被送到 nginx。"
        echo "  2) 证书是本地 CA 自签的: 客户端带 ca.crt, 或用 --servercert pin-sha256。"
        echo "  3) 只放行 TCP 80/443, 没有开放任何 UDP; ocserv 走 tcp-port=${OCSERV_PORT} 承载全部流量。"
        echo "  4) VPN 客户端上网依赖 NAT: 已配置 firewalld masquerade + net.ipv4.ip_forward=1。"
        echo "  5) 改端口/域名后重新执行本脚本即可 (旧配置已备份为 *.bak.${STAMP})。"
    } | tee "$INFO_FILE"

    echo
    msg "部署完成, 详细信息已保存到 ${INFO_FILE}"
}

#-------------------------------------------------------------------------------
main() {
    parse_args "$@"
    preflight
    install_packages
    config_kernel
    gen_certs
    config_ocserv
    config_nginx
    config_haproxy
    config_firewall
    config_selinux
    start_services
    verify
    summary
}

main "$@"

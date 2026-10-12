#!/bin/bash
basepath=$(dirname $0)
cd ${basepath}&&mkdir -p ocsauto&&cd ocsauto
fileurl=https://raw.githubusercontent.com/ZhangShuxiang/ocserv-auto/master/ocs/
#########################################
function ConfigEnvironment {
    #随机字符串
    randstr() {
        openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16
    }
    #用户名，默认随机
    username=$(randstr)
    echo -e "\nPlease input ocserv user name."
    printf "Default user name is \e[33m${username}\e[0m, let it blank to use this user name: "
    read usernametmp
    if [[ -n "${usernametmp}" ]]; then
        username=${usernametmp}
    fi
    #密码，默认随机
    password=$(randstr)
    printf "\nPlease input \e[33m${username}\e[0m's password.\n"
    printf "Random password is \e[33m${password}\e[0m, let it blank to use this password: "
    read passwordtmp
    if [[ -n "${passwordtmp}" ]]; then
        password=${passwordtmp}
    fi
    #端口
    #echo -n "ocs port: "
    #read porttmp1
    #aadd_port1=${porttmp1}
    ssh_ser=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || echo 22)
    #域名
    echo -n "www."
    read wwwtmp1
    wwwtmp=${wwwtmp1}
}
#########################################
function InstallOcserv {
    #升级系统
    dnf update -qqy
    #安装epel-release
    dnf install -qqy epel-release
    #sed -i "0,/enabled=0/s//enabled=1/" /etc/yum.repos.d/epel.repo
    #添加nginx官方源
    curl -o /etc/yum.repos.d/nginx.repo ${fileurl}nginx.repo
    dnf makecache -qqy
    #安装ocserv
    dnf install -qqy ocserv nginx gnutls-utils certbot firewalld
    dnf clean all -qqy
}
#########################################
function InstallCert {
    curl -O ${fileurl}ca.tmpl ${fileurl}server.tmpl ${fileurl}ocsver.tmpl ${fileurl}user.tmpl
    sed -i "s@\[WWWURL\]@${wwwtmp}@g" *.tmpl
    sed -i "s@\[WWWUSER\]@${username}@g" *.tmpl
#---创建根证书（参考https://ocserv.openconnect-vpn.net/ocserv.8.html）#
    certtool --generate-privkey --outfile ca-key.pem
    certtool --generate-self-signed --load-privkey ca-key.pem \
    --template ca.tmpl --outfile ca-cert.pem
#---创建服务器证书------------------------#
    certtool --generate-privkey --outfile server-key.pem
    certtool --generate-certificate --load-privkey server-key.pem \
    --load-ca-certificate ca-cert.pem --load-ca-privkey ca-key.pem \
    --template server.tmpl --outfile server-cert.pem
#---创建服务器证书------------------------#
    certtool --generate-privkey --outfile ocsver-key.pem
    certtool --generate-certificate --load-privkey ocsver-key.pem \
    --load-ca-certificate ca-cert.pem --load-ca-privkey ca-key.pem \
    --template ocsver.tmpl --outfile ocsver-cert.pem
#---创建用户证书--------------------------#
    certtool --generate-privkey --outfile user-key.pem
    certtool --generate-certificate --load-privkey user-key.pem \
    --load-ca-certificate ca-cert.pem --load-ca-privkey ca-key.pem \
    --template user.tmpl --outfile user-cert.pem
}
#########################################
function InstallUserCert {
    #导出用户证书
    certtool --to-p12 --load-privkey user-key.pem \
    --pkcs-cipher 3des-pkcs12 \
    --load-certificate user-cert.pem \
    --outfile user.p12 --outder
    #复制证书文件
    cp user.p12 /usr/share/nginx/html/user.p12.bak
    mkdir -p /etc/pki/ocs
    cp -a . /etc/pki/ocs/
}
#########################################
function ConfigOcserv {
    #添加用户和密码
    (echo "${password}"; sleep 1; echo "${password}") | ocpasswd -c "/etc/ocserv/ocpasswd" ${username}
    #编辑配置文件
    mv /etc/ocserv/ocserv.conf /etc/ocserv/ocserv.conf.bak
    curl -o /etc/ocserv/ocserv.conf ${fileurl}ocserv.conf
    sed -i "s@\[WWWURL\]@${wwwtmp}@g" /etc/ocserv/ocserv.conf
    sed -i "s@\[WWWUSER\]@${username}@g" /etc/ocserv/ocserv.conf
}
#########################################
function ConfigNginx {
    #编辑配置文件
    mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
    curl -o /etc/nginx/nginx.conf ${fileurl}nginx.conf
    mv /usr/share/nginx/html/index.html /usr/share/nginx/html/index.html.bak
    curl -o /usr/share/nginx/html/index.html ${fileurl}index.html
    sed -i "s@\[WWWURL\]@${wwwtmp}@g" /etc/nginx/nginx.conf
    sed -i "s@\[WWWUSER\]@${username}@g" /etc/nginx/nginx.conf
}
#########################################
#function ConfigRoute {
#    #添加自定义规则
#}
#########################################
function ConfigFirewall {
    echo "===== 配置防火墙(AI生成)====="
    # ---------- 1. 内核参数 ----------
    # IPv4 / IPv6 转发
    grep -q '^net.ipv4.ip_forward=1'          /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1'          >> /etc/sysctl.conf
    grep -q '^net.ipv6.conf.all.forwarding=1' /etc/sysctl.conf || echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
    grep -q '^net.ipv6.conf.all.accept_ra=2'  /etc/sysctl.conf || echo 'net.ipv6.conf.all.accept_ra=2'  >> /etc/sysctl.conf
    sysctl --system >/dev/null 2>&1
    # ---------- 2. 启动 firewalld ----------
    systemctl -q enable --now firewalld.service
    # ---------- 3. 关键：6in4 隧道必须关闭严格 rpfilter ----------
    # strict 会因隧道非对称路由丢弃入站 IPv6 包
    sed -i 's/^IPv6_rpfilter=.*/IPv6_rpfilter=loose/' /etc/firewalld/firewalld.conf
    grep -q '^IPv6_rpfilter=' /etc/firewalld/firewalld.conf || \
        echo 'IPv6_rpfilter=loose' >> /etc/firewalld/firewalld.conf
    # 重启使 rpfilter 生效
    systemctl -q restart firewalld.service
    # ---------- 4. 自动探测 6in4 隧道接口并绑定到 public zone ----------
    firewall-cmd -q --permanent --zone=public --add-interface=ipv6net 2>/dev/null
    # ---------- 5. IPv4 放行 ----------
    firewall-cmd -q --permanent --add-port=80/tcp
    firewall-cmd -q --permanent --add-port=443/tcp
    firewall-cmd -q --permanent --add-port=${ssh_ser}/tcp
    # ---------- 6. IPv6 放行（显式 family=ipv6） ----------
    for p in 80 443 ${ssh_ser}; do
        [ -n "$p" ] || continue
        firewall-cmd -q --permanent --add-rich-rule="rule family=\"ipv6\" port port=\"${p}\" protocol=\"tcp\" accept"
    done
    # ---------- 7. ICMPv6 关键类型放行（ping6 / ND / RA 必需） ----------
    firewall-cmd -q --permanent --add-rich-rule='rule family="ipv6" protocol value="ipv6-icmp" accept'
    # ---------- 8. proto-41 放行（6in4 隧道封装） ----------
    firewall-cmd -q --permanent --add-rich-rule='rule protocol value="41" accept'
    # ---------- 9. IPv4 出站伪装 ----------
    firewall-cmd -q --permanent --add-masquerade
    # ---------- 10. IPv6 转发放行 + NAT66（ULA 客户端出站需要） ----------
    # 使用 zone 的 forward 而非 direct 规则（nftables 后端下 direct ACCEPT 不可靠）
    firewall-cmd -q --permanent --zone=public --add-forward
    firewall-cmd -q --permanent --add-rich-rule='rule family="ipv6" masquerade'
    # ---------- 11. 重载 ----------
    firewall-cmd -q --reload
    echo "===== 防火墙配置完成 ====="
    echo "--- active zones ---"
    firewall-cmd --get-active-zones
    echo "--- rich rules ---"
    firewall-cmd --permanent --list-rich-rules
    echo "--- ports ---"
    firewall-cmd --permanent --list-ports
}
#########################################
function ConfigSystem {
    # SELinux：允许 nginx 连接后端、ocserv 读证书
    setsebool -P httpd_can_network_connect 1
    setsebool -P httpd_can_network_relay   1

    # 端口上下文（如使用非标准端口需要；80/443/8443/4443）
    semanage port -a -t http_port_t  -p tcp 8443 2>/dev/null || true
    semanage port -a -t ocserv_port_t -p tcp 4443 2>/dev/null || true

    # 开机启动
    systemctl -q enable firewalld.service
    systemctl -q enable ocserv.service
    systemctl -q enable nginx.service

    # 启动服务
    systemctl -q restart ocserv.service
    systemctl -q restart nginx.service
}
#########################################
ConfigEnvironment
echo "ConfigEnvironment Successful!"
InstallOcserv
echo "InstallOcserv Successful!"
InstallCert
echo "InstallCert Successful!"
InstallUserCert
echo "InstallUserCert Successful!"
ConfigOcserv
echo "ConfigOcserv Successful!"
ConfigNginx
echo "ConfigNginx Successful!"
#ConfigRoute
#echo "ConfigRoute Successful!"
ConfigFirewall
echo "ConfigFirewall Successful!"
ConfigSystem
echo "ConfigSystem Successful!"
exit

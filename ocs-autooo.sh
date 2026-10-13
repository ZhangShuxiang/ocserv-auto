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
    read -r usernametmp
    if [[ -n "${usernametmp}" ]]; then
        username=${usernametmp}
    fi
    #密码，默认随机
    password=$(randstr)
    printf "\nPlease input \e[33m${username}\e[0m's password.\n"
    printf "Random password is \e[33m${password}\e[0m, let it blank to use this password: "
    read -r passwordtmp
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
    read -r www_url_1
    www_url=${www_url_1}
    # 获取接口IPv6地址和前缀
    IPV6_ADDR=$(ip -6 addr show dev "ipv6net" scope global | awk '/inet6/{print $2; exit}')
    IPV6_PREFIX=$(python3 -c "import ipaddress; print(ipaddress.ip_interface('$IPV6_ADDR').network)")
    echo $IPV6_PREFIX
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
    curl -OOOO ${fileurl}ca.tmpl ${fileurl}server.tmpl ${fileurl}ocsver.tmpl ${fileurl}user.tmpl
    sed -i "s@\[WWWURL\]@${www_url}@g" *.tmpl
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
    --load-certificate user-cert.pem --outfile user.p12 \
    --p12-name "${username}" --password "${password}"
    #复制证书文件
    cp user.p12 /usr/share/nginx/html/user.p12.bak
    mkdir -p /etc/pki/ocs
    cp -a . /etc/pki/ocs/
}
#########################################
function ConfigOcserv {
    #添加用户和密码
    #(echo "${password}"; sleep 1; echo "${password}") | ocpasswd -c "/etc/ocserv/ocpasswd" ${username}
    printf '%s\n%s\n' "${password}" "${password}" | ocpasswd -c /etc/ocserv/ocpasswd "${username}"
    #编辑配置文件
    mv /etc/ocserv/ocserv.conf /etc/ocserv/ocserv.conf.bak
    curl -o /etc/ocserv/ocserv.conf ${fileurl}ocserv.conf
    sed -i "s@\[WWWURL\]@${www_url}@g" /etc/ocserv/ocserv.conf
    sed -i "s@\[WWWUSER\]@${username}@g" /etc/ocserv/ocserv.conf
    if [ -n "${IPV6_PREFIX}" ]; then
        sed -i "s@fc00::/64@${IPV6_PREFIX}@g" /etc/ocserv/ocserv.conf
    fi
}
#########################################
function ConfigNginx {
    #编辑配置文件
    mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
    curl -o /etc/nginx/nginx.conf ${fileurl}nginx.conf
    sed -i "s@\[WWWURL\]@${www_url}@g" /etc/nginx/nginx.conf
    sed -i "s@\[WWWUSER\]@${username}@g" /etc/nginx/nginx.conf
    #添加网页文件
    mv /usr/share/nginx/html/index.html /usr/share/nginx/html/index.html.bak
    curl -o /usr/share/nginx/html/index.html ${fileurl}index.html
}
#########################################
#function ConfigRoute {
#    #添加自定义规则
#}
#########################################
function ConfigFirewall {
    # ----------1.内核转发----------
    curl -o /etc/sysctl.d/99-ocserv.conf ${fileurl}99-ocserv.conf
    #sysctl --system
    sysctl -p /etc/sysctl.d/99-ocserv.conf
    # ----------2.启动防火墙----------
    systemctl -q enable --now firewalld.service
    # ----------3.接口绑定----------
    firewall-cmd -q --permanent --zone=public --change-interface=eth0
    firewall-cmd -q --permanent --zone=public --change-interface=ipv6net
    firewall-cmd -q --permanent --zone=internal --change-interface=ocstun
    # ----------4.放行端口----------
    firewall-cmd -q --permanent --zone=public --add-protocol=41
    firewall-cmd -q --permanent --zone=public --add-port=80/tcp
    firewall-cmd -q --permanent --zone=public --add-port=443/tcp
    firewall-cmd -q --permanent --zone=public --add-port=${ssh_ser}/tcp
    # ----------5.IPv4NAT----------
    firewall-cmd -q --permanent --zone=public --add-masquerade
    # ----------6.同区转发----------
    #firewall-cmd -q --permanent --zone=public --add-forward
    # ----------6.转发放行----------
    if ! firewall-cmd --permanent --get-policies | grep -qx 'ocserv-forward'; then
        firewall-cmd --permanent --new-policy=ocserv-forward
        firewall-cmd --permanent --policy=ocserv-forward --add-ingress-zone=internal
        firewall-cmd --permanent --policy=ocserv-forward --add-egress-zone=public
        firewall-cmd --permanent --policy=ocserv-forward --set-target=ACCEPT
    fi
    # ----------7.重载----------
    firewall-cmd -q --reload
}
#########################################
function ConfigSystem {
    #SELinux默认关闭
    #setenforce 0
    #sudo sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    # SELinux：允许 nginx 连接后端、ocserv 读证书
    #setsebool -P httpd_can_network_connect 1
    #setsebool -P httpd_can_network_relay   1
    # 端口上下文（如使用非标准端口需要；80/443/8443/4443）
    #semanage port -a -t http_port_t  -p tcp 8443 2>/dev/null || true
    #semanage port -a -t ocserv_port_t -p tcp 4443 2>/dev/null || true

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
exit 0

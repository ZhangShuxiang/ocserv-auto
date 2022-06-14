#!/bin/bash

basepath=$(dirname $0)
cd ${basepath}

function ConfigEnvironmentVariable {
    # 变量设置
    # 单IP最大连接数，默认是2
    maxsameclients=8
    # 最大连接数，默认是16
    maxclients=64
    # 服务器的证书和key文件，放在本脚本的同目录下，key文件的权限应该是600或者400
    servercert=${1-server-cert.pem}
    serverkey=${2-server-key.pem}
    # 配置目录
    confdir="/etc/ocserv"
    # 端口，默认是443
    port=8080
    # 用户名，默认是user
    username=adminuser
    # 随机密码
    randstr() {
        index=0
        str=""
        for i in {a..z}; do arr[index]=$i; index=$(expr ${index} + 1); done
        for i in {A..Z}; do arr[index]=$i; index=$(expr ${index} + 1); done
        for i in {0..9}; do arr[index]=$i; index=$(expr ${index} + 1); done
        for i in {1..10}; do str="$str${arr[$RANDOM%$index]}"; done
        echo ${str}
    }
    password=$(randstr)
    printf "\nPlease input \e[33m${username}\e[0m's password.\n"
    printf "Random password is \e[33m${password}\e[0m, let it blank to use this password: "
    read passwordtmp
    if [[ -n "${passwordtmp}" ]]; then
        password=${passwordtmp}
    fi
}

function InstallOcserv {
    # 升级系统
    #dnf update -y -q

    # 安装 epel-release
    if [ $(grep epel /etc/yum.repos.d/*.repo | wc -l) -eq 0 ]; then
        dnf install -y -q epel-release && dnf clean all && dnf makecache fast
    fi
    # 安装ocserv
    dnf install -y ocserv gnutls-utils nginx
}

function ConfigOcserv {
    # 检测是否有证书和 key 文件
    if [[ ! -f "${servercert}" ]] || [[ ! -f "${serverkey}" ]]; then
        # 创建 ca 证书和服务器证书（参考http://www.infradead.org/ocserv/manual.html#heading5）
        certtool --generate-privkey --outfile ca-key.pem
#########################################
        cat << _EOF_ >ca.tmpl
cn = "ocserv VPN"
organization = "ocserv"
serial = 1
expiration_days = 3650
ca
signing_key
cert_signing_key
crl_signing_key
_EOF_
#########################################
        certtool --generate-self-signed --load-privkey ca-key.pem \
        --template ca.tmpl --outfile ca-cert.pem
        certtool --generate-privkey --outfile ${serverkey}
#########################################
        cat << _EOF_ >server.tmpl
cn = "ocserv VPN"
organization = "ocserv"
serial = 2
expiration_days = 3650
signing_key
encryption_key #only if the generated key is an RSA one
tls_www_server
_EOF_
#########################################
        certtool --generate-certificate --load-privkey ${serverkey} \
        --load-ca-certificate ca-cert.pem --load-ca-privkey ca-key.pem \
        --template server.tmpl --outfile ${servercert}
    fi

    # 复制证书
    cp "${servercert}" /etc/pki/ocserv/public/server.crt
    cp "${serverkey}" /etc/pki/ocserv/private/server.key

    # 编辑配置文件
    (echo "${password}"; sleep 1; echo "${password}") | ocpasswd -c "${confdir}/ocpasswd" ${username}

    sed -i 's@auth = "pam"@#auth = "pam"\nauth = "plain[passwd=/etc/ocserv/ocpasswd]"@g' "${confdir}/ocserv.conf"
    sed -i "s/max-same-clients = 2/max-same-clients = ${maxsameclients}/g" "${confdir}/ocserv.conf"
    sed -i "s/max-clients = 16/max-clients = ${maxclients}/g" "${confdir}/ocserv.conf"
    sed -i "s/tcp-port = 443/tcp-port = ${port}/g" "${confdir}/ocserv.conf"
    sed -i "s/udp-port = 443/udp-port = ${port}/g" "${confdir}/ocserv.conf"
    sed -i 's/^ca-cert = /#ca-cert = /g' "${confdir}/ocserv.conf"
    sed -i 's/^cert-user-oid = /#cert-user-oid = /g' "${confdir}/ocserv.conf"
    sed -i "s/default-domain = example.com/#default-domain = example.com/g" "${confdir}/ocserv.conf"
    sed -i "s@#ipv4-network = 192.168.1.0/24@ipv4-network = 172.16.8.0/24@g" "${confdir}/ocserv.conf"
    sed -i "s/#dns = 192.168.1.2/dns = 8.8.4.4\ndns = 8.8.8.8/g" "${confdir}/ocserv.conf"
    sed -i "s@no-route = 192.168.5.0/255.255.255.0@no-route = 192.168.0.0/255.255.0.0\no-route = fd00::/64@g" "${confdir}/ocserv.conf"
    # sed -i "s/cookie-timeout = 300/cookie-timeout = 86400/g" "${confdir}/ocserv.conf"
    sed -i 's/user-profile = profile.xml/#user-profile = profile.xml/g' "${confdir}/ocserv.conf"
}

function ConfigFirewall {
    systemctl start firewalld.service
    echo "Adding firewall ports."
    firewall-cmd --permanent --add-port=${port}/tcp
    firewall-cmd --permanent --add-port=${port}/udp
    echo "Allow firewall to forward."
    firewall-cmd --permanent --add-masquerade
    echo "Reload firewall configure."
    firewall-cmd --reload
}

function ConfigSystem {
    #修改系统
    echo "Enable IP forward."
    sysctl -w net.ipv4.ip_forward=1
    echo net.ipv4.ip_forward = 1 >> "/etc/sysctl.conf"
    systemctl daemon-reload
    echo "Enable firewalld service to start during bootup."
    systemctl enable firewalld.service
    echo "Enable ocserv service to start during bootup."
    systemctl enable ocserv.service
    #开启ocserv服务
    systemctl start ocserv.service
    echo
}

ConfigEnvironmentVariable $@
InstallOcserv
ConfigOcserv
ConfigFirewall
ConfigSystem

exit 0

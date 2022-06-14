#!/bin/bash
basepath=$(dirname $0)
cd ${basepath}
#########################################
function ConfigEnvironmentVariable {
    # 变量设置
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
#########################################
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
#########################################
function ConfigOcserv {
    # 检测是否有证书和 key 文件
    if [[ ! -f "${servercert}" ]] || [[ ! -f "${serverkey}" ]]; then
        # 创建 ca 证书和服务器证书（参考http://www.infradead.org/ocserv/manual.html#heading5）
#---------------------------------------#
        certtool --generate-privkey --outfile ca-key.pem
        cat << _EOF_ >ca.tmpl
cn = "ocservca"
organization = "ocserv"
serial = 1
expiration_days = 3650
ca
signing_key
cert_signing_key
crl_signing_key
_EOF_
        certtool --generate-self-signed --load-privkey ca-key.pem \
        --template ca.tmpl --outfile ca-cert.pem
#---------------------------------------#
        certtool --generate-privkey --outfile server-key.pem
        cat << _EOF_ >server.tmpl
cn = "ocservserver"
organization = "ocserv"
serial = 2
expiration_days = 3650
signing_key
encryption_key #only if the generated key is an RSA one
tls_www_server
_EOF_
        certtool --generate-certificate --load-privkey server-key.pem \
        --load-ca-certificate ca-cert.pem --load-ca-privkey ca-key.pem \
        --template server.tmpl --outfile server-cert.pem
#---------------------------------------#
        certtool --generate-privkey --outfile user-key.pem
cat << _EOF_ >user.tmpl
cn = "ocservuser"
uid = "adminuser"
unit = "ocserv"
expiration_days = 3650
signing_key
tls_www_client
_EOF_
        certtool --generate-certificate --load-privkey user-key.pem \
        --load-ca-certificate ca-cert.pem --load-ca-privkey ca-key.pem \
        --template user.tmpl --outfile user-cert.pem
#---------------------------------------#
        certtool --to-p12 --load-privkey user-key.pem \
        --pkcs-cipher 3des-pkcs12 \
        --load-certificate user-cert.pem \
        --outfile user.p12 --outder
#---------------------------------------#
    fi

    # 复制证书
    cp ./server-cert.pem /etc/pki/ocserv/public/server.crt
    cp ./server-key.pem /etc/pki/ocserv/private/server.key
    cp ./ca-cert.pem /etc/ocserv/ca.pem
    cp ./user.p12 /usr/share/nginx/html/user.p12.bak

    # 编辑配置文件
    (echo "${password}"; sleep 1; echo "${password}") | ocpasswd -c "${confdir}/ocpasswd" ${username}
    # sed -i 's@auth = "pam"@#auth = "pam"@g' "${confdir}/ocserv.conf"
    # sed -i 's@#auth = "plain[passwd=./sample.passwd,otp=./sample.otp]"@auth = "plain[passwd=/etc/ocserv/ocpasswd]"@g' "${confdir}/ocserv.conf"
    sed -i 's@auth = "pam"@#auth = "pam"\nauth = "plain[passwd=/etc/ocserv/ocpasswd]"@g' "${confdir}/ocserv.conf"
    sed -i 's@#enable-auth = "certificate"@enable-auth = "certificate"@g' "${confdir}/ocserv.conf"
    sed -i 's@#ca-cert = /etc/ocserv/ca.pem@ca-cert = /etc/ocserv/ca.pem@g' "${confdir}/ocserv.conf"
    sed -i "s/max-same-clients = 2/max-same-clients = 8/g" "${confdir}/ocserv.conf"
    sed -i "s/max-clients = 16/max-clients = 64/g" "${confdir}/ocserv.conf"
    sed -i "s/tcp-port = 443/tcp-port = ${port}/g" "${confdir}/ocserv.conf"
    sed -i "s/udp-port = 443/udp-port = ${port}/g" "${confdir}/ocserv.conf"
    sed -i "s@#ipv4-network = 192.168.1.0/24@ipv4-network = 172.16.8.0/24@g" "${confdir}/ocserv.conf"
    sed -i "s/#dns = 192.168.1.2/dns = 8.8.4.4\ndns = 8.8.8.8/g" "${confdir}/ocserv.conf"
    sed -i "s@no-route = 192.168.5.0/255.255.255.0@no-route = 192.168.0.0/16\nno-route = fd00::/64@g" "${confdir}/ocserv.conf"
}
#########################################
function ConfigFirewall {
    #设置防火墙
    echo "Adding firewall ports."
    systemctl start firewalld.service
    firewall-cmd --permanent --add-port=26685/tcp
    firewall-cmd --permanent --add-port=${port}/tcp
    firewall-cmd --permanent --add-port=${port}/udp
    firewall-cmd --permanent --add-port=80/tcp
    echo "Allow firewall to forward."
    firewall-cmd --permanent --add-masquerade
    echo "Reload firewall configure."
    firewall-cmd --reload
}
#########################################
function ConfigSystem {
    #修改系统
    echo "Enable firewalld service to start during bootup."
    systemctl enable firewalld.service
    echo "Enable ocserv service to start during bootup."
    systemctl enable ocserv.service
    echo "Enable nginx service to start during bootup."
    systemctl enable nginx.service
    #开启服务
    systemctl start ocserv.service
    systemctl start nginx.service
    echo
}
#########################################
ConfigEnvironmentVariable $@
InstallOcserv
ConfigOcserv
ConfigFirewall
ConfigSystem
exit 0

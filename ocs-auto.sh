#!/bin/bash
basepath=$(dirname $0)
cd ${basepath}&&mkdir ocsauto&&cd ocsauto
#########################################
function ConfigEnvironment {
    #配置目录
    confdir="/etc/ocserv"
    htmldir="/usr/share/nginx/html"
    #随机字符串
    randstr() {
        index=0
        str=""
        for i in {a..z}; do arr[index]=$i; index=$(expr ${index} + 1); done
        for i in {A..Z}; do arr[index]=$i; index=$(expr ${index} + 1); done
        for i in {0..9}; do arr[index]=$i; index=$(expr ${index} + 1); done
        for i in {1..10}; do str="$str${arr[$RANDOM%$index]}"; done
        echo ${str}
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
    echo -n "ocs port: "
    read porttmp1
    add-port1=${porttmp1}
    echo -n "ssh port: "
    read porttmp2
    add-port2=${porttmp2}
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
    dnf makecache -qqy
    #安装ocserv
    dnf install -qqy ocserv gnutls-utils nginx
    dnf clean all -qqy
}
#########################################
function InstallCert {
    #创建证书（参考https://ocserv.openconnect-vpn.net/ocserv.8.html）
    certtool --generate-privkey --outfile ca-key.pem
    cat << _EOF_ >ca.tmpl
cn = "GovernmentCA"
organization = "Government"
serial = 1
expiration_days = -1
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
cn = "GovServer"
dns_name = "${wwwtmp}"
dns_name = "abc.${wwwtmp}"
organization = "Government"
expiration_days = -1
signing_key
encryption_key
tls_www_server
_EOF_
    certtool --generate-certificate --load-privkey server-key.pem \
    --load-ca-certificate ca-cert.pem --load-ca-privkey ca-key.pem \
    --template server.tmpl --outfile server-cert.pem
#---------------------------------------#
    certtool --generate-privkey --outfile user-key.pem
    cat << _EOF_ >user.tmpl
dn = "cn=GovUser,O=Government,UID=${username},OU=ocserv"
expiration_days = -1
signing_key
tls_www_client
_EOF_
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
}
#########################################
function ConfigOcserv {
    #复制证书文件
    cp ./server-cert.pem /etc/pki/ocserv/public/server.crt
    cp ./server-key.pem /etc/pki/ocserv/private/server.key
    cp ./ca-cert.pem /etc/pki/ocserv/cacerts/ca.pem
    cp ./user.p12 ${htmldir}/user.p12.bak
    #添加用户和密码
    (echo "${password}"; sleep 1; echo "${password}") | ocpasswd -c "${confdir}/ocpasswd" ${username}
    #编辑配置文件
    cp ${confdir}/ocserv.conf ${confdir}/ocserv.conf.bak
    sed -i 's@auth = "pam"@#auth = "pam"\nauth = "plain[passwd=/etc/ocserv/ocpasswd]"@g' "${confdir}/ocserv.conf"
    sed -i 's@#enable-auth = "certificate"@enable-auth = "certificate"@g' "${confdir}/ocserv.conf"
    sed -i 's@#ca-cert = /etc/ocserv/ca.pem@ca-cert = /etc/pki/ocserv/cacerts/ca.pem@g' "${confdir}/ocserv.conf"
    sed -i "s/example.com/abc.785118406.xyz/g" "${confdir}/ocserv.conf"
    sed -i "s@#ipv4-network = 192.168.1.0/24@ipv4-network = 172.16.8.0/24@g" "${confdir}/ocserv.conf"
    sed -i "s@#dns = 192.168.1.2@dns = 8.8.4.4\ndns = 8.8.8.8@g" "${confdir}/ocserv.conf"
    sed -i "s@no-route = 192.168.5.0/255.255.255.0@no-route = 192.168.0.0/16@g" "${confdir}/ocserv.conf"
}
#########################################
function ConfigRoute {
    #添加自定义规则
    cat << _EOF_ >>${confdir}/ocserv.conf
no-route = 192.168.0.0/16
_EOF_
}
#########################################
function InstallHtml {
    #添加公益404网页文件
    mv ${htmldir}/index.html ${htmldir}/index.html.bak
    cat << _EOF_ >${htmldir}/index.html
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-cn">
  <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
  </head>
  <body>
        <script src="//cdn.dnpw.org/404/v1.min.js" maincolor="#F00" jumptime="-1" jumptarget="/" tips="404" error="" charset="utf-8"></script>
  </body>
</html>
_EOF_
}
#########################################
function ConfigFirewall {
    #开启防火墙服务
    systemctl -q start firewalld.service
    #添加防火墙允许端口--add-port--remove-port
    firewall-cmd -q --permanent --add-port=${add-port2}/tcp
    firewall-cmd -q --permanent --add-port=${add-port1}/tcp
    firewall-cmd -q --permanent --add-port=${add-port1}/udp
    firewall-cmd -q --permanent --add-port=80/tcp
    #开启伪装IP
    firewall-cmd -q --permanent --add-masquerade
    #重新加载防火墙
    firewall-cmd -q --reload
}
#########################################
function ConfigSystem {
    #添加开机启动
    systemctl -q enable firewalld.service
    systemctl -q enable ocserv.service
    systemctl -q enable nginx.service
    #开启服务
    systemctl -q start ocserv.service
    systemctl -q start nginx.service
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
#ConfigRoute
#echo "ConfigRoute Successful!"
InstallHtml
echo "InstallHtml Successful!"
ConfigFirewall
echo "ConfigFirewall Successful!"
ConfigSystem
echo "ConfigSystem Successful!"
exit

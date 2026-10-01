#!/bin/bash
basepath=$(dirname $0)
cd ${basepath}&&mkdir -p ocsauto&&cd ocsauto
fileurl=https://raw.githubusercontent.com/ZhangShuxiang/ocserv-auto/master/ocs/
file1="/etc/yum.repos.d/"
file2="/etc/ocserv/"
file3="/etc/nginx/"
file4="/usr/share/nginx/html/"
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
    echo -n "ssh port: "
    read porttmp2
    aadd_port2=${porttmp2}
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
    curl -o ${file1}nginx.repo ${fileurl}nginx.repo
    dnf makecache -qqy
    #安装ocserv
    dnf install -qqy ocserv nginx gnutls-utils certbot firewalld
    dnf clean all -qqy
}
#########################################
function InstallCert {
    #创建根证书（参考https://ocserv.openconnect-vpn.net/ocserv.8.html）
    certtool --generate-privkey --outfile ca-key.pem
    curl -O ${fileurl}ca.tmpl
    certtool --generate-self-signed --load-privkey ca-key.pem \
    --template ca.tmpl --outfile ca-cert.pem
#---创建服务器证书------------------------#
    certtool --generate-privkey --outfile server-key.pem
    curl -O ${fileurl}server.tmpl
    sed -i "s@\[WWWURL\]@${wwwtmp}@g" server.tmpl
    sed -i "s@\[WWWUSER\]@${username}@g" server.tmpl
    certtool --generate-certificate --load-privkey server-key.pem \
    --load-ca-certificate ca-cert.pem --load-ca-privkey ca-key.pem \
    --template server.tmpl --outfile server-cert.pem
#---------------------------------------#
    certtool --generate-privkey --outfile user-key.pem
    curl -O ${fileurl}user.tmpl
    sed -i "s@\[WWWUSER\]@${username}@g" user.tmpl
    certtool --generate-certificate --load-privkey user-key.pem \
    --load-ca-certificate ca-cert.pem --load-ca-privkey ca-key.pem \
    --template user.tmpl --outfile user-cert.pem
}
#########################################
function InstallUserCert {
    #导出用户证书
    (echo "${password}"; sleep 2; echo "${password}") | \
    certtool --to-p12 --load-privkey user-key.pem \
    --pkcs-cipher 3des-pkcs12 \
    --load-certificate user-cert.pem \
    --outfile user.p12 --outder
    #复制证书文件
    cp ./user.p12 ${file4}user.p12.bak
    mkdir -p /etc/pki/ocs
    cp -a . /etc/pki/ocs/
    #/etc/pki/ocs/server-cert.pem
    #/etc/pki/ocs/server-key.pem
    #/etc/pki/ocs/ca-cert.pem
}
#########################################
function ConfigOcserv {
    #添加用户和密码
    (echo "${password}"; sleep 1; echo "${password}") | ocpasswd -c "${file2}ocpasswd" ${username}
    #编辑配置文件
    mv ${file2}ocserv.conf ${file2}ocserv.conf.bak
    curl -o ${file2}ocserv.conf ${fileurl}ocserv.conf
    sed -i "s@\[WWWURL\]@${wwwtmp}@g" ${file2}ocserv.conf
    sed -i "s@\[WWWUSER\]@${username}@g" ${file2}ocserv.conf
}
#########################################
function ConfigNginx {
    #编辑配置文件
    mv ${file3}nginx.conf ${file3}nginx.conf.bak
    curl -o ${file3}nginx.conf ${fileurl}nginx.conf
    mv ${file4}index.html ${file4}index.html.bak
    curl -o ${file4}index.html ${fileurl}index.html
    sed -i "s@\[WWWURL\]@${wwwtmp}@g" ${file3}nginx.conf
    sed -i "s@\[WWWUSER\]@${username}@g" ${file3}nginx.conf
}
#########################################
function ConfigRoute {
    #添加自定义规则
}
#########################################

#########################################
function ConfigFirewall {
    #编辑系统文件
    sysctl -w net.ipv4.ip_forward=1 >> /etc/sysctl.conf
    sysctl -w net.ipv6.conf.all.forwarding=1 >> /etc/sysctl.conf
    #开启防火墙服务
    systemctl -q start firewalld.service
    #添加防火墙允许端口--add-port--remove-port
    firewall-cmd -q --permanent --add-port=${aadd_port2}/tcp
    firewall-cmd -q --permanent --add-port=443/tcp
    firewall-cmd -q --permanent --add-port=80/tcp
    #开启伪装IP
    firewall-cmd -q --permanent --add-masquerade
    firewall-cmd -q --permanent --add-rich-rule='rule family=ipv6 masquerade'
    #重新加载防火墙
    firewall-cmd -q --reload
}
#########################################
function ConfigSystem {
    # 允许 nginx 连接后端网络端口（stream proxy_pass 需要）
    #setsebool -P httpd_can_network_connect 1
    #setsebool -P httpd_can_network_relay  1
    # 让 ocserv 能读证书
    #semanage fcontext -a -t cert_t "/etc/pki/ocs(/.*)?"
    #restorecon -Rv /etc/pki/ocs
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
ConfigNginx
echo "ConfigNginx Successful!"
#ConfigRoute
#echo "ConfigRoute Successful!"
#InstallHtml
#echo "InstallHtml Successful!"
ConfigFirewall
echo "ConfigFirewall Successful!"
ConfigSystem
echo "ConfigSystem Successful!"
exit

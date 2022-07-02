#!/bin/bash
#curl -LO https://github.com/ZhangShuxiang/ocserv-auto/raw/master/ysgm.sh&&chmod +x ysgm.sh&&sudo sh ysgm.sh
#---------------------------------------------------
utsc(){
sudo -E sed -e 's|^mirrorlist=|#mirrorlist=|g' \
    -e 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.ustc.edu.cn/rocky|g' \
    -i.bak \
    /etc/yum.repos.d/Rocky-AppStream.repo \
    /etc/yum.repos.d/Rocky-BaseOS.repo \
    /etc/yum.repos.d/Rocky-Extras.repo \
    /etc/yum.repos.d/Rocky-PowerTools.repo
}
#---------------------------------------------------
repo(){
sudo -E cat << _EOF_ >/etc/yum.repos.d/mongodb-org-5.0.repo
[mongodb-org-5.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/5.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-5.0.asc
_EOF_
}
#---------------------------------------------------
$1
repo
sudo -E dnf makecache -qy
sudo -E dnf install -qy epel-release
sudo -E dnf makecache -qy
sudo -E dnf install -qy java-17-openjdk.x86_64
sudo -E dnf install -qy mongodb-org
exit

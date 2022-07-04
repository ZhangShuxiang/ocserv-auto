#!/bin/bash
#---------------------------------------------------
#curl -LO https://github.com/ZhangShuxiang/ocserv-auto/raw/master/ysgm.sh&&sudo chmod +x ysgm.sh&&sudo sh ysgm.sh
#(*.yuanshen.com)
#(*.hoyoverse.com)
#(*.mihoyo.com)
#要用root身份运行(sudo su)
#---------------------------------------------------
utsc(){
sed -e 's|^mirrorlist=|#mirrorlist=|g' \
    -e 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.ustc.edu.cn/rocky|g' \
    -i.bak \
    /etc/yum.repos.d/Rocky-AppStream.repo \
    /etc/yum.repos.d/Rocky-BaseOS.repo \
    /etc/yum.repos.d/Rocky-Extras.repo \
    /etc/yum.repos.d/Rocky-PowerTools.repo
}
#---------------------------------------------------
repo(){
cat << _EOF_ >/etc/yum.repos.d/mongodb-org-5.0.repo
[mongodb-org-5.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/5.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-5.0.asc
_EOF_
}
#---------------------------------------------------
install(){
dnf makecache -qy
dnf install -qy git java-17-openjdk.x86_64 mongodb-org
}
#---------------------------------------------------
firewall(){
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=22102/tcp
}
#---------------------------------------------------
Grasscutter(){
cd $HOME
git clone https://github.com/Koko-boya/Grasscutter_Resources.git
git clone https://github.com/Grasscutters/Grasscutter.git
ln -sf $HOME/Grasscutter_Resources/Resources $HOME/Grasscutter/resources
cd Grasscutter && chmod +x gradlew && ./gradlew jar
java -jar grasscutter*.jar
java -jar grasscutter*.jar -handbook
}
#====================================================
#utsc
repo
install
firewall
#Grasscutter
exit

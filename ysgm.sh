#!/bin/bash
#---------------------------------------------------
#要用root身份运行,先切换到root用户(sudo su)
#curl -LO https://github.com/ZhangShuxiang/ocserv-auto/raw/master/ysgm.sh&&chmod +x ysgm.sh&&sh ysgm.sh
#(*.yuanshen.com)(*.hoyoverse.com)(*.mihoyo.com)>>serverip
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
dnf install -qy git tmux java-17-openjdk.x86_64 mongodb-org
}
#---------------------------------------------------
firewall(){
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=22102/tcp
}
#重启一下--------------------------------------------
Grasscutter(){
cd $HOME
git clone https://github.com/Koko-boya/Grasscutter_Resources.git
git clone https://github.com/Grasscutters/Grasscutter.git
ln -sf $HOME/Grasscutter_Resources/Resources $HOME/Grasscutter/resources
cd Grasscutter && chmod +x gradlew &&bash ./gradlew jar
#新建会话tmux new -s ys#退出会话tmux detach#查看会话tmux ls
#进入会话tmux attach -t ys#结束会话tmux kill-session -t ys#切换会话tmux switch -t ys
#控制台Ctrl+b 帮助？
#java -jar grasscutter*.jar -handbook
#修改一下配置vi config.json
#java -jar grasscutter*.jar
}
#====================================================
utsc
repo
install
firewall
#Grasscutter
exit

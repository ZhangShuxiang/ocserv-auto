aria2c --allow-overwrite -d C:\Users\lenovo\.aria2 https://raw.githubusercontent.com/P3TERX/aria2.conf/master/dht.dat
aria2c --allow-overwrite -d C:\Users\lenovo\.aria2 https://raw.githubusercontent.com/P3TERX/aria2.conf/master/dht6.dat
aria2c --allow-overwrite -d C:\Users\lenovo\.aria2 https://raw.githubusercontent.com/ZhangShuxiang/ocserv-auto/master/aria2.conf
aria2c --allow-overwrite -d C:\Users\lenovo\.aria2 https://trackerslist.com/all_aria2.txt
set /p="bt-tracker="<nul>>aria2.conf 
type all_aria2.txt>>aria2.conf

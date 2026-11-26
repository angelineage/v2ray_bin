#!/bin/sh

# shadowsocks script for AM380 merlin firmware
# by sadog (sadoneli@gmail.com) from koolshare.cn

eval `dbus export ss`
source /koolshare/scripts/base.sh
source helper.sh
# Variable definitions
alias echo_date='echo 【$(TZ=UTC-8 date -R +%Y年%m月%d日\ %X)】:'
dbus set ss_basic_version_local=`cat /koolshare/ss/version`
LOG_FILE=/tmp/syslog.log
V2RAY_CONFIG_FILE_TMP="/tmp/v2ray_tmp.json"
V2RAY_CONFIG_FILE="/koolshare/ss/v2ray.json"
LOCK_FILE=/var/lock/koolss.lock
DNSF_PORT=7913
DNSC_PORT=53
ISP_DNS1=$(nvram get wan0_dns|sed 's/ /\n/g'|grep -v 0.0.0.0|grep -v 127.0.0.1|sed -n 1p)
ISP_DNS2=$(nvram get wan0_dns|sed 's/ /\n/g'|grep -v 0.0.0.0|grep -v 127.0.0.1|sed -n 2p)
IFIP_DNS1=`echo $ISP_DNS1|grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:"`
IFIP_DNS2=`echo $ISP_DNS2|grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:"`
gfw_on=`dbus list ss_acl_mode_|cut -d "=" -f 2 | grep -E "1"`
chn_on=`dbus list ss_acl_mode_|cut -d "=" -f 2 | grep -E "2|3|4"`
all_on=`dbus list ss_acl_mode_|cut -d "=" -f 2 | grep -E "5"`
lan_ipaddr=$(nvram get lan_ipaddr)
ip_prefix_hex=`nvram get lan_ipaddr | awk -F "." '{printf ("0x%02x", $1)} {printf ("%02x", $2)} {printf ("%02x", $3)} {printf ("00/0xffffff00\n")}'`
[ "$ss_basic_mode" == "4" ] && ss_basic_mode=3
game_on=`dbus list ss_acl_mode|cut -d "=" -f 2 | grep 3`
[ -n "$game_on" ] || [ "$ss_basic_mode" == "3" ] || [ "$ss_basic_udp_sync" == "1" ] && mangle=1
ss_basic_password=`echo $ss_basic_password|base64_decode`

SS2022="N"
case $ss_basic_method in
	2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) SS2022="Y";;
esac

# slimmed: Xray-only node types
[ -z "$ss_basic_type" ] && {
	if [ -n "$ss_basic_trojan_binary" ];then
		ss_basic_type="4"
	else
		ss_basic_type="3"
	fi
}
case "$ss_basic_type" in
	3|4) ;;
	*) ss_basic_type="3" ;;
esac
[ "$ss_basic_type" == "4" ] && echo "$ss_basic_trojan_binary" | grep -qv "^Trojan" && ss_basic_type="3"

get_lan_cidr(){
	netmask=`nvram get lan_netmask`
	local x=${netmask##*255.}
	set -- 0^^^128^192^224^240^248^252^254^ $(( (${#netmask} - ${#x})*2 )) ${x%%.*}
	x=${1%%$3*}
	suffix=$(( $2 + (${#x}/4) ))
	#prefix=`nvram get lan_ipaddr | cut -d "." -f1,2,3`
	echo $lan_ipaddr/$suffix
}

get_wan0_cidr(){
	netmask=`nvram get wan0_netmask`
	local x=${netmask##*255.}
	set -- 0^^^128^192^224^240^248^252^254^ $(( (${#netmask} - ${#x})*2 )) ${x%%.*}
	x=${1%%$3*}
	suffix=$(( $2 + (${#x}/4) ))
	prefix=`nvram get wan0_ipaddr`
	if [ -n "$prefix" -a -n "$netmask" ];then
		echo $prefix/$suffix
	else
		echo ""
	fi
}

get_server_resolver(){
	if [ "$ss_basic_server_resolver" == "1" ];then
		if [ -n "$IFIP_DNS1" ];then
			RESOLVER="$ISP_DNS1"
		else
			RESOLVER="114.114.114.114"
		fi
	fi
	[ "$ss_basic_server_resolver" == "2" ] && RESOLVER="223.5.5.5"
	[ "$ss_basic_server_resolver" == "3" ] && RESOLVER="223.6.6.6"
	[ "$ss_basic_server_resolver" == "4" ] && RESOLVER="114.114.114.114"
	[ "$ss_basic_server_resolver" == "5" ] && RESOLVER="114.114.115.115"
	[ "$ss_basic_server_resolver" == "6" ] && RESOLVER="1.2.4.8"
	[ "$ss_basic_server_resolver" == "7" ] && RESOLVER="210.2.4.8"
	[ "$ss_basic_server_resolver" == "8" ] && RESOLVER="117.50.11.11"
	[ "$ss_basic_server_resolver" == "9" ] && RESOLVER="117.50.22.22"
	[ "$ss_basic_server_resolver" == "10" ] && RESOLVER="180.76.76.76"
	[ "$ss_basic_server_resolver" == "11" ] && RESOLVER="119.29.29.29"
	[ "$ss_basic_server_resolver" == "13" ] && RESOLVER="8.8.8.8"
	[ "$ss_basic_server_resolver" == "12" ] && {
		[ -n "$ss_basic_server_resolver_user" ] && RESOLVER="$ss_basic_server_resolver_user" || RESOLVER="114.114.114.114"
	}
	echo $RESOLVER
}

set_lock(){
	exec 1000>"$LOCK_FILE"
	flock -x 1000
}

unset_lock(){
	flock -u 1000
	rm -rf "$LOCK_FILE"
}

close_in_five(){
	echo_date "插件将在5秒后自动关闭！！"
	sleep 1
	echo_date 5
	sleep 1
	echo_date 4
	sleep 1
	echo_date 3
	sleep 1
	echo_date 2
	sleep 1
	echo_date 1
	sleep 1
	echo_date 0
	dbus set ss_basic_enable="0"
	disable_ss >/dev/null
	echo_date "插件已关闭！！"
	echo_date ======================= 梅林固件 - 【科学上网】 ========================
	unset_lock
	exit
}

# ================================= ss stop ===============================
restore_conf(){
	echo_date 删除ss相关的名单配置文件.
	rm -rf /jffs/configs/dnsmasq.d/gfwlist.conf
	rm -rf /jffs/configs/dnsmasq.d/cdn.conf
	rm -rf /jffs/configs/dnsmasq.d/custom.conf
	rm -rf /jffs/configs/dnsmasq.d/wblist.conf
	rm -rf /jffs/configs/dnsmasq.d/ss_host.conf
	rm -rf /jffs/configs/dnsmasq.d/ss_server.conf
	rm -rf /jffs/configs/dnsmasq.conf.add
	rm -rf /jffs/scripts/dnsmasq.postconf
	rm -rf /tmp/sscdn.conf
	rm -rf /tmp/custom.conf
	rm -rf /tmp/wblist.conf
	rm -rf /tmp/ss_host.conf
}

kill_process(){
	xray_process=`pidof xray`
	if [ -n "$xray_process" ];then 
		echo_date 关闭XRay进程...
		# 有时候killall杀不了Xray进程，所以用不同方式杀两次
		killall xray >/dev/null 2>&1
		kill -9 "$xray_process" >/dev/null 2>&1
	fi
	ssredir=`pidof ss-redir`




	rssredir=`pidof rss-redir`
	sslocal=`ps | grep -w ss-local | grep -v "grep" | grep -w "23456" | awk '{print $1}'`
	if [ -n "$sslocal" ];then 
		echo_date 关闭ss-local进程:23456端口...
		kill $sslocal  >/dev/null 2>&1
	fi

	ssrlocal=`ps | grep -w rss-local | grep -v "grep" | grep -w "23456" | awk '{print $1}'`
	if [ -n "$ssrlocal" ];then 
		echo_date 关闭ssr-local进程:23456端口...
		kill $ssrlocal  >/dev/null 2>&1
	fi
	sstunnel=`pidof ss-tunnel`
	if [ -n "$sstunnel" ];then 
		echo_date 关闭ss-tunnel进程...
		killall ss-tunnel >/dev/null 2>&1
	fi
	rsstunnel=`pidof rss-tunnel`
	if [ -n "$rsstunnel" ];then 
		echo_date 关闭rss-tunnel进程...
		killall rss-tunnel >/dev/null 2>&1
	fi
	chinadns_process=`pidof chinadns`
	if [ -n "$chinadns_process" ];then 
		echo_date 关闭chinadns2进程...
		killall chinadns >/dev/null 2>&1
	fi
	chinadns1_process=`pidof chinadns1`
	if [ -n "$chinadns1_process" ];then 
		echo_date 关闭chinadns1进程...
		killall chinadns1 >/dev/null 2>&1
	fi
	chinadnsNG_process=$(pidof chinadns-ng)
	if [ -n "$chinadnsNG_process" ]; then
		echo_date 关闭chinadns-ng进程...
		killall chinadns-ng >/dev/null 2>&1
	fi
	cdns_process=`pidof cdns`
	if [ -n "$cdns_process" ];then 
		echo_date 关闭cdns进程...
		killall cdns >/dev/null 2>&1
	fi
	dns2socks_process=`pidof dns2socks`
	if [ -n "$dns2socks_process" ];then 
		echo_date 关闭dns2socks进程...
		killall dns2socks >/dev/null 2>&1
	fi
	pdu_process=`pidof pdu`
	if [ -n "$pdu_process" ];then 
		echo_date 关闭pdu进程...
		kill -9 $pdu >/dev/null 2>&1
	fi
	client_linux_arm5_process=`pidof client_linux_arm5`
	haproxy_process=`pidof haproxy`
	speederv1_process=`pidof speederv1`
	speederv2_process=`pidof speederv2`
	ud2raw_process=`pidof udp2raw`
	https_dns_proxy_process=`pidof https_dns_proxy`
	if [ -n "$https_dns_proxy_process" ];then 
		echo_date 关闭https_dns_proxy进程...
		killall https_dns_proxy >/dev/null 2>&1
	fi
	haveged_process=`pidof haveged`
}

# ================================= ss prestart ===========================
ss_pre_start(){
	echo_date ---------------------- 【科学上网 Xray】 启动前检查 ----------------------
	# 负载均衡已移除；清理旧版残留的 haproxy 进程
	[ -n "$(pidof haproxy)" ] && killall haproxy >/dev/null 2>&1
}
# ================================= ss start ==============================

resolv_server_ip(){
	if [ "$ss_basic_type" == "3" ] && [ "$ss_basic_v2ray_use_json" == "1" ];then
		#echo_date "你使用的v2ray json配置，请自行将v2ray服务器ip地址添加到IP/CIDR白名单！"
		return 1
	else
		IFIP=`echo $ss_basic_server|grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:"`
		if [ -z "$IFIP" ];then
			# 服务器地址强制由114解析，以免插件还未开始工作而导致解析失败
			echo "server=/$ss_basic_server/$(get_server_resolver)#53" > /jffs/configs/dnsmasq.d/ss_server.conf
			echo_date 尝试解析节点服务器的ip地址，DNS：$(get_server_resolver)
			server_ip=`nslookup "$ss_basic_server" $(get_server_resolver) | sed '1,4d' | awk '{print $3}' | grep -v :|awk 'NR==1{print}'`
			if [ "$?" == "0" ];then
				server_ip=`echo $server_ip|grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:"`
			else
				echo_date 节点服务器域名解析失败！
				echo_date 尝试用resolveip方式解析，DNS：系统
				server_ip=`resolveip -4 -t 2 $ss_basic_server|awk 'NR==1{print}'`
				if [ "$?" == "0" ];then
			    	server_ip=`echo $server_ip|grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:"`
				fi
			fi

			if [ -n "$server_ip" ];then
				echo_date 节点服务器的ip地址解析成功：$server_ip
				# 解析并记录一次ip，方便插件触发重启设定工作
				echo "address=/$ss_basic_server/$server_ip" > /tmp/ss_host.conf
				# 去掉此功能，以免ip发生变更导致问题，或者影响域名对应的其它二级域名
				#ln -sf /tmp/ss_host.conf /jffs/configs/dnsmasq.d/ss_host.conf
				ss_basic_server="$server_ip"
				ss_basic_server_ip="$server_ip"
				dbus set ss_basic_server_ip="$server_ip"
			else
				dbus remove ss_basic_server_ip
				echo_date 节点服务器的ip地址解析失败，将由ss-redir自己解析.
			fi
		else
			ss_basic_server_ip="$ss_basic_server"
			dbus set ss_basic_server_ip=$ss_basic_server
			echo_date 检测到你的节点服务器已经是IP格式：$ss_basic_server,跳过解析... 
		fi
	fi
}

# create shadowsocks config file...

get_type_name() {
	case "$1" in
		3) echo "xray" ;;
		4) echo "trojan" ;;
		*) echo "xray" ;;
	esac
}

get_dns_name() {
	case "$1" in
		1)
			echo "cdns"
		;;
		2)
			echo "chinadns2"
		;;
		3)
			echo "dns2socks"
		;;
		4)
			echo "dns2socks (ss-tunnel removed)"
		;;
		5)
			echo "chinadns1"
		;;
		6)
			echo "https_dns_proxy"
		;;
		7)
			echo "v2ray dns"
		;;
		8)
			echo "直连"
		;;
		10)
			echo "ChinaDNS-NG"
		;;
	esac
}


start_dns(){
	if [ "$ss_basic_mode" == "6" -a "$ss_foreign_dns" != "8" ];then
		ss_foreign_dns="8"
		dbus set ss_foreign_dns="8"
	fi
	
	# Start ss-local
	
	# Start cdns
	if [ "$ss_foreign_dns" == "1" ];then
		echo_date 开启cdns，用于dns解析...
		cdns -c /koolshare/ss/rules/cdns.json > /dev/null 2>&1 &
	fi

	# Start chinadns2
	if [ "$ss_foreign_dns" == "2" ];then
		echo_date 开启chinadns2，用于dns解析...
		clinet_ip="114.114.114.114"
		public_ip=`nvram get wan0_realip_ip`
		if [ -z "$public_ip" ];then
			# 路由公网ip为空则获取
			public_ip=`curl --connect-timeout 1 --retry 0 --max-time 1 -sk 'http://members.3322.org/dyndns/getip'`
			if [ "$?" == "0" ] && [ -n "$public_ip" ];then
				# 获取成功
				echo_date 你的公网ip地址是：$public_ip
				dbus set ss_basic_publicip="$public_ip"
				clinet_ip="$public_ip"
			else
				# 获取失败，则自动为114
				[ -n "$ss_basic_publicip" ] && clinet_ip="$ss_basic_publicip"
			fi
		else
			# 获取失败，则自动为114
			clinet_ip="$public_ip"
		fi

		if [ -n "$ss_basic_server_ip" ];then
			# 用chnroute去判断SS服务器在国内还是在国外
			ipset test chnroute $ss_basic_server_ip > /dev/null 2>&1
			if [ "$?" != "0" ];then
				# ss服务器是国外IP
				ss_real_server_ip="$ss_basic_server_ip"
			else
				# ss服务器是国内ip （可能用了国内中转，那么用谷歌dns ip地址去作为国外edns标签）
				ss_real_server_ip="8.8.8.8"
			fi
		else
			# ss服务器可能是域名且没有正确解析
			ss_real_server_ip="8.8.8.8"
		fi
		chinadns -p $DNSF_PORT -s $ss_chinadns_user -e $clinet_ip,$ss_real_server_ip -c /koolshare/ss/rules/chnroute.txt >/dev/null 2>&1 &
	fi
	
	# Start DNS2SOCKS (default) - 原生单上游
	if [ "$ss_foreign_dns" == "3" ] || [ -z "$ss_foreign_dns" ];then
		[ -z "$ss_foreign_dns" ] && dbus set ss_foreign_dns="3"
		echo_date 开启dns2socks，用于dns解析...
		dns2socks 127.0.0.1:23456 "$ss_dns2socks_user" 127.0.0.1:$DNSF_PORT > /dev/null 2>&1 &
	fi
	
	# ss-tunnel 已移除：Xray 不支持该方案，统一退回 dns2socks
	if [ "$ss_foreign_dns" == "4" ];then
		echo_date Xray不支持ss-tunnel，自动切换到dns2socks...
		dbus set ss_foreign_dns=3
		dns2socks 127.0.0.1:23456 "$ss_dns2socks_user" 127.0.0.1:$DNSF_PORT > /dev/null 2>&1 &
	fi
	
	#start chinadns1
	if [ "$ss_foreign_dns" == "5" ]; then
		echo_date 开启dns2socks，用于chinadns1上游...
		dns2socks 127.0.0.1:23456 "$ss_chinadns1_user" 127.0.0.1:1055 >/dev/null 2>&1 &
		echo_date 开启chinadns1，用于dns解析...
		chinadns1 -p $DNSF_PORT -s $CDN,127.0.0.1:1055 -d -c /koolshare/ss/rules/chnroute.txt >/dev/null 2>&1 &
	fi

	#start chinadns-ng（国外上游可配置，默认 8.8.8.8:53 经 Xray socks 代理）
	if [ "$ss_foreign_dns" == "10" ]; then
		[ -z "$ss_chinadnsng_user" ] && ss_chinadnsng_user="8.8.8.8:53"
		# 国外上游：经 dns2socks 走代理（默认），支持在输入框填 ip:port
		NG_UPSTREAM="${ss_chinadnsng_user}"
		echo_date "开启dns2socks，用于 chinadns-ng 国外上游 ${NG_UPSTREAM} ..."
		dns2socks 127.0.0.1:23456 "$ss_chinadnsng_user" 127.0.0.1:1055 >/dev/null 2>&1 &
		sed -e '/^server=/d' -e 's/ipset=\/.//g' -e 's/\/gfwlist//g' /koolshare/ss/rules/gfwlist.conf > /tmp/gfwlist.txt
		# --- 动态拼装 chinadns-ng 参数 ---
		NG_OPTS=""
		# 屏蔽 IPv6 (AAAA)：默认开启，-N
		[ "$ss_chinadnsng_noipv6" != "0" ] && NG_OPTS="$NG_OPTS -N"
		# 国内域名优先（chnlist-first）：默认开启，-M
		[ "$ss_chinadnsng_chnfirst" != "0" ] && NG_OPTS="$NG_OPTS -M"
		# fair 模式
		[ "$ss_chinadnsng_fair" == "1" ] && NG_OPTS="$NG_OPTS -f"
		# 复用端口
		[ "$ss_chinadnsng_reuseport" == "1" ] && NG_OPTS="$NG_OPTS -r"
		# 无 IP 应答视为国内
		[ "$ss_chinadnsng_noip" == "1" ] && NG_OPTS="$NG_OPTS -n"
		# 详细日志
		[ "$ss_chinadnsng_verbose" == "1" ] && NG_OPTS="$NG_OPTS -v"
		# 上游超时秒数 -o（1-60）
		NG_TIMEOUT="${ss_chinadnsng_timeout:-5}"
		case "$NG_TIMEOUT" in ''|*[!0-9]*) NG_TIMEOUT=5;; esac
		[ "$NG_TIMEOUT" -lt 1 ] 2>/dev/null && NG_TIMEOUT=1
		[ "$NG_TIMEOUT" -gt 60 ] 2>/dev/null && NG_TIMEOUT=60
		NG_OPTS="$NG_OPTS -o $NG_TIMEOUT"
		# 重复次数 -p（1-10）
		NG_REPEAT="${ss_chinadnsng_repeat:-1}"
		case "$NG_REPEAT" in ''|*[!0-9]*) NG_REPEAT=1;; esac
		[ "$NG_REPEAT" -lt 1 ] 2>/dev/null && NG_REPEAT=1
		[ "$NG_REPEAT" -gt 10 ] 2>/dev/null && NG_REPEAT=10
		NG_OPTS="$NG_OPTS -p $NG_REPEAT"
		echo_date "启动 chinadns-ng：国内DNS ${CDN}#${DNSC_PORT} | 国外DNS 127.0.0.1#1055(${NG_UPSTREAM}) | 参数:${NG_OPTS}"
		chinadns-ng ${NG_OPTS} -l ${DNSF_PORT} -c ${CDN}#${DNSC_PORT} -t 127.0.0.1#1055 -g /tmp/gfwlist.txt -m /koolshare/ss/rules/cdn.txt >/dev/null 2>&1 &
	fi

	#start DoH (https_dns_proxy) - 支持主/备双服务器 + 可走代理
	if [ "$ss_foreign_dns" == "6" ];then
		echo_date "开启DoH(https_dns_proxy)，用于dns解析..."
		# EDNS Client Subnet 标签
		if [ -n "$ss_basic_server_ip" ];then
			ipset test chnroute $ss_basic_server_ip > /dev/null 2>&1
			if [ "$?" != "0" ];then ss_real_server_ip="$ss_basic_server_ip"; else ss_real_server_ip="8.8.8.8"; fi
		else
			ss_real_server_ip="8.8.8.8"
		fi
		# DoH URL：优先用输入的，否则按预设回退
		DOH_PRIMARY="${ss_doh_primary}"
		if [ -z "$DOH_PRIMARY" ];then
			case "${ss_doh_preset}" in
				google)   DOH_PRIMARY="https://dns.google/resolve?";;
				quad9)    DOH_PRIMARY="https://dns.quad9.net:5053/dns-query?ct=application/dns-json&";;
				adguard)  DOH_PRIMARY="https://dns.adguard-dns.com/resolve?";;
				*)        DOH_PRIMARY="https://cloudflare-dns.com/dns-query?ct=application/dns-json&";;
			esac
		fi
		# 是否走 socks 代理
		DOH_PROXY_OPT=""
		[ "$ss_doh_via_proxy" != "0" ] && DOH_PROXY_OPT="-t socks5h://127.0.0.1:23456"
		# ECS 选项
		DOH_ECS_OPT=""
		[ "$ss_doh_ecs" == "1" ] && DOH_ECS_OPT="-e $ss_real_server_ip/16"
		DOH_BOOT="-b 8.8.8.8,1.1.1.1,8.8.4.4,1.0.0.1"
		echo_date "DoH 服务器：${DOH_PRIMARY}"
		https_dns_proxy -u nobody -p 7913 $DOH_BOOT $DOH_ECS_OPT -r "$DOH_PRIMARY" $DOH_PROXY_OPT -d >/dev/null 2>&1
	fi
	
	# start v2ray DNSF_PORT
	if [ "$ss_foreign_dns" == "7" ];then
		if [ "$ss_basic_type" == "3" ];then
			return 0
		else
			echo_date $(get_type_name $ss_basic_type)下不支持v2ray dns，改用dns2socks！
			dbus set ss_foreign_dns=3
			echo_date 开启dns2socks，用于dns解析...
			dns2socks 127.0.0.1:23456 "$ss_dns2socks_user" 127.0.0.1:$DNSF_PORT > /dev/null 2>&1 &
		fi
	fi

	# direct
	if [ "$ss_foreign_dns" == "8" ];then
		if [ "$ss_basic_mode" == "6" ];then
			echo_date 回国模式，国外dns采用直连方案。
		else
			echo_date 非回国模式，国外dns不能使用，自动切换到dns2socks方案。
			dbus set ss_foreign_dns=3
			echo_date 开启dns2socks，用于dns解析...
			dns2socks 127.0.0.1:23456 "$ss_dns2socks_user" 127.0.0.1:$DNSF_PORT > /dev/null 2>&1 &
		fi
	fi
	
}
#--------------------------------------------------------------------------------------

detect_domain(){
	domain1=`echo $1|grep -E "^https://|^http://|www|/"`
	domain2=`echo $1|grep -E "\."`
	if [ -n "$domain1" ] || [ -z "$domain2" ];then
		return 1
	else
		return 0
	fi
}

create_dnsmasq_conf(){
	if [ "$ss_dns_china" == "1" ];then
		if [ "$ss_basic_mode" == "6" ];then
			# 使用回国模式的时候，ISP dns是国外的，所以这里直接用114取代
			CDN="114.114.114.114"
		else
			if [ -n "$IFIP_DNS1" ];then
				# 用chnroute去判断运营商DNS是否为局域网(国外)ip地址，有些二级路由的是局域网ip地址，会被ChinaDNS 判断为国外dns服务器，这个时候用114取代之
				ipset test chnroute $IFIP_DNS1 > /dev/null 2>&1
				if [ "$?" != "0" ];then
					# 运营商DNS：ISP_DNS1是局域网(国外)ip
					CDN="114.114.114.114"
				else
					# 运营商DNS：ISP_DNS1是国内ip
					CDN="$ISP_DNS1"
				fi
			else
				# 运营商DNS：ISP_DNS1不是ip格式，用114取代之
				CDN="114.114.114.114"
			fi
		fi
	fi
	[ "$ss_dns_china" == "2" ] && CDN="223.5.5.5"
	[ "$ss_dns_china" == "3" ] && CDN="223.6.6.6"
	[ "$ss_dns_china" == "4" ] && CDN="114.114.114.114"
	[ "$ss_dns_china" == "5" ] && CDN="114.114.115.115"
	[ "$ss_dns_china" == "6" ] && CDN="1.2.4.8"
	[ "$ss_dns_china" == "7" ] && CDN="210.2.4.8"
	[ "$ss_dns_china" == "8" ] && CDN="117.50.11.11"
	[ "$ss_dns_china" == "9" ] && CDN="117.50.22.22"
	[ "$ss_dns_china" == "10" ] && CDN="180.76.76.76"
	[ "$ss_dns_china" == "11" ] && CDN="119.29.29.29"
	[ "$ss_dns_china" == "12" ] && {
		[ -n "$ss_dns_china_user" ] && CDN="$ss_dns_china_user" || CDN="114.114.114.114"
	}
	# delete pre settings
	rm -rf /tmp/sscdn.conf
	rm -rf /tmp/custom.conf
	rm -rf /tmp/wblist.conf
	rm -rf /tmp/gfwlist.conf
	rm -rf /tmp/gfwlist.txt
	rm -rf /jffs/configs/dnsmasq.d/custom.conf
	rm -rf /jffs/configs/dnsmasq.d/wblist.conf
	rm -rf /jffs/configs/dnsmasq.d/cdn.conf
	rm -rf /jffs/configs/dnsmasq.d/gfwlist.conf
	rm -rf /jffs/scripts/dnsmasq.postconf
	
	# custom dnsmasq settings by user
	if [ -n "$ss_dnsmasq" ];then
		echo_date 添加自定义dnsmasq设置到/tmp/custom.conf
		echo "$ss_dnsmasq" | base64_decode | sort -u >> /tmp/custom.conf
	fi

	# these sites need to go ss inside router
	if [ "$ss_basic_mode" != "6" ];then
		echo "#for router itself" >> /tmp/wblist.conf
		echo "server=/.google.com.tw/127.0.0.1#7913" >> /tmp/wblist.conf
		echo "ipset=/.google.com.tw/router" >> /tmp/wblist.conf
		echo "server=/dns.google.com/127.0.0.1#7913" >> /tmp/wblist.conf
		echo "ipset=/dns.google.com/router" >> /tmp/wblist.conf
		echo "server=/.github.com/127.0.0.1#7913" >> /tmp/wblist.conf
		echo "ipset=/.github.com/router" >> /tmp/wblist.conf
		echo "server=/.github.io/127.0.0.1#7913" >> /tmp/wblist.conf
		echo "ipset=/.github.io/router" >> /tmp/wblist.conf
		echo "server=/.raw.githubusercontent.com/127.0.0.1#7913" >> /tmp/wblist.conf
		echo "ipset=/.raw.githubusercontent.com/router" >> /tmp/wblist.conf
		echo "server=/.adblockplus.org/127.0.0.1#7913" >> /tmp/wblist.conf
		echo "ipset=/.adblockplus.org/router" >> /tmp/wblist.conf
		echo "server=/.entware.net/127.0.0.1#7913" >> /tmp/wblist.conf
		echo "ipset=/.entware.net/router" >> /tmp/wblist.conf
		echo "server=/.apnic.net/127.0.0.1#7913" >> /tmp/wblist.conf
		echo "ipset=/.apnic.net/router" >> /tmp/wblist.conf
	fi
	
	# append white domain list, not through ss
	wanwhitedomain=$(echo $ss_wan_white_domain | base64_decode)
	if [ -n "$ss_wan_white_domain" ];then
		echo_date 应用域名白名单
		echo "#for white_domain" >> /tmp/wblist.conf
		for wan_white_domain in $wanwhitedomain
		do
			detect_domain "$wan_white_domain"
			if [ "$?" == "0" ];then
				# 回国模式下，用外国DNS，否则用中国DNS。
				if [ "$ss_basic_mode" != "6" ];then
					echo "$wan_white_domain" | sed "s/^/server=&\/./g" | sed "s/$/\/$CDN#53/g" >> /tmp/wblist.conf
					echo "$wan_white_domain" | sed "s/^/ipset=&\/./g" | sed "s/$/\/white_list/g" >> /tmp/wblist.conf
				else
					echo "$wan_white_domain" | sed "s/^/server=&\/./g" | sed "s/$/\/$ss_direct_user/g" >> /tmp/wblist.conf
					echo "$wan_white_domain" | sed "s/^/ipset=&\/./g" | sed "s/$/\/white_list/g" >> /tmp/wblist.conf
				fi
			else
				echo_date ！！检测到域名白名单内的【"$wan_white_domain"】不是域名格式！！此条将不会添加！！
			fi
		done
	fi
	
	# 非回国模式下，apple 和 microsoft需要中国cdn
	if [ "$ss_basic_mode" != "6" ]; then
		echo "#for special site (Mandatory China DNS)" >>/tmp/wblist.conf
		for wan_white_domain2 in "apple.com" "microsoft.com" "dns.msftncsi.com"; do
			echo "$wan_white_domain2" | sed "s/^/server=&\/./g" | sed "s/$/\/$CDN#$DNSC_PORT/g" >>/tmp/wblist.conf
			echo "$wan_white_domain2" | sed "s/^/ipset=&\/./g" | sed "s/$/\/white_list/g" >>/tmp/wblist.conf
		done
	fi

	# append black domain list, through ss
	wanblackdomain=$(echo $ss_wan_black_domain | base64_decode)
	if [ -n "$ss_wan_black_domain" ];then
		echo_date 应用域名黑名单
		echo "#for black_domain" >>/tmp/wblist.conf
		for wan_black_domain in $wanblackdomain; do
			detect_domain "$wan_black_domain"
			if [ "$?" == "0" ]; then
				if [ "$ss_basic_mode" != "6" ]; then
					echo "$wan_black_domain" | sed "s/^/server=&\/./g" | sed "s/$/\/127.0.0.1#$DNSF_PORT/g" >>/tmp/wblist.conf
					echo "$wan_black_domain" | sed "s/^/ipset=&\/./g" | sed "s/$/\/black_list/g" >>/tmp/wblist.conf
				else
					echo "$wan_black_domain" | sed "s/^/server=&\/./g" | sed "s/$/\/$CDN#$DNSC_PORT/g" >>/tmp/wblist.conf
					echo "$wan_black_domain" | sed "s/^/ipset=&\/./g" | sed "s/$/\/black_list/g" >>/tmp/wblist.conf
				fi
			else
				echo_date ！！检测到域名黑名单内的【"$wan_black_domain"】不是域名格式！！此条将不会添加！！
			fi
		done
	fi

	# 使用cdn.conf和gfwlist的策略
	# cdn.conf的作用：cdn.conf内包含了4万多条国内的网站，基本包含了普通人的所有国内上网需求，使用cdn.conf会让里面指定的网站强制走中国DNS的解析
	# gfwlist的主用：gfwlist内包含了已知的被墙网站，大部分人的翻墙需求（google, youtube, netflix, etc...），能得到满足，使用gfwlist会让里面指定的网站走国外的dns解析（墙内出去需要防污染，墙外进来直连即可）
	# 1.1 在国内优先模式下（在墙内出去），dnsmasq的全局dns是中国的，所以不需要cdn.conf，此时对路由的dnsmasq的负担也较小，但是为了保证国外被墙的网站解析无污染，使用gfwlist来解析国外被墙网站（此处需要防污染的软件来获得正确dns，如dns2socks的转发方式，chinadns的过滤方式，cdns的edns的特殊获取方式等），这样如果遇到gfwlist漏掉的，或者上普通未被墙的国外网站可能速度较慢；
	# 1.2 在国内优先模式下（在墙外回来），dnsmasq的全局dns是中国的，所以不需要cdn.conf，此时对路由的dnsmasq的负担也较小，但是为了保证国外被墙的网站解析无污染，使用gfwlist来解析国外被墙网站（因为本来身在国外，直连国外当地dns即可，如果转发，则会让这些请求在国内vps上去做，导致污染，如果使用chinadns过滤，则无需指定通过转发的），但是这样会导致很多国外网站的访问是从国内的vps发起的，导致一些国外网站的体验不好
	
	# 2.1 在国外优先的模式下（在墙内出去），dnsmasq的全局dns是国外的（此处需要使用防污染的软件来获得正确的dns），但是要保证国内的网站的解析效果，只好引入cdn.conf，此时路由的负担也会较大，这样国内的网站解析效果完全靠cdn.tx，一般来说能普通人的所有国内上网需求
	# 2.2 在国外优先的模式下（在墙外回来），dnsmasq的全局dns是国外的（此处只需要直连国外当地的dns服务器即可！），但是要保证国内的网站的解析效果，只好引入cdn.conf，此时路由的负担也会较大，这样国内的网站解析效果完全靠cdn.conf，一般来说翻墙回来都是看国内影视剧和音乐等需要，cdn.conf应该能够满足。

	# 总结
	# 国内优先模式，使用gfwlist，不用cdn.conf，国内cdn好，国外cdn差，路由器负担小
	# 国外优先模式，不用gfwlist，使用cdn.conf，国内cdn好，国外cdn好，路由器负担大（dns2socks ss-tunnel，cdns）
	# 国外优先模式，如果dns自带了国内cdn，不用gfwlist，不用cdn.conf，国内cdn好，国外cdn好，路由器负小（chinadns1 chinadns2）

	# 使用场景 
	# 1.1 gfwlist模式：该模式的特点就是只有gfwlist内的网站走代理，所以dns部分也应该是相同的策略，即国内优先模式。
	# 1.2 在gfwlist模式下，如果访问控制内有主机走chnroute模式，那么怎么办？也许这台主机希望获得更好的国外访问效果？原来ks的策略是如果检测到这种情况则切换到国外优先，并且保持gfwlist存在（因为主模式下的主机在iptables内必须匹配gfwlist的ipset）；
	# 2.1 chnroute模式：除了国内的IP不走代理，其余都应该走代理，即使是某个国外的网站未被墙，因为用户的初衷是为了获得更好的国外访问效果才使用chnroute模式，所以dns部分也应该是类似的策略，即国外优先模式：
	# 2.2 在chnroute模式下，如果访问控制内有主机走gfwlist模式，那么怎么办？这台机器应该指望着获得更好的国内访问效果？原来ks的策略是如果检测这种情况，保持国外优先不变的情况下，再引入gfwlist（因为这些gfwlist的主机在iptables内必须匹配gfwlist的ipset）；
	# 对于访问控制存在上面的情况，都是向着国外优先

	# 指定策略
	# 1 一刀切的自动方案：和原KS方案相同，不过对于回国模式需要做出修改，国外的dns不能由软件转发等，直连就行了（fix）
	# 2 用户自己选择，一刀切的方案很多情况下都会走到国外优先上去，这对路由器的负担是很大的，而多数人的上网需求国内优先就足够了，一些人需要国外访问快（代理够快的情况下），可以自行选择国外优先（todo）
	# 3 所以最终保留自动方案，增加国内优先和国外优先的选择方案（todo）

	if [ "$ss_basic_mode" == "6" ];then
		# 回国模式中，因为国外DNS无论如何都不会污染的，所以采取的策略是直连就行，默认国内优先即可
		echo_date 自动判断在回国模式中使用国内优先模式，不加载cdn.conf
	else
		if [ "$ss_basic_mode" == "1" -a -z "$chn_on" -a -z "$all_on" ] || [ "$ss_basic_mode" == "6" ];then
			# gfwlist模式的时候，且访问控制主机中不存在 大陆白名单模式 游戏模式 全局模式，则使用国内优先模式
			# 回国模式下自动判断使用国内优先
			echo_date 自动判断使用国内优先模式，不加载cdn.conf
		else
			# 其它情况，均使用国外优先模式，以下区分是否加载cdn.conf
			# if [ "$ss_foreign_dns" == "2" ] || [ "$ss_foreign_dns" == "5" ] || [ "$ss_foreign_dns" == "9" -a "$ss_dns_china" == "13" ]; then
			if [ "$ss_foreign_dns" == "2" -o "$ss_foreign_dns" == "5" -o "$ss_foreign_dns" == "10" ]; then
				# 因为chinadns1 chinadns2自带国内cdn，所以也不需要cdn.conf
				echo_date 自动判断dns解析使用国外优先模式...
				echo_date 国外解析方案【$(get_dns_name $ss_foreign_dns)】自带国内cdn，无需加载cdn.conf，路由器开销小...
			else
				echo_date 自动判断dns解析使用国外优先模式...
				echo_date 国外解析方案【$(get_dns_name $ss_foreign_dns)】，需要加载cdn.conf提供国内cdn...
				echo_date 建议将系统dnsmasq替换为dnsmasq-fastlookup，以减轻路由cpu消耗...
				echo_date 生成cdn加速列表到/tmp/sscdn.conf，加速用的dns：$CDN
				echo "#for china site CDN acclerate" >>/tmp/sscdn.conf
				cat /koolshare/ss/rules/cdn.txt | sed "s/^/server=&\/./g" | sed "s/$/\/&$CDN#$DNSC_PORT/g" | sort | awk '{if ($0!=line) print;line=$0}' >>/tmp/sscdn.conf
			fi
		fi
	fi

	#ln_conf
	if [ -f /tmp/custom.conf ];then
		#echo_date 创建域自定义dnsmasq配置文件软链接到/jffs/configs/dnsmasq.d/custom.conf
		ln -sf /tmp/custom.conf /jffs/configs/dnsmasq.d/custom.conf
	fi
	if [ -f /tmp/wblist.conf ];then
		#echo_date 创建域名黑/白名单软链接到/jffs/configs/dnsmasq.d/wblist.conf
		ln -sf /tmp/wblist.conf /jffs/configs/dnsmasq.d/wblist.conf
	fi
	
	if [ -f /tmp/sscdn.conf ];then
		#echo_date 创建cdn加速列表软链接/jffs/configs/dnsmasq.d/cdn.conf
		ln -sf /tmp/sscdn.conf /jffs/configs/dnsmasq.d/cdn.conf
	fi

	if [ "$ss_basic_mode" == "1" ];then
		echo_date 创建gfwlist的软连接到/jffs/etc/dnsmasq.d/文件夹.
		ln -sf /koolshare/ss/rules/gfwlist.conf /jffs/configs/dnsmasq.d/gfwlist.conf
	elif [ "$ss_basic_mode" == "2" ] || [ "$ss_basic_mode" == "3" ];then
		if [ -n "$gfw_on" ];then
			echo_date 创建gfwlist的软连接到/jffs/etc/dnsmasq.d/文件夹.
			ln -sf /koolshare/ss/rules/gfwlist.conf /jffs/configs/dnsmasq.d/gfwlist.conf
		fi
	elif [ "$ss_basic_mode" == "6" ];then
		# 回国模式下默认方案是国内优先，所以gfwlist里的网站不能由127.0.0.1#7913来解析了，应该是国外当地直连
		if [ -n "`echo $ss_direct_user|grep :`" ];then
			echo_date 国外直连dns设定格式错误，将自动更正为8.8.8.8#53.
			ss_direct_user="8.8.8.8#53"
			dbus set ss_direct_user="8.8.8.8#53"
		fi
		echo_date 创建回国模式专用gfwlist的软连接到/jffs/etc/dnsmasq.d/文件夹.
		[ -z "$ss_direct_user" ] && ss_direct_user="8.8.8.8#53"
		cat /koolshare/ss/rules/gfwlist.conf|sed "s/127.0.0.1#7913/$ss_direct_user/g" > /tmp/gfwlist.conf
		ln -sf /tmp/gfwlist.conf /jffs/configs/dnsmasq.d/gfwlist.conf
	fi

	#echo_date 创建dnsmasq.postconf软连接到/jffs/scripts/文件夹.
	[ ! -L "/jffs/scripts/dnsmasq.postconf" ] && ln -sf /koolshare/ss/rules/dnsmasq.postconf /jffs/scripts/dnsmasq.postconf
}


auto_start(){
	# nat_auto_start
	mkdir -p /jffs/scripts
	# creating iptables rules to nat-start
	if [ ! -f /jffs/scripts/nat-start ]; then
	cat > /jffs/scripts/nat-start <<-EOF
		#!/bin/sh
		/usr/bin/onnatstart.sh
		
		EOF
	fi
	
	writenat=$(cat /jffs/scripts/nat-start | grep "ssconfig")
	if [ -z "$writenat" ];then
		echo_date 添加nat-start触发事件...用于ss的nat规则重启后或网络恢复后的加载...
		sed -i '2a sh /koolshare/ss/ssconfig.sh' /jffs/scripts/nat-start
		chmod +x /jffs/scripts/nat-start
	fi

	# wan_auto_start
	# Add service to auto start
	if [ ! -f /jffs/scripts/wan-start ]; then
		cat > /jffs/scripts/wan-start <<-EOF
			#!/bin/sh
			/usr/bin/onwanstart.sh
			
			EOF
	fi
	
	startss=$(cat /jffs/scripts/wan-start | grep "/koolshare/scripts/ss_config.sh")
	if [ -z "$startss" ];then
		echo_date 添加wan-start触发事件...用于ss的各种程序的开机启动...
		sed -i '2a sh /koolshare/scripts/ss_config.sh' /jffs/scripts/wan-start
	fi
	chmod +x /jffs/scripts/wan-start
}





get_function_switch() {
	case "$1" in
		1)
			echo "true"
		;;
		*)
			echo "false"
		;;
	esac
}

get_ws_header() {
	if [ -n "$1" ];then
		echo {\"Host\": \"$1\"}
	else
		echo "null"
	fi
}

get_h2_host() {
	if [ -n "$1" ];then
		echo [\"$1\"]
	else
		echo "null"
	fi
}

get_path(){
	if [ -n "$1" ];then
		echo \"$1\"
	else
		echo "null"
	fi
}

get_fingerprint(){
	if [ -n "$1" ];then
		echo \"$1\"
	else
		echo "null"
	fi
}

resolve_node_ip4json(){	
	
	# 检测用户json的服务器ip地址
		node_protocol=$(cat "$V2RAY_CONFIG_FILE" | jq -r .outbounds[0].protocol)
		case $node_protocol in
		vmess)
			node_server=$(cat "$V2RAY_CONFIG_FILE" | jq -r .outbounds[0].settings.vnext[0].address)
			;;
		vless)
			node_server=$(cat "$V2RAY_CONFIG_FILE" | jq -r .outbounds[0].settings.vnext[0].address)
			;;			
		socks)
			node_server=$(cat "$V2RAY_CONFIG_FILE" | jq -r .outbounds[0].settings.servers[0].address)
			;;
		trojan)
			node_server=$(cat "$V2RAY_CONFIG_FILE" | jq -r .outbounds[0].settings.servers[0].address)
			;;
		shadowsocks)
			node_server=$(cat "$V2RAY_CONFIG_FILE" | jq -r .outbounds[0].settings.servers[0].address)
			;;
		*)
			node_server=""
			;;
		esac

		if [ -n "$node_server" -a "$node_server" != "null" ];then
			IFIP_VS=`echo $node_server|grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:"`
			if [ -n "$IFIP_VS" ];then
				ss_basic_server_ip="$node_server"
				echo_date "检测到你的json配置的${node_protocol}服务器是：$node_server"
			else
				echo_date "检测到你的json配置的${node_protocol}服务器：$node_server不是ip格式！"
				echo_date "为了确保${node_protocol}的正常工作，建议配置ip格式的${node_protocol}服务器地址！"
				echo_date "尝试解析${node_protocol}服务器的ip地址，DNS：$(get_server_resolver)"
				# 服务器地址强制由114解析，以免插件还未开始工作而导致解析失败
				echo "server=/$node_server/$(get_server_resolver)#53" > /jffs/configs/dnsmasq.d/ss_server.conf
				node_server_ip=`nslookup "$node_server" $(get_server_resolver) | sed '1,4d' | awk '{print $3}' | grep -v :|awk 'NR==1{print}'`
				if [ "$?" == "0" ]; then
					node_server_ip=`echo $node_server_ip|grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:"`
				else
					echo_date ${node_protocol}服务器域名解析失败！
					echo_date 尝试用resolveip方式解析，DNS：系统
					node_server_ip=`resolveip -4 -t 2 $ss_basic_server|awk 'NR==1{print}'`
					if [ "$?" == "0" ];then
						node_server_ip=`echo $node_server_ip|grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:"`
					fi
				fi

				if [ -n "$node_server_ip" ];then
					echo_date "${node_protocol}服务器的ip地址解析成功：$node_server_ip"
					# 解析并记录一次ip，方便插件触发重启设定工作
					echo "address=/$node_server/$node_server_ip" > /tmp/ss_host.conf
					# 去掉此功能，以免ip发生变更导致问题，或者影响域名对应的其它二级域名
					#ln -sf /tmp/ss_host.conf /jffs/configs/dnsmasq.d/ss_host.conf
					ss_basic_server_ip="$node_server_ip"
				else
					echo_date "${node_protocol}服务器的ip地址解析失败!插件将继续运行，域名解析将由${node_protocol}自己进行！"
					echo_date "请自行将${node_protocol}服务器的ip地址填入IP/CIDR白名单中!"
					echo_date "为了确保${node_protocol}的正常工作，建议配置ip格式的${node_protocol}服务器地址！"
					#close_in_five
				fi
			fi
		else
			echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
			echo_date "+       没有检测到你的${node_protocol}服务器地址，如果你确定你的配置是正确的        +"
			echo_date "+   请自行将${node_protocol}服务器的ip地址填入【IP/CIDR】黑名单中，以确保正常使用   +"
			echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		fi
	
}


create_fragment_config(){
	case "$ss_basic_fragment" in
	1)
		cat <<EOF
 ,{
    "protocol": "freedom",
    "settings": {
        "fragment": {
            "interval": "10-20",
            "length": "50-100",
            "packets": "tlshello"
        },
        "noises": [
            {
                "delay": "10-20",
                "packet": "100-200",
                "type": "rand"
            }
        ]
    },
    "streamSettings": {
        "network": "tcp",
        "security": "",
        "sockopt": {
            "TcpNoDelay": true,
            "mark": 255
        }
    },
    "tag": "fragment"
 }
EOF
		;;
	*)
		echo ""
		;;
	esac
}


create_v2ray_json(){
	rm -rf "$V2RAY_CONFIG_FILE_TMP"
	rm -rf "$V2RAY_CONFIG_FILE"
	if [ "$ss_basic_v2ray_use_json" == "0" ]; then
		echo_date 生成V2Ray配置文件...
		local kcp="null"
		local tcp="null"
		local ws="null"
		local h2="null"
		local grpc="null"
		local tls="null"
		local reality="null"
		local vless_flow=""
		local xhttp="null"
		[ "$ss_basic_fingerprint" == "none" ] && local ss_basic_fingerprint=""

		# tcp和kcp下tlsSettings为null，ws和h2下tlsSettings
		[ -z "$(dbus get ss_basic_v2ray_mux_concurrency)" ] && local ss_basic_v2ray_mux_concurrency=8
		[ "$ss_basic_v2ray_network_security" == "none" ] && local ss_basic_v2ray_network_security=""

		# incase multi-domain input
		if [ "$(echo $ss_basic_v2ray_network_host | grep ",")" ]; then
			ss_basic_v2ray_network_host=$(echo $ss_basic_v2ray_network_host | sed 's/,/", "/g')
		fi

		if [ "$ss_basic_v2ray_network" == "ws" -o "$ss_basic_v2ray_network" == "h2" -o "$ss_basic_v2ray_network" == "xhttp" ] && [ -z "$ss_basic_v2ray_network_tlshost" ] && [ -n "$ss_basic_v2ray_network_host" ]; then
		 	local ss_basic_v2ray_network_tlshost="$ss_basic_v2ray_network_host"
		fi

		case "$ss_basic_v2ray_network_security" in
		tls)
			local tls="{
					\"allowInsecure\": $(get_function_switch $ss_basic_allowinsecure),
					\"fingerprint\": $(get_fingerprint $ss_basic_fingerprint),
					\"serverName\": \"$ss_basic_v2ray_network_tlshost\"
					}"
			[ "$ss_basic_v2ray_network_flow" != "none" -a "$ss_basic_v2ray_network_flow" != "" ] && local vless_flow="\"flow\": \"$ss_basic_v2ray_network_flow\","	|| 	local vless_flow=""
			;;
		reality)
			local reality="{
					\"serverName\": \"$ss_basic_v2ray_network_tlshost\",
					\"fingerprint\": $(get_fingerprint $ss_basic_fingerprint),
					\"publicKey\": \"$ss_basic_xray_publicKey\",
					\"shortId\": \"$ss_basic_xray_shortId\",
					\"spiderX\": \"\"
					}"
			local vless_flow="\"flow\": \"$ss_basic_v2ray_network_flow\","
			;;	
		*)
			local tls="null"
			local reality="null"
			;;
		esac
		
		case "$ss_basic_v2ray_network" in
		tcp)
			if [ "$ss_basic_v2ray_headtype_tcp" == "http" ]; then
				local tcp="{
					\"connectionReuse\": true,
					\"header\": {
					\"type\": \"http\",
					\"request\": {
					\"version\": \"1.1\",
					\"method\": \"GET\",
					\"path\": [\"/\"],
					\"headers\": {
					\"Host\": [\"$ss_basic_v2ray_network_host\"],
					\"User-Agent\": [\"Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/55.0.2883.75 Safari/537.36\",\"Mozilla/5.0 (iPhone; CPU iPhone OS 10_0_2 like Mac OS X) AppleWebKit/601.1 (KHTML, like Gecko) CriOS/53.0.2785.109 Mobile/14A456 Safari/601.1.46\"],
					\"Accept-Encoding\": [\"gzip, deflate\"],
					\"Connection\": [\"keep-alive\"],
					\"Pragma\": \"no-cache\"
					}
					},
					\"response\": {
					\"version\": \"1.1\",
					\"status\": \"200\",
					\"reason\": \"OK\",
					\"headers\": {
					\"Content-Type\": [\"application/octet-stream\",\"video/mpeg\"],
					\"Transfer-Encoding\": [\"chunked\"],
					\"Connection\": [\"keep-alive\"],
					\"Pragma\": \"no-cache\"
					}
					}
					}
					}"
			else
				local tcp="null"
			fi
			;;
		kcp)
			local kcp="{
				\"mtu\": 1350,
				\"tti\": 50,
				\"uplinkCapacity\": 12,
				\"downlinkCapacity\": 100,
				\"congestion\": false,
				\"readBufferSize\": 2,
				\"writeBufferSize\": 2,
				\"seed\": \"$ss_basic_v2ray_network_path\",
				\"header\": {
				\"type\": \"$ss_basic_v2ray_headtype_kcp\",
				\"request\": null,
				\"response\": null
				}
				}"
			[ -z "$ss_basic_v2ray_network_path" ] && local kcp=$(echo $kcp |sed 's/"seed": "*, //')
			;;
		ws)
			local ws="{
				\"connectionReuse\": true,
				\"fingerprint\": $(get_fingerprint $ss_basic_fingerprint),
				\"path\": $(get_path $ss_basic_v2ray_network_path),
				\"headers\": $(get_ws_header $ss_basic_v2ray_network_host)
				}"
			;;
		h2)
			local h2="{
				\"fingerprint\": $(get_fingerprint $ss_basic_fingerprint),
				\"path\": $(get_path $ss_basic_v2ray_network_path),
				\"host\": $(get_h2_host $ss_basic_v2ray_network_host)
				}"
			;;
		grpc)
			local grpc="{
				\"multiMode\": true,
  				\"idle_timeout\": 13,
				\"fingerprint\": $(get_fingerprint $ss_basic_fingerprint),
				\"serviceName\": $(get_path $ss_basic_v2ray_serviceName) 
				}"
			;;	
		xhttp)
			local xhttp_path=$(dbus get ss_basic_v2ray_network_path)
			[ -z "$xhttp_path" ] && xhttp_path="/"
			local xhttp_host=$(dbus get ss_basic_v2ray_network_host)
			local xhttp_mode=$(dbus get ss_basic_v2ray_xhttp_mode)
			[ -z "$xhttp_mode" ] && xhttp_mode="auto"
			local xhttp_extra=$(dbus get ss_basic_v2ray_xhttp_extra)
			[ -z "$xhttp_extra" ] && xhttp_extra='{}'
			printf '%s' "$xhttp_extra" | /koolshare/bin/jq -e . >/dev/null 2>&1 || xhttp_extra='{}'
			local xhttp=$(/koolshare/bin/jq -cn --arg p "$xhttp_path" --arg h "$xhttp_host" --arg m "$xhttp_mode" --argjson e "$xhttp_extra" '
				if ($p | length) == 0 then error("xhttp path is required") else
				  {path: $p, mode: $m}
				  + (if ($h | split(",")[0] | length) > 0 then {host: ($h | split(",")[0])} else {} end)
				  + (if ($e | length) > 0 then {extra: $e} else {} end)
				end')
			;;	
		esac

		local tls_fragment=$(create_fragment_config)
		# log area
		cat >"$V2RAY_CONFIG_FILE_TMP" <<-EOF
			{
			"log": {
				"access": "/dev/null",
				"error": "/tmp/v2ray_log.log",
				"loglevel": "error"
			},
		EOF
		# inbounds area (7913 for dns resolve)
		if [ "$ss_foreign_dns" == "7" ]; then
			echo_date 配置v2ray dns，用于dns解析...
			cat >>"$V2RAY_CONFIG_FILE_TMP" <<-EOF
				"inbounds": [
					{
					"tag": "in-dns",
					"protocol": "dokodemo-door",
					"port": $DNSF_PORT,
					"settings": {
						"address": "8.8.8.8",
						"port": 53,
						"network": "udp",
						"timeout": 0,
						"followRedirect": false
						}
					},
					{
						"tag": "in-redir",
						"listen": "0.0.0.0",
						"port": 3333,
						"protocol": "dokodemo-door",
						"settings": {
							"network": "tcp,udp",
							"followRedirect": true
						}
					}
				],
			EOF
		else
			# inbounds area (23456 for socks5)
			cat >>"$V2RAY_CONFIG_FILE_TMP" <<-EOF
				"inbounds": [
					{
						"tag": "in-socks",
						"port": 23456,
						"listen": "0.0.0.0",
						"protocol": "socks",
						"settings": {
							"auth": "noauth",
							"udp": true,
							"ip": "127.0.0.1",
							"clients": null
						},
						"streamSettings": null
					},
					{
						"tag": "in-redir",
						"listen": "0.0.0.0",
						"port": 3333,
						"protocol": "dokodemo-door",
						"settings": {
							"network": "tcp,udp",
							"followRedirect": true
						}
					}
				],
			EOF
		fi
		# outbounds area
		if [ "$ss_basic_v2ray_protocol" == "vmess" ]; then
			cat >>"$V2RAY_CONFIG_FILE_TMP" <<-EOF
				"outbounds": [
				  {
					"tag": "agentout",
					"protocol": "vmess",
					"settings": {
					  "vnext": [
						{
						  "address": "$(dbus get ss_basic_server)",
						  "port": $ss_basic_port,
						  "users": [
							{
							  "id": "$ss_basic_v2ray_uuid",
							  "alterId": $ss_basic_v2ray_alterid,
							  "security": "$ss_basic_v2ray_security"
							}
						  ]
						}
					  ],
					  "servers": null
					},
					"streamSettings": {
					  "network": "$ss_basic_v2ray_network",
					  "security": "$ss_basic_v2ray_network_security",
					  "tlsSettings": $tls,
					  "tcpSettings": $tcp,
					  "kcpSettings": $kcp,
					  "wsSettings": $ws,
					  "httpSettings": $h2,
					  "grpcSettings": $grpc,
					  "xhttpSettings": $xhttp
					},
					"mux": {
					  "enabled": $(get_function_switch $ss_basic_v2ray_mux_enable),
					  "concurrency": $ss_basic_v2ray_mux_concurrency
					}
				  }
				]
				}
			EOF
		elif [ "$ss_basic_v2ray_protocol" == "vless" ]; then
		  #vless
		  cat >>"$V2RAY_CONFIG_FILE_TMP" <<-EOF
				"outbounds": [
				  {
					"tag": "agentout",
					"protocol": "vless",
					"settings": {
					  "vnext": [
						{
						  "address": "$(dbus get ss_basic_server)",
						  "port": $ss_basic_port,
						  "users": [
							{
							  "id": "$ss_basic_v2ray_uuid",
							  "level": 1,
							  $vless_flow
							  "encryption": "none"
							}
						  ]
						}
					  ],
					  "servers": null
					},
					"streamSettings": {
					  "network": "$ss_basic_v2ray_network",
					  "security": "$ss_basic_v2ray_network_security",
					  "tlsSettings": $tls,
					  "realitySettings": $reality,
					  "tcpSettings": $tcp,
					  "kcpSettings": $kcp,
					  "wsSettings": $ws,
					  "httpSettings": $h2,
					  "grpcSettings": $grpc,
					  "xhttpSettings": $xhttp
					},
					"mux": {
					  "enabled": $(get_function_switch $ss_basic_v2ray_mux_enable),
					  "concurrency": $ss_basic_v2ray_mux_concurrency
					}
				  } ${tls_fragment}
				]
				}
			EOF
		fi
		echo_date 解析V2Ray配置文件...
		cat "$V2RAY_CONFIG_FILE_TMP" | jq --tab . >"$V2RAY_CONFIG_FILE"
		echo_date V2Ray配置文件写入成功到"$V2RAY_CONFIG_FILE"
	elif [ "$ss_basic_v2ray_use_json" == "1" ]; then
		echo_date 使用自定义的v2ray json配置文件...
		echo "$ss_basic_v2ray_json" | base64_decode >"$V2RAY_CONFIG_FILE_TMP"
		local OB=$(cat "$V2RAY_CONFIG_FILE_TMP" | jq .outbound)
		local OBS=$(cat "$V2RAY_CONFIG_FILE_TMP" | jq .outbounds)

		# 兼容旧格式：outbound
		if [ "$OB" != "null" ]; then
			OUTBOUNDS=$(cat "$V2RAY_CONFIG_FILE_TMP" | jq .outbound)
		fi
		
		# 新格式：outbound[]
		if [ "$OBS" != "null" ]; then
			OUTBOUNDS=$(cat "$V2RAY_CONFIG_FILE_TMP" | jq .outbounds[])
		fi
		
		if [ "$ss_foreign_dns" == "7" ]; then
			local TEMPLATE="{
								\"log\": {
									\"access\": \"/dev/null\",
									\"error\": \"/tmp/v2ray_log.log\",
									\"loglevel\": \"error\"
								},
								\"inbounds\": [
									{
										\"tag\": \"in-dns\",
										\"protocol\": \"dokodemo-door\", 
										\"port\": $DNSF_PORT,
										\"settings\": {
											\"address\": \"8.8.8.8\",
											\"port\": 53,
											\"network\": \"udp\",
											\"timeout\": 0,
											\"followRedirect\": false
										}
									},
									{
										\"tag\": \"in-redir\",
										\"listen\": \"0.0.0.0\",
										\"port\": 3333,
										\"protocol\": \"dokodemo-door\",
										\"settings\": {
											\"network\": \"tcp,udp\",
											\"followRedirect\": true
										}
									}
								]
							}"
		else
			local TEMPLATE="{
								\"log\": {
									\"access\": \"/dev/null\",
									\"error\": \"/tmp/v2ray_log.log\",
									\"loglevel\": \"error\"
								},
								\"inbounds\": [
									{
										\"tag\": \"in-socks\",
										\"port\": 23456,
										\"listen\": \"0.0.0.0\",
										\"protocol\": \"socks\",
										\"settings\": {
											\"auth\": \"noauth\",
											\"udp\": true,
											\"ip\": \"127.0.0.1\",
											\"clients\": null
										},
										\"streamSettings\": null
									},
									{
										\"tag\": \"in-redir\",
										\"listen\": \"0.0.0.0\",
										\"port\": 3333,
										\"protocol\": \"dokodemo-door\",
										\"settings\": {
											\"network\": \"tcp,udp\",
											\"followRedirect\": true
										}
									}
								]
							}"
		fi
		echo_date 解析V2Ray配置文件...

		# 1) 统一 OUTBOUNDS 为数组
		OUTBOUNDS_ARR=$(cat "$V2RAY_CONFIG_FILE_TMP" | jq -c '
		if (.outbounds? // null) != null then
			.outbounds
		elif (.outbound? // null) != null then
			[ .outbound ]
		else
			[]
		end
		')

		# 2) 判断是否是 xagg 聚合输入（只要存在 xagg_ 前缀）
		IS_XAGG=$(echo "$OUTBOUNDS_ARR" | jq -r '
		any(.[]; ((.tag // "") | startswith("xagg_")))
		')

		# ===== 新增 A：读取聚合策略（默认 leastPing） =====
		XAGG_STRATEGY=$(echo "$OUTBOUNDS_ARR" | jq -r '
		.[] | select(.tag=="xagg_meta") | .settings.strategy // empty
		')

		[ -z "$XAGG_STRATEGY" ] && XAGG_STRATEGY="leastPing"
		# =====================================================

		if [ "$IS_XAGG" = "true" ]; then
			echo_date "检测到 xagg 聚合节点，策略: $XAGG_STRATEGY"

			# ===== 新增 B：剔除 xagg_meta =====
			REAL_OUTBOUNDS=$(echo "$OUTBOUNDS_ARR" | jq -c '
			map(select(.tag != "xagg_meta"))
			')
			# ==================================

			# 3) 提取真实节点 tag（只剩 xagg_1 / xagg_2 ...）
			TAGS=$(echo "$REAL_OUTBOUNDS" | jq -c '[ .[] | .tag ]')

			# 4) 生成 routing + observatory
			ROBS=$(jq -nc --argjson tags "$TAGS" --arg strategy "$XAGG_STRATEGY" '
			{
				"routing": {
					"domainStrategy": "AsIs",
					"balancers": [
						{
							"tag": "balancer-main",
							"selector": $tags,
							"strategy": { "type": $strategy }
						}
					],
					"rules": [
						{
							"type": "field",
							"inboundTag": ["in-socks","in-redir"],
							"balancerTag": "balancer-main"
						}
					]
				},
				"observatory": {
					"subjectSelector": $tags,
					"probeURL": "https://www.gstatic.com/generate_204",
					"probeInterval": "30s"
				}
			}
			')

	# 5) 合并（注意：用 REAL_OUTBOUNDS）
	echo "$TEMPLATE" | jq \
		--argjson outbounds "$REAL_OUTBOUNDS" \
		--argjson robs "$ROBS" \
		'. + {outbounds: $outbounds} + $robs' >"$V2RAY_CONFIG_FILE"

	else
		# 普通自定义 JSON，未启用聚合逻辑
		echo "$TEMPLATE" | jq \
			--argjson outbounds "$OUTBOUNDS_ARR" \
			'. + {outbounds: $outbounds}' >"$V2RAY_CONFIG_FILE"
	fi

	echo_date "V2Ray/Xray 配置文件写入成功: $V2RAY_CONFIG_FILE"


		# 检测用户json的服务器ip地址
		resolve_node_ip4json
	fi

	cd /koolshare/bin
	result=$(xray -test -config="$V2RAY_CONFIG_FILE" | grep "Configuration OK.")

	if [ -n "$result" ]; then
		echo_date $result
		echo_date Xray配置文件通过测试!!!
	else
		echo_date Xray配置文件没有通过测试，请检查设置!!!
		rm -rf "$V2RAY_CONFIG_FILE_TMP"
		rm -rf "$V2RAY_CONFIG_FILE"
		close_in_five
	fi
}

create_trojan_json(){
	rm -rf "$V2RAY_CONFIG_FILE_TMP"
	rm -rf "$V2RAY_CONFIG_FILE"
	if  [ "$ss_basic_type" == "4" ] && [ "$ss_basic_trojan_binary" == "Trojan" ]; then
		echo_date 生成Trojan配置文件...
		 #trojan
		 local tls_fragment=$(create_fragment_config)
		 
		 # inbounds area (23456 for socks5)  
		cat >"$V2RAY_CONFIG_FILE_TMP" <<-EOF
		{
			"log": {
				"access": "/dev/null",
				"error": "/tmp/v2ray_log.log",
				"loglevel": "error"
			},
				"inbounds": [
					{
						"port": 23456,
						"listen": "0.0.0.0",
						"protocol": "socks",
						"settings": {
							"auth": "noauth",
							"udp": true,
							"ip": "127.0.0.1",
							"clients": null
						},
						"streamSettings": null
					},
					{
						"listen": "0.0.0.0",
						"port": 3333,
						"protocol": "dokodemo-door",
						"settings": {
							"network": "tcp,udp",
							"followRedirect": true
						}
					}
				],
			"outbounds": [
			  {
				"protocol": "trojan",
				"settings": {
				  "servers": [
					{
					  "address": "$(dbus get ss_basic_server)",
					  "port": $ss_basic_port,
					  "password": "$ss_basic_password"
					}
				  ]
				},
				"streamSettings": {
				  "network": "tcp",
				  "security": "tls",
				  "tlsSettings": {
					"allowInsecure": $(get_function_switch $ss_basic_allowinsecure),  
                    "serverName": "$ss_basic_trojan_sni"
                }
				}
			  }  ${tls_fragment}
			]
		}
		EOF
	
		echo_date 解析Trojan配置文件...
		cat "$V2RAY_CONFIG_FILE_TMP" | jq --tab . >"$V2RAY_CONFIG_FILE"
			
		echo_date Trojan配置文件写入成功到"$V2RAY_CONFIG_FILE"
			
		cd /koolshare/bin
		echo_date 测试Trojan配置文件.....
		result=$(xray -test -config="$V2RAY_CONFIG_FILE" | grep "Configuration OK.")
		if [ -n "$result" ]; then
			echo_date $result
			echo_date Trojan配置文件通过测试!!!
		else
			echo_date Trojan配置文件没有通过测试，请检查设置!!!
			rm -rf "$V2RAY_CONFIG_FILE_TMP"
			rm -rf "$V2RAY_CONFIG_FILE"
			close_in_five
		fi
	fi
}


create_trojango_json(){
	rm -rf "$V2RAY_CONFIG_FILE_TMP"
	rm -rf "$V2RAY_CONFIG_FILE"
	if  [ "$ss_basic_type" == "4" ] && [ "$ss_basic_trojan_binary" == "Trojan-Go" ]; then
		[ -z "$(dbus get ss_basic_v2ray_mux_concurrency)" ] && local ss_basic_v2ray_mux_concurrency=8
		local trojan_sni="$ss_basic_trojan_sni"
		[ -z "$trojan_sni" ] && [ -n "$ss_basic_v2ray_network_host" ] && trojan_sni="$ss_basic_v2ray_network_host"

		if [ "$ss_basic_trojan_network" == "1" ]; then
			[ -n "$ss_basic_v2ray_network_path" ] && local ss_basic_v2ray_network_path=$(echo "/$ss_basic_v2ray_network_path" | sed 's,//,/,')
			local trojango_network="ws"
			local ws_settings="{\"path\": \"$ss_basic_v2ray_network_path\", \"headers\": {\"Host\": \"$ss_basic_v2ray_network_host\"}}"
		else
			local trojango_network="tcp"
			local ws_settings="null"
		fi

		echo_date 生成Trojan-Go Xray配置文件...
		cat >"$V2RAY_CONFIG_FILE_TMP" <<-EOF
		{
			"log": {
				"access": "/dev/null",
				"error": "/tmp/v2ray_log.log",
				"loglevel": "error"
			},
			"inbounds": [
				{
					"tag": "in-socks",
					"port": 23456,
					"listen": "0.0.0.0",
					"protocol": "socks",
					"settings": {
						"auth": "noauth",
						"udp": true,
						"ip": "127.0.0.1",
						"clients": null
					},
					"streamSettings": null
				},
				{
					"tag": "in-redir",
					"listen": "0.0.0.0",
					"port": 3333,
					"protocol": "dokodemo-door",
					"settings": {
						"network": "tcp,udp",
						"followRedirect": true
					}
				}
			],
			"outbounds": [
				{
					"tag": "agentout",
					"protocol": "trojan-go",
					"settings": {
						"trojanGoMux": {
							"enabled": $(get_function_switch $ss_basic_v2ray_mux_enable),
							"concurrency": $ss_basic_v2ray_mux_concurrency,
							"idle_timeout": 60
						},
						"servers": [
							{
								"address": "$(dbus get ss_basic_server)",
								"port": $ss_basic_port,
								"password": "$ss_basic_password"
							}
						]
					},
					"streamSettings": {
						"network": "$trojango_network",
						"security": "tls",
						"tlsSettings": {
							"allowInsecure": $(get_function_switch $ss_basic_allowinsecure),
							"serverName": "$trojan_sni",
							"alpn": ["http/1.1"],
							"fingerprint": $(get_fingerprint $ss_basic_fingerprint)
						},
						"wsSettings": $ws_settings
					},
					"mux": {
						"enabled": false,
						"concurrency": 1
					}
				}
			]
		}
		EOF

		echo_date 写入Trojan-Go Xray配置文件...
		mv -f "$V2RAY_CONFIG_FILE_TMP" "$V2RAY_CONFIG_FILE"
		echo_date Trojan-Go Xray配置文件写入成功到"$V2RAY_CONFIG_FILE"

		cd /koolshare/bin
		echo_date 测试Trojan-Go Xray配置文件.....
		result=$(xray -test -config="$V2RAY_CONFIG_FILE" | grep "Configuration OK.")
		if [ -n "$result" ]; then
			echo_date $result
			echo_date Trojan-Go Xray配置文件通过测试!!!
		else
			echo_date Trojan-Go Xray配置文件没有通过测试，请检查设置!!!
			rm -rf "$V2RAY_CONFIG_FILE_TMP"
			rm -rf "$V2RAY_CONFIG_FILE"
			close_in_five
		fi
	fi
}



create_ss2022_json(){
	rm -rf "$V2RAY_CONFIG_FILE_TMP"
	rm -rf "$V2RAY_CONFIG_FILE"
	if  [ "$ss_basic_type" == "3" ] && [ "$SS2022" == "Y" ]; then
		echo_date 生成 Shadowsocks 2022 配置文件...
		 #Shadowsocks 2022 
		 # inbounds area (23456 for socks5)  
		cat >"$V2RAY_CONFIG_FILE_TMP" <<-EOF
		{
			"log": {
				"access": "/dev/null",
				"error": "/tmp/v2ray_log.log",
				"loglevel": "error"
			},
				"inbounds": [
					{
						"port": 23456,
						"listen": "0.0.0.0",
						"protocol": "socks",
						"settings": {
							"auth": "noauth",
							"udp": true,
							"ip": "127.0.0.1",
							"clients": null
						},
						"streamSettings": null
					},
					{
						"listen": "0.0.0.0",
						"port": 3333,
						"protocol": "dokodemo-door",
						"settings": {
							"network": "tcp,udp",
							"followRedirect": true
						}
					}
				],
			"outbounds": [
			  {
				"protocol": "shadowsocks",
				"settings": {
				  "servers": [
					{
					  "address": "$(dbus get ss_basic_server)",
					  "port": $ss_basic_port,
					  "method": "$ss_basic_method",
					  "password": "$ss_basic_password"
					}
				  ]
				}
			  }
			]
		}
		EOF
	
		echo_date 解析 Shadowsocks 2022 配置文件...
		cat "$V2RAY_CONFIG_FILE_TMP" | jq --tab . >"$V2RAY_CONFIG_FILE"
			
		echo_date Shadowsocks 2022 配置文件写入成功到"$V2RAY_CONFIG_FILE"
			
		cd /koolshare/bin
		echo_date 测试 Shadowsocks 2022 配置文件.....
		result=$(xray -test -config="$V2RAY_CONFIG_FILE" | grep "Configuration OK.")
		if [ -n "$result" ]; then
			echo_date $result
			echo_date Shadowsocks 2022 配置文件通过测试!!!
		else
			echo_date Shadowsocks 2022 配置文件没有通过测试，请检查设置!!!
			rm -rf "$V2RAY_CONFIG_FILE_TMP"
			rm -rf "$V2RAY_CONFIG_FILE"
			close_in_five
		fi
	fi
}



start_xray_core() {
	if [ "$ss_basic_type" == "4" ]; then
		# Trojan-Go 与 Trojan 均由 Xray 承载，配置由 create_trojango_json / create_trojan_json 分别生成
		start_trojan
	elif [ "$SS2022" == "Y" ]; then
		start_ss2022
	else
		start_xray
	fi
}

start_xray() {
	# xray start
	cd /koolshare/bin
	#export GOGC=30
	xray run -config=/koolshare/ss/v2ray.json >/dev/null 2>&1 &
	local xrayPID
	local i=10
	until [ -n "$xrayPID" ]; do
		i=$(($i - 1))
		xrayPID=$(pidof xray)
		if [ "$i" -lt 1 ]; then
			echo_date "xray 进程启动失败！"
			close_in_five
		fi
		sleep 1
	done
	echo_date xray启动成功，pid：$xrayPID
}

start_trojan() {
	# trojan start
	cd /koolshare/bin
	#export GOGC=30
	xray run -config=/koolshare/ss/v2ray.json >/dev/null 2>&1 &
	local trojanPID
	local i=10
	until [ -n "$trojanPID" ]; do
		i=$(($i - 1))
		trojanPID=$(pidof xray)
		if [ "$i" -lt 1 ]; then
			echo_date "trojan进程启动失败！"
			close_in_five
		fi
		sleep 1
	done
	echo_date trojan启动成功，pid：$trojanPID
}






start_ss2022() {
	# Shadowsocks 2022  start
	cd /koolshare/bin
	#export GOGC=30
	xray run -config=/koolshare/ss/v2ray.json >/dev/null 2>&1 &
	local ss2022PID
	local i=10
	until [ -n "$ss2022PID" ]; do
		i=$(($i - 1))
		ss2022PID=$(pidof xray)
		if [ "$i" -lt 1 ]; then
			echo_date "Shadowsocks 2022 进程启动失败！"
			close_in_five
		fi
		sleep 1
	done
	echo_date Shadowsocks 2022 启动成功，pid：$ss2022PID
}

write_cron_job(){
	sed -i '/ssupdate/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	if [ "1" == "$ss_basic_rule_update" ]; then
		echo_date 添加shadowsocks规则定时更新任务，每天"$ss_basic_rule_update_time"自动检测更新规则.
		cru a ssupdate "15 $ss_basic_rule_update_time * * * /bin/sh /koolshare/scripts/ss_rule_update.sh"
	else
		echo_date shadowsocks规则定时更新任务未启用！
	fi
	sed -i '/ssnodeupdate/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	if [ "$ss_basic_node_update" = "1" ];then
		if [ "$ss_basic_node_update_day" = "7" ];then
			cru a ssnodeupdate "2 $ss_basic_node_update_hr * * * /koolshare/scripts/ss_online_update.sh 3"
			echo_date "设置自动更新节点订阅在每天 $ss_basic_node_update_hr 点。"
		else
			cru a ssnodeupdate "2 $ss_basic_node_update_hr * * $ss_basic_node_update_day /koolshare/scripts/ss_online_update.sh 3"
			echo_date "设置自动更新节点订阅在星期 $ss_basic_node_update_day 的 $ss_basic_node_update_hr 点。"
		fi
	fi
}

kill_cron_job(){
	if [ -n "`cru l|grep ssupdate`" ];then
		echo_date 删除shadowsocks规则定时更新任务...
		sed -i '/ssupdate/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	fi
	if [ -n "`cru l|grep ssnodeupdate`" ];then
		echo_date 删除节点定时订阅任务...
		sed -i '/ssnodeupdate/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	fi
}
#--------------------------------------nat part begin------------------------------------------------
load_tproxy(){
	MODULES="nf_tproxy_core xt_TPROXY xt_socket xt_comment"
	OS=$(uname -r)
	# load Kernel Modules
	echo_date 加载TPROXY模块，用于udp转发...
	checkmoduleisloaded(){
		if lsmod | grep $MODULE &> /dev/null; then return 0; else return 1; fi;
	}
	
	for MODULE in $MODULES; do
		if ! checkmoduleisloaded; then
			insmod /lib/modules/${OS}/kernel/net/netfilter/${MODULE}.ko
		fi
	done
	
	modules_loaded=0
	
	for MODULE in $MODULES; do
		if checkmoduleisloaded; then
			modules_loaded=$(( j++ )); 
		fi
	done
	
	if [ $modules_loaded -ne 3 ]; then
		echo "One or more modules are missing, only $(( modules_loaded+1 )) are loaded. Can't start.";
		close_in_five
	fi
}


flush_nat(){
	echo_date 清除iptables规则和ipset...
	# flush rules and set if any
	nat_indexs=`iptables -nvL PREROUTING -t nat |sed 1,2d | sed -n '/SHADOWSOCKS/='|sort -r`
	for nat_index in $nat_indexs
	do
		iptables -t nat -D PREROUTING $nat_index >/dev/null 2>&1
	done
	#iptables -t nat -D PREROUTING -p tcp -j SHADOWSOCKS >/dev/null 2>&1
	
	iptables -t nat -F SHADOWSOCKS > /dev/null 2>&1 && iptables -t nat -X SHADOWSOCKS > /dev/null 2>&1
	iptables -t nat -F SHADOWSOCKS_EXT > /dev/null 2>&1
	iptables -t nat -F SHADOWSOCKS_GFW > /dev/null 2>&1 && iptables -t nat -X SHADOWSOCKS_GFW > /dev/null 2>&1
	iptables -t nat -F SHADOWSOCKS_CHN > /dev/null 2>&1 && iptables -t nat -X SHADOWSOCKS_CHN > /dev/null 2>&1
	iptables -t nat -F SHADOWSOCKS_GAM > /dev/null 2>&1 && iptables -t nat -X SHADOWSOCKS_GAM > /dev/null 2>&1
	iptables -t nat -F SHADOWSOCKS_GLO > /dev/null 2>&1 && iptables -t nat -X SHADOWSOCKS_GLO > /dev/null 2>&1
	iptables -t nat -F SHADOWSOCKS_HOM > /dev/null 2>&1 && iptables -t nat -X SHADOWSOCKS_HOM > /dev/null 2>&1

	mangle_indexs=`iptables -nvL PREROUTING -t mangle |sed 1,2d | sed -n '/SHADOWSOCKS/='|sort -r`
	for mangle_index in $mangle_indexs
	do
		iptables -t mangle -D PREROUTING $mangle_index >/dev/null 2>&1
	done
	#iptables -t mangle -D PREROUTING -p udp -j SHADOWSOCKS >/dev/null 2>&1
	
	iptables -t mangle -F SHADOWSOCKS >/dev/null 2>&1 && iptables -t mangle -X SHADOWSOCKS >/dev/null 2>&1
	iptables -t mangle -F $(get_action_chain $ss_basic_mode) > /dev/null 2>&1 && iptables -t mangle -X $(get_action_chain $ss_basic_mode) > /dev/null 2>&1
	iptables -t nat -D OUTPUT -p tcp -m set --match-set router dst -j REDIRECT --to-ports 3333 >/dev/null 2>&1
	iptables -t nat -F OUTPUT > /dev/null 2>&1
	iptables -t nat -X SHADOWSOCKS_EXT > /dev/null 2>&1
	#iptables -t nat -D PREROUTING -p udp -s $(get_lan_cidr) --dport 53 -j DNAT --to $lan_ipaddr >/dev/null 2>&1
	# 清理DNS劫持规则和链
	chromecast_nu=`iptables -t nat -L PREROUTING -v -n --line-numbers|grep "SHADOWSOCKS_DNS_"|awk '{print $1}'|sort -r`
	if [ -n "$chromecast_nu" ]; then
		for chromecast_index in $chromecast_nu
		do
			iptables -t nat -D PREROUTING $chromecast_index >/dev/null 2>&1
		done
	fi
	VLAN_INDEXS=$(ifconfig | grep -E "^br" | awk '{print $1}' | sed 's/^br//g')
	for VLAN_INDEX in $VLAN_INDEXS
	do
		iptables -t nat -F SHADOWSOCKS_DNS_${VLAN_INDEX} >/dev/null 2>&1 && iptables -t nat -X SHADOWSOCKS_DNS_${VLAN_INDEX} >/dev/null 2>&1
	done

	iptables -t mangle -D QOSO0 -m mark --mark "$ip_prefix_hex" -j RETURN >/dev/null 2>&1
	# flush ipset
	ipset -F chnroute >/dev/null 2>&1 && ipset -X chnroute >/dev/null 2>&1
	ipset -F white_list >/dev/null 2>&1 && ipset -X white_list >/dev/null 2>&1
	ipset -F black_list >/dev/null 2>&1 && ipset -X black_list >/dev/null 2>&1
	ipset -F gfwlist >/dev/null 2>&1 && ipset -X gfwlist >/dev/null 2>&1
	ipset -F router >/dev/null 2>&1 && ipset -X router >/dev/null 2>&1
	#remove_redundant_rule
	ip_rule_exist=`ip rule show | grep "lookup 310" | grep -c 310`
	if [ -n "$ip_rule_exist" ];then
		#echo_date 清除重复的ip rule规则.
		until [ "$ip_rule_exist" = 0 ]
		do 
			IP_ARG=`ip rule show | grep "lookup 310"|head -n 1|cut -d " " -f3,4,5,6`
			ip rule del $IP_ARG
			ip_rule_exist=`expr $ip_rule_exist - 1`
		done
	fi
	#remove_route_table
	#echo_date 删除ip route规则.
	ip route del local 0.0.0.0/0 dev lo table 310 >/dev/null 2>&1
}

# create ipset rules
create_ipset(){
	echo_date 创建ipset名单
	ipset -! create white_list nethash && ipset flush white_list
	ipset -! create black_list nethash && ipset flush black_list
	ipset -! create gfwlist nethash && ipset flush gfwlist
	ipset -! create router nethash && ipset flush router
	ipset -! create chnroute nethash && ipset flush chnroute
	sed -e "s/^/add chnroute &/g" /koolshare/ss/rules/chnroute.txt | awk '{print $0} END{print "COMMIT"}' | ipset -R
}

add_white_black_ip(){
	# black ip/cidr
	if [ "$ss_basic_mode" != "6" ];then
		ip_tg="149.154.0.0/16 91.108.4.0/22 91.108.56.0/24 109.239.140.0/24 67.198.55.0/24"
		for ip in $ip_tg
		do
			ipset -! add black_list $ip >/dev/null 2>&1
		done
	fi
	
	if [ -n "$ss_wan_black_ip" ];then
		ss_wan_black_ip=`dbus get ss_wan_black_ip|base64_decode|sed '/\#/d'`
		echo_date 应用IP/CIDR黑名单
		for ip in $ss_wan_black_ip
		do
			ipset -! add black_list $ip >/dev/null 2>&1
		done
	fi
	
	# white ip/cidr
	[ -n "$ss_basic_server_ip" ] && SERVER_IP="$ss_basic_server_ip" || SERVER_IP=""
	[ -n "$IFIP_DNS1" ] && ISP_DNS_a="$ISP_DNS1" || ISP_DNS_a=""
	[ -n "$IFIP_DNS2" ] && ISP_DNS_b="$ISP_DNS2" || ISP_DNS_a=""
	ip_lan="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4 223.5.5.5 223.6.6.6 114.114.114.114 114.114.115.115 1.2.4.8 210.2.4.8 117.50.11.11 117.50.22.22 180.76.76.76 119.29.29.29 $ISP_DNS_a $ISP_DNS_b $SERVER_IP $(get_wan0_cidr)"
	for ip in $ip_lan
	do
		ipset -! add white_list $ip >/dev/null 2>&1
	done
	
	if [ -n "$ss_wan_white_ip" ];then
		ss_wan_white_ip=`echo $ss_wan_white_ip|base64_decode|sed '/\#/d'`
		echo_date 应用IP/CIDR白名单
		for ip in $ss_wan_white_ip
		do
			ipset -! add white_list $ip >/dev/null 2>&1
		done
	fi
}

get_action_chain() {
	case "$1" in
		0)
			echo "RETURN"
		;;
		1)
			echo "SHADOWSOCKS_GFW"
		;;
		2)
			echo "SHADOWSOCKS_CHN"
		;;
		3)
			echo "SHADOWSOCKS_GAM"
		;;
		5)
			echo "SHADOWSOCKS_GLO"
		;;
		6)
			echo "SHADOWSOCKS_HOM"
		;;
	esac
}

get_mode_name() {
	case "$1" in
		0)
			echo "不通过SS"
		;;
		1)
			echo "gfwlist模式"
		;;
		2)
			echo "大陆白名单模式"
		;;
		3)
			echo "游戏模式"
		;;
		5)
			echo "全局模式"
		;;
		6)
			echo "回国模式"
		;;
	esac
}

factor(){
	if [ -z "$1" ] || [ -z "$2" ]; then
		echo ""
	else
		echo "$2 $1"
	fi
}

get_jump_mode(){
	case "$1" in
		0)
			echo "j"
		;;
		*)
			echo "g"
		;;
	esac
}

lan_acess_control(){
	# lan access control
	acl_nu=`dbus list ss_acl_mode_|cut -d "=" -f 1 | cut -d "_" -f 4 | sort -n`
	if [ -n "$acl_nu" ]; then
		for acl in $acl_nu
		do
			ipaddr=`dbus get ss_acl_ip_$acl`
			# 跳过残缺规则：IP 为空会让 -s 被省略，规则会误作用到所有主机
			if [ -z "$ipaddr" ];then
				echo_date "ACL规则[$acl]缺少IP，已跳过"
				continue
			fi
			ipaddr_hex=`dbus get ss_acl_ip_$acl | awk -F "." '{printf ("0x%02x", $1)} {printf ("%02x", $2)} {printf ("%02x", $3)} {printf ("%02x\n", $4)}'`
			ports=`dbus get ss_acl_port_$acl`
			proxy_mode=`dbus get ss_acl_mode_$acl`
			proxy_name=`dbus get ss_acl_name_$acl`
			if [ "$ports" == "all" ];then
				ports=""
				echo_date 加载ACL规则：【$ipaddr】【全部端口】模式为：$(get_mode_name $proxy_mode)
			else
				echo_date 加载ACL规则：【$ipaddr】【$ports】模式为：$(get_mode_name $proxy_mode)
			fi
			# 1 acl in SHADOWSOCKS for nat
			iptables -t nat -A SHADOWSOCKS $(factor $ipaddr "-s") -p tcp $(factor $ports "-m multiport --dport") -$(get_jump_mode $proxy_mode) $(get_action_chain $proxy_mode)
			# 2 acl in OUTPUT（used by koolproxy）
			iptables -t nat -A SHADOWSOCKS_EXT -p tcp  $(factor $ports "-m multiport --dport") -m mark --mark "$ipaddr_hex" -$(get_jump_mode $proxy_mode) $(get_action_chain $proxy_mode)
			# 3 acl in SHADOWSOCKS for mangle
			if [ "$proxy_mode" == "3" ];then
				iptables -t mangle -A SHADOWSOCKS $(factor $ipaddr "-s") -p udp $(factor $ports "-m multiport --dport") -$(get_jump_mode $proxy_mode) $(get_action_chain $proxy_mode)
			else
				[ "$mangle" == "1" ] && iptables -t mangle -A SHADOWSOCKS $(factor $ipaddr "-s") -p udp -j RETURN
			fi
		done

		if [ "$ss_acl_default_port" == "all" ];then
			ss_acl_default_port=""
		fi
		# 默认模式为空时回退到主模式，避免生成空 -j 目标链
		if [ -z "$ss_acl_default_mode" ] || [ -z "$(get_action_chain $ss_acl_default_mode)" ];then
			ss_acl_default_mode="$ss_basic_mode"
			dbus set ss_acl_default_mode="$ss_basic_mode"
		fi
		if [ -z "$ss_acl_default_port" ];then
			echo_date 加载ACL规则：【剩余主机】【全部端口】模式为：$(get_mode_name $ss_acl_default_mode)
		else
			echo_date 加载ACL规则：【剩余主机】【$ss_acl_default_port】模式为：$(get_mode_name $ss_acl_default_mode)
		fi
	else
		ss_acl_default_mode="$ss_basic_mode"
		if [ "$ss_acl_default_port" == "all" ];then
			ss_acl_default_port="" 
			echo_date 加载ACL规则：【全部主机】【全部端口】模式为：$(get_mode_name $ss_acl_default_mode)
		else
			echo_date 加载ACL规则：【全部主机】【$ss_acl_default_port】模式为：$(get_mode_name $ss_acl_default_mode)
		fi
	fi
	dbus remove ss_acl_ip
	dbus remove ss_acl_name
	dbus remove ss_acl_mode
	dbus remove ss_acl_port
}

apply_nat_rules(){
	#----------------------BASIC RULES---------------------
	echo_date 写入iptables规则到nat表中...
	# 创建SHADOWSOCKS nat rule
	iptables -t nat -N SHADOWSOCKS
	# 扩展
	iptables -t nat -N SHADOWSOCKS_EXT
	# IP/cidr/白域名 白名单控制（不走ss）
	iptables -t nat -A SHADOWSOCKS -p tcp -m set --match-set white_list dst -j RETURN
	iptables -t nat -A SHADOWSOCKS_EXT -p tcp -m set --match-set white_list dst -j RETURN
	#-----------------------FOR GLOABLE---------------------
	# 创建gfwlist模式nat rule
	iptables -t nat -N SHADOWSOCKS_GLO
	# IP黑名单控制-gfwlist（走ss）
	iptables -t nat -A SHADOWSOCKS_GLO -p tcp -j REDIRECT --to-ports 3333
	#-----------------------FOR GFWLIST---------------------
	# 创建gfwlist模式nat rule
	iptables -t nat -N SHADOWSOCKS_GFW
	# IP/CIDR/黑域名 黑名单控制（走ss）
	iptables -t nat -A SHADOWSOCKS_GFW -p tcp -m set --match-set black_list dst -j REDIRECT --to-ports 3333
	# IP黑名单控制-gfwlist（走ss）
	iptables -t nat -A SHADOWSOCKS_GFW -p tcp -m set --match-set gfwlist dst -j REDIRECT --to-ports 3333
	#-----------------------FOR CHNMODE---------------------
	# 创建大陆白名单模式nat rule
	iptables -t nat -N SHADOWSOCKS_CHN
	# IP/CIDR/域名 黑名单控制（走ss）
	iptables -t nat -A SHADOWSOCKS_CHN -p tcp -m set --match-set black_list dst -j REDIRECT --to-ports 3333
	# cidr黑名单控制-chnroute（走ss）
	iptables -t nat -A SHADOWSOCKS_CHN -p tcp -m set ! --match-set chnroute dst -j REDIRECT --to-ports 3333
	#-----------------------FOR GAMEMODE---------------------
	# 创建游戏模式nat rule
	iptables -t nat -N SHADOWSOCKS_GAM
	# IP/CIDR/域名 黑名单控制（走ss）
	iptables -t nat -A SHADOWSOCKS_GAM -p tcp -m set --match-set black_list dst -j REDIRECT --to-ports 3333
	# cidr黑名单控制-chnroute（走ss）
	iptables -t nat -A SHADOWSOCKS_GAM -p tcp -m set ! --match-set chnroute dst -j REDIRECT --to-ports 3333
	#-----------------------FOR HOMEMODE---------------------
	# 创建回国模式nat rule
	 iptables -t nat -N SHADOWSOCKS_HOM
	# IP/CIDR/域名 黑名单控制（走ss）
	iptables -t nat -A SHADOWSOCKS_HOM -p tcp -m set --match-set black_list dst -j REDIRECT --to-ports 3333
	# cidr黑名单控制-chnroute（走ss）
	iptables -t nat -A SHADOWSOCKS_HOM -p tcp -m set --match-set chnroute dst -j REDIRECT --to-ports 3333

	[ "$mangle" == "1" ] && load_tproxy
	[ "$mangle" == "1" ] && ip rule add fwmark 0x07 table 310
	[ "$mangle" == "1" ] && ip route add local 0.0.0.0/0 dev lo table 310
	# 创建游戏模式udp rule
	[ "$mangle" == "1" ] && iptables -t mangle -N SHADOWSOCKS
	# IP/cidr/白域名 白名单控制（不走ss）
	[ "$mangle" == "1" ] && iptables -t mangle -A SHADOWSOCKS -p udp -m set --match-set white_list dst -j RETURN
	# 创建游戏模式udp rule
	[ "$mangle" == "1" ] && iptables -t mangle -N $(get_action_chain $ss_basic_mode)
	# IP/CIDR/域名 黑名单控制（走ss）
	[ "$mangle" == "1" ] && iptables -t mangle -A $(get_action_chain $ss_basic_mode) -p udp -m set --match-set black_list dst -j TPROXY --on-port 3333 --tproxy-mark 0x07
	# cidr黑名单控制-chnroute（走ss）
	[ "$mangle" == "1" ] && iptables -t mangle -A $(get_action_chain $ss_basic_mode) -p udp -m set ! --match-set chnroute dst -j TPROXY --on-port 3333 --tproxy-mark 0x07
	#-------------------------------------------------------
	# 局域网黑名单（不走ss）/局域网黑名单（走ss）
	lan_acess_control
	#-----------------------FOR ROUTER---------------------
	# router itself
	[ "$ss_basic_mode" != "6" ] && iptables -t nat -A OUTPUT -p tcp -m set --match-set router dst -j REDIRECT --to-ports 3333
	iptables -t nat -A OUTPUT -p tcp -m mark --mark "$ip_prefix_hex" -j SHADOWSOCKS_EXT
	
	# 把最后剩余流量重定向到相应模式的nat表中对应的主模式的链
	ACL_DEFAULT_CHAIN=$(get_action_chain $ss_acl_default_mode)
	if [ -n "$ACL_DEFAULT_CHAIN" ];then
		iptables -t nat -A SHADOWSOCKS -p tcp $(factor $ss_acl_default_port "-m multiport --dport") -j $ACL_DEFAULT_CHAIN
		iptables -t nat -A SHADOWSOCKS_EXT -p tcp $(factor $ss_acl_default_port "-m multiport --dport") -j $ACL_DEFAULT_CHAIN
	else
		echo_date "警告：ACL默认模式无效（$ss_acl_default_mode），跳过默认跳转规则"
	fi
	
	# 如果是主模式游戏模式，则把SHADOWSOCKS链中剩余udp流量转发给SHADOWSOCKS_GAM链
	# 如果主模式不是游戏模式，则不需要把SHADOWSOCKS链中剩余udp流量转发给SHADOWSOCKS_GAM，不然会造成其他模式主机的udp也走游戏模式
	###[ "$mangle" == "1" ] && ss_acl_default_mode=3
	[ "$ss_acl_default_mode" != "0" ] && [ "$ss_acl_default_mode" != "3" ] && [ "$ss_basic_udp_sync" != "1" ]  && ss_acl_default_mode=0
	[ "$ss_basic_mode" == "3" ] || [ "$ss_basic_udp_sync" == "1" ]  && [ -n "$(get_action_chain $ss_acl_default_mode)" ] && iptables -t mangle -A SHADOWSOCKS -p udp -j $(get_action_chain $ss_acl_default_mode)
	# 重定所有流量到 SHADOWSOCKS
	KP_NU=`iptables -nvL PREROUTING -t nat |sed 1,2d | sed -n '/KOOLPROXY/='|head -n1`
	[ "$KP_NU" == "" ] && KP_NU=0
	INSET_NU=`expr "$KP_NU" + 1`
	iptables -t nat -I PREROUTING "$INSET_NU" -p tcp -j SHADOWSOCKS
	[ "$mangle" == "1" ] && iptables -t mangle -A PREROUTING -p udp -j SHADOWSOCKS
	# QOS开启的情况下
	QOSO=`iptables -t mangle -S | grep -o QOSO | wc -l`
	RRULE=`iptables -t mangle -S | grep "A QOSO" | head -n1 | grep RETURN`
	if [ "$QOSO" -gt "1" ] && [ -z "$RRULE" ];then
		iptables -t mangle -I QOSO0 -m mark --mark "$ip_prefix_hex" -j RETURN
	fi
}

dns_hijack_control(){
	if [ "$ss_basic_dns_hijack" == "1" ];then
		local VLAN_INDEXS=$(ifconfig | grep -E "^br" | awk '{print $1}' | sed 's/^br//g')
		for VLAN_INDEX in ${VLAN_INDEXS}
		do
			local dest_ipaddr=$(ifconfig br${VLAN_INDEX} | grep "inet addr" | awk '{print $2}'|awk -F ":" '{print $2}')
			iptables -t nat -N SHADOWSOCKS_DNS_${VLAN_INDEX} >/dev/null 2>&1
			iptables -t nat -F SHADOWSOCKS_DNS_${VLAN_INDEX} >/dev/null 2>&1
			iptables -t nat -A SHADOWSOCKS_DNS_${VLAN_INDEX} -p udp -j DNAT --to ${dest_ipaddr}:53
		done
	fi
}


chromecast(){
	chromecast_nu=`iptables -t nat -L PREROUTING -v -n --line-numbers|grep "SHADOWSOCKS_DNS_"|awk '{print $1}'|sort -r`
	if [ -n "$chromecast_nu" ]; then
		for chromecast_index in $chromecast_nu
		do
			iptables -t nat -D PREROUTING $chromecast_index >/dev/null 2>&1
		done
	fi
	if [ "$ss_basic_dns_hijack" == "1" ];then
		echo_date 开启DNS劫持功能功能，防止DNS污染...
		dns_hijack_control
		local VLAN_INDEXS=$(ifconfig | grep -E "^br" | awk '{print $1}' | sed 's/^br//g')
		local INSET_NU_DNS=$((${INSET_NU} + 1))
		for VLAN_INDEX in ${VLAN_INDEXS}
		do
			iptables -t nat -I PREROUTING "${INSET_NU_DNS}" -i br${VLAN_INDEX} -p udp -m udp --dport 53 -j SHADOWSOCKS_DNS_${VLAN_INDEX}
			let INSET_NU_DNS+=1
		done
	else
		echo_date DNS劫持功能未开启，建议开启！
	fi
}
# -----------------------------------nat part end--------------------------------------------------------

restart_dnsmasq(){
	# Restart dnsmasq
	echo_date 重启dnsmasq服务...
	service restart_dnsmasq >/dev/null 2>&1
}

load_module(){
	xt=`lsmod | grep xt_set`
	OS=$(uname -r)
	if [ -f /lib/modules/${OS}/kernel/net/netfilter/xt_set.ko ] && [ -z "$xt" ];then
		echo_date "加载xt_set.ko内核模块！"
		insmod /lib/modules/${OS}/kernel/net/netfilter/xt_set.ko
	fi
}

# write number into nvram with no commit
write_numbers(){
	nvram set update_ipset="$(cat /koolshare/ss/rules/version | sed -n 1p | sed 's/#/\n/g'| sed -n 1p)"
	nvram set update_chnroute="$(cat /koolshare/ss/rules/version | sed -n 2p | sed 's/#/\n/g'| sed -n 1p)"
	nvram set update_cdn="$(cat /koolshare/ss/rules/version | sed -n 4p | sed 's/#/\n/g'| sed -n 1p)"
	nvram set ipset_numbers=$(cat /koolshare/ss/rules/gfwlist.conf | grep -c ipset)
	nvram set chnroute_numbers=$(cat /koolshare/ss/rules/chnroute.txt | grep -c .)
	nvram set cdn_numbers=$(cat /koolshare/ss/rules/cdn.txt | grep -c .)
}

set_ulimit(){
	ulimit -n 16384
	echo 1 > /proc/sys/vm/overcommit_memory
}

remove_ss_reboot_job(){
	if [ -n "`cru l|grep ss_reboot`" ]; then
		echo_date 删除插件自动重启定时任务...
		#cru d ss_reboot >/dev/null 2>&1
		sed -i '/ss_reboot/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	fi
}

set_ss_reboot_job(){
	if [[ "${ss_reboot_check}" == "0" ]]; then
		remove_ss_reboot_job
	elif [[	"${ss_reboot_check}" ==	"1"	]];	then
		echo_date 设置每天${ss_basic_time_hour}时${ss_basic_time_min}分重启插件...
		cru	a ss_reboot	${ss_basic_time_min} ${ss_basic_time_hour}"	* *	* /koolshare/ss/ssconfig.sh	restart"
	elif [[	"${ss_reboot_check}" ==	"2"	]];	then
		echo_date 设置每周${ss_basic_week}的${ss_basic_time_hour}时${ss_basic_time_min}分重启插件...
		cru	a ss_reboot	${ss_basic_time_min} ${ss_basic_time_hour}"	* *	"${ss_basic_week}" /koolshare/ss/ssconfig.sh restart"
	elif [[	"${ss_reboot_check}" ==	"3"	]];	then
		echo_date 设置每月${ss_basic_day}日${ss_basic_time_hour}时${ss_basic_time_min}分重启插件...
		cru	a ss_reboot	${ss_basic_time_min} ${ss_basic_time_hour} ${ss_basic_day}"	* *	/koolshare/ss/ssconfig.sh restart"
	elif [[	"${ss_reboot_check}" ==	"4"	]];	then
		if [[ "${ss_basic_inter_pre}" == "1" ]]; then
			echo_date 设置每隔${ss_basic_inter_min}分钟重启插件...
			cru	a ss_reboot	"*/"${ss_basic_inter_min}" * * * * /koolshare/ss/ssconfig.sh restart"
		elif [[	"${ss_basic_inter_pre}"	== "2" ]]; then
			echo_date 设置每隔${ss_basic_inter_hour}小时重启插件...
			cru	a ss_reboot	"0 */"${ss_basic_inter_hour}" *	* *	/koolshare/ss/ssconfig.sh restart"
		elif [[	"${ss_basic_inter_pre}"	== "3" ]]; then
			echo_date 设置每隔${ss_basic_inter_day}天${ss_basic_inter_hour}小时${ss_basic_time_min}分钟重启插件...
			cru	a ss_reboot	${ss_basic_time_min} ${ss_basic_time_hour}"	*/"${ss_basic_inter_day} " * * /koolshare/ss/ssconfig.sh restart"
		fi
	elif [[	"${ss_reboot_check}" ==	"5"	]];	then
		check_custom_time=`dbus	get	ss_basic_custom	| base64_decode`
		echo_date 设置每天${check_custom_time}时的${ss_basic_time_min}分重启插件...
		cru	a ss_reboot	${ss_basic_time_min} ${check_custom_time}" * * * /koolshare/ss/ssconfig.sh restart"
	else
		remove_ss_reboot_job
	fi
}

remove_ss_trigger_job(){
	if [ -n "`cru l|grep ss_tri_check`" ]; then
		echo_date 删除插件触发重启定时任务...
		#cru d ss_tri_check >/dev/null 2>&1
		sed -i '/ss_tri_check/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	fi
}

set_ss_trigger_job(){
	if [ "$ss_basic_tri_reboot_time" == "0" ] || [ -z "$ss_basic_tri_reboot_time" ];then
		remove_ss_trigger_job
	else
		if [ "$ss_basic_tri_reboot_policy" == "1" ];then
			echo_date 设置每隔$ss_basic_tri_reboot_time分钟检查服务器IP地址，如果IP发生变化，则重启科学上网插件...
		else
			echo_date 设置每隔$ss_basic_tri_reboot_time分钟检查服务器IP地址，如果IP发生变化，则重启dnsmasq...
		fi
		cru d ss_tri_check  >/dev/null 2>&1
		cru a ss_tri_check "*/$ss_basic_tri_reboot_time * * * * /koolshare/scripts/ss_reboot_job.sh check_ip"
	fi
}

load_nat(){
	nat_ready=$(iptables -t nat -L PREROUTING -v -n --line-numbers|grep -v PREROUTING|grep -v destination)
	i=120
	until [ -n "$nat_ready" ]
	do
		i=$(($i-1))
		if [ "$i" -lt 1 ];then
			echo_date "错误：不能正确加载nat规则!"
			close_in_five
		fi
		sleep 1
		nat_ready=$(iptables -t nat -L PREROUTING -v -n --line-numbers|grep -v PREROUTING|grep -v destination)
	done
	echo_date "加载nat规则!"
	#create_ipset
	add_white_black_ip
	apply_nat_rules
	chromecast
}

ss_post_start(){
	# 在SS插件启动成功后触发脚本
	mkdir -p /koolshare/ss/postscripts && cd /koolshare/ss/postscripts
	for i in $(find ./ -name 'P*' | sort) ;
	do
		trap "" INT QUIT TSTP EXIT
		echo_date ------------- 【科学上网】 启动后触发脚本: $i -------------
		if [ -r "$i" ]; then
			$i start
		fi
		echo_date ----------------- 触发脚本: $i 运行完毕 -----------------
	done
}

ss_pre_stop(){
	# 在SS插件关闭前触发脚本
	mkdir -p /koolshare/ss/postscripts && cd /koolshare/ss/postscripts
	for i in $(find ./ -name 'P*' | sort -r) ;
	do
		trap "" INT QUIT TSTP EXIT
		echo_date ------------- 【科学上网】 关闭前触发脚本: $i ------------
		if [ -r "$i" ]; then
			$i stop
		fi
		echo_date ----------------- 触发脚本: $i 运行完毕 -----------------
	done
}

detect(){
	# 检测jffs2脚本是否开启，如果没有开启，将会影响插件的自启和DNS部分（dnsmasq.postconf）
	if [ "`nvram get jffs2_scripts`" != "1" ];then
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date "+     发现你未开启Enable JFFS custom scripts and configs选项！     +"
		echo_date "+    【软件中心】和【科学上网】插件都需要此项开启才能正常使用！！         +"
		echo_date "+     请前往【系统管理】- 【系统设置】去开启，并重启路由器后重试！！      +"
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		close_in_five
	fi
	
	# 检测是否在lan设置中是否自定义过dns,如果有给干掉
	if [ -n "`nvram get dhcp_dns1_x`" ];then
		nvram unset dhcp_dns1_x
		nvram commit
	fi
	if [ -n "`nvram get dhcp_dns2_x`" ];then
		nvram unset dhcp_dns2_x
		nvram commit
	fi
}

mount_dnsmasq(){
	killall dnsmasq >/dev/null 2>&1
	mount --bind /koolshare/bin/dnsmasq /usr/sbin/dnsmasq
	#service restart_dnsmasq >/dev/null 2>&
}

umount_dnsmasq(){
	killall dnsmasq >/dev/null 2>&1
	umount /usr/sbin/dnsmasq
}


mount_dnsmasq_now(){
	MOUNTED=`mount|grep -o dnsmasq`
	case $ss_basic_dnsmasq_fastlookup in
	0)
		if [ -n "$MOUNTED" ];then
			echo_date "【dnsmasq替换】：从dnsmasq-fastlookup切换为原版dnsmasq"
			umount_dnsmasq
		fi
		;;
	1|3)
		if [ -n "$MOUNTED" ];then
			echo_date "【dnsmasq替换】：dnsmasq-fastlookup已经替换过了！"
		else
			echo_date "【dnsmasq替换】：用dnsmasq-fastlookup替换原版dnsmasq！"
			mount_dnsmasq
		fi
		;;
	2)
		if [ -L "/jffs/configs/dnsmasq.d/cdn.conf" ];then
			if [ -z "$MOUNTED" ];then
				echo_date "【dnsmasq替换】：检测到cdn.conf，用dnsmasq-fastlookup替换原版dnsmasq！"
				mount_dnsmasq
			fi
		else
			if [ -n "$MOUNTED" ];then
				echo_date "【dnsmasq替换】：没有检测到cdn.conf，从dnsmasq-fastlookup切换为原版dnsmasq"
				umount_dnsmasq
			else
				echo_date "【dnsmasq替换】：没有检测到cdn.conf，不替换dnsmasq-fastlookup"
			fi
		fi
		;;
	esac
}

umount_dnsmasq_now(){
	MOUNTED=`mount|grep -o dnsmasq`
	case $ss_basic_dnsmasq_fastlookup in
	0|1|2)
		if [ -n "$MOUNTED" ];then
			echo_date "【dnsmasq替换】：从dnsmasq-fastlookup切换为原版dnsmasq"
			umount_dnsmasq
		fi
		;;
	3)
		if [ -n "$MOUNTED" ];then
			echo_date "【dnsmasq替换】：dnsmasq-fastlookup已经替换过了，插件关闭后保持替换！"
		else
			echo_date "【dnsmasq替换】：用dnsmasq-fastlookup替换原版dnsmasq！且插件关闭后保持替换！"
			mount_dnsmasq
		fi
		;;
	esac
}

disable_ss(){
	echo_date ======================= 梅林固件 - 【科学上网】 ========================
	echo_date
	echo_date ------------------------- 关闭【科学上网】 -----------------------------
	nvram set ss_mode=0
	dbus set dns2socks=0
	dbus remove ss_basic_server_ip
	nvram commit
	kill_process
	remove_ss_trigger_job
	remove_ss_reboot_job
	restore_conf
	umount_dnsmasq_now
	restart_dnsmasq
	flush_nat
	kill_cron_job
	echo_date ------------------------ 【科学上网】已关闭 ----------------------------
}

apply_ss(){
	# router is on boot
	WAN_ACTION=`ps|grep /jffs/scripts/wan-start|grep -v grep`
	# now stop first
	echo_date ======================= 梅林固件 - 【科学上网】 ========================
	echo_date
	echo_date ------------------------- 启动【科学上网】 -----------------------------
	ss_pre_stop
	nvram set ss_mode=0
	dbus set dns2socks=0
	nvram commit
	kill_process
	remove_ss_trigger_job
	remove_ss_reboot_job
	restore_conf
	# restart dnsmasq when ss server is not ip or on router boot
	restart_dnsmasq
	flush_nat
	kill_cron_job
	#echo_date ------------------------ 【科学上网】已关闭 ----------------------------
	# pre-start
	ss_pre_start
	# start
	#echo_date ------------------------- 启动 【科学上网】 ----------------------------
	detect
	resolv_server_ip
	load_module
	create_ipset
	create_dnsmasq_conf
	# do not re generate json on router start, use old one
	# Xray-only: VLESS/VMess/SS2022 (type=3), Trojan/Trojan-Go (type=4)
	[ -z "$WAN_ACTION" ] && [ "$ss_basic_type" = "3" ] && [ "$SS2022" != "Y" ] && create_v2ray_json
	[ -z "$WAN_ACTION" ] && [ "$ss_basic_type" = "3" ] && [ "$SS2022" == "Y" ] && create_ss2022_json
	[ -z "$WAN_ACTION" ] && [ "$ss_basic_type" = "4" ] && echo "$ss_basic_trojan_binary" | grep -q "^Trojan-Go" && create_trojango_json
	[ -z "$WAN_ACTION" ] && [ "$ss_basic_type" = "4" ] && ! echo "$ss_basic_trojan_binary" | grep -q "^Trojan-Go" && create_trojan_json
	start_xray_core
	start_dns
	#===load nat start===
	load_nat
	#===load nat end===
	mount_dnsmasq_now
	restart_dnsmasq
	auto_start
	write_cron_job
	set_ss_reboot_job
	set_ss_trigger_job
	# post-start
	ss_post_start
	echo_date ------------------------ 【科学上网】 启动完毕 ------------------------
}

# for debug
get_status(){
	echo_date 
	echo_date =========================================================
	echo_date "PID of this script: $$"
	echo_date "PPID of this script: $PPID"
	echo_date ========== 本脚本的PID ==========
	ps|grep $$|grep -v grep
	echo_date ========== 本脚本的PPID ==========
	ps|grep $PPID|grep -v grep
	echo_date ========== 所有运行中的shell ==========
	ps|grep "\.sh"|grep -v grep
	echo_date ------------------------------------

	WAN_ACTION=`ps|grep /jffs/scripts/wan-start|grep -v grep`
	NAT_ACTION=`ps|grep /jffs/scripts/nat-start|grep -v grep`
	WEB_ACTION=`ps|grep "ss_config.sh"|grep -v grep`
	[ -n "$WAN_ACTION" ] && echo_date 路由器开机触发koolss重启！
	[ -n "$NAT_ACTION" ] && echo_date 路由器防火墙触发koolss重启！
	[ -n "$WEB_ACTION" ] && echo_date WEB提交操作触发koolss重启！
	
	iptables -nvL PREROUTING -t nat
	iptables -nvL OUTPUT -t nat
	iptables -nvL SHADOWSOCKS -t nat
	iptables -nvL SHADOWSOCKS_EXT -t nat
	iptables -nvL SHADOWSOCKS_GFW -t nat
	iptables -nvL SHADOWSOCKS_CHN -t nat
	iptables -nvL SHADOWSOCKS_GAM -t nat
	iptables -nvL SHADOWSOCKS_GLO -t nat
}

# =========================================================================

case $ACTION in
start)
	set_lock
	if [ "$ss_basic_enable" == "1" ];then
		logger "[软件中心]: 启动科学上网插件！"
		set_ulimit >> "$LOG_FILE"
		apply_ss >> "$LOG_FILE"
		write_numbers >> "$LOG_FILE"
	else
		logger "[软件中心]: 科学上网插件未开启，不启动！"
	fi
	#get_status >> /tmp/ss_start.txt
	unset_lock
	;;
stop)
	set_lock
	ss_pre_stop
	disable_ss
	echo_date
	echo_date 你已经成功关闭shadowsocks服务~
	echo_date See you again!
	echo_date
	echo_date ======================= 梅林固件 - 【科学上网】 ========================
	#get_status >> /tmp/ss_start.txt
	unset_lock
	;;
restart)
	set_lock
	set_ulimit
	apply_ss
	write_numbers
	echo_date
	echo_date "Across the Great Wall we can reach every corner in the world!"
	echo_date
	echo_date ======================= 梅林固件 - 【科学上网】 ========================
	#get_status >> /tmp/ss_start.txt
	unset_lock
	;;
flush_nat)
	set_lock
	flush_nat
	unset_lock
	;;
*)
	set_lock
	if [ "$ss_basic_enable" == "1" ];then
		set_ulimit
		apply_ss
		write_numbers
	fi
	#get_status >> /tmp/ss_start.txt
	unset_lock
	;;
esac

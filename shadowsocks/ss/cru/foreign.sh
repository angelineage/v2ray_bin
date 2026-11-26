#!/bin/sh
source /koolshare/scripts/base.sh
LOGTIME=$(date "+%Y-%m-%d %H:%M:%S")

# Probe through the plugin's local socks5 entry (127.0.0.1:23456).
# The hostname is resolved by the proxy side, so this check does NOT depend
# on dnsmasq, the router ipset, or the nat OUTPUT redirect. That keeps the
# indicator correct even with dnsmasq-fastlookup enabled.
result=$(/koolshare/bin/curl -k -sS --socks5-hostname 127.0.0.1:23456 -m 8 -o /dev/null -w '%{http_code} %{time_total}' https://www.google.com.tw/ 2>/dev/null)
code=${result%% *}
elapsed=${result##* }

case "$code" in
	2*|3*)
		ms=$(awk -v t="$elapsed" 'BEGIN{printf "%.0f", t*1000}')
		log='国外链接 【'$LOGTIME'】 ✓&nbsp;&nbsp;'$ms' ms'
		;;
	*)
		# fallback for node types without a local socks5 entry
		ret=$(/koolshare/bin/httping www.google.com.tw -s -Z -c1 -f -t 3 2>/dev/null|sed -n '2p'|sed 's/seq=0//g'|sed 's/([0-9]\+\sbytes),\s//g')
		S1=$(echo $ret|grep -Eo "200 OK")
		if [ -n "$S1" ]; then
			S2=$(echo $ret|sed 's/time=//g'|awk '{printf "%.0f ms\n",$(NF -3)}')
			log='国外链接 【'$LOGTIME'】 ✓&nbsp;&nbsp;'$S2''
		else
			log='国外链接 【'$LOGTIME'】 <font color='#FF0000'>X</font>'
		fi
		;;
esac

nvram set ss_foreign_state="$log"

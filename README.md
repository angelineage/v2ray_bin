# Xray-only 科学上网插件 for koolshare Merlin 380 ARM

基于 fancyss_arm380 精简重构：**仅保留 Xray 内核**，移除 SS / SSR / KoolGame / NaiveProxy / Hysteria2 / AnyTLS / haproxy 负载均衡等全部非 Xray 组件。

## 保留的能力

* **内核**：Xray（唯一内核，v26.6.1）
* **协议**：VLESS、VMess、Trojan、Trojan-Go（均走 Xray）；Shadowsocks 2022（2022-blake3-*，走 Xray）
* **传输**：TCP / WebSocket / HTTP/2 / gRPC / **XHTTP**（含 mode、extra）、XTLS Vision、Reality
* **功能**：Xray 本地聚合（leastPing / roundRobin / random）、多链接订阅、VLESS/VMess/Trojan 订阅导入
* **DNS**：dns2socks / chinadns / chinadns-ng / chinadns1 / SmartDNS / ChinaDNS-NG / cdns / https_dns_proxy / dnsmasq-fastlookup（保留完整域名分流）
* **分流**：gfwlist / chnroute / 大陆白名单 / 全局 / 回国模式、访问控制、DNS 劫持

## 已移除

SS/SSR 原生内核及其插件、KoolGame（含游戏模式 UDP 通道）、KCP/UDPspeeder/UDP2raw、haproxy 负载均衡页、NaiveProxy / Hysteria2 / AnyTLS / Trojan-Go 独立二进制、在线更新与历史版本回滚（历史存档已删除）。

> ss-tunnel 是 SS 专用 DNS 方案，已移除；选择该方案的节点会自动回退到 dns2socks。

## 安装

离线安装包位于 `380_armv5_packge/latest.tar.gz`，仅适用于 koolshare 梅林 380（内核 2.6.36.4、armv7）平台。在软件中心选择离线安装即可。

支持机型：RT-AC56U / AC68U / AC66U-B1 / AC1900P / AC87U / AC88U / AC3100 / AC3200 / AC5300；Netgear R6300V2 / R6400 / R6900 / R7000 / R8000 / R8500；Linksys EA6200~EA6900；华为 WS880。

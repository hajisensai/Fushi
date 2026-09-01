# vcpkg overlay ports（本仓私有补丁）

`libtorrent/` 是从 vcpkg baseline `aae277acf4`（见 `../vcpkg.json`）抽出的
libtorrent **2.0.11** port 原样拷贝，外加一个本仓补丁；两个构建脚本
（`build_windows_dll.ps1` / `build_android_so.ps1`）通过
`-DVCPKG_OVERLAY_PORTS` 指到本目录，overlay 无条件优先于 registry。

## 为什么需要补丁（dht-follows-peer-proxy-exemption.patch）

上游 `udp_socket.cpp` 的发送路径把「既非 peer 也非 tracker」的 UDP 流量
（即 DHT）在配置了任何代理时**无条件**走代理——代理承载不了 UDP
（HTTP 代理、或无 UDP ASSOCIATE 的 SOCKS5）时包直接被丢，DHT 判死。
这是上游的防泄漏设计，settings_pack 无法绕过；但它让「混合代理档」
（tracker 经代理 + peer/DHT 直连，`ht_apply_proxy_mode` mode=2）失去
最大的节点来源。

补丁把无 flag UDP（DHT）的代理豁免对齐到 **peer 面**
（`proxy_peer_connections`）：全代理档（peer=true）行为与上游完全一致；
混合档（peer=false）DHT 走直连。接收路径上游本来就在任一豁免 flag
关闭时放行裸包（`udp_socket.cpp` 的 `proxy_only` 判定），补丁只对齐
发送侧，不改任何默认行为。

## 清理条件

- bridge 迁到 libtorrent 2.1 时（`../vcpkg.json` 里 overrides 删除之日），
  本 overlay 需要基于 2.1 的 port 重做，补丁逻辑同两行。
- 若上游将来提供 DHT 独立的代理豁免设置，删本 overlay 改用官方设置。

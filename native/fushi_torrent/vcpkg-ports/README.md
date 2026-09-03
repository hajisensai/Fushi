# vcpkg overlay ports（本仓私有补丁）

`libtorrent/` 是从 vcpkg baseline `aae277acf4`（见 `../vcpkg.json`）抽出的
libtorrent **2.0.11** port 原样拷贝（与上游只差 `PATCHES` 一行和
`port-version`），外加一个本仓补丁；**三个**构建脚本
（`build_windows_dll.ps1` / `build_android_so.ps1` / CI 走的
`build_android_so.sh`）都通过 `-DVCPKG_OVERLAY_PORTS` 指到本目录，
overlay 无条件优先于 registry。漏挂任何一个 = 那条产线的补丁静默失效。

## 为什么需要补丁（dht-follows-peer-proxy-exemption.patch）

上游 `udp_socket.cpp` 的发送路径把「既非 peer 也非 tracker」的 UDP 流量
（即 DHT）在配置了任何代理时**无条件**走代理——代理承载不了 UDP
（HTTP 代理、或无 UDP ASSOCIATE 的 SOCKS5）时包直接被丢，DHT 判死。
这是上游的防泄漏设计，settings_pack 无法绕过；但它让「混合代理档」
（tracker 经代理 + peer/DHT 直连，`ht_apply_proxy_mode` mode=2）失去
最大的节点来源。

补丁把无 flag UDP（DHT）的代理豁免对齐到 **peer 面**
（`proxy_peer_connections`）：全代理档（peer=true）行为与上游完全一致；
混合档（peer=false）DHT 走直连。**发送和接收两侧都要改，只改一侧的混合档
是半死的**：

- 发送侧（`send` / `send_hostname` 各一处 `use_proxy`）：无 flag UDP 跟随
  peer 面，混合档下直发。
- 接收侧（`read()`）：上游只在 **SOCKS5 隧道没起来**时才走 `proxy_only`
  判定放行裸包；一旦 `active_socks5()` 为真，**任何源地址不是代理的包一律
  丢弃**。于是 SOCKS5 混合档会变成「DHT/uTP 查询直发出去、回包全被吃掉」。
  补丁把「是否走解包路径」的判据从 `active_socks5()` 改成
  `active_socks5() && 包确实来自代理`，非代理来源的包落进原来的 `proxy_only`
  分支——全代理档 `proxy_only` 恒为真，照旧丢弃，行为与上游逐位一致；
  混合档 `proxy_only` 为假，裸包放行。

三个 hunk 合起来才是「混合档」的完整语义；默认档（direct / 全代理）行为
不变。

## 清理条件

- bridge 迁到 libtorrent 2.1 时（`../vcpkg.json` 里 overrides 删除之日），
  本 overlay 需要基于 2.1 的 port 重做，补丁逻辑同三处。
- 若上游将来提供 DHT 独立的代理豁免设置，删本 overlay 改用官方设置。

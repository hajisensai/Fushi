# vcpkg overlay ports（本仓私有补丁）

`libtorrent/` 是从 vcpkg baseline `aae277acf4`（见 `../vcpkg.json`）抽出的
libtorrent **2.0.11** port 原样拷贝（与上游只差 `PATCHES` 三行和
`port-version`），外加三个补丁：两个本仓补丁、一个上游修复回移；**三个**构建脚本
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

## 上游修复回移（dh-shared-secret-padding.patch）

上游 `arvidn/libtorrent@e7049d21d335`（RC_2_0，2026-05-31；v2.1.0 也有），
2.0.11 发布时还没有，2.0 线不会再发版，只能自己回移。原样一行，不做改动。

2.0.11 的 `dh_key_exchange::compute_secret()` 算 MSE 握手的 req3 异或掩码时，
用裸 `mp::export_bits()` 往一个**未初始化**的 96 字节数组里写共享密钥：
密钥首字节为 0（约 1/256 次握手）时写不满，尾部是栈上残留，两端算出的掩码
不同。接收方找到同步点（req1 走的是补齐到 96 字节的 `export_key()`，两端一致）
之后反查种子失败，以 `invalid info-hash` 断开。默认加密策略下发起方随后退回明文
重连，通常能自愈，但每次都白白多一轮连接；「强制加密」时没有明文退路。
详见 `docs/bugs/BUG-2814-libtorrent-mse-mask-padding.md`。

## 为什么需要补丁（listen-bind-access-denied-fallback.patch）

`session_impl::setup_listener` 先 bind TCP，再把 uTP 的 UDP socket bind 到**同一个
端口**；TCP、UDP 两段都只在 `address_in_use` 上重试 / 走
`listen_system_port_fallback`，其它错误一律丢掉整条 listen socket（连同已经
bind 好的 TCP）。Windows 上 TCP 可用、UDP 回 WSAEACCES(10013) 的端口很常见：
Hyper-V/WinNAT 的 UDP 排除段、被系统服务独占的 UDP 端口（mDNS 5353）。
`127.0.0.1:0` / 用户配的端口碰上它就 `listen_port()==0`，而且没有 listen socket
连出站连接都建不起来（`[sock_bind] not supported`）。

补丁把两段四处判据都改成 `address_in_use || access_denied`：TCP 能用就留在原端口，
uTP 退到后面的端口或 OS 挑的端口——与上游 `address_in_use` 时的既有行为一致，
`listen_system_port_fallback` 的文档（「绑定指定端口失败就让 OS 挑」）本来就是这个
意思。上游 RC_2_0 / master 至今未修。详见
`docs/bugs/BUG-2023-torrent-ffi-listen-port-zero-ci-flake.md`。

## 清理条件

- bridge 迁到 libtorrent 2.1 时（`../vcpkg.json` 里 overrides 删除之日），
  本 overlay 需要基于 2.1 的 port 重做：DHT 豁免补丁逻辑同三处；
  `listen-bind-access-denied-fallback.patch` 若上游仍未修，按同样四处判据重打；
  `dh-shared-secret-padding.patch` 直接删掉（v2.1.0 已含该修复）。
- 若上游将来提供 DHT 独立的代理豁免设置，删本 overlay 改用官方设置。

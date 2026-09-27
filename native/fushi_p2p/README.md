# fushi_p2p

iroh（1.2.0，MIT/Apache-2.0）上的 TCP-over-P2P 隧道，dumbpipe 形态，C ABI 给
Dart FFI（`packages/fushi_p2p`，纯 Dart，无 Flutter / 插件依赖）。设计见
`docs/specs/2026-09-28-interconnect-remote-reach.md` §5 / §6。

## 形态

- **主机** `fp2p_host_listen(h, port)`：接受 ALPN `fushi/tcp/1` 的连接；每条双向流
  → `127.0.0.1:port`，双向泵字节。`port = 0` 停止接受。
- **客户端** `fp2p_client_forward(h, nodeId, hint?)`：在 `127.0.0.1:0` 监听并返回端口；
  每条本地 TCP → 在到 `nodeId` 的 iroh 连接上开一条新双向流。连接按节点缓存，
  开流失败（对端重启 / 网络切换）换新连接重试一次；并发的首批本地连接只拨一次号。
- 每条流开头客户端写 4 字节魔数 `FTP1`：QUIC 流在发送方写出首字节前对端看不见，
  服务端先说话的协议会卡死（dumbpipe 用同样的握手字节）；顺带挡掉乱入的流。
- 半关闭：任一方向读到 EOF 就把对侧写端关掉（TCP `shutdown(Write)` / QUIC `finish`），
  两个方向都结束才收尾；任一方向出错就 reset/stop 流、丢掉 TCP。
- 地址提示 `{"directAddrs":["ip:port"],"relayUrl":"https://..."}`：给了就直接拨，
  不必等 n0 DNS / DHT 发现。主机地址集里带着直连地址时应当传。

## 发现与中继

- 默认 `presets::N0`：n0 的 pkarr 发布 + DNS 解析（`iroh.link`）+ n0 公共中继。
- **Mainline DHT 发现：已开启**（cargo feature `dht`，默认开）。iroh 1.x 把它拆成了独立
  crate `iroh-mainline-address-lookup` 0.5。按其默认只往 DHT 发布 **home relay**（`AddrFilter::relay_only`），
  不把本机 IP 泄进公共 DHT。关掉：`cargo build --no-default-features`。
- `relay_urls_json` 非空 = 只用这些自建 `iroh-relay`（`RelayMode::Custom`），见 spec §6。

## 连接状态

`fp2p_conn_status` 读 `Connection::paths()`（iroh 1.x 多路径 API）：选中路径是 IP →
`direct`，是中继 → `relay`；没选中但两种路径都开着 → `mixed`（打洞中）；无连接 → `none`。
`rttMs` 取选中路径的 RTT。出站连接优先，其次入站连接（主机也能查对端）。
桌面开 Clash TUN 等改写 UDP 源端口的环境会长期停在 `relay`，UI 据此提示。

## C ABI 约定

- 永不 panic 过 FFI（每个导出函数 `catch_unwind`；`panic = "unwind"`）。
- 返回的 `char*` 用 `fp2p_string_free` 释放（`fp2p_version` 是静态串除外）。
- 复杂返回值是 JSON：`{"ok":true,...}` / `{"ok":false,"error":"..."}`。
- `fp2p_endpoint_create` 失败返回 NULL，原因用 `fp2p_last_error()`（线程局部）。
- `fp2p_endpoint_close` 同步：iroh 的 `Endpoint::close` 会等对端确认，实测有过连接时
  0.8~2.1 s（空闲端点 ~10 ms），上限 3 s。Dart 侧 UI isolate 用 `closeAsync()`。

## 构建

| 平台 | 命令 | 产物 |
|---|---|---|
| Windows x64 | `powershell -ExecutionPolicy Bypass -File native/fushi_p2p/build_windows_dll.ps1` | `prebuilt/windows-x64/fushi_p2p.dll` |
| Android | `build_android_so.ps1 [-NdkRoot …]` / `build_android_so.sh <ndk-root> [abi…]`（cargo-ndk，API 24，NDK 28.2） | `prebuilt/android/<abi>/libfushi_p2p.so` |
| Linux x64 | `build_linux_so.sh` | `prebuilt/linux-x64/libfushi_p2p.so`（服务端 bundle 放 `lib/`） |
| macOS / iOS | 仅 CI，本机未验证：`cargo build --release --target aarch64-apple-darwin`（cdylib → dylib）/ `aarch64-apple-ios`（staticlib，链进主二进制，Dart 侧走 `DynamicLibrary.process()`） | — |

`target/`、`prebuilt/` 不入库。访问 crates.io 不稳时设 `CARGO_HTTP_PROXY`。

体积（release，`opt-level="s"` + fat LTO + `codegen-units=1` + strip，2026-09-28 实测）：
Windows x64 DLL 7.68 MB；Android arm64-v8a 6.6 MB、x86_64 7.4 MB（只依赖 libc/libm/libdl）。
`opt-level="z"` 可再省约 0.57 MB（Windows 7.11 MB），但隧道要扛视频流，QUIC 包处理
变慢不划算，未采用。cargo-ndk 会顺带拷出 `libiroh-<hash>.so` 等无人加载的 cdylib
副本，构建脚本会删掉它们。

## 测试

```
FUSHI_P2P_LIB=<绝对路径>/fushi_p2p.dll dart test   # 在 packages/fushi_p2p 下
```

同进程两个端点经直连地址提示互拨：并发 HTTP、3 MB 请求体回显、8 MB blob 的多段
Range、半关闭、连接状态、停止转发口；库缺失时整组 skip。

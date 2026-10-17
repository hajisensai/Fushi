# 互联：无公网 IP 可达（地址集 / 并发选路 / IPv6 / 扫码配对 / P2P 隧道）

- 日期：2026-09-28
- 状态：已实现（分支 `worktree-interconnect-remote`），遗留项见 §9
- 背景调研结论见本会话；核心判断：「谁牵线、谁兜底中继」是唯一问题，协议层不动，只换可达性。

## 0. 目标与非目标

目标：
1. 已配对的两台设备在不同网络下（无公网 IPv4）仍能互联，**现有 HTTP 协议、TLS 指纹钉扎、per-peer token 一行不改**。
2. 扫码 / 深链 / NFC 贴纸完成配对，不必同网段、不必手输地址。
3. 地址失效时不再逐个吃超时。

非目标：
- 项目方运营的官方中继（带宽成本）。只提供用户自填中继。
- 替换现有 LAN mDNS 发现（保留，作为补充路径）。
- iOS 当主机（后台 UDP 被挂起，平台限制）。

## 1. 数据结构（第一刀）

现状错在：主机最清楚自己有哪些地址，却只有用户手输。客户端 `sync_hibiki_client_urls` 是扁平地址列表，没有「这几条属于同一台主机」的概念。

改为：
- `FushiClientUrl` 新增两个可选字段（旧 JSON 缺省即旧行为）：
  - `hostId`：主机稳定设备 id（与 mDNS TXT `id=` 同一个值）。
  - `learned`：此条由主机公布自动学到（非用户手输）。只有 learned 条目会被自动增删；手输条目永不被自动改动。
- 主机侧新增纯函数 `collectInterconnectHostAddresses(interfaces, port, tls, publicUrls)` → `List<HostAddress{url, kind}>`，kind ∈ `lan | lanV6 | ipv6 | overlay | public | p2p`。
  - 私网 v4（10/8、172.16/12、192.168/16）→ lan；ULA fc00::/7 → lanV6；全局单播 2000::/3 → ipv6；100.64/10 → overlay（Tailscale/ZeroTier/EasyTier 虚拟网卡）；用户配置的公网地址 → public；P2P 节点 → `p2p://<nodeId>`。
  - 排除 loopback、169.254、fe80::（无 scope id 不可用）。
- 新增需鉴权端点 `GET /api/host/addresses` → `{hostId, addresses}`。**不放进无鉴权的 `/api/ping`**（不向能探到端口的人泄露内网拓扑），也**不并进 `/api/capabilities`**（那是「支持什么」，这是「在哪里」；capabilities 被各功能频繁读，每次枚举网卡是白费）。老 host 404 → client 不学。
- `/api/ping` 只加 `hostId`（它本就在 LAN 广播 TXT 里公开）：选路探测据此核对「这个地址背后还是不是我那台 host」——学到的 LAN 地址换个网络可能指向别人的 Fushi host，明文 http 下只看 `app=='fushi'` 会把 token 发过去。
- 客户端纯函数 `mergeLearnedHostAddresses(list, anchor, hostId, addresses)`：
  - 锚点条目补 `hostId`；同 hostId 的 learned 条目按新集合增删；token / 指纹 / 展示名从锚点复制（per-peer token 对这台主机的所有地址都有效，证书同一张）。
  - 已存在的 URL（无论手输与否）不重复添加。
  - 插入位置按 rank（lan/lanV6=0，ipv6=1，overlay=2，public=3，p2p=4）插到同组内第一个 rank 更高的条目之前；**手输条目相对顺序不变**。
- 刷新时机：配对成功、每次同步选路成功后（异步、失败只记日志，不影响本次同步）。

## 2. 并发选路（统一选择器）

现状：同步 backend、POST 传输、漫画 OCR、任务、订阅、下载 6 处各写一个串行循环，死地址逐个吃超时。学到 LAN 地址后在外网会更糟——所以 §1 与 §2 必须同批落地。

改为一个共享函数 `rankInterconnectCandidates(candidates, fallbackToken)`：
- 对全部候选**同时**发起可达性探测（https+指纹 → 钉扎连接；http → 普通连接；p2p → 先确保隧道再探测），2s 超时。
- **按列表顺序依次 await**：第一个成功者即返回，优先级语义与今天完全一致，总延迟 ≤ 单个超时（今天是 N×超时）。
- 返回重排后的列表（可达者在前、其余保持原序），各消费方循环不改结构，只把数据源换成它。
- 鉴权失败语义保持 BUG-1550：记下、继续下一台。

## 3. IPv6 双栈

- 服务端绑定 `anyIPv6`（`v6Only:false`，双栈）；平台禁用 IPv6 导致 bind 失败时回落 `anyIPv4`（平台边界，不是掩盖）。仅本机时仍 loopback v4。
- 双栈下 v4 客户端的来源地址是 `::ffff:a.b.c.d`：`_remoteAddress` 归一化为 v4，否则 LAN 免 PIN、`lastSeenIp`、限速来源 key 全部错判。
- URL 规范化支持 `[v6]:port`；`isPrivateNetworkHost` 识别方括号 v6。
- 无头服务端同样生效（引擎同一份）。

## 4. 扫码 / 深链 / NFC 配对

载荷（深链即二维码内容）：
```
fushi://pair?v=1&h=<hostId>&n=<展示名>&fp=<证书指纹>&k=<ticketId>.<secret>&a=<url>&a=<url>...
```
- 主机「显示配对二维码」生成一次性 ticket：32 字节随机 secret，5 分钟有效，同时只存一张，成功配对即作废。
- 协议：`pair/v2` 请求新增可选 `ticket`（ticketId）。命中有效 ticket 时：`pinRequired=true`、会话 PIN = secret、**不弹审批框**（主机上主动打开二维码 = 用户已批准）。`confirm` 路径**一行不改**：client 用 secret 代替 PIN 算 `HMAC(secret, clientNonce|hostNonce)`。
  - 老主机不认 ticket 字段 → 走原审批 + PIN 流程；但老主机根本不会生成二维码，所以不会出现。
  - 限速器照旧生效；secret 128+ bit，不可爆破。
- 指纹来自带外通道 → 跳过「确认身份」弹窗与 TOFU（这是比现状更安全的地方）。
- 客户端入口：「扫码配对」（`mobile_scanner`：Android/iOS/macOS）+「粘贴配对链接」（五平台）+ 系统深链 `fushi://pair`（Android intent-filter / iOS URL scheme / Windows 协议注册均已存在，只加 host 分发）。
- 配对成功后，载荷里的全部地址作为该主机的 learned 条目入列。
- NFC（仅 Android）：已配对设备可把**不含 secret** 的链接（hostId + 指纹 + 地址）写进 NTAG 贴纸。碰贴纸 → 系统按 `fushi://pair` 拉起 app → 地址与指纹已知，仍需主机审批（+ 非 LAN 时 PIN）。贴纸是长期物，绝不写 secret。

## 5. P2P 隧道（iroh）

- 原生库 `native/fushi_p2p/`（Rust，iroh 1.x，MIT/Apache），C ABI，Dart FFI 绑定放 `packages/fushi_engine`（与 fushi_torrent 同模式，不引插件，守纯度）。
- 形态照 dumbpipe：
  - 主机：`listen(forwardPort)`，每条 iroh 双向流 → 连 `127.0.0.1:forwardPort` 双向泵字节。
  - 客户端：`connect(nodeId)` → 本机 `127.0.0.1:<随机端口>` 监听，每条本地 TCP → 一条双向流。
- **信任区（安全关键）**：隧道流量在服务端看来来自 127.0.0.1，会被当成 LAN 免 PIN。故服务端为隧道单独起一个 loopback 监听口，同一个 handler，请求 context 标 `fushi.zone=p2p`；配对判据对 p2p 区一律视为非 LAN（强制 PIN / ticket）。原主监听口不受影响。
- 设备身份：iroh secret key 存设备本地偏好（加入 `deviceLocalPrefKeys`，绝不随备份外带，否则两台设备同一 NodeId）。
- 地址集里以 `p2p://<nodeId>` 出现，rank 最低（直连全失败才走）。选择器遇到 `p2p://` 先确保隧道、再把该候选的 url 改写为本地转发地址后探测；改写只存在于内存，不落库。
- 中继：默认 iroh 公共中继（限速，仅适合同步/查词/看书）；设置里可填**自建 iroh-relay** 地址（§6）。
- 已知坑：桌面开 Clash TUN 模式时 UDP 源端口被改写 → 100% 走中继。检测到只走中继时在 UI 提示。
- 平台：Windows / Android 本机可编；macOS / iOS / Linux 走 CI。库缺失 → 该能力判不可用，其余互联照旧。

## 6. 用户自填中继

- 偏好 `interconnect_p2p_relay_urls`（可多条）。空 = iroh 默认公共中继。
- 主机与客户端各自使用自己的配置（中继只做牵线/转发，两端不必相同，iroh 会协商）。

## 7. 破坏性检查

| 面 | 结论 |
|---|---|
| 旧客户端连新主机 | capabilities 多两个字段，旧端忽略 |
| 新客户端连旧主机 | capabilities 无 `addresses` → 不学习，行为同今天 |
| `sync_hibiki_client_urls` 旧 JSON | 新字段缺省；learned=false → 永不被自动改动 |
| pair/v2 | 新增可选 `ticket`，缺省走原流程；confirm 不变 |
| 双栈 bind | v4 映射地址已归一化；bind 失败回落 v4 |
| 冻结 wire 格式（docs/plans/2026-09-06） | 未改任何既有字段 |

## 8. 分批

- PR-1（纯 Dart）：§1 + §2 + §3 + §4。
- PR-2（原生）：§5 + §6。

实际落地为同一分支上的 6 个提交（设计 → IPv6 → 地址集与选路 → 票据与链接 → 配对 UI → P2P 接线），合为一个 PR 便于整体审查。

## 9. 实现中的修正与遗留

实现时对设计的修正（都已落地）：
- 地址集**不并进 capabilities**，单独 `GET /api/host/addresses`：capabilities 是「支持什么」，被各功能频繁读，每次枚举网卡是白费；并进去还让「能力位只探一次」的既有测试多出一次请求。
- `/api/ping` 加 `hostId`，选路探测核对身份：学到的 LAN 地址换个网络可能指向别人的 Fushi host，明文 http 下会把 token 发过去。
- URL 身份审计：同步目录缓存（folderId 是绝对 URL）只恢复同源条目；制卡源编辑草稿身份改为 host + 凭据（v1 草稿照认）；`onlyCandidate` / 下载执行设备 / 下载对话框默认目标按 host 认；「已配对 N 台」按 host 计。
- P2P 地址捎 home relay 与直连地址作拨号提示，不依赖 n0 DNS 发现（发现服务在某些网络里解析不了）。
- `fushi://pair` 深链一律先弹「连接到 <设备>？」确认框：链接可能来自任何网页。

代码审查后的修正（2026-09-28，均已落地并有测试）：
- **只学密码学认证过的地址**：hostId 是公开的、证明不了身份，所以 learned 地址只收 `https://`（继承钉扎指纹）与 `p2p://`（节点公钥即身份）；地址集只经已钉扎的 https 锚点拉取。明文 host 只绑 IPv4、不公布网卡明文地址。
- 链接配对：链接冒用已配对 host 的 hostId 但指纹不符时，新地址另起一组，不并入、不删改真 host 的组。
- 票据在**建会话时**即消耗（拍到二维码的人不能预开会话）；关闭二维码连带作废已凭票开出、未 confirm 的会话。
- 隧道请求在审批框里标「P2P tunnel」而不是看似本机的 127.0.0.1；隧道监听口单飞启动，server 停后拒绝开口、不留孤儿口。
- 客户端地址列表的读改写经 `SyncRepository.updateFushiClientUrls` 串行，写后广播 `fushiClientUrlsRevision`，设置页据此重载。

第二轮根治（2026-09-28，均已落地并有测试）：
- **隧道主机资源封顶**（`native/fushi_p2p`）：QUIC 层每连接并发双向流 ≤ 32、单向流 0（协议层流控，对端开不出第 33 条，客户端表现为背压而非失败）；同一 NodeId 只留最新入站连接；入站连接总数 ≤ 64、转发流总数 ≤ 256，超出 refuse / reset 快速失败。NodeId 不花钱就能生成，只按对端限等于没限，所以全局上限是必需的。
- **隧道请求按真实身份限流**：Rust 登记「转发 TCP 连接的本地源端口 → 对端 NodeId」（`fp2p_host_peer`），`FushiSyncServer.p2pPeerResolver` 据连接的对端端口查出 NodeId 挂进请求 context（`fushi.p2p.peer`），配对会话记 `tunnelPeer`。PIN 限流对隧道会话按 `p2p:<NodeId>` 分桶、**不认**自报 deviceId（可冒报成受害者的把人锁外）；查不到身份时共用一个桶（收紧而非放开）。
- **地址列表所有读改写串行**：设置页增删改排序改成在库里最新列表上按 URL 执行的变换（排序表达为 `moveInterconnectUrlBefore`）；`SyncRepository` 内 TOFU 落指纹、落 per-peer token、清 token、清指纹、登出清表全部走同一把静态锁。守卫测试钉住 `lib/` 不许再直接 `setFushiClientUrls`。
- **NFC 贴纸可选写后锁定**：写入前问「写入后锁定」，默认关（锁定不可撤销，本机地址或证书一变贴纸就作废）；原生返回 `locked` / `written` / `failed` 三态，要求锁定而芯片不支持只读时如实提示。
- **CI / 发布接入 Rust 构建**：Android 三 ABI、Windows DLL、macOS dylib（进 `Contents/Frameworks`；当时是 universal，2026-10 起 macOS 版只出 arm64）、iOS 静态库（`-force_load`，出包查符号防 dead-strip）、Linux 桌面与无头服务端 `.so`；构建失败即 job 失败（与内置 libtorrent 同口径），出包后核对库确实进包，真隧道测试额外核日志无 skip 防缺库伪绿。iOS 出口合规维持 `ITSAppUsesNonExemptEncryption=false`：iroh 走标准 TLS 1.3（rustls），与互联既有的自签 TLS 同属标准协议加密。
- **无头服务端 WebUI**：「远程访问」卡片管理公网地址 / P2P 开关 / 自建中继，admin API 同名字段，改完即生效（`HeadlessHost.applyConfig`，配置不再是启动快照）；P2P 起停与换中继串行。
- **持续走中继提示**：设置页 `p2p://` 地址行显示「P2P 直连 / 经中继 · RTT」；连上后持续 20 秒仍只有中继路径（iroh 先走中继再升级，刚连上不误报）时，说明任一端开着 Clash TUN / 全局 VPN 等改写 UDP 端口的工具会让打洞失败及处理办法。

仍需外部条件：
1. ~~macOS / iOS 构建链路以 CI 首跑为准~~ → **已由 PR #1734 的 CI 验证**：iOS 静态库编译、`-force_load` 链进 Runner 且 `fp2p_*` 符号在（未被 dead-strip），macOS universal dylib 进 `Contents/Frameworks` 并过冒烟；Linux / Windows 用新编的库跑了真隧道 FFI 测试，Android 三 ABI 交叉编译通过。首跑暴露并已修的两处：rustc 的 native-static-libs 行在 `CARGO_TERM_COLOR=always` 下带 ANSI 转义（链接报 `Library 'm…' not found`，脚本改 `--color never` 并校验 token）；universal dylib 的 `otool -D` 按架构分段输出（核对改为逐段）。iOS 真机运行时（端点能否在 iOS 后台 / 蜂窝下保持）未测。
2. **真实网络实测**：本机实测（Windows，**开着 FlClash TUN**，公网 IPv4/IPv6 全被接管，所以测不到真实公网打洞率；局域网 Mac 当时离线，跨机未测）：
   - home relay 可达 20/20，上线耗时中位数约 3.6 秒、最长 15.5 秒（流量经代理出口到 aps1 / euc1 中继）。
   - 只凭 NodeId 发现：新上线的 host 要 10–50 秒才能被 n0 DNS 查到（pkarr 记录发布中位数约 23 秒），期间首拨约一半失败；host 已上线 40 秒以上时正常（首字节 < 1 秒）。→ 已落地：`p2p://` 地址**只在带中继或可路由直连提示时才公布**（`interconnectP2pPublishableUrl`），客户端不依赖发现。
   - iroh 会把 TUN 网卡地址 `198.18.0.1` 与代理出口当本机地址报出来。→ 已落地：直连提示剔除 `198.18.0.0/15`、回环、链路本地、未指定地址（`isInterconnectP2pDialableAddr`）。代理出口地址无法可靠识别，仍会随提示发出（只是多拨一次）。
   - 同机两进程：先走中继，约 1 秒内升级直连，直连约 1.5–2 Gbit/s，20 秒内不回退。强制只走中继：7–13 Mbit/s，传输中 RTT 约 1 秒——API 与同步够用，视频边下边播吃力，面向国内用户应推荐自建中继。
   - 未测、仍需真机：跨运营商 / 蜂窝网络的打洞率；不开 TUN 时的表现。脚本与原始日志在本次任务的临时目录（不入库）。

# 互联：无公网 IP 可达（地址集 / 并发选路 / IPv6 / 扫码配对 / P2P 隧道）

- 日期：2026-09-28
- 状态：实施中（worktree `interconnect-remote`）
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

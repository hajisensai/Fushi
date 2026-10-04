## BUG-2935 · 「整套下载」MAL 关联链走到上限静默截断，哆啦A梦等长寿系列可能漏收作品
- **报告**：2026-10-04（用户：「我希望下载全部的哆啦a梦大电影，你试着交互一下」）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/media/video/discovery/video_franchise.dart` 的 `resolveMalFranchise` 用 `visited.length < maxWorks`（旧上限 60）做 BFS 预算，撞上限直接退出循环，返回的 `VideoFranchise` 没有任何「没走完」的标记；reducer `_onFranchiseLoaded` 照常说「找到 N 部剧场版」，用户只能把残缺清单当成全部。
  - 预算计的是**请求数**：OVA / Special 不进清单，但要请求一次才知道它是 OVA。
  - 2026-10-04 核对 MAL 页面：2005 版（mal:8687）只有 27 条外传（26 部剧场版 + 1 部 TV Special），**没有指回 1979 版的前传**；1979 版（mal:2471）有 37 条外传（26 部剧场版 + 11 部特别篇）与前作 1973 版。从 2005 版出发要经新剧场版的「Alternative version」（重制）绕回旧剧场版、再经「Parent story」回 1979 版，共约 67 个节点——60 会截掉最后 7 个节点且无声；截掉的是剧场版还是特别篇取决于 MAL 关联的返回顺序（本次连不上 Jikan 无法核对），上限越贴近系列规模越可能丢剧场版。
  - 没配 TMDB key 时 MAL 链是剧场版的唯一来源（TMDB collection 才是完整片单），所以这是默认配置下的真实路径。
- **[x] ① 已修复** — `VideoFranchise.truncated`（MAL 遍历队列里还有没走到的节点、或中途请求失败时为 true；`mergeVideoFranchises` 任一份 truncated 即 truncated；`loadFranchise` 重建 TMDB 那份时保留）；reducer 在 `franchiseFound` 之后追加 `VideoAcquisitionSayKind.franchiseTruncated`（i18n `ai_video_acquire_franchise_truncated`）明说清单可能不全，流程照常往下走；上限 `kVideoFranchiseMaxMalWorks` 60 → 150（≈2.8 分钟，按 MAL 页面计数的哆啦A梦图规模留余量）。远程助手会话里旧客户端不认识新 kind 时 `_messageFromJson` 整条跳过，不崩。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/discovery/video_franchise_test.dart`（按 MAL 真实形状建的 67 节点哆啦A梦关系图：默认上限收全 52 部剧场版 + 1973/1979/2005 三部 TV 且不 truncated；上限 60 时 truncated 且恰好请求 60 次；失败中断 / 合并的 truncated 语义）、`fushi/test/media/video/acquisition/video_acquisition_franchise_test.dart`（truncated 时说 `franchiseTruncated` 且照常逐部找资源；走完时不说）。
- **备注**：本次没能直连 Jikan（代理与直连均超时），图形状来自 MAL 网页的 Related Entries 计数。

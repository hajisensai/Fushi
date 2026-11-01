# 远程复习（在已配对设备的复习库上刷卡）

日期：2026-11-01　状态：已实现

## 1. 目标

已配对的互联客户端**不下载卡组**，直接在互联主机的复习库（Fushi SRS）上刷卡。互联主机是开着互联服务的
任意一台 Fushi——电脑、手机、平板都可以，文案与代码一律说「已配对设备 / 互联主机（host）」，不说「电脑」。

排队、FSRS / RWKV 排程、模板渲染、写日志全在主机的 Rust 内核与 `SrsDbStore` 里做；客户端只拿到正在看的那张卡
需要的数据，媒体按需拉。

**远程复习与本机复习功能一致**（所有者 2026-11-01 拍板：「不应该和在手机上刷卡一模一样吗」）。做法不是另写一个
精简版复习页，而是把**本机的复习页及它能打开的页面原样跑在一个远程实现的复习库上**：查词、复习中编辑笔记、
AI 字段、卡面缩放、手势、手柄、自定义学习、卡片菜单（挂起 / 埋 / 旗标 / 重置 / 改到期 / 换牌组）、浏览器、
牌组设置、修改历史、换笔记类型、撤销……都是同一份代码。

它是**附加模式**，不替代复习同步 v2（`2026-10-25-srs-sync-v2-design.md`）：

| | 完整同步（v2） | 远程复习（本文） |
|---|---|---|
| 客户端存什么 | 完整操作日志 + 全部媒体 | 只缓存看过的卡的媒体 |
| 主机不在线 | 照常离线刷，回头再合 | 刷不了（明确报错，不吞答案） |
| 适合 | 主力设备 | 空间小的设备、临时设备 |

所有写入落在主机的操作日志里，之后照常经 v2 同步到其它设备。

## 2. 结构

```
客户端                                           互联主机
SrsReviewPage / SrsNoteEditorPage / ...           FushiSyncServer
   │ ref.watch(srsStoreProvider)                    │ POST /api/srs/remote/call
   ▼                                                ▼
SrsRemoteStore (implements SrsDbStore) ──HTTP──▶ SrsRemoteStoreService ──▶ 主机的 SrsDbStore
SrsRemoteMediaStore (extends SrsMediaStore) ─GET /api/srs/remote/media/<名字>─▶ 主机的 SrsMediaStore
```

- **`SrsRemoteCollectionScope`**（`srs_remote_review_page.dart`）：一个子 `ProviderScope`，把
  `srsStoreProvider` 覆盖成 `SrsRemoteStore`、`srsMediaStoreProvider` 覆盖成媒体缓存，并重新覆盖依赖它们的
  派生 provider（`srsCardAudioOutputProvider`；Riverpod 2.6 子作用域里派生 provider 不重覆盖就仍读根作用域的值）。
  本机专属的 `srsRwkvServiceProvider` / `srsAppRuntimeProvider` 置 null，`srsRevisionProvider` /
  `srsLocalWriteProvider` 置 0（远程库自己按回包刷新）。
- **`SrsRemoteStore`**（`fushi/lib/src/srs/srs_remote_store_client.dart`）：`implements SrsDbStore`，把页面用到的
  每个成员转成一次 `call(op, args)`；没覆盖的成员经 `noSuchMethod` 抛 `UnsupportedError`（不静默走错库）。
- **扩展方法转发**：`SrsDbStore` 上有些能力是静态派发的扩展方法（换笔记类型、旧 Lapis 迁移、修改历史、设备名、
  按类型列笔记），直接读 `db` / `core` 或走内核命令。它们在开头判 `if (self is SrsRemoteForwarding)` 转给远程库
  的 `remoteXxx`，本机路径体搬进私有 `_xxxLocal`，行为不变。
- **`SrsRemoteStoreService`**（`packages/fushi_engine/lib/srs/srs_remote_store.dart`，纯 Dart，无头服务端也能挂）：
  操作表 `operations`，每个操作是「读主机 `SrsDbStore` → 编成线格式」，写操作结束后调 `onWrite`（app 里是复习运行时的
  `_bumpRevision`，主机自己的界面随之刷新）。

## 3. 协议

鉴权与其它互联端点相同（配对 token，HTTPS 时按配对指纹钉证书）。主机在 `GET /api/capabilities` 声明
`srsRemoteStoreV1: true`；复习模块关着时不声明、端点 404。

- `POST /api/srs/remote/call`，体 `{profile?, op, args, request?}`。
- 回包信封 `{profile, rev, fp, tt, now, ts, sched, rwkv, dev, result}`：主机 profile uid、复习库版本、排程指纹、
  牌组树标签、主机此刻 / 时间源、排程是否可用、RWKV 是否就绪、主机在同步集合里的设备 id、操作结果。
  客户端每次回包都吸收信封：`now()` 按主机时钟偏移算（日界、到期显示与主机同口径）。
- `GET /api/srs/remote/media/<名字>`：媒体字节。
- 错误：`{error: stale | profile_changed | unavailable | bad_request | unknown_op | failed}`。

### 3.1 线格式

- 笔记 / 笔记类型 / 牌组以 `SrsEntitySource`（`payloadJson` + 编辑项）传，客户端用与本机同一套
  `srsMaterializeNotes` / `srsMaterializeNoteTypes` / `srsMaterializeDecks` 重建视图——不另写一份序列化，字段、
  模板、牌组设置的语义与本机逐位一致。
- 标签 `payloadLen:editCount:lastEditId` 做客户端缓存键：笔记类型按标签缓存，牌组树按信封 `tt` 缓存，没变不重拉。
- 卡片行、复习日志、卡片历史（`SrsCardHistory.toWire/fromWire`）、排程预览、渲染结果、排队状态、自定义学习、
  同步 v2 结果各有编解码（`SrsRemoteWire`）。

### 3.2 正确性要点

1. **幂等**：写操作带客户端生成的 `request`（每次一个，重发不变）。主机按它缓存最近 256 个写操作的回包，并对
   进行中的同 id 请求去重；连接层失败（回包丢了）客户端用同一个 id 重发一次，主机只写一遍。缓存在内存：主机进程在
   「写完、回包丢了」与「重发」之间重启才会漏掉，此时作答走到下一条的陈旧判定，不会重复记账。
2. **陈旧卡**：客户端记下取卡时该卡的 `lastLogId`（基线），作答带 `checkBase + base`。主机现读卡片行比对，不一致
   （别的设备 / 主机自己刚复习过、卡被删 / 挂起）回 `stale`。客户端作废基线、抛 `SrsCardChangedError`，复习页提示
   「这张卡刚在别处复习过，已跳过」并按最新状态重新排队——不记日志，也不会卡在这张上。其它写操作清掉对应卡的基线。
3. **配置切换**：请求带客户端上次看到的 profile uid，主机期间切换了 → `profile_changed`，不把写入记进另一份配置。
4. **作答时刻**：排程与日志用主机收到作答的时刻（与本机「在评分这一刻重算」同口径）；`durationMs` 两端都截到
   `kSrsMaxAnswerDurationMs`。
5. **撤销**：`SrsDbStore.undo` 原样转发，语义与本机一致。

### 3.3 媒体

卡面引用的媒体名是内容哈希（`SrsMediaStore.contentName`），同名即同内容、永不变，客户端缓存按名字存：
`<临时目录>/srs_remote_media/<hostId>/`。`renderCard` 之前把这张卡引用的媒体拉进缓存，卡面仍经
`SrsMediaStore` 读本地文件，卡面渲染、`[sound:]` 播放、图片拦截一行不改；漏拉的（脚本动态引用）在 `load` 时补拉。
非法名字不发请求。

## 4. 一致性守卫

`fushi/test/srs/srs_remote_store_parity_guard_test.dart` 按源码核对：

1. 远程会话可达的页面（清单 `_reachable`）经 `store` / `_store` 用到的 `SrsDbStore` 成员，`SrsRemoteStore` 都覆盖了；
2. 可达页面用到的扩展方法，若（连同它调用的扩展私有方法）读 `db` / `core`、走 `sync2Command` 或调用没覆盖的
   成员，就必须带 `SrsRemoteForwarding` 转发；
3. 客户端调用的操作名主机都有。

新页面能从复习页 / 远程牌组列表打开时加进 `_reachable`；守卫红了就补转发，不要把页面从清单里拿掉。

## 5. 入口与边界

入口：牌组列表工具栏「复习已配对设备的卡组」。探测此刻声明了 `srsRemoteStoreV1` 的已配对主机（只有一台时直接进），
列出主机的牌组：点牌组进复习页；每行「⋯」有自定义学习、浏览该牌组、牌组设置；工具栏有添加笔记、浏览、刷新。

**没有代理的（属于「管理这份收藏」而不是「刷卡」，到主机上做）**：

- 牌组的新建 / 改名 / 移动 / 删除 / 折叠、导入、同步设置与冲突中心、单词音频补全——即完整的本机牌组列表页
  `SrsDeckListPage` 的管理功能；
- 牌组设置里的「立即优化参数」：优化跑在主机的复习运行时上，作用域里 `srsAppRuntimeProvider` 为 null，按钮不可用；
- 卡面查词弹窗里的制卡：制卡目标是本机的制卡配置（本机的复习库 / Anki），不会写到主机；
- 无头服务端（`packages/fushi_server`）尚未挂 `srsRemoteStoreProvider`，只有 app 当主机时提供远程复习。

不新增 FFI：主机侧每个操作仍是原来那次 `SrsDbStore` 调用。

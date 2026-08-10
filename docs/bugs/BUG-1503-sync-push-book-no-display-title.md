## BUG-1503 · 本端把书 push 给 host 时不带显示名（裸 epub 上传无元数据）
- **报告**：2026-08-11（BUG-1488 收尾时自曝的未覆盖方向，用户拍板「全部修复」）
- **真实性**：✅ 真 bug。BUG-1488 只打通了「host → peer」一个方向；反方向的内容 push
  是**裸 .epub 字节流上传，无任何元数据 sidecar**，所以本机用户给这本书改的名字不跟随：
  - 发起：`SyncOrchestrator._syncBooksContentLive`
    （`fushi/lib/src/sync/sync_orchestrator.dart:1486`，push 循环 `putRemoteBook`
    调用点改前在 :1545）只传 `(title, File, onProgress)` 三个参数；
  - wire：`InterconnectSyncBackend.putRemoteBook`
    （`fushi/lib/src/sync/interconnect_sync_backend.dart:873-895`，改前）=
    `PUT {base}/api/library/books/{encodeComponent(title)}`，
    `Content-Type: application/epub+zip` + `addStream(file.openRead())`，
    **非 multipart、无 query、无自定义 header**；
  - 落地：`_serveAssetPackage` 的 PUT 分支
    （`fushi/lib/src/sync/fushi_sync_server.dart:1253-1276`）把 body 落成临时文件
    `<title>.epub` 后调 `import(tmp)`，而书域传的是 `svc.importBook` tear-off；
    契约 `Future<void> importBook(File epubFile)`
    （`fushi/lib/src/sync/fushi_library_host_service.dart:1244`，改前）**单参、无元数据**
    —— 这是全域唯一没走元数据参数的资产（视频早有
    `importVideo(File, {id, title, originalFileName})`）。

- **[x] ① 已修复** — `1c9a0e1e4a`。**选的方案：additive 自定义 header**，理由是
  它是本仓这条链路**已有的先例**而不是新发明——视频推送的
  `X-Hibiki-Video-Title` / `X-Hibiki-Video-Filename`
  （client `interconnect_sync_backend.dart` ↔ host `_decodeHeaderValue`
  `fushi_sync_server.dart`）就是这么给二进制 PUT 附元数据的；而 host 的路由只看
  `Uri.decodeFull(request.url.path)`、PUT 分支从头到尾不读 header/query，所以
  **旧 host 收到新 header 是静默忽略而不是报错**，零版本协商、零破坏。
  （另两条路被否：query 参数在本仓只用于 GET，且同样要改两侧；再开一次轻量元数据
  调用则把「一本书落地」从原子变成两段，中途失败会留下无名书。）
  - **wire 常量单一真相源**：`kBookDisplayTitleHeader` /
    `kBookDisplayTitleAtHeader`（`fushi/lib/src/sync/fushi_library_host_service.dart`
    顶部），两侧共用。值走 `Uri.encodeComponent`（HTTP header 只收 ASCII，日文书名
    裸塞会抛）；没改过名 / 显示名等于 raw title 时**一个 header 都不发**。
  - **契约**：`FushiLibraryHostService.importBook(File, {String? displayTitle,
    int displayTitleAt = 0})`；`_serveAssetPackage` 的四域共用签名**没动**，书域
    改传一个读 header 的闭包即可。
  - **拿到真实身份键**：`AppModelLibraryHostService` 的 `importBookFromFile` 回调
    类型从 `Future<void> Function(File)` 改成 `Future<String?> Function(File)`，
    返回 `EpubImporter.importFromPath` 本来就有的落地 bookKey。显示名**必须**挂在它
    上面——重名时 importer 会加 `(2)` 后缀，派生键与 URL 里的 title 不同。
  - **身份红线（BUG-1488 定的原则，继续遵守）**：端点寻址、host 端 bookKey/uid 派生
    仍恒用 raw title，`displayTitle` 永不参与任何键派生；host 落地后只写一行
    `override_title://` 覆盖偏好。
  - **LWW 与 BUG-1502 同一套**：header 带戳，host 侧
    `_adoptPushedDisplayTitle` 走 `MediaSource.adoptOverrideTitleIfNewer`
    （严格更新才覆盖 / 平局保留本机 / 本机无该行则采纳）。走 MediaSource 而不是裸写
    DB，是因为 host 是个正在跑的 app，只写 DB 会让它的书架一直显示旧名（而且
    `getPreference` 的 miss 会把 null 反写进内存缓存）。显示名落不上不会把整个 PUT
    变成 500（书已经入库了），只记 `ErrorLogService`。
  - push 侧读本机 override 复用 BUG-1502 建的
    `readOverrideTitlesByBookKey`（`fushi/lib/src/sync/override_title_lookup.dart`），
    一趟读完，推多本书只查一次偏好表。

- **[x] ② 已加自动化测试** — `fushi/test/sync/book_rename_lww_test.dart`（13 例，
  与 BUG-1502 共用）的 E 组 4 例：
  ① client 侧编码——起裸 `HttpServer` 收真实 PUT，断言两个 header 存在且显示名是
  `Uri.encodeComponent` 后的日文；② 没改过名 / 显示名等于 raw title 时一个 header
  都不发；③ host 侧落地——显示名写成 override 且挂在 importer 返回的**带 `(2)` 后缀**
  的真实 bookKey 上，书的 title/bookKey 不被显示名污染；④ 旧 client（无 header）
  → 与本轮之前逐字同行为（不写任何 override 行）。
  **变异实测**（2026-08-11，反向替换还原，零 lib 残留）：`putRemoteBook` 里两个
  `req.headers.set` 整段删掉 → ①转红（`Expected: '%E6%9C%AC…' Actual: null`）。

- **备注**：本轮只修「显示名」这一项。**标签仍不跟随 push 方向**（`RemoteBookInfo`
  带 `tags`/`tagsAddedAt`/`tagTombstones` 但只在 host→client 方向消费，client→host
  的标签只有云后端 sidecar 通道，互联路径不经过），那是独立缺口，未在本轮扩大范围。
  **未做真机双设备验证**（母/子两台真设备互联对拉）——只有单测覆盖。

# 互联实时库 Phase 2-4 实现计划（书籍/有声书/本地音频 live 同步 + 远程观看电脑视频/书籍）

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 逐任务实现，`- [ ]` 跟踪。中文回复，函数类型注解，TDD（红→绿→提交），提交只 stage 本任务文件（禁 `git add -A`）。
> 接续 `2026-06-08-interconnect-live-library-sync-plan.md`（Phase 1 词典 live 已落地）。

**Goal:** 把互联（仅 HibikiClient 后端）的**书籍/有声书/本地音频**也改为直读对端实时库端点（无暂存，复用 Phase 1 模式）；并新增**远程观看**：手机经互联浏览电脑上的视频（Range 流式播放，可选下载）与书籍（按需下载入库后打开）。

**Architecture:**
- **host 无 per-asset 开关**（用户定）：host 端点只受配对 token 鉴权，无条件暴露自己的库；**拉/推什么由 client 现有开关（`syncContent`/`syncAudioBookFiles`/`syncLocalAudio`）决定**。
- 统一端点命名空间 `/api/library/<type>`（`dictionaries` 已有；新增 `books`/`audiobooks`/`localaudio`/`videos`）。
- 新增**可 Range 流式 GET 基础设施**（解析 `Range:` 头返回 206），供大文件（视频流播、可选下载、有声书音频）共用。
- 远程视频=`media_kit` 直接播 `http://<host>/api/library/videos/<id>`（带鉴权头），不入库；可选「下载到本机」走同一端点整段拉。远程书籍=按需经 `books` 端点下载+`EpubImporter` 入库再正常打开。

**Tech Stack:** shelf（host）、WebDavOps/HttpClient（client）、media_kit（网络流播放）、Drift、`SyncAssetPackageService`/`repackageExtractedEpub`/`EpubImporter`、flutter_test。

**真机验证（用户做，我后台测不了播放/LAN）**：每个 Phase 末由用户双设备验证再进下一个。

---

## 贯穿约束（同 Phase 1 + 新增）
1. 仅 `_backend is HibikiClientSyncBackend` 走 live；云后端/旧路径零改动（Never break）。
2. host 端点经现有 `_authMiddleware` 鉴权；name/id 经统一路径穿越校验（拒 `/ \ ..`）；host 库变动经 `runExclusiveWithSync` 串行。
3. host **不**按自身开关 gate 库暴露；client 开关决定同步范围。
4. 流式不入内存；大文件 Range 流播 + 进度；临时文件 finally 清理；错误 loud（不静默吞致数据不一致）。
5. CJK 名安全：client `Uri.encodeComponent`，host 经 `_handleRequest` 的 `Uri.decodeFull` 解一次、端点内**不再二次 decode**（Phase 1 已确立）。

---

## Phase 2 — 书籍内容 live 同步（也支撑远程书籍按需下载）

复用 Phase 1 词典模式。host 用真实 `EpubBookRow` + `repackageExtractedEpub`（`sync_manager.dart:27`）即时打包、`EpubImporter` 导入。

### 任务清单
- **T2.1** 扩 `HibikiLibraryHostService`：加 `listBooks()→List<RemoteBookInfo{title,hasContent}>`、`exportBook(title)→File(epub)`（`repackageExtractedEpub` 即时打包 extractDir；无 extractDir 抛 StateError）、`importBook(File epub)`（EpubImporter 入库）、`deleteBook(title)`。`AppModelLibraryHostService` 实现（写操作经 runExclusive）。纯 diff `computeBookSyncDiff`（按 sanitizeTtuFilename(title) union）。TDD：内存 DB + 真 epub fixture round-trip。
- **T2.2** host 端点 `/api/library/books`（GET 列表 / GET `<title>` 流式 epub(StateError→404) / PUT 导入 / DELETE），复用 Phase 1 的统一路径穿越校验 + GET 临时清理 transformer + PUT finally 清理。capabilities `books:true`。
- **T2.3** client `HibikiClientSyncBackend`：`listRemoteBooks()`/`getRemoteBook(title,dest)`/`putRemoteBook(title,file)`/`deleteRemoteBook(title)`（镜像 dict 方法，绝对 URL + encodeComponent + checkStatus）。
- **T2.4** orchestrator：`importRemoteBooks`（`sync_orchestrator.dart:256`）+ 书籍内容 push 在 `_backend is HibikiClientSyncBackend` 时走 books 端点（不经书文件夹+.epub 暂存）；**仅当 client `syncContent` 开**才传内容（保持现有开关语义；host 不 gate）。**进度/统计/有声书位置等 per-book 轻量元数据保持现有 SyncManager 路径不变**，live 只接管内容文件 epub。删除传播走 `DELETE /api/library/books`。
- **T2.5** 全量 analyze + test/sync 绿 + 提交；真机验证（用户）。

> 远程书籍「打开即下载」在 Phase 4 的远程浏览 UI 里调 `getRemoteBook` 下载到书库再 `EpubImporter` 打开——本 Phase 先把端点/同步备好。

---

## Phase 3 — 有声书 + 本地音频 live 同步

- **T3.1** 扩 host 服务：audiobook（`exportAudioDatabasePackage`/`importAudioDatabasePackage`，`sync_asset_package_service.dart`）+ local-audio（`exportLocalAudioPackage`/`importLocalAudioPackage`）的 list/export/import/delete。`AppModelLibraryHostService` 实现。
- **T3.2** host 端点 `/api/library/audiobooks`、`/api/library/localaudio`（GET 列表/GET `<id>` 流式包/PUT/DELETE）。capabilities `audio:true`。**大文件用 Phase 4 的 Range 流式 GET 基础设施**（见下；audiobook 包可达数百 MB）。
- **T3.3** client 方法（list/get/put/delete，复用流式 download/upload）。
- **T3.4** orchestrator：`syncLocalAudioPackages`（`sync_orchestrator.dart:395`）+ 有声书包同步在互联 live 时走端点（替换 `__local_audio__` 等暂存命名空间），**仅当对应 client 开关开**。
- **T3.5** 全量验证 + 真机（用户）。

---

## Phase 4 — 远程观看（视频流式 + 可选下载；书籍按需下载打开）

### 4A 地基：可 Range 流式 GET（新基础设施，Phase 3 大文件也用）
- **T4.1** host：新增 `_handleRangeGet(File file, shelf.Request req)` helper：解析 `Range: bytes=start-end` 头 → 命中返回 `206 Partial Content` + `Content-Range`/`Accept-Ranges: bytes` + `file.openRead(start, end+1)`；无 Range 头退化为 200 全量（Content-Length）。流式不入内存。单测：用临时大文件断言 206 + 正确字节区间 + 越界处理（416）。

### 4B 视频远程流播
- **T4.2** 扩 host 服务：`listVideos()→List<RemoteVideoInfo{id,title,sizeBytes,durationMs?,hasSubtitle}>`（从视频媒体历史/库读，id 用稳定标识）、`resolveVideoFile(id)→File`、`resolveVideoSubtitle(id)→File?`。**只读，不提供 PUT/DELETE**（视频不同步入库）。
- **T4.3** host 端点 `/api/library/videos`（GET 列表）、`/api/library/videos/<id>`（**Range 流式**走 T4.1）、`/api/library/videos/<id>/subtitle`（GET 字幕，可空 404）。capabilities `videos:true`。
- **T4.4** client：`listRemoteVideos()→List<RemoteVideoInfo>`、`remoteVideoStreamUrl(id)`+`remoteVideoAuthHeaders()`（返回 media_kit 用的 URL + `Authorization` 头）、`getRemoteVideoSubtitle(id,dest)`、可选 `downloadRemoteVideo(id,dest,onProgress)`（整段拉，用于「下载到本机」）。
- **T4.5** UI「浏览电脑」：在 `home_video_page` 加一个入口/分区（仅当互联 client 已配置且可达时显示），列出 `listRemoteVideos()`；点击→用 media_kit 播放网络 URL（带鉴权头）+ 加载字幕（远程字幕轨可查词/显示按现有视频逻辑）；提供「下载到本机」按钮（调 downloadRemoteVideo + 走现有视频导入）。
  - 可 headless 测：list 解析、URL/头构造、入口可见性逻辑（widget/单测）；**真机测**：实际流播 + 拖进度 + 字幕 + 下载。

### 4C 书籍远程按需打开（复用 Phase 2 端点）
- **T4.6** UI「浏览电脑」书籍：在 `home_reader`/书架加入口列出 `listRemoteBooks()`；点书→`getRemoteBook` 下载到书库 + `EpubImporter` 入库 + 打开（之后即本地书，可离线/制卡）。复用 Phase 2 端点，无新端点。

### 4D 收尾
- **T4.7** 全量 analyze + test + 提交；真机验证（用户）：远程列视频/书、流播视频可拖动、字幕、下载到本机、远程开书。

---

## 风险 / 已知
- **media_kit 网络流 + 鉴权头**：确认 media_kit（桌面 mpv / 移动）支持自定义 HTTP header 播放（mpv `http-header-fields`）；若移动端后端不支持鉴权头，退路=短时一次性 token query 参数（仿 Phase 1 audio token `/api/lookup/audio/file?id=`，`hibiki_sync_server.dart:419`）。**T4.4 实现前先验证这条**，决定走 header 还是 one-time-token URL。
- 视频 id 稳定标识：用文件路径 hash 或媒体库 key；host 侧 `resolveVideoFile(id)` 必须防路径穿越（id→真实文件映射只查库，不接受任意路径）。
- UI 真机不可测部分明确标注，留给用户验证；逻辑层尽量纯函数化做 headless 守卫。
- Never break：所有改动只在 `is HibikiClientSyncBackend` 分支 + 新增 UI 入口（条件显示），不动云后端/现有本地视频书籍播放路径。

---

## 执行顺序
Phase 2 → 用户真机验证 → Phase 3 → 验证 → Phase 4（4A→4B→4C→4D）→ 验证。每 Phase 内逐任务 TDD + 双评审（spec/质量），Phase 末全量 analyze+test。

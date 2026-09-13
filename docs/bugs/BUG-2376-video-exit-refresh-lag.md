## BUG-2376 · 从视频退出后库页刷新卡顿
- **报告**：2026-09-09（用户：「现在每次从视频里退出来都会卡一两秒」）
- **真实性**：⚠️ 部分证实。**测到过**最坏单帧 1848ms 的停顿，时间线与库页封面回填重合；
  但**无法稳定复现**，故 1~2 秒的用户现象不能算已定位到唯一根因。
  - 停顿位置：`fushi/lib/src/pages/implementations/home_video_page.dart` 的 `_open()`
    从播放器 `await` 返回后调用的 `_refresh()`（旧代码 `home_video_page.dart:1968`），
    而不是视频页销毁或退全屏。
  - 已实测**排除**的三条：
    - 退出汇聚点 `_handleBackOrExit` / `exitAfterPersist`：pop 无条件同步，落库 fire-and-forget。
    - 视频页 `dispose()` + 原生 mpv/纹理拆除：探针实测 `backPressed→disposeBegin` 374ms
      （路由转场动画），`disposeBegin→disposeEnd` **5ms**；pop 后最坏单帧 131ms。
    - `_loadLibraryMapsInner` 的 14 条全表读：真实 1024 部库上 **35~151ms**
      （离线基准 `flutter test` 直连生产库副本），09-07 `2fb9e0641a` 新增的
      `db.allVideoBooks()` + `getMediaSourcesByKind('video')` 两条只占 ~12ms。
  - 停顿签名：帧计时 `build=37ms raster=2ms total=774ms`——build 与 raster 都不慢，
    **慢的是帧根本没被服务**，即 UI isolate 的事件循环被非帧工作堵住。空窗期内唯一在跑的
    是 `_maybeBackfillCovers()`（`home_video_page.dart` 内）：`listAll()` 再读一遍全表，
    然后逐行同步 `File.existsSync()`（1024 次）、候选行同步 `statSync()`、每个候选一次
    同步 64KB 头部读（判据在 `fushi/lib/src/media/video/video_cover_extractor.dart:358`）
    并串行 spawn ffmpeg——**全部压在 UI isolate 上，快速跳过分支整段不 await 让出**。
  - **无法复现的原因（重要）**：历次最坏帧 1848 → 1366 → 1115 → 780 → 226 → 249ms
    单调下降，是操作系统页缓存在一轮轮跑之间被焐热。首次触碰那 1024 个封面文件与候选
    视频时是真实首次磁盘 IO。试过「先真播 33 秒再退出」以冲掉页缓存（本机内存大，未奏效），
    也试过两次独立冷跑，均未再现。
  - **未被排除的候选**：全部测量都在**离屏集成 runner + debug 构建**里做的，窗口在屏外且
    `WS_EX_NOACTIVATE`，没有真实 DWM 合成、没有真正的原生全屏。因此
    `fushi/windows/runner/win32_window.cpp:683-700` 退全屏时 `SetWindowPlacement` +
    `ShowWindow(SW_MAXIMIZE)` 的两次 WM_SIZE（embedder 每次阻塞平台线程等一帧新内容），
    以及 HDR 直通下 `hdr_video_host_window.cpp:134-142` 的 `SetMainTransparency(false)`
    强制 DWM 全窗重合成，**结构上就测不到**，只是没被测到、不是被排除。
- **[x] ① 已修复（部分：把已证实的无效功从退出路径上摘掉）** —
  新增 `_refreshAfterPlayback()` 只给 `_open()` 用：只重读书架 `listForShelf()` +
  「最近观看」两张表（`_loadWatchRecency()`）。看完一个视频只可能改动 `video_books`
  那一行与 `StudyClock` 写的 `study_segments`；合集 / 来源 / 刮削资料 / 元数据作品·图片·
  分集·花絮 / 媒体图组这十二张表播放页一行都不写（换音轨只动
  `media_collections.audio_track_id`，库页不渲染它，且有 `watchCollectionTablesChanged`
  流兜底），因此全量重算在这条路径上是纯无效功。封面回填是「给缺封面的存量行补抽帧」的
  后台产线，播放不产生新的缺封面行，其真正触发时机（新行入库）由 `watchVideoBookUids`
  流 → `_onVideoUidsChanged` → `_refresh()` 覆盖，入口另有 `initState` 与下拉刷新
  （后者还会先清失败记账重试），从退出路径摘掉不会让任何条目永久漏掉。
  `_refresh()` 本体与其余 9 个调用点原样不动。
  顺带修掉一个真 bug：`_maybeBackfillCovers` 的节流重列写成
  `setState(() => _future = widget.repo.listForShelf())`，箭头体把赋值结果（一个 Future）
  当闭包返回值交给 `setState`，**debug 断言「setState() callback argument returned a
  Future」当场抛出、整个回填循环被掀掉**（实测探针 `backfill.threw`），release 因断言被
  编译掉而侥幸跑通——于是「封面回填在 debug 下根本不工作」长期无人发现。改块体。
- **[x] ② 已加自动化测试** — `fushi/test/tools/load_paths_perf_guard_test.dart`
  新增两条守卫：`cover backfill never hands setState a closure returning a Future`
  与 `returning from the player does not rerun the whole library load`（后者同时钉住
  窄重载与全量重载共用 `_buildWatchRecency` 这一单一真相源，以及两条路径各记各的代）。
  原先按字面量钉死那行 `setState` 的断言改为钉「几次重列」的不变式。
- **备注**：用户现象是否已消失**未经真机确认**——本机所有测量都无法再现 1~2 秒，
  离屏 runner 也够不到真实窗口/全屏/DWM 那一层。下一步最省事的判别是问用户一句：
  **窗口模式（不进全屏）退出还卡不卡**——不卡则元凶是退全屏的 Win32 几何握手
  （上面「未被排除的候选」第一条），卡则回到本条已摘掉的那批 UI isolate 同步 IO。

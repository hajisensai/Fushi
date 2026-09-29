## BUG-2542 · 手机端片段导出点了没反应：ffmpeg-kit 无界 await 挂死 + 分享被静默丢弃后仍报成功
- **报告**：2026-09-14（用户：直接反馈「手机片段导出没反应」，附了一段 in-app 错误日志）
- **真实性**：✅ 真 bug。**用户贴的日志与本条无关**（`SyncRunReport.errors` 互联 15 s 超时、`DictionaryMedia.cache` 取不到 daijirin2 的 SVG，是同一页里的其它条目）——这一点本身就是症状的一部分：导出链路上的失败出口大多不写 `ErrorLogService`，用户想给证据也只能截到别的条目。

  两个「片段导出」都在 Android 上可用、都无平台闸门（视频侧可见性门 `video_fushi_page.dart:5879-5882` 无条件 `return true`；有声书三个入口只看 `hasAudio`），ffmpeg 在手机上也**不是** CLI（`engine_bindings.dart:67` → `KitFfmpegBackend`，进程内 ffmpeg-kit），所以「手机上没 ffmpeg」这个直觉不成立。真实根因是一组**静默**，任一条都能让用户看到「点了没反应」：

  1. **`KitFfmpegBackend` 的 method channel 往返在 `.timeout()` 之外**（`fushi/lib/src/media/video/ffmpeg_kit_backend.dart`，修前 `:37` / `:48` / `:57` / `:58`，`runProbe` 同构）。`.timeout()` 只包完成回调的 `Completer`，而启动 `executeWithArgumentsAsync`（内含 init / createSession / asyncExecute 三次往返）、超时分支里的 `FFmpegKit.cancel`、收尾的 `getReturnCode` / `getOutput` 全是裸 await。任一不回包 → `run()` **永不返回** → 调用方的「导出中」标志永久为真 → 此后每次点击都撞在防重入门上。**这是移动端专属**：桌面 CLI 后端起子进程，有独立超时。更糟的是超时分支里那个 `cancel` 也无界——超时机制会被它自己要取消的东西挂住。
  2. **有声书那道防重入门完全静默**（`reader_fushi/audiobook.part.dart` 修前 `:1353` 裸 `if (_audiobookClipExporting) return;`）——全链路唯一零 toast / 零日志 / 零 debugPrint 的用户可达早退。对照组：视频页同性质的门一直会弹 `video_clip_exporting`（`video_fushi/clip_export.part.dart:11-14`），可见这是漏，不是设计。
  3. **防重入标志置位在 try 之外**（同文件修前 `:1538` 置位，try 从 `:1562` 起），而调用点是 `unawaited(...)`（`:1401`）。于是置位到 try 之间的 `_readerThemeColors` / `_settings` / `Overlay.maybeOf(context)` 任一抛出，都变成**无人接管的异步错误**：无 catch、无 toast、标志永久为真 → 之后每次点击都命中第 2 条。
  4. **手机端产物只落 app 私有目录**（视频 `documents/video_clips/`、有声书走系统分享），不进相册、不注册 MediaStore，**系统分享面板是用户取回文件的唯一通道**；而 `FushiShare.shareFiles` 修前首行 `if (_sharing || files.isEmpty) return;` 静默丢弃、返回 `Future<void>`，调用方无从得知，于是照样弹「已保存 / 已导出」。面板没出现 + 相册里没有 + 私有目录进不去 = 文件凭空消失，UI 却是绿色成功。`_sharing` 还是 **static 全 App 共享**，且底层 `Share.shareFiles` 无超时——平台不回包就永久钉在 true，此后全 App 每次分享都被静默丢弃。
  5. **视频侧 `!mounted` 时把已成功的产物删掉**（`video_fushi/clip_export.part.dart` 修前 `:129-132`）：用户等完导出后退出视频页 / 换集 / 进退全屏，`_deleteClipOutput` 一律删——既没看到成功也没看到失败，文件也不存在，错误日志页还是空的，三重静默。
  6. **合成层两条最需要证据的出口零日志**（`media/audiobook/audiobook_clip_export.dart` 修前 `:707-712` `inputMissing`、`:732-736` `outputMissing`，序列帧变体 `:780-785` / `:806-810` 同构）。`outputMissing` = ffmpeg 报退出码 0 却没留下产物，偏偏一行不记（下面那条 log 只在 `!isSuccess` 时跑）；`inputMissing` 还不区分缺图还是缺音频。这正是用户日志页一片空白的直接原因。

- **[x] ① 已修复** — 提交见本条末尾
  - `ffmpeg_kit_backend.dart`：`run` / `runProbe` 两份同构代码收敛成一个会话驱动 `runKitFfmpegSession`，**四处 method channel 往返各自有上限**——启动取 `min(主预算, 30 s)`（主预算是给 ffmpeg *跑* 的，不该被启动吃掉）、`cancel` 与收尾各 10 s。超时一律返回 `returnCode: null` 的失败结果，并把阶段（`start` / `execute` / `epilogue`）写进 `output`：旧实现恒返回空串，把「卡在哪」这唯一线索也抹掉了，三个阶段在用户眼里都是「没反应」但修法完全不同。只取消本次 session 的 BUG-905 语义保持不变。
  - `fushi_share.dart`：`shareFiles` / `shareText` 改为返回 **`Future<bool>`**（面板是否真的呈现），重入丢弃与平台超时都回 `false` 并写 `ErrorLogService`；两处平台调用各加 30 s 呈现上限，保证 `finally` 一定跑到、`_sharing` 不会永久钉住。空输入不记日志（调用方自己的空调用，没有用户意图被丢掉，记成用户可见错误只是噪声）。
  - `video_fushi/clip_export.part.dart`：`controller == null` 补 OSD（复用 `video_clip_export_input_missing`）；`!mounted` 分支改为**成功产物保留 + 记落点，失败残片仍删**；成功路径改成**先分享、再按面板是否呈现报结果**，没呈现时给新文案 `video_clip_export_share_unavailable`。
  - `reader_fushi/audiobook.part.dart`：防重入门补「正在导出」提示；置位与 try/finally **同域**（把 toast 与三个 context 读取挪进 try 顶部——它们仍必须在首个 await 之前，所以是挪进去而不是把置位推后）；移动端分享消费返回值，没呈现时给 `audiobook_export_clip_share_unavailable`。
  - `media/audiobook/audiobook_clip_export.dart`：两个合成变体的 `inputMissing`（区分缺图 / 缺帧目录 / 缺音频）与 `outputMissing`（带合并日志摘要）都补 `ErrorLogService`。
  - 新 i18n key 两条（`video_clip_export_share_unavailable` / `audiobook_export_clip_share_unavailable`），经 `i18n_sync --add` 补齐 17 语言 + `dart run slang`。
- **[x] ② 已加自动化测试**
  - `fushi/test/media/video/ffmpeg_kit_session_timeout_test.dart`（**行为测试**，9 条）：注入「永不回包」的假件复现三个挂死阶段，断言调用**会返回**而不是永久 pending、返回失败、`output` 指明阶段；另钉「取消本身不回包时超时机制仍生效」「只取消本次 session（BUG-905）」「成功 / 非零退出码路径未被超时收敛改变」。
  - `fushi/test/utils/fushi_share_reentrancy_test.dart` 扩 4 条：成功回 `true`、重入丢弃回 `false`、空输入回 `false`，加一条源码守卫钉两处平台调用都有 `.timeout(...)` 且签名不得退回 `Future<void>`。
  - `fushi/test/media/mobile_clip_export_silent_hang_guard_test.dart`（新，9 条）：钉住有声书防重入门有反馈、置位与 try 同域（按**带类型的完整声明**匹配——裸符号名会命中解释性注释）、两个导出的分享失败不报成功、`!mounted` 只删失败残片且留记录、合成层两个变体的两条出口都记日志、ffmpeg-kit 四处往返都带超时且超时 output 非空。
- **备注**：
  - 本轮是**单测 + analyze 全绿**，未在真机复现原始失败路径。第 1 条（ffmpeg-kit 启动挂死）在本机没有稳定复现手段——它依赖 native loader 的具体卡死条件；修复的正确性由「每处往返都有上限」这个不变式保证，行为测试直接钉这个不变式。真机验证时应先在设置 → 系统 → 诊断里**打开「调试日志」**再复现，并看错误日志页里 source 为 `VideoClipExport` / `AudiobookClipSynth` / `FushiShare.shareFiles` 的条目。
  - **同型但本条未改**（各自独立，不塞进本条范围）：
    - 视频单帧截图 `_saveScreenshot`（同文件）也是 fire-and-forget 分享 + 不消费返回值，手机上同样会「报成功但什么都没发生」。
    - 硬字幕烧录在 Android 上**必然失败后静默降级成无字幕**：门控只探 filter（`overlay`）不探 codec，而移动端自编 AAR 是 `--disable-zlib`、连 png 解码器都没有（守卫 `ffmpeg_kit_mobile_recipe_guard_test.dart` 已断言 `inflateInit_` / `deflateInit2_` 不存在）。用户端表现是「导出成功但没字幕」，OSD 不报错。属 AAR 配方问题，需重编带 `--enable-zlib`。
    - 两个导出的产物都不注册 MediaStore，且 `video_clips/` 被刻意排除在数据根迁移与存储统计之外——分享面板是唯一出口这件事本身值得重新设计。
    - `third_party/ffmpeg_kit_flutter` 的初始化把 `_initialized = true` 置在 `await` **之前**，初始化失败时标志已为真 → 此后进程内所有 ffmpeg 调用的 complete 回调都收不到，每次都跑满全额超时才失败。属上游代码，归 [BUG-1427](BUG-1427-mobile-mining-ffmpeg-stuck-6-0.md) 的 ffmpeg-kit-next 迁移范围；本条的超时收敛已让它从「永久挂死」退化为「等满超时后失败」。
    - 失败 toast 普遍被 `if (mounted)` 吞掉（Android 低内存重建 Activity / 用户切走时提示整片消失，日志仍写）——需要页面外的通知通道，独立议题。

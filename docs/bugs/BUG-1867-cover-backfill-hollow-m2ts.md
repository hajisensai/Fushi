## BUG-1867 · 封面回填把 best-effort 失败刷进用户错误日志，且对未落盘文件仍走 ffmpeg
- **报告**：2026-08-25（用户：错误日志页连刷 `extractVideoFrameViaFfmpeg ffmpeg exit -1094995529 … Error opening input files: Invalid data found when processing input`）
- **真实性**：✅ 真 bug（本机生产库实测复现，三类失败全部拿到 ffmpeg 原始 stderr 与逐条耗时）
- **[x] ① 已修复** — `501ccabefd` 见下「修复」
- **[x] ② 已加自动化测试** — `501ccabefd` · `fushi/test/media/video/video_cover_source_filter_test.dart`（新增 9 例，4 个变异实测全部抓住）
- **备注**：本轮只让**失败变安静**，没让封面补上来。**「封面始终补不上」的真根因是另一件事**：
  `-ss 10` 对 BDMV 的 m2ts 要 18–75s/条，一轮 34 条要 339s，而 `_maybeBackfillCovers` 里的
  `if (!mounted) return;` 让用户切走页面就中断——本机那 4 条「能成功」的至今 `cover_path` 仍为空，
  说明它们从来没轮到过。**已立项 [BUG-1877](BUG-1877-cover-backfill-never-completes.md)**，见文末「相邻发现」。
  ⚠ **上面这句「让用户切走页面就中断」经复核是错的**：`HomeTab.video` 在 `home_page.dart:1244-1249` 的
  `_keepAliveTabs` 里，切 tab / 切库页分区都不 unmount `HomeVideoPage`，`!mounted` 只在 app 重启或切
  Profile 时命中。真机制是「关 app 即整轮丢失 + 内存账本清零 + 下一轮又从 index 0 串行重扫」，另加
  「单条两次 ffmpeg 各 30s 上限」；`-ss` 也**在 `-i` 之前**（fast seek），慢的是 TS 的无界 probe 而非 seek。
  更正与证据见 BUG-1877。

### 复现与证据（本机生产库 `D:\APP\HIBIKI_date\support\fushi.db`，随包 `D:\APP\Hibiki\ffmpeg.exe` n7.1.5）

`_maybeBackfillCovers`（`fushi/lib/src/pages/implementations/home_video_page.dart:805`）扫全库 858 行，
筛出 **34 条**「无封面 + 本地文件存在」的候选，全部是 BDMV `.m2ts`。逐条按生产参数
（`buildFfmpegFrameArgs`：`-ss 10.000 -i <path> -an -frames:v 1 -update 1 out.jpg`）实跑并计时：

| 类 | ffmpeg 末行 | 实际是什么 | 条数 | ffmpeg 合计 | 单条均值 |
|---|---|---|---|---|---|
| A | `Error opening input files: Invalid data found when processing input` | torrent **预分配但未下载完成**的空洞文件（头 64KB 全 `0x00`，无 TS sync），共 70.3GB | 12 | 0.3s | 0.02s |
| B | `Output file does not contain any stream` | BDMV 的**纯音频短 m2ts**（菜单/音轨，0.3–3.3MB），容器里没有视频流 | 16 | 1.2s | 0.07s |
| C | `Nothing was written…` / `Conversion failed!` | 有视频流，`-ss 10` 处取不到帧 | 2 | 36.6s | 18.31s |
| — | 成功 | 真出封面 | 4 | 301.3s | 75.33s |

A 类逐字命中用户日志。判据交叉验证：实跑分类为 A 的 12 条，`head[0:65536] == b"\x00"*65536` **全部**为 True；
B/C/OK 的 22 条**全部**为 False（零假阳性零假阴性）。对照样本 `Vol1\STREAM\00010.m2ts`（完整，192 字节步长
10922/10922 命中 `0x47`）抽帧成功；`Vol1\STREAM\00014.m2ts`（空洞，0/10922）报 A。

### 根因

1. **best-effort 的回填失败被当成 app 错误上报**（= 用户看到的刷屏）。
   `extractVideoFrameViaFfmpeg`（`fushi/lib/src/utils/misc/desktop_audio_clipper.dart:745`）非零退出一律走
   `_reportFfmpegFailure` → `ErrorLogService.log`（**用户可见错误日志页**）。
   而同一条产线上游的 `extractEmbeddedVideoCoverViaFfmpeg`
   （`fushi/lib/src/media/video/video_cover_extractor.dart:94`）对非零退出的判定是
   「这容器没有内嵌封面 = 预期内的正常结果」，**不上报**。同一个「这文件给不出封面」的事实，
   两步给了两种严重性。回填这条后台 best-effort 路径上，A/B/C 三类全是预期内的正常结果：
   书架显示占位图本身就是用户可见的反馈，错误日志页是留给「app 出错了」的。

2. **候选判据只问「路径存在」，不问「内容是否已落盘」**。
   `isLocalFrameExtractableVideoSource`（`video_cover_extractor.dart:149`）只排除空路径 / `http(s)` / 播放列表清单；
   `_maybeBackfillCovers` 再补一道 `File(path).existsSync()`。torrent 预分配的空洞文件两道都过——它有正确的
   扩展名、正确的字节数（8GB）、路径存在，只是**内容还不在盘上**。

   ⚠ 诚实计量：这一条**不是性能问题**。实测 ffmpeg 在头部就 probe 失败，0.02s/条，12 条合计 0.3s。
   修它买的是三件事：① 不为必然失败的抽帧去排 `VideoCoverMutationGate` 的队（同期的删除、手选封面、
   刮削要等在后面）；② 把「还没下完」与「这文件坏了」分成两个可诊断的原因，而不是混成同一个
   `extract-failed`；③ 判定不依赖 ffmpeg 的具体行为（换 demuxer 白名单或版本都不影响判据正确性）。

放大器：`CoverBackfillLedger`（`fushi/lib/src/media/video/cover_backfill_ledger.dart`）是**会话级内存单例**，
文件头注释写「不落库持久化 … 每次冷启动最多为每个坏条目付一次探测成本」。该取舍在本库上的实际代价是：
每次冷启动进视频页 = 重烧 34 次 ffmpeg（**合计 339s**）+ 刷 30 条用户可见错误日志。

### 修复

- ① 回填路径的 ffmpeg 失败降级为诊断：`extractVideoFrameViaFfmpeg` /
  `extractEmbeddedVideoCoverViaFfmpeg` / `extractVideoCover` 加 `diagnosticOnly`（复用既有机制
  `desktop_audio_clipper.dart` 的 `_logFfmpegSummary`），`_maybeBackfillCovers` 传 `true`。
  **两段都要降**：只降抽帧那一段的话，ffmpeg 缺失时内嵌封面那一段仍会按错误级刷满 34 条。
  降级的确切含义是**不计入错误计数、不落盘，转入日志页的「诊断/取证」分节**——证据仍随复制/分享/
  上传带走，不是删证据。**`ProcessException`（ffmpeg 根本起不来）仍进错误日志**；用户主动触发的
  导入/换封面路径保持默认 `false`。
- ② 新增 `isHollowMediaHeaderBytes` / `hasHollowMediaHeader`（`video_cover_extractor.dart`）。
  接线**只有一处**：抽取器层 `_extractVideoCoverUnlocked` 早退（与 BUG-1564 的清单拒收同层收口，
  所有调用方——回填 / 导入 / 拆集 / host 服务——一并免疫）。判据安全性：每种被支持的容器头部都有
  魔数（TS `0x47` / MP4 `ftyp` / MKV `1A45DFA3` / RIFF / FLV），合法媒体文件头部不可能全零，无误伤面。
- **读不出来 != 空壳**：打开/读取失败（权限、掉盘、竞态删除、传进来的根本不是普通文件）返回
  `false` 并记一条诊断，**不是** `true`。返回 true 会让所有调用方静默拿到 null——一条日志都没有，
  用户主动触发的导入/换封面也查不出「为什么没有封面」。返回 false 是把这类输入交回下游 ffmpeg，
  让它走原本那条可诊断路径（严重性由各调用方的 `diagnosticOnly` 决定）。
- ledger 持久化**不做**：失败重烧的时间大头不在 A 类（见上表），持久化解决不了它，反而要付 schema
  迁移 + 陈旧账本的代价。保持 BUG-1564 的原取舍。

**审查采纳后删掉的两样东西（如实记账）**：

- page 层 `_maybeBackfillCovers` 里的**空洞预判**已删。它与抽取器层是同一事实的两处真相源，
  同一个文件会被读两次 64KB。删掉后空洞候选照旧被抽取器层判掉（确定性 null，不起 ffmpeg 子进程），
  只是改由既有的 `extract-failed` 记账收尾。
- 随之删掉的还有 `reason: 'hollow-header'`。原先声称的收益「把『还没下完』与『这文件坏了』分成两个
  可诊断的原因」**当前不可观测**：`CoverBackfillLedger.failureReason()` 全仓零消费者（既不进日志、
  也不进 UI），这个区分只活在内存里给不存在的读者看。等真有消费端时再加，不先欠一笔。

### 测试

`fushi/test/media/video/video_cover_source_filter_test.dart`：

- 纯函数判据：空 / 全零 / 只有尾字节非零 / 四种真容器魔数；
- 真文件 IO：空洞预分配 / 192 字节步长的真 m2ts 布局 / 内容只在探测窗之后 / 短于探测窗 / 零长 /
  单字节 `0x00`；**读失败契约**——不存在的路径与目录都返回 `false`，各留一条
  `source == 'hasHollowMediaHeader'` 的诊断，且用户可见错误计数不变；
- 抽取器层**双向**：空洞文件返回 null（无 path_provider mock、无 ffmpeg，靠早退才不炸
  MissingPluginException）+ **正向对照**——真容器头必须*穿过*拒收继续走到
  `AppPaths.videoCoversDirectory()` 并抛。没有这条正向对照，把 `_extractVideoCoverUnlocked`
  改成无条件 `return null` 也照样绿；
- 抽取器接线守卫（源码扫描）：空洞拒收是唯一一道门且在 AppPaths/ffmpeg 之前 / 两段 ffmpeg 都吃到
  `diagnosticOnly` / 读失败分支必须是「记诊断 + return false」；
- 视频页接线守卫：回填必须 `diagnosticOnly: true`，且 page 层**不得**再出现 `hasHollowMediaHeader`
  （判据唯一真相源）。

变异实测（二进制读写、唯一锚点、sha256 校验回滚，4/4 全部抓住）：
真删除 page 层判据整块 → 顺序守卫红；删 `diagnosticOnly: true` → 分级守卫红；
删抽取器层拒收 → 行为测试红（MissingPluginException）；判据恒返 false → 4 条真文件用例红。

相邻定向：`cover_backfill_ledger_test` / `video_cover_extractor_test` / `playlist_cover_test` /
`video_import_cover_gate_guard_test` / `media_cover_write_guard_test` / `ffmpeg_tls_pin_args_test` /
`ffmpeg_backend_test` / `home_video_cover_badge_test` / `continue_cover_portrait_guard_test` /
`home_video_collection_cover_card_test` / `audiobook_clip_export_logging_guard_test` /
`audio_stream_map_tolerant_guard_test` / `ffmpeg_min_network_h264_guard_test` /
`youtube_stream_replay_ua_test` 全绿。

### 相邻发现（**未修**，独立问题，需要单独立项）

上表右两列是本轮调查的副产品：真正的时间大头不是失败，是**成功与 C 类的抽帧本身**——
`-ss 10` 对 BDMV 的 m2ts 要 **18s（C）到 75s（成功）** 一条。34 条候选跑满一轮 = **339s**。
后果是：`_maybeBackfillCovers` 每次冷启动都要在后台烧近 6 分钟 ffmpeg，而 `if (!mounted) return;`
让用户切走页面就中断——本机那 4 条「能成功」的至今 `cover_path` 仍为空，说明它们从来没轮到过。
方向（待验证）：BDMV 的 m2ts 没有全局索引，输入定位在其上退化；可考虑先 ffprobe 拿时长/关键帧，
或对无索引容器改用更小的 seek 点。本 bug 不扩大范围去改抽帧策略。

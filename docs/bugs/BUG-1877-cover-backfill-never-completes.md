## BUG-1877 · 封面回填永远跑不完：单条两次 ffmpeg 各 30s 上限 + 失败账本只在内存 + 每轮从头串行扫
- **报告**：2026-08-25（BUG-1867 调查的「相邻发现」，用户裁定单独立项）
- **真实性**：✅ 真 bug。耗时数据来自 BUG-1867 在本机生产库（`D:\APP\HIBIKI_date\support\fushi.db`，随包 `ffmpeg.exe` n7.1.5）的逐条实测；本轮代码路径全部对 `origin/develop` = `b033568067` 复核。
  用户可见症状：视频书架的 BDMV 条目**永远显示占位图**。本机 34 条候选里有 4 条实测「抽帧能成功」，但它们的 `video_books.cover_path` 至今为空——说明它们**从来没轮到过**。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：与 [BUG-1867](BUG-1867-cover-backfill-hollow-m2ts.md) 是同一函数上的两件事。1867 只让**失败变安静**（`diagnosticOnly` + 空洞头拒收，已合入 `origin/develop`），本条管**成功也补不上**。⚠ **BUG-1867 备注里「`if (!mounted) return;` 让用户切走页面就中断」这句话是错的**，见下「根因 ④」——真机制不是切页，是关 app；立项时予以更正。

### 实测成本结构（BUG-1867 §复现与证据，34 条候选全部是 BDMV `.m2ts`）

| 类 | 实际是什么 | 条数 | 单条均值 | 小计 |
|---|---|---|---|---|
| A | torrent 预分配未下完的空洞文件（头 64KB 全零） | 12 | 0.02s | 0.3s |
| B | BDMV 纯音频短 m2ts（菜单/音轨，容器里没有视频流） | 16 | 0.07s | 1.2s |
| C | 有视频流但 `-ss 10` 处取不到帧 | 2 | 18.31s | 36.6s |
| — | **真出封面** | **4** | **75.33s** | **301.3s** |
| | | 34 | | **339s** |

**时间大头是成功那 4 条**（301s / 339s = 89%），不是失败。A/B 两类在 BUG-1867 合入后已经不起 ffmpeg 子进程了，账面上省下的是 1.5s——**对本 bug 毫无帮助**。

### 根因

一条 best-effort 后台产线，被四个互相叠加的约束卡成「结构性跑不完」。

**① 单条要跑两次 ffmpeg，各带 30s 硬上限 → 单条最长 60s。**
`extractVideoCover`（`fushi/lib/src/media/video/video_cover_extractor.dart:310`）先探内嵌封面、失败再抽帧：
- 第一趟 `extractEmbeddedVideoCoverViaFfmpeg`，参数 `-y -i <path> -an -map 0:v:disp:attached_pic -frames:v 1 -update 1 out.jpg`（`video_cover_extractor.dart:75`），**整趟没有 `-ss`**，超时 `video_cover_extractor.dart:111`。
- 第二趟 `extractVideoFrameViaFfmpeg`，超时 `fushi/lib/src/utils/misc/desktop_audio_clipper.dart:760`。

**这里要更正一个常见误判**：`-ss` **是放在 `-i` 之前**的（输入定位 / fast seek，`desktop_audio_clipper.dart:701`；只有 `decodeFromStart` 才挪到 `-i` 之后，见 BUG-1416 的注释 `:678`），回填路径不传该参数、恒走 fast seek。**慢的不是 seek 策略，是 TS 的 probe**：BDMV 的 `.m2ts` 是 192 字节包、无全局索引、常带多路 video/audio/PGS，`avformat_find_stream_info` 在其上是无界的。第一趟（无 `-ss`，必须完整 probe）就已经是秒级到十几秒；第二趟的输入定位在 TS 上是按字节二分 + 解析 PTS，同样要真读盘。**两趟叠加 = 实测的 18~75s**。

**② 并发度 1，且每轮都从同一个位置从头扫 → 慢条目后面的行结构性饿死。**
`_maybeBackfillCovers`（`fushi/lib/src/pages/implementations/home_video_page.dart:774`）是 `for` 循环内逐条 `await`。取数 `widget.repo.listAll()`（`:783` → `fushi/lib/src/media/video/video_book_repository.dart:386` → `allVideoBooks()`）**没有 ORDER BY**，按 rowid 插入序返回；循环恒从 index 0 开始。慢的 BDMV 行位置固定，排在它们后面的候选每一轮都得先等前面那 300 多秒。

**③ 失败账本只在内存，冷启动清零 → 每次重烧。**
`CoverBackfillLedger`（`fushi/lib/src/media/video/cover_backfill_ledger.dart`）是进程单例 `Map<String, CoverBackfillFailure>`，文件头注释明确写了「不落库持久化」（BUG-1564 的取舍）。消费点 `home_video_page.dart:801` / `:843` / `:849` / `:537`。**成功侧有持久化**（`video_books.cover_path`），失败侧没有——于是每次冷启动都把 C 类那 2 条 ×18s 重烧一遍。

**④ 整轮只在「关 app / 切 Profile」时丢失，不是切页——但丢失即从头开始。**
`if (!mounted) return;`（`home_video_page.dart:785` / `:850`）是唯一的中断点，`dispose()` 里没有任何回填取消逻辑。而 `HomeVideoPage` 在 develop 上**切页不会 unmount**：
- 视频 tab 在保活集合里：`fushi/lib/src/pages/implementations/home_page.dart:1244-1249` 的 `_keepAliveTabs` 含 `HomeTab.video`，实现 `home_page.dart:2206-2209`（`Offstage` + `TickerMode`，注释明写「State 不销毁」）。
- 库页内切分区也不 unmount：`fushi/lib/src/pages/implementations/video_library_shell.dart` 里 `HomeVideoPage` 挂在无条件存在的 `Offstage` 下，无 key，`section` 变化走 `didUpdateWidget`。

**所以「切页即断」不成立，`!mounted` 实际只在 app 重启 / 切 Profile 时命中。** 但这不改变结论，只改变机制：用户必须让 app **连续前台运行约 6 分钟**，那 4 条才轮得到；一旦关掉 app，③ 让账本清零、② 让下一轮又从 index 0 开始——两者合起来就是「永远补不上」。这也解释了为什么本机那 4 条至今为空。

**放大器（不是根因，但同一段代码的真实代价）**：整条 ffmpeg 跑在进程级封面写锁 `VideoCoverMutationGate.runExclusive` **之内**（`home_video_page.dart:805`），同期的删除、手选封面、刮削会被单条最长 60s 地堵在后面；外层还持一整轮的 `VideoScrapeOperationGate` lease（`:776-782`），整轮期间 `tryEnterMaintenance()` 必失败，且拿不到 lease 时**整轮直接跳过、没有任何重排机制**。

### 修复方向（未定，供裁定）

**A. 砍掉每条的第二次 ffmpeg / 给 probe 加界**（治单条耗时）
- 内嵌封面探测对 `.m2ts` / `.ts` 是纯浪费——TS 容器不存在 `attached_pic`。按容器跳过这一趟（只对 mkv/mp4/m4v 之类真会带附件封面的容器尝试），单条立刻砍掉一半。
- 给 ffmpeg 加 `-probesize` / `-analyzeduration` 上界，把 TS 的无界 `find_stream_info` 变成有界。
- 回填是后台增强，30s×2 的预算过奢；分级成更短预算（失败即记账，把时间还给后面的行）。
- ⚠ 风险：`-probesize` 收太狠会让本来能抽到帧的 BDMV（多音轨 + PGS）抽不到；缩超时会把「慢但能成」误判成失败。而账本靠 mtime/size 失效——**文件不变就永不重试**，一次误判 = 这条这辈子补不上。改超时前必须先让失败可重试。

**B. 让队列单调前进**（治「永远补不上」，比 A 更根本）
- 把「已尝试且失败」落持久化（键 `videoPath` + mtime/size，语义与内存账本一致）。就算单条仍要 60s，只要不重置，几次会话就能跑完。可用 `preferences` 表存序列化账本规避 schema 迁移（当前 v62）。
- owner 从 `_HomeVideoPageState` 抬成进程级服务（与 `CoverBackfillLedger` 同层），`mounted` 只管 `setState`，不管任务存活。
- ⚠ 风险：抬成后台服务后 ffmpeg 会在用户不在视频页时跑，必须有让路策略（正在播放视频时不抢 IO），否则变成新的「后台偷跑」投诉。
- ⚠ 下拉刷新的 `clearAll()`（`home_video_page.dart:537`）语义要跟着走，否则用户失去强制重试的手段。

**C. 收细锁粒度**（治放大器，可独立做）
- `VideoCoverMutationGate.runExclusive` 现在包住两次 ffmpeg。真正需要串行的只有「准入 → 文件替换 → DB 指针 → provenance 提交」；ffmpeg 应在锁外写临时文件，拿到字节后再进锁 rename。
- ⚠ 风险：临时文件名不得与 `<uid>.jpg` 同名同路径，落地必须走 `MediaCoverService.applyCoverBytes` 的原子 rename + 双键缓存驱逐，否则重演 BUG-1118 的「显示旧封面」。

**D. 两处产物校验判据不一致（不属本条根因，如实记一笔）**
- 抽帧那段严格：`desktop_audio_clipper.dart:763` 是 `code == 0 && output.existsSync() && output.lengthSync() > 0`。
- 内嵌封面那段宽松：`video_cover_extractor.dart:124` 是 `if (output.existsSync() && output.lengthSync() > 0) return outputPath;`，**不看 returnCode**。
- 这是**有意为之**且带注释（`:122-123`）：没有内嵌封面的容器本就非零退出且不写文件，故靠产物而非退出码区分。残留风险只在一个窄缝里：ffmpeg **既非零退出、又已写出非空残文件**（写到一半被超时杀掉 / 磁盘写失败）时，半张 jpg 会被当成功封面落库。未实测到这种例，**不建议在本条里顺手改**（改完容器就再也区分不出「没封面」与「抽失败」）；要收只能改成「非零退出时额外校图片魔数」，开销另评。

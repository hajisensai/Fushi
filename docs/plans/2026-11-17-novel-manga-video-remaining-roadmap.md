# 2026-11-17 小说 / 漫画 / 视频优化：剩余路线图

> 这份文档给以后接手的人和 agent 用：不需要看过当初的草稿，照这里就能知道还剩什么、先做哪个、每组要等谁。
> 文中的事实来自审读与复核记录；标「部分成立」「需先量」的照复核结论写（复核收窄或推翻了哪一半，条目里写了），没有实测数据的地方都写明了。

## 0. 这是什么

- **来源**：对小说、漫画、视频三个域做了一轮只读代码审读，得到三份优化清单；之后又补读了十块没读到的区域（阅读器引擎 JS 两块、小说杂项、漫画杂项、来源扫描、网页视频、远端 / 媒体服务器、字幕面板、原盘与图形字幕、视频杂项）。每一条都由另一位审查者回到代码逐条复核，结论分四档。三份原始清单 159 条：成立 100、部分成立 34、需先量 8、被反驳 17；补读的十块 98 条：成立 47、部分成立 33、需先量 18、没有被反驳的。合计 257 条：成立 147、部分成立 67、需先量 26、被反驳 17。
- **代码基准**：审读与复核用的是 `upstream/develop` @ `4c347287835`（2026-11-17），文中的位置与行号都是这个基准上的，开工前要重新定位。本文档所在分支基于更新的 `29ee33b204b`（比基准多 40 个提交）；文中点名的路径在这个提交上都存在。
- **分组**：复核后的条目按「文件不相交、可并行」分成 57 组，排成 7 波：第 1 波 23 组（互相独立）、第 2 波 6 组、第 3 波 13 组、第 4 波 7 组、第 5 波 3 组、第 6～7 波 5 个测量组。另剔除 54 条（3 条待拍板的在第 5.1 节，其余见第 6 节）。
- **2026-11-20 更新**：剩余 33 组已全部做完并开 PR（均未合并），结果、PR 号、测量数字与待拍板去向见文末**第 8 节**，下面各节的状态描述以第 8 节为准。
- **当前进度（写于 2026-11-17 晚）**：第 1 波 23 组加上提前做完的 c41，共 24 个 PR 已开，**全部未合并、真机验证全部未做**。剩下 33 组：第 2 波 6、第 3 波 12、第 4 波 7、第 5 波 3、第 6 波 4、第 7 波 1。
- **条目 id 的读法**：`novel-N` / `manga-N` / `video-N` 是三份原始清单的条目号；`-dN` 是清单「需所有者拍板」一节的第 N 项；`-s2-N` / `-s3-N` 是清单第 2 节 / 第 3 节的第 N 项；`gap-<块>-N` 是补读发现的条目。`cNN` 是实施组，`mN` 是测量组。

### 路径缩写

| 缩写 | 全路径 |
|---|---|
| `F/` | `fushi/lib/src/` |
| `PI/` | `fushi/lib/src/pages/implementations/` |
| `RF/` | `PI/reader_fushi/` |
| `VF/` | `PI/video_fushi/` |
| `MV/` | `F/media/video/` |
| `MG/` | `F/media/manga/` |
| `EN/` | `packages/fushi_engine/lib/` |
| `EV/` | `EN/media/video/` |
| `CORE/` | `packages/fushi_core/lib/src/database/` |
| `AU/` | `packages/fushi_audio/lib/src/` |
| `T/` | `fushi/test/` |
| `VFP` | `PI/video_fushi_page.dart` |
| `VPC` | `MV/video_player_controller.dart` |
| `HVP` | `PI/home_video_page.dart` |

### 所有组通用的做法

- 一组 = 一个 worktree = 一个分支 = 一个 PR，分支从 `upstream/develop` 新建，建完跑 `tool/setup_worktree.ps1`，在 `../coordination/claims/` 登记。
- 可靠性条目按 `docs/BUGS.md` 流程一条一个 bug 文件，记根因 `file:line`，配最强可落地层的自动化测试。`docs/BUGS.md` / `docs/bugs/` 与 17 份 i18n json 是各组必然相交的共用落点。
- 同一波内各组的文件集合两两不相交；跨波同文件的写了依赖，等前一组合入再开。
- 第 3 波起各组写了「闸」：点名的在途 PR 合入（或明确放弃）后才开。
- 第一波踩过的坑，后面各组直接照做：
  - `dart run tool/bug.dart settle` 的默认基线是 `origin/develop`。上游 remote 不叫 `origin` 的 clone 里它可能是过期的，会报「判不出先后」，这时带 `--base upstream/develop`。并行组多时号会反复相撞，合入后由 develop 上的 settle CI 收口。
  - 闭包不碰 `dart:ui` 的新测试要 `import 'package:test/test.dart'`，否则 `pure_dart_test_import_guard_test.dart` 在 PR CI 里红（c10、c20 都红过）。
  - 源码扫描型守卫不得手写注释剥离，统一用 `helpers/source_guard.dart` 的 `maskComments`（c04 红过）。
  - 新写的 Node 测试跑手：payload 走 stdin 而不是 `process.argv` 指的文件，执行脚本用 `node:vm` 的 `compileFunction` 而不是 `new Function`，公共段抽进支持模块，否则 SonarCloud 的安全评级与重复率两项会红（c05、c06 都修过一轮）。
  - 定向测试里只要有 Windows 专属套件，外包到 dist 机器时它没有可用 worker、零执行、整体退出码 1。这不是红，要在本机用 `heavy.dart --here` 补跑那几个文件。
  - 改了生产代码的函数签名 / 结构后，去 grep 一遍相关的源码守卫测试，红了先分清是哪一种（两种都是 PR CI 才发现）：c14 是守卫钉着旧字符串锚点，改的是守卫；c16 是守卫没错，分支把同步 `existsSync()` 内联回了库页每次刷新都走的读路径，改的是生产代码。

---

## 1. 已提交部分一览（第 1 波 23 组 + c41）

以下 24 个 PR 截至 2026-11-17 晚在 GitHub 上都是 OPEN，**没有一个合并，真机 / 真 app 验证一项都没做**。多数 PR 推完后的 CI 结论没有等到。

### 小说 / 阅读器

| 组 | 分支 | PR | 条目 | 做了什么 |
|---|---|---|---|---|
| c01 | `pr/online-novel-loader` | #3699 | novel-18、novel-1、novel-2、novel-10、novel-d5 | 两个按需取章 loader 抽共用骨架；取章后把正文字数交回阅读器；预取链不再隔一章；前台请求让位、关书停预取；取章失败文案归一 |
| c02 | `pr/lnreader-hardening` | #3705 | novel-5、novel-11、novel-d4、novel-17g（只删覆盖点） | LNReader 状态读失败不当空；章节插图走统一请求头；已上架作品页先出旧目录再后台刷新 |
| c03 | `pr/reader-nav-lookup-state` | #3711 | novel-12、novel-19、novel-16 | 追踪上报挪出返回键等待链；进度快照两处闸收成一处；点词选区状态在 await 前写齐 |
| c04 | `pr/reader-audiobook-cues` | #3698 | novel-8、novel-17b | 整书 cue 重灌不再重复排序 / 解码，桥接脚本并成一次注入；高亮 Future 接错误 |
| c05 | `pr/reader-js-paged-anchor` | #3710 | gap-readerjs1-1、-8、-4、-6、-7 | 分页 settle / 揭示帧按语义锚重算；度量少量两次矩形；补「方法 × shell」总表守卫 |
| c06 | `pr/reader-js-vn-seamless` | #3712 | gap-readerjs2-1、-3、-4、-6、-10 | VN 重切不打断当前屏、首屏不等图片、合成书句子命中；无缝衔接启动失败复位 |
| c07 | `pr/import-dir-ownership` | #3693 | novel-3、novel-13、manga-11、gap-mangamisc-9 | 导入解析失败不留暂存目录；同名并发导入加锁；漫画导入改用书根暂存并只回滚自己建的目录；残留清扫 |
| c13 | `pr/audiobook-file-swap` | #3709 | gap-novelmisc-4、novel-17c | 换音频 / 换字幕改成「拷新 → 写库 → 删旧」并可撤回；播放位置两次写并进一个事务 |

### 漫画

| 组 | 分支 | PR | 条目 | 做了什么 |
|---|---|---|---|---|
| c09 | `pr/manga-online-startup` | #3702 | manga-1、manga-5、manga-17c、manga-17d、manga-18b（未修到根因） | 在线章只等本地就绪；广告候选页有界并发；全源搜索取消后不再发请求；Cloudflare 按类型判 |
| c10 | `pr/manga-ocr-pipeline` | #3700 | manga-2、manga-15、manga-24、manga-25、manga-26 | Lens 只认自己的逐页缓存；系统 OCR 取消不写半卷；恢复补系统 OCR 缓存；原子写共用；探测并行 |
| c11 | `pr/manga-ocr-host-io` | #3696 | manga-7、manga-8、manga-9 | AI 复核回写攒批；互联同卷重传能命中逐页缓存；host 逐页供图不再全表读 |
| c12 | `pr/kavita-offline-panel-misc` | #3701 | manga-d11、gap-mangamisc-10、-11、-6 | Kavita 不可达本会话记住；页图 / 模型下载按停顿超时；分镜大格按行切修好 |
| c41 | `pr/manga-ocr-cancel-exit` | #3719 | manga-16 | 取消 / 暂停后等 OCR isolate 真退出才还并发名额；原子写临时文件唯一名；Windows 上读写互斥。**原属第 3 波，已提前做完；叠在 #3700 上，#3700 合入后 base 要改成 develop** |

### 视频

| 组 | 分支 | PR | 条目 | 做了什么 |
|---|---|---|---|---|
| c14 | `pr/web-video-queue-reliability` | #3694 | gap-webvideo-1、-12、-2、-5、-7 | 网页视频制卡队列中途抛错必收尾、按视频归组、让位不误标失败、宿主页不写机器播放头 |
| c15 | `pr/video-mine-queue-hygiene` | #3706 | video-9、video-s2-3、video-36l、video-36p、video-24、gap-webvideo-3 | 暂存队列退出只提交待写入的行、写完即删行；窄查询；Anki 模板一次往返读 |
| c16 | `pr/video-library-scrape-io` | #3697 | video-10、video-14、video-36j、video-17、video-36k、video-s3-19 | 复用已记 ED2K；补刮计划失败不再吞成空清单；封面 IO 少同步 stat |
| c17 | `pr/video-stream-probe` | #3703 | video-13、video-36n、video-36h、gap-remote-5、gap-remote-9 | HLS 画质探测走应用代理；HLS 解析收成一份；YouTube 出口不通提前停、字幕加超时；中继登记表淘汰 |
| c18 | `pr/legacy-subtitle-decode` | #3716 | video-35、video-s2-8 | 桌面三端与无头服务端用 Rust（`fushi_compute`）解 CP932 / GBK / EUC-JP / Big5 文本 |
| c19 | `pr/graphic-sub-regions` | #3713 | gap-disc-3、-7、-2、-8、-6（只做远端索引记忆） | 图形字幕抽取的取消所有权与失败日志；原盘采样按脏位读轨道；遮蔽层 Ticker；字幕手改存储键 |
| c20 | `pr/media-server-launch` | #3704 | video-7、gap-remote-1、-6、-8 | 起播只取一次条目详情；Plex 探测并发；互联视频同步缺文件不再每轮报错 |
| c21 | `pr/anki-video-template-errors` | #3708 | gap-vidmisc-8、-9、-7 | 视频模板报错带码并走 i18n；坏备份逐文件跳过；卡面片段加载失败落占位 |
| c22 | `pr/android-pip-controls` | #3715 | gap-vidmisc-1、-4（只算代码已写） | PiP 里换集后认领状态；小窗补播放 / 暂停键与换集比例同步 |
| c23 | `pr/subtitle-panels-reliability` | #3714 | gap-subpanels-2、-3、-5、-6 | 字幕搜索代次与重入守卫；多选契约；批量失败带原因；探测失败不进缓存 |

### 跨域

| 组 | 分支 | PR | 条目 | 做了什么 |
|---|---|---|---|---|
| c08 | `pr/source-scan-integrity` | #3707 | gap-scanner-1、-2、-7、-10、-11 | 视频搬家要正证据；过滤系统垃圾条目；漫画索引逐卷落盘；扫描残留可回收；写死中文串改类型化错误 |

### 合并这 24 个 PR 时要知道的

- **bug 号大面积相撞**：多数 PR 都占着 BUG-4798 / BUG-4799（c07 与 c41 还共用 BUG-4800）。谁后合谁被 develop 上的 settle CI 再改一次号，PR 标题与提交信息里的旧号不会跟着变。
- **叠放**：#3719 的 base 是 `pr/manga-ocr-pipeline`，先合 #3700。#3719 与 #3696 试合并无冲突。
- **互相碰同一文件**：c01 与 c03 都改了 `PI/reader_fushi_page.dart` 和 `T/reader/reader_read_ledger_wiring_guard_static_test.dart`，后合的一方可能要手解。c02 的 `lnreader_novel_detail_page.dart` 同时在别的在途 claim 里。c04 的 `audiobook_controller.dart` / `RF/audiobook.part.dart` 被十几个在途 claim 声明。
- **c18 带了一个 develop 级修复**：`fushi/integration_test/support/test_app_launcher.dart` 给夹具播种 `library_layout_default_notice_handled`。在它合入前，所有动原生代码的 PR 的 Windows / macOS appSmoke 都会红在「Second nav tab must be reachable by focus」。
- **用户可见的行为变化**（都写在各自 PR 正文里，所有者合之前过目）：
  - c10：别的引擎已识别完的卷再用 Lens「只补缺页」，现在整卷每页都上传重认。
  - c14：一行抛出后**结束本轮**而不是「标失败并继续」（偏离计划字面，理由是分不清是行的错还是环境的错）；落卡顺序按视频聚合。
  - c15：瞬时失败（如 Anki 没开）退出后不再自动重试，要进列表点「全部写入」。
  - c23：多选态点行只勾选；部分失败不自动关页，已下好的要等用户关页才应用；批量途中返回会把已落盘的第一条应用成当前字幕；页面关闭后还在路上的那一条不再落盘。
  - c02：Secure cookie 不再发给 `http://` 地址（为此动了计划外的 `MG/cookie/manga_cookie_jar.dart`，出站桥与 Cloudflare 解题页也经它取 cookie）；章节插图请求的 Accept 不再声明 AVIF。
  - c17：YouTube 解析出站的建连超时从 20 秒收到 10 秒，慢代理下没有实测。
  - c13：有声书旧音频的回收目录结构改成每次同步一个批次 `.retired/<n>/`，写库成立后所有批次一起落已提交标记再删。
  - c08：视频搬家判据比计划更严（要两层目录链都对得上且不全是通用目录名），代价是部分真搬家会另建 `X (2)`（旧行与进度都在）。
  - c12：恢复策略取了「任何一次答话都结束不可达」。
  - c22：同步器从常规播放起就挂着，不只在 PiP 表面。

---

## 2. 剩余路线图

每组写：建议分支名、规模（S / M / L）、依赖（哪些 PR 先合）、闸、是否要 i18n / 升 schema、条目（现象 → 位置 → 修法方向）、涉及文件、测试与验证。

### 波次之间的开工条件

| 波 | 组 | 开工条件 |
|---|---|---|
| 第 2 波 | c24～c29 | 各自依赖的第 1 波 PR 合入 develop。六组之间互不相交，可并行 |
| 第 3 波 | c30～c40、c42 | 依赖的第 1 / 2 波组合入，**并且**各组点名的在途 PR 有结论 |
| 第 4 波 | c43～c49 | 依赖的第 1～3 波组合入。c44、c45、c47、c48 除了前两波的组，还直接依赖第 1 波的 PR（c15 / c16 / c17 / c13、c03、c04） |
| 第 5 波 | c50～c52 | 依赖的第 1～4 波组合入。c50 直接依赖 c28（第 2 波）与 c12 #3701（第 1 波），c52 直接依赖 c13 #3709（第 1 波） |
| 第 6 波 | m1～m4 | 实测步骤只读，**现在就能在 develop 尖端做**；改动步骤等各自依赖合入 |
| 第 7 波 | m5 | m1～m3 有结论 |

闸里点名的在途 PR 现状（2026-11-17 晚）。「直接压着」是各组标题行写的闸；「间接压着」是没在标题行写闸、但要改同一个热文件或依赖着被压的组，计划的未决问题里把它们算作同一道闸：

| PR | 分支 | 状态 | 直接压着 | 间接压着（热文件 / 依赖链） |
|---|---|---|---|---|
| #3672 | `pr/video-stutter` | OPEN | c32、c33、c45（只 gap-scanner-4）、m3、m5 | c46（`VPC`，依赖 c32）、c47（`HVP`，依赖 c33） |
| #3679 | `pr/embedded-sub-watched` | OPEN | c31、c32、c36、c44 | c46（`VPC`）、c45、c51（`VFP` 与 `VF/subtitle.part.dart`） |
| #3663 | `claude/subtitle-workbench-optimization-f99c1a`（字幕工作台改全屏） | OPEN | c31、c32、c33、c34、c35、c36、c47 | c46（`VPC`）、c45、c51（`VFP`）、c44（`F/models/app_model.dart`） |
| #3515 | `pr/collage-polish` | OPEN | c33、c35、c37、c39、c40、c48 | c49、c50（书架 / 作品页那几个文件，都依赖 c37）、c47、m3（`HVP`）、c44（`app_model.dart`） |
| #3534 | `pr/tab-switch-jank` | OPEN | c37、c42、c48 | c49、c50（同上） |
| #3467 | `pr/book-volume-covers` | OPEN | c37、c48 | c49、c50（同上） |
| #3665、#3667、#3668、#3670 | 漫画有声四件（`feat/manga-audio-*`） | OPEN，base 不是 develop | c37、c48（四件都等）；c38、c35（只 #3670） | c49、c50（同上）；c44（只 #3670，`app_model.dart`） |
| #3644 | `fix/leftover-disc-menu` | 已合并 | 原来压着 c31，这条闸已解 | — |
| #3466 | `feat/ocr-local-models`（外部作者） | OPEN | 原来压着 c41；c41 已提前做完，PR 正文写了两边 hunk 不相交，后合的一方要调测试装配 | — |

- 漫画有声四件的 base 是 `claude/manga-audio-character-voice-memory-a2e701`，不是 `develop`。它们「合入」指整叠落到 develop，只合进那条基底分支不算解闸。
- c37、c48、c49、c50 四组在计划里是同一整套闸（#3515、#3467、#3534 加四件套）。c49、c50 的标题行没写闸，是因为它们依赖 c37，c37 解闸之前本来就开不了。
- #3466 是外部作者的 PR，**合不合由所有者定**（计划的未决问题里写明了）。它决定 #3719 与 #3466 谁先合、谁调测试装配。

### 第 2 波（6 组）

#### c24 `pr/reader-chapter-prefetch-restore`（S）
- 依赖：c01 #3699、c03 #3711、c05 #3710。
- novel-17d：章节缓存命中之前已经读过盘（先读后查）。位置 `RF/webview.part.dart`。修法：缓存检查放在 `_ensureOnlineChapter` 与 404 判定之后、读盘之前；字体 / CSS 分支仍读字节。
- novel-17f：章节 HTML 预取固定取 `+1`，不看阅读方向，也不认「插图并入正文」的重定向。位置 `RF/webview.part.dart`。修法：用 `_chapterAdvanceDirection` 并先过 `_resolveNavChapter`。
- gap-readerjs1-2（部分成立）：引擎初始化链没有失败出口，有声书 cue 应用或恢复函数一抛异常就不通知恢复完成，只能等 Dart 侧 8 秒兜底。位置 `F/reader/reader_pagination_scripts.dart`。复核没找到真实抛出路径，属加固。修法：cue 应用单独隔离并 `console.error` 上报后照常恢复；恢复失败发带失败标记的回执让 Dart 立刻走 `_failNavigation`。不删 `imagePromises`。
- 文件：`RF/webview.part.dart`、`RF/navigation.part.dart`、`F/reader/reader_pagination_scripts.dart`、`T/reader/image_chapter_lazy_load_guard_test.dart`。
- 测试：守卫 + Node 行为测试。验证：paginated / continuous / vn 各换章、往回翻。
- 注意：c01 把 `OnlineNovelChapterLoader.ensureLoaded` 的返回值改成 `OnlineNovelChapterLoaded?`，并新增 `dispose()`；预取记录过期时 `characters` 为 null。按新签名写。

#### c25 `pr/web-novel-snapshot-consistency`（S）
- 依赖：c01 #3699。
- gap-novelmisc-3（成立，低频）：网页小说章节加载「先写文件、后写库」，中途失败后这本书永久追不了更。位置 `F/media/novel/web/web_novel_library.dart`。修法：短路判据以快照为准，index 等于快照章数且文件已非占位时判不一致并重新取页。开 bug 文件。
- gap-novelmisc-5（部分成立，触发频率被说大了）：每并入一章 / 每次补占位都整本重建，且逐章重复解析快照。修法只做便宜的一半：解析一次并建 url → index 表。不做增量追加。
- 文件：`F/media/novel/web/web_novel_library.dart`。测试：单测。无设备验证。

#### c26 `pr/manga-import-fastpath`（M）
- 依赖：c07 #3693。
- manga-10（部分成立）：重复卷要先完整解压、读完所有页才被判重跳过（重导一个已导过 49 / 50 卷的文件夹，49 个包白解）。成立的入口是导入框批量 / 拖放、操作目录导入、服务端首次撞名；app 的来源库扫描已经在导入前判重，不白解。位置 `EN/media/manga/manga_archive_importer.dart`、`manga_importer.dart`。修法：入口加仅对「跳过」策略生效的共用预检，原判重保留，异常里的 title 保持一致。`ask` 策略顺序不动（所有者定）。
- manga-23（部分成立）：纯图 EPUB 导入解压两遍、多次落盘（暂存目录与数据根同盘时是两次写加一次改名，跨盘才是三次写），且走的 zip 解压器没有 ZIP 分支那套「按实际字节封顶」。修法：EPUB 分支加按实际字节封顶（`native_zip` 的上限做成可选参数）；去掉一次重复解压。
- manga-29a / b / c：压缩包导入的进度条只覆盖最短的入库阶段；mokuro 清单解析三遍；读整页只为探尺寸。修法：进度总量定义成解压 + 入库；`parseMokuro` 带出顶层 root 并直接传已解析 payload；探尺寸改读前缀并留全量回退。
- 文件：`EN/media/manga/manga_archive_importer.dart`、`EN/media/manga/manga_importer.dart`、`EN/epub/book_title_conflict.dart`、`EN/utils/archive/native_zip.dart`、`EN/epub/epub_parser.dart`。
- 测试：导入器单测。验证：真机批量导入一个已导过大半的文件夹看耗时。
- 注意：`native_zip` 被小说导入与同步包共用。c07 把 `sweepImportResidue` 改成了返回 `Future`，调用要 await。c07 没处理的 `_looksLikeImageEpub` 同步探测仍用系统临时目录，可在本组或 c39 一并收。

#### c27 `pr/source-scan-skip-known`（M）
- 依赖：c08 #3707。
- novel-6 + gap-scanner-6（后者部分成立，只做书的一半）：来源库重扫时每本已入库的书都被整本解压、解析、计数，再因重名丢弃；网络来源还先整本下载。位置 `F/media/source_library/source_library_scanner.dart`。修法：书接来源索引（`BookSourceIndex` 存在偏好键里，不用升 schema）；命中仍给出 bookKey 供补挂有声书与配对；本地来源的标题预判复刻「无 dc:title 回退」。
- gap-scanner-3（需先量；自动扫描是每来源开关、默认关，原文前提说重了）：没有任何变化的视频来源重扫并不便宜。修法：先做「一轮一份 `video_books` 快照往下传」并分段计时；指纹跳过看计时结果再定。
- gap-scanner-8：远端漫画每卷都把父目录整棵重新列一遍，而整份清单扫描开始时已经拿到。修法：未入库卷复用已在手的 `entries`，按前缀取、别线性扫。
- 文件：`F/media/source_library/source_library_scanner.dart`、`EN/media/source_library/book_library_prune.dart`、`EV/disc/disc_library_import.dart`、`EV/video_folder_group_coordinator.dart`、`EV/metadata/video_source_metadata_indexer.dart`、`T/media/source_library/source_library_scanner_test.dart`。
- 测试：扫描器单测。验证：100 本以上的本地来源触发重扫，看暂存目录写入量与耗时；有声书补挂不回归。
- 风险：m3u8 重读是 BUG-830 的刻意设计；盘跳过必须同时看库侧状态。

#### c28 `pr/manga-download-control`（M）
- 依赖：c09 #3702。要跑 `gradlew :app:assembleRelease`。
- manga-12：下载的暂停 / 取消传不到在途请求；失败不分型一律退避重试，一串要 Cloudflare 验证或已下架的章节每章白等一轮。位置 `MG/download/manga_download_service.dart`。修法：token 换可完成信号，章节任务接 `adapter.cancelChapterPages`，退避可打断（保留 `_wait` 注入口）；前置条件类错误改专用类型直接 failed，Cloudflare 按类型判。开 bug 文件。
- manga-17a：Android 取图线程池 4 线程，注释按「直读 3 + 下载 1」算，而下载默认页并发是 4。位置 `MihonChannelHandler.kt`、`manga_download_service.dart`。修法：池宽改「直读 3 + 下载并发」并用守卫把两个常量钉在一起。
- manga-27：在线直读与下载各有一套「取页落盘」，命名、上限、扩展名已分叉。修法：抽共用的「字节 → 暂存 → 改名」加扩展名表；下载侧落盘名与目录归属不动。
- 文件：`MG/download/manga_download_service.dart`、`MG/library/online_manga_runtime_adapter.dart`、`F/utils/net/transient_fetch_retry.dart`、`fushi/android/app/src/main/kotlin/app/fushi/reader/mihon/MihonChannelHandler.kt`、`MG/mihon/online_manga_reader_session.dart`。
- 测试：下载服务单测。验证：Android 真机边整章下载边在线读另一章；暂停立即生效。
- 风险：暂停后已落地页续跑的语义不能变。

#### c29 `pr/web-video-builtin-host`（M）
- 依赖：c14 #3694。
- gap-webvideo-8：内置档页的渲染进程死亡后回到起始页，页面状态与重放循环不知情。位置 `PI/web_video_fushi_page.dart`、`MV/web_video_session.dart`。修法：渲染进程死亡后补钩子，并给可捕获档补环境重建入口。开 bug 文件。
- gap-webvideo-4（部分成立）：内置档页里 YouTube 的本机制卡走「排队 + 实时重放」，同页遥控和原生页都是直接裁流。修法：统一分流，保留「直裁失败 → 入队」。
- gap-webvideo-10（部分成立）：live 轨每次变化整轨重投，Dart 侧整份重灌。修法：仅当前轨更新或选轨变化才 `setCues`（不碰 `VPC`）。
- 文件：`PI/web_video_fushi_page.dart`、`MV/web_video_session.dart`、`VF/web_source.part.dart`。
- 测试：单测。验证：桌面杀掉 WebView 渲染进程后继续播；内置档页 YouTube 制卡。
- 顺带：c15 合入后 `web_video_fushi_page.dart` 里两处注释（「缺音频记进行 warning」「看队列行 status / error」）不再准确，在这组订正。

### 第 3 波（12 组，c41 已提前完成）

#### c30 `pr/web-novel-session-continue`（L）
- 依赖：c25。属于新增交互，所有者已按建议放行。
- novel-d6：网页小说末尾的「下一章」占位只在开书时补，读完刚拉回的那一章后要重开书才有下一个占位。位置 `F/media/novel/web/web_novel_library.dart`、`PI/reader_fushi_page.dart`。修法：阅读器开着时续拉下一章占位——要在会话内改 spine，推翻 `web_novel_library.dart` 里写明的回避。
- 测试：库单测 + 阅读器集成测试。验证：真机网页小说读到章末，三种 view mode 各验章末续拉与位置不跳。
- 风险：会话内改 spine 会动章号、字数表、进度前缀和。章末现状没有实测，**先复现再动**。

#### c31 `pr/video-page-load-failures`（M）
- 依赖：c20 #3704、c15 #3706。闸：#3679、#3663（#3644 已合）。
- video-2：`_initVideo` 的未预期异常不进失败态，页面永久转圈，没有原因也没有重试入口。位置 `VFP`。修法：`_init` 统一 catch 置 `_failed` / `_failReason`，不再 rethrow，清在途 controller 标记；`_retryLoad` 同补。
- gap-remote-2：远端换集时，已作废的那一程失败后仍把页面置成失败态；`_applyLoad` 之后还有几处写不看代际。修法：失败态与那几个字段写入前判 seq；换集重新挂首帧自愈监听。（复核里「制卡源串集」那一半标需先量。）
- gap-remote-3：流媒体书的客户端与来源解析器从不关闭，SFTP 来源每开一次片留一条 SSH 连接。修法：只关本页自建的客户端，关闭挂在收尾 future 之后。
- video-11：卡片回看模式下 Jellyfin 转码会话不释放，服务器上的 ffmpeg 空转到超时。位置 `MV/source_review_remote_report_gate.dart`、`F/sync/jellyfin_video_client.dart`。修法：`gate.stop` 的回看分支调一个「只摘会话 + 停转码」的可选能力。
- 文件：`VFP`、`MV/source_review_remote_report_gate.dart`、`F/sync/remote_video_client.dart`、`F/sync/jellyfin_video_client.dart`、`MV/url_stream_video.dart`、`VF/lookup_mining.part.dart`。
- 测试：页面 widget 测试（注入会抛的 repo）+ gate 单测；四条各开 bug 文件。验证：真 Emby docker 回看一段转码内容后看服务器转码会话；远端换集失败页能自愈。

#### c32 `pr/video-controller-handles`（M）
- 闸：#3672、#3679、#3663。直接撞 #3679 在 `VPC` 里的改动行。
- video-6（部分成立）：`_releaseMediaHandles` 之后 `_videoParamsSub` 仍挂在已销毁的旧 Player 上，数据根迁移、删视频、文件名整理后新 Player 的画面参数事件收不到。复核把后果收窄了：每次 load 都会拿当前快照补判一次，多数文件 HDR 输出与杜比视界提示照常生效，失效的只有快照当时还没到（慢源、网络流）和播放中途参数变化两种情况，是时序相关的概率性失效，不是必然。`_audioDeviceSub` 在建 Player 时被直接覆盖赋值，功能不坏，取消它只是整洁项。位置 `VPC`。修法：两条订阅在 `_releaseMediaHandles` 里取消并置空。开 bug 文件。
- video-12（部分成立）：音轨恢复用 200 ms × 20 次轮询，4 秒后静默放弃。「真有超过 4 秒才出音轨的片源（大 REMUX、慢盘）」是推断，复核没找到证据。位置 `VF/audio_track.part.dart`。修法：新增「等目标音轨 id 出现」的事件驱动方法，换片 / 卸载为终止条件。
- video-36a / 36c / 36d：章节逐条读（2N+1 次串行往返）→ 一次读 `chapter-list`（各端是否返回 JSON 要真机确认）；`setVideoBrightness` 无调用方 → 确认不做对应功能后删；`refreshDecodeAfterResume` 用可能陈旧的 position 原地 seek → seek 前读实时 `time-pos`。
- video-36b（部分成立，优先级低）：网络流缓存状态 1 秒轮询，暂停时照跑。暂停时照跑不是纯浪费：mpv 仍在缓冲，HLS 的可 seek 区间快照是给下一次 seek 用的。修法：改事件式观测（不是「暂停即停」，那会让暂停态 seek 拿到陈旧的缓冲段）。
- gap-vidmisc-2：字幕动画 ticker 不看播放态，按屏幕刷新率而不是按时钟变化重建整层。位置 `MV/video_subtitle_overlay.dart`。修法：时钟没变就不 `setState`。
- 文件：`VPC`、`VF/audio_track.part.dart`、`MV/video_subtitle_overlay.dart`。
- 测试：控制器单测。验证：真机慢盘大 REMUX 恢复音轨；数据根迁移后 HDR 提示；暂停时卡拉 OK 字幕不再逐帧重建；章节列表各端核对（video-36a 改成一次读之后）。
- 注意：video-36b 与 gap-vidmisc-2 贴近掉帧方向，开工前先看 #3672 做没做，做了就划掉。c19 留下两件要在这组收（都要动 `VPC` 主文件）：重新选同一条图形轨会把在途抽取杀掉重来；图形字幕判据对象目前挂在 `Expando` 上，应折成普通字段。

#### c33 `pr/video-library-covers-import`（S）
- 依赖：c27。闸：#3672、#3515、#3663。
- video-18 + video-s3-13（都是部分成立）：远端封面 / 剧照按 TMDB 原图全尺寸解码，几张原图就能压满 ImageCache。复核收窄的地方：库页这两处远端图只是回落，本地封面文件存在就不走，命中面是「图片没落到本地」的作品，占比没测；作品详情页则是本地图与远端图都不带解码上限。位置 `HVP`、`PI/video_work_detail_page.dart`。修法：套 `ResizeImage(width: kLocalCoverDecodePixelWidth)`，详情页的本地图同样限解码尺寸；不改 TMDB 尺寸档（默认满分辨率是 BUG-1082 的拍板）、不传 `maxWidth`。
- video-36g：导入 / 扫描路径用同步字幕解析。位置 `EV/video_library_import.dart` 及四个调用点。修法：改异步（engine 里用 `Isolate.run`）。
- 文件：`HVP`、`PI/video_work_detail_page.dart`、`EV/video_library_import.dart`、`F/media/source_library/source_library_scanner.dart`、`MV/video_import_dialog.dart`、`EN/sync/local_library_host_service/videos.part.dart`。
- 测试：widget 测试 + 导入单测。验证：真机看作品详情页剧照内存。

#### c34 `pr/interconnect-transcode-cache`（M）
- 闸：#3663。
- video-34 + video-s2-9（部分成立）：互联实时转码每段现起 ffmpeg，不预取、不缓存，回跳要重转。位置 `EN/sync/fushi_sync_server/video.part.dart`、`EV/live_transcode.dart`。修法分两步：先做小 LRU（键含 token + 段号，`_releaseVideoTicket` 时清）；host 预取下一段放在**量过单段墙钟耗时之后**，且不得占满 3 个并发名额。
- 测试：转码调度单测。验证：互联转码 HLS 装置上回跳不重转；4K HEVC 源记每段耗时对比 6 秒段长。
- 分歧（见第 5 节）：所有者定的是「预取下一段 + 小 LRU」，复核结论是客户端已经在预取、host 再主动预取会占并发名额。量出来没收益的话建议只留 LRU。分段独立编码依赖 `-bf 0`。

#### c35 `pr/subtitle-generation-fixes`（M，i18n）
- 闸：#3663；另 #3670 / #3515 动 `app_model.dart`。
- gap-subpanels-1：改过一次 Jimaku key 后，同一面板里每次搜索都重建整套下载管线运行时。位置 `F/models/app_model.dart`。修法：`AppModel.setJimakuApiKey` 值没变直接返回。
- gap-subpanels-4（部分成立，不卡 UI，只是预估行晚出）：费用预估每次刷新都对没识别过的各集串行跑 ffprobe，`knownDurationsMs` 没有任何调用方传。修法：服务内缓存时长（或复用 `state.json` 的 `durationMs`）。
- gap-subpanels-7（部分成立，第 1 点被推翻）：生成管线装配里的失败处理。修法：登记抛错不连带后面几集；保存看 `_active`。
- gap-subpanels-9（部分成立，窗口很窄）：远端生成的失败 / 取消路径不清临时目录。修法：finally 清临时目录。（「一集失败即终止」与本机管线同口径，不改。）
- gap-subpanels-10（功能缺口，新增交互，已放行）：远端生成不带语言参数，只能出日语。修法：host 加语言能力位，客户端见位才显示语言选择；任务键与「已有字幕跳过」按语言分。老 host 不校验未知参数，所以必须先加能力位。
- 文件：`F/models/app_model.dart`、`MV/subtitle/app_video_subtitle_service.dart`、`MV/subtitle/video_subtitle_glossary_page.dart`、`MV/subtitle/remote_video_subtitle_service.dart`、`EV/subtitle/asr_proofread/video_subtitle_host_job_runner.dart`、`MV/subtitle/remote_video_subtitle_sheet.dart`、`fushi/lib/i18n/*.i18n.json`。
- 测试：服务与 host runner 单测。验证：两台设备互联远端生成，老 host 上不出现语言选择。
- 边界：ASR 算法不在本仓改，只做装配与 UI。

#### c36 `pr/graphic-sub-ocr-resilience`（M，i18n）
- 依赖：c19 #3713。闸：#3663、#3679。
- gap-disc-1：整轨转文字时一条 cue 出错整个任务作废，已识别的文字全部丢掉。位置 `MV/graphic_subtitle_track_ocr.dart`。修法：单条失败不整体作废，加全局终止条件（连续失败达阈值仍整体失败）；失败条不自动重试；一条新文案。开 bug 文件。
- gap-disc-4（成立，收益未测，修法有存储代价）：同一条图形轨有两套抽取（时间表 / 遮蔽抽一遍、整轨转文字再抽一遍）。修法：两边共享在途任务，不保留载荷。
- video-32（成立，量级要实测）：PGS 边抽边识别每 2 秒整文件重读重解码（在后台 isolate，不是掉帧来源，代价是 CPU、IO 与内存峰值）。位置 `EV/bitmap_subtitle/`。修法：做增量会话（记字节偏移与未收尾 display set），沿用 TS 的会话淘汰。
- video-3：自动对轴的结果可能写到换集后的视频上（触发面是原地换集的远端 / 在线源合集）。位置 `VF/subtitle.part.dart`。修法：开始时记 `_episodeLoadSeq` 并校验 controller 与 cues 身份。开 bug 文件。
- 文件：`MV/graphic_subtitle_track_ocr.dart`、`VF/subtitle.part.dart`、`T/media/video/graphic_subtitle_track_ocr_test.dart`、`MV/video_graphic_subtitle_regions.dart`、`MV/video_graphic_subtitle_timing.part.dart`、`EV/bitmap_subtitle/graphic_subtitle_track_extract.dart`、`EV/bitmap_subtitle/pgs_subtitle_parser.dart`、`fushi/lib/i18n/*.i18n.json`。
- 测试：OCR 轨单测 + PGS 增量单测。验证：Windows 真机 2 小时片 PGS 转文字（中途断网一次）；远端合集抽音频中换集。
- 注意：#3663 在 `subtitle.part.dart` 改了 612 行，行号整体下移约 500。

#### c37 `pr/book-delete-cleanup`（M）
- 依赖：c02 #3705、c08 #3707。闸：#3515、#3467、#3534、#3665、#3667、#3668、#3670——**全计划被最多在途 PR 压着的一组**。
- novel-4：书架删书不清自定义封面，同名书重新导入后旧封面复活（只有传了 `appModel` 才清）。位置 `F/media/sources/reader_fushi_source.dart`、`PI/reader_history/books.part.dart`。修法：`deleteBook` 的 `appModel` 改必填，7 个调用点补齐。开 bug 文件，**先复现一次**。
- novel-7 + novel-d1：每删一本书跑一次整库 `VACUUM` 加 `wal_checkpoint(TRUNCATE)`，批删串行 N 次。修法：`deleteBook` 加「本次不回收」开关，批量调用方循环结束后在 finally 里回收一次；单删行为不变；两份测试的 VACUUM 断言同步。
- novel-17a：「同步删除」的墓碑写入失败被吞、无日志。修法：补 `ErrorLogService` 日志，不翻转删除结果。
- 文件：`F/media/sources/reader_fushi_source.dart`、`PI/reader_history/books.part.dart`、`PI/reader_fushi_history_page.dart`、`MG/library/manga_series_page.dart`、`F/media/kavita/kavita_book_service.dart`、`F/media/novel/online/lnreader_novel_detail_page.dart`、`F/ops/ctl_library_routes.dart`、`F/settings/storage_usage_actions.dart`、`T/media/sources/reader_fushi_source_test.dart`、`T/media/sources/reader_fushi_cover_cache_test.dart`。
- 验证：真机批删 20 本看耗时与磁盘回收；删书后同名重导看封面。
- 注意：#3515 在同一函数加了 `reclaimUnreferencedFiles()`。

#### c38 `pr/manga-reader-hotpath`（M）
- 依赖：c12 #3701。闸：#3670（纯增量，愿意承担合并冲突的话这组可以提前，见第 5.2 节）。
- manga-6：页图降采样队列里，不需要缩的页也排队起 isolate，且是 FIFO、没有可见页优先。位置 `MG/reader/manga_page_fit.dart`、`MG/manga_overlay_html.dart`。修法：入队前在 Dart 侧头探测判「不缩」；队列让当前跨页插队，不丢弃。
- manga-14：捏合 / Ctrl 滚轮缩放每一步都 `setState` 整个阅读页，而 release 下没有消费者。修法：缩放 handler 直接赋值，仅 `kDebugMode` 下 `setState`。
- manga-21：分镜导航的检测懒到按下翻页键才做。修法：检测到页预热，限开关开且非条漫，复用 `_panelGeneration`。
- manga-22（部分成立，请求数没测）：`resize` 不节流。复核收窄后剩下的是：拖窗口跨过多个 128 px 档时，已加载的页每档排一次整张转码，旧档请求不丢弃；只在开了按显示尺寸降采样的本地卷 / 已下载章上发生，高分辨率卷才明显。修法：改走已有的 200 ms `_scheduleRefit`。
- manga-30：阅读器里几处注释与代码不符，订正。
- gap-mangamisc-7（部分成立）：分镜检测的失败结果被两层缓存，检测器创建没有在途去重。修法：只对抛错不缓存；`_ensurePanelDetector` 存在途 Future。
- 文件：`MG/reader/manga_fushi_page.dart`、`MG/manga_overlay_html.dart`、`MG/reader/manga_page_fit.dart`、`T/media/manga/manga_page_fit_test.dart`、`EN/media/manga/panel_detection.dart`。
- 测试：fit 单测 + 分镜单测。验证：Android 真机 4K 页图卷跳页、捏合 profile；桌面拖窗口看 `fit=` 请求数。
- 风险：fit 串行是 BUG-4704 的刻意设计。c10 留下的一件可在这组收：`manga_fushi_page.dart` 里同名的 `parseMangaJsonOffUi` 静态方法没有转调新的顶层函数。

#### c39 `pr/manga-import-dialog-async`（M）
- 依赖：c26。闸：#3515。
- manga-3：`.epub` 定性在 UI isolate 上同步整本解压，批量导入每本解两遍以上，选中一本几百 MB 的 EPUB 界面直接停住。位置 `MG/manga_import_dialog.dart`、`F/media/import/import_carrier.dart`。修法：批量路径 `.epub` 不预定性、交导入阶段判；单选定性改异步并过 memo 守卫。
- 文件：`MG/manga_import_dialog.dart`、`F/media/import/import_carrier.dart`、`MG/import/manga_folder_batch.dart`、`EN/media/manga/manga_archive_importer.dart`。
- 测试：守卫 + 批量单测。验证：桌面把 300 MB 以上的文字 EPUB 选进漫画导入框，界面不停住。
- 顺带收 c26 遗留：`_looksLikeImageEpub` 定性探测仍把 container / OPF / spine 文档解进系统临时目录（c26 后页图已不落盘，只剩几 KB，finally 删除）；定性改异步时一并改成书库根下的 `.tmp-*`（要给探测接口带 db），见 BUG-5013 备注。

#### c40 `pr/novel-heavy-work-off-ui`（M）
- 依赖：c01 #3699、c04 #3698。闸：#3515。
- novel-14：三处重活在 UI isolate 上——TXT 转 EPUB 全同步；LNReader 连载更新同步逐章逐图读盘并整本重打包；书内搜索首搜在主 isolate 取每章 HTML 且随后驻留内存。修法：TXT 转 EPUB 用 `Isolate.run`；连载更新搬进 isolate；书内搜索换显式章内容版本号并让 isolate 按路径自读。
- 文件：`EN/media/audiobook/text_to_epub.dart`、`F/media/audiobook/book_import_dialog.dart`、`F/media/novel/online/lnreader_online_book.dart`、`F/media/audiobook/audiobook_bridge.dart`、`EN/epub/epub_book.dart`。
- 测试：单测。验证：几 MB 的 TXT 导入与几百章带图连载更新时界面不卡；书内搜索结果与改前一致。
- 风险：`chapterPlainText` 的文本内容不能变（有声书对齐与统计水位建在它上面）。
- 顺带（都落在 `lnreader_online_book.dart`，c01 / c02 留下的）：state 读失败时报的是「插件缺失」而不是读盘错误；原子写改名失败后删临时文件再抛会盖掉原始异常。

#### c42 `pr/plex-auto-route`（M）
- 依赖：c20 #3704。闸：#3534。
- gap-remote-7（现状成立，属行为改变，只做第一步）：Plex 连接地址只在登录时取一次，播放期不会自动换线路。位置 `F/sync/plex_video_client.dart`。修法：失败后在已存地址里自动探测并切换，核对 machineIdentifier，切换点在建客户端之前，写回后失效清单缓存。不存账号 token。
- 文件：`F/sync/plex_video_client.dart`、`MV/media_server/media_server_library.dart`、`PI/home_page.dart`、`F/sync/plex_settings_widget.dart`。
- 测试：单测。验证：Plex 局域网 / 外网切换各一次。

### 第 4 波（7 组）

#### c43 `pr/manga-reader-settings-session`（M）
- 依赖：c38、c28。
- manga-13：阅读器任何一项设置变更都整份重载窗口文档（含整卷 DOM），改常亮、音量键这类不进文档的项也重取页图。位置 `MG/reader/manga_fushi_page.dart`。修法：文档输入收成值对象或取文档串哈希比较，相同跳过 `loadData`；「纯 CSS 项直接推 JS」不做。
- manga-19：阅读器偏好有两套状态（`_readerPreferences` 加约 20 个镜像字段）。修法：删 12 个死镜像，有读者的改读 `_readerPreferences`；统一 `_tapZonePaging` 口径；函数签名先保留。
- manga-18a：桌面 sidecar 一重启（装 / 更新 / 卸任何扩展都会重启），正在读的在线章剩下的页全部失败，只能退出重进。位置 `MG/mihon/online_manga_reader_session.dart`。修法：重启后重解析页表，只换取页引用不换身份串，页数不一致按失败。开 bug 文件。
- gap-mangamisc-5：阅读器里的章节抽屉开之前先对全部章判一遍「是否已下载」（扫盘成本只落在已下载的章，未下载章一查即返回），列表不是懒建。位置 `MG/reader/manga_chapter_drawer.dart`。修法：改 sliver，定位换 `scrollToMangaChapter`，进场动效保留。
- 文件：`MG/reader/manga_fushi_page.dart`、`MG/manga_overlay_html.dart`、`MG/reader/manga_chapter_drawer.dart`、`MG/mihon/online_manga_reader_session.dart`、`MG/library/online_manga_runtime_adapter.dart`。
- 测试：单测 + widget 测试。验证：真机改各类设置（进文档 / 不进文档），iOS / macOS 看闪烁；桌面读在线章时装一个扩展。

#### c44 `pr/mining-extract-parallel`（M）
- 依赖：c15 #3706、c35。闸：#3679。
- video-30（部分成立）：制卡全进程一条串行队列，一张断流的远端卡会挡住后面所有卡。队列不只是因为临时文件名写死：它是 BUG-1228 按用户要求建的，同时管临时文件争用、AnkiConnect 单端点、换集后旧卡被新集数据污染三件事。位置 `F/mining/immersion_mining_engine.dart`、`F/mining/serial_job_queue.dart`。修法：抽取每任务独立目录并有界并发，落卡保持 FIFO 且按入队顺序提交；重写钉着「第二张不得启动」的测试。
- 文件：`F/mining/immersion_mining_engine.dart`、`F/mining/serial_job_queue.dart`、`F/models/app_model.dart`、`F/media/favorites/favorite_batch_mining_runner.dart`、`F/mining/video_mine_queue.dart`、`T/mining/immersion_mining_queue_test.dart`。
- 验证：桌面连点三张卡，其中一张远端断流，后两张不被挡。
- 风险：队列是 BUG-1228 按用户要求建的，落卡顺序不能乱；若要改 `desktop_audio_clipper.dart` 会撞 #3679。

#### c45 `pr/video-open-io-series-speed`（M）
- 依赖：c31、c36、c16 #3697。
- video-5：打开合集里的一集，首帧前有 N+1 串行查询（24 集多约 50 次往返）。位置 `VFP`。修法：用 `getByBookUids` + 新增批量 scrape meta 查询 + `Future.wait`，不后置。
- video-20（部分成立）：本地开播的串行 IO 链里有重复读和同步 IO。复核收窄的地方：`loadCues` 整表读后被外挂档覆盖不是纯白读——外挂档重解析为空时它是 BUG-1848 的回退，只有「字幕显式关闭」的分支才是读了就丢；视频文件的两次 stat 都是异步 `exists()`，同步 IO 只在着色器 / Lua 目录；对齐产物判定会把刚读过的字幕文件整份再读一遍算哈希。修法：`loadCues` 改惰性（重解析成功才不读，回退语义保留）；对齐判定并行并复用已读字节；Lua / 着色器目录改异步。
- video-s2-2：倍速记忆本地每集一份、远端原地换集沿用，两边不一致。修法：新增系列键，读时回退旧每集键（照 `videoVolumeReadKeys` 的做法；旧键冻结不改）。
- gap-scanner-4（成立，有修正）：首次扫描逐条提交，每条都让订阅方重查整张 `video_books`。修法：`watchVideoBookUids` 只选 `book_uid` 并合并在途重查。**仅在 #3672 合入且确认它没做这处时才做。**
- 文件：`VFP`、`EV/video_book_repository.dart`、`CORE/database_video_domain.part.dart`、`VF/subtitle.part.dart`、`EV/subtitle/subtitle_alignment_backup.dart`、`MV/video_lua_script_manager.dart`、`MV/video_shader_manager.dart`、`VF/speed.part.dart`。
- 验证：真机开 24 集合集的一集计时；网络盘片子冷开；本地 / 远端合集换集后倍速沿用。

#### c46 `pr/video-controller-mpv-batch`（M）
- 依赖：c32。
- video-4：制卡截帧占着播放器串行锁，「制卡后立刻续播」要排在它后面。位置 `ci/patches/hosted/media_kit-1.2.6/lib/src/player/native/player/real.dart`。修法：在 media_kit 补丁里只让取原始帧持锁、编码在锁外；守卫测试同步。
- video-36m：mpv 属性批量下发 helper 有五份，mpv 拒绝写入没有痕迹。修法：五份合一，逐条 await，拒绝写入留痕。
- video-19（部分成立，需先量）：开播时 `open` 与 `play()` 之间串行等几十次 mpv 属性往返。修法：先给 `load` 各阶段打点并看 mpv 日志有无解码器重建；有收益再把与片源无关的配置整组前移到 open 前（仍串行）。
- 文件：上述补丁文件与 `PATCHES.md`、`VPC`、`MV/video_mpv_config.dart`、`T/media/video/video_mpv_ui_thread_native_calls_guard_test.dart`。
- 验证：真机 1080p / 4K 各测「点制卡 → play() 生效」，并确认截到的是查词那一帧。
- 风险：`volume-max` 先于 `volume`、rawConf 最后，libmpv 异步不保序。video-19 贴近掉帧方向，先看 #3672。

#### c47 `pr/remote-stream-timeouts-resume`（M）
- 依赖：c31、c33、c17 #3703、c42。闸：#3663。
- video-8：远端起播的默认字幕下载挡在开流之前且没有读超时，第三方字幕站不回数据时页面永远停在「正在下载字幕」。位置 `MV/online/anime_source_video_client.dart`、`F/sync/jellyfin_video_client.dart`。修法：在线源 get 加超时；Jellyfin `downloadToFile` 只加空闲超时。不并行化（所有者定）。开 bug 文件。
- video-15：在线源客户端只有一个「当前流」槽位，下载中心里两集并发时先下完的那集字幕静默丢失。修法：按集 id 存候选，保留一个「最近一次」槽给不带 id 的 `httpHeaderFields`。开 bug 文件。
- video-26：媒体服务器整片下载不能续传、无空闲超时。修法：Jellyfin / Plex 整片下载改走 `ResumableDownloader`，断点键用条目 id，侧车与日志不落 URL；转码流不续传。
- gap-remote-10：YouTube 起播时拿到的 manifest 用完即丢，点开画质菜单要重新取一遍。修法：先做内存版（各档列表挂在本次起播的客户端上）。
- 文件：`MV/online/anime_source_video_client.dart`、`F/sync/jellyfin_video_client.dart`、`MV/url_stream_video.dart`、`EV/youtube_source_resolver.dart`、`MV/stream_video_launch.dart`、`VF/quality.part.dart`、`EN/media/video/media_server/plex/plex_api.dart`、`F/sync/plex_video_client.dart`、`HVP`。
- 验证：真 Emby docker 下载几个 GB 的片暂停再继续；兼容层不支持 Range 时的回落。
- 顺带：c17 明确留给这组的两处——直链字幕（`url_stream_video.dart`）与 Plex `downloadToFile` 的超时。

#### c48 `pr/shelf-audiobook-links`（M）
- 依赖：c37、c13 #3709、c03 #3711、c04 #3698。闸同 c37。
- gap-novelmisc-1：书架「重新定位音频」只写 SrtBooks 一侧，EPUB 有声书的 `audiobooks` 行仍是坏路径。后果两种：旧路径全断时进度归零、字幕不跟；部分还在时文件列表缺项、cue 错位。位置 `PI/reader_history/books.part.dart`。修法：仓库层加窄入口，同一事务只改两行的 `audioPaths`，文件数不等时拒绝。（不能直接套 `replaceAudio`，那会按「音频变了」判进度去留。）
- gap-novelmisc-2（部分成立，耗时未测）：SRT 卡 build 期同步探外部音频路径，同一批路径每次书架刷新被探多轮。修法：断链状态随 `srtBooksProvider` 异步算一次按 uid 缓存，`hasMissingPaths` 改短路。
- gap-novelmisc-6（部分成立）：互联下载编排的断点回填复制了三份。修法：只收成一个函数（「寄生在页面 State 上」是有文档的刻意设计，不动）。
- gap-novelmisc-7（部分成立，8 小项里第 8 项被推翻）：只做批删兜底、歌词加载错误收口、行映射复用。
- novel-15：BUG-509（已结）的修复不完整，句间静音里悬浮字幕不会提前切到下一句。位置 `F/media/audiobook/audiobook_controller.dart`、`audiobook_session.dart`。修法：控制器每 tick 记显示句身份，变了才发只给显示面的信号；关联 BUG-509 新开一条。
- 文件：`PI/reader_history/books.part.dart`、`PI/reader_fushi_history_page.dart`、`PI/reader_history/remote.part.dart`、`AU/audiobook/audiobook_repository.dart`、`AU/audiobook/srt_book_repository.dart`、`AU/audiobook/audiobook_storage.dart`、`RF/lyrics.part.dart`、`RF/chrome.part.dart`、`F/media/audiobook/audiobook_session_launcher.dart`、`F/media/audiobook/audiobook_controller.dart`、`F/media/audiobook/audiobook_session.dart`、`F/media/audiobook/now_listening_mini_bar.dart`。
- 验证：真机重新定位断链音频后播放进度不归零；句间有静音的有声书看悬浮字幕提前切句。
- 顺带：c04 没修的第四处裸调 `AudiobookBridge.highlight`（`RF/lyrics.part.dart`，退出歌词模式后的显式 reveal）在这组收。

#### c49 `pr/shelf-slim-read`（M，可能升 schema）
- 依赖：c37。闸经 c37 继承（#3515、#3467、#3534、漫画有声四件），要改的也是同一批书架文件。
- novel-9（部分成立，需先量）：书架主路径与归组器各整表读一次 `EpubBooks` 全列，书架主路径还在 UI isolate 上逐本解码 `chaptersJson` 只为取字数。「每次刷新读两遍」不成立：两次整表读的触发器不同，关书、阅读位置变化只触发前一次，导入、删书时两次才叠加。位置 `F/media/sources/reader_fushi_source.dart`、`EN/media/collections/book_series_grouper.dart`。步骤：**先量 300 本库的一次刷新耗时**；再把书架主路径改瘦投影（首选在 SQLite 侧用 `json_each` 抽每章字数）；归组器加带 `sourceMetadata` 的投影；`resolveCaseInsensitive` 一次调用内复用目录列表。封面负向缓存不做。
- video-36i（部分成立，实际代价很小）：新装库缺统计索引（`idx_study_segments_profile_date` 只在一处迁移里建，同一处的 `idx_galgame_sessions_profile_date` 同病）。表是千行量级。修法：两个统计索引加进 `_ensureIndexes`；若本组因 JSON1 不可用而落列升 schema，就顺带给存量库补索引。
- 文件：`F/media/sources/reader_fushi_source.dart`、`CORE/database_content_misc.part.dart`、`packages/fushi_core/lib/src/database/epub_book_meta.dart`、`EN/media/collections/book_series_grouper.dart`、`PI/reader_history/card_widgets.part.dart`、`CORE/database_infra.part.dart`。
- **升不升 schema 没定**：取决于随包 SQLite 带不带 JSON1。`packages/fushi_core/lib` 里目前没有任何 `json_each` / `json_extract` 用法，没人验证过。带就不升；不带才落列并升版本，那时要照升级清单改 25 处以上硬编码版本号的测试。
- 验证：Android 真机 100 本无封面书滚动看帧。

### 第 5 波（3 组）

#### c50 `pr/manga-series-entry-state`（M）
- 依赖：c43、c37、c28、c49、c12 #3701。闸经 c37 继承（同 c49），`MG/library/manga_series_page.dart` 在那套闸的文件里。
- manga-4：「是否已下载」判据很重（主 isolate 解析整份 `manga.json` 再逐页同步 stat），却被开章、预下载、每页下载事件、作品页全书扫描反复调用。位置 `EN/media/manga/manga_chapter_storage.dart`、`MG/library/manga_series_page.dart`。修法：作品页缓存每章结论、只重判状态变了的章、加重入守卫；开章把判据解析出的 payload 交给装载；下载进度写库节流（不改成只放内存，所有者定）。
- gap-mangamisc-1：在线作品描述符整份读-改-写，几个写方各拿各的快照互相回滚（进页几秒内点订阅被刷新回滚最容易撞到）；复核另发现按下标传章会开错章。修法：三个写方改事务内重读只改字段；`selectChapter` 按 chapterKey，阅读器用返回值重算下标。不动小说侧三个调用点。开 bug 文件。
- gap-mangamisc-2 + gap-mangamisc-3（后者需先量）：Kavita 对账 / 批量标已读后「继续阅读」落到已读过的旧章；同步基线每查一章整份解码偏好 JSON。修法：库里加批量写口（一次事务、同一时间戳；不能把 updatedAt 置 0）。开 bug 文件。
- gap-mangamisc-4：作品页每次 build 都做「排队数 × 章数」次 sha256 和路径规范化。修法：entry / bookDir 变时建一次目录 → key map，保留 `p.equals` 语义。
- 文件：`MG/library/manga_series_page.dart`、`EN/media/manga/manga_chapter_storage.dart`、`MG/reader/manga_fushi_page.dart`、`MG/download/manga_download_service.dart`、`CORE/database_content_misc.part.dart`、`MG/library/online_manga_library_service.dart`、`F/updates/update_probes.dart`、`F/media/kavita/kavita_manga_sync.dart`。
- 验证：真机已下载 100 章以上的书开着作品页再下一章看帧；进页几秒内点订阅不被回滚；Kavita 续读落在最新章。

#### c51 `pr/video-page-rebuild-trims`（S）
- 依赖：c45。
- video-25（部分成立）：每查一个词都把全部收藏句 JSON 读出并解析（不阻塞弹窗，代价随收藏总量增长，没测）；收藏状态存两份——弹窗星标读库、字幕条星标读内存镜像。「互不通知」不成立：页内两份互相维护，漏的只有页外来源（收藏夹页、同步合并）改动后镜像不刷新。修法：弹窗星标改读内存镜像，镜像填完补刷当前句；取消收藏时那一次全量读留着。
- video-36e：「换集保持全屏」逐帧重试最多 30 次。修法：在 `_videoControlsContext` 赋值点直接触发。
- video-36f：字幕样式滑条每个采样整页 `setState`。修法：改 `ValueNotifier`（28 处读点）。
- 文件：`VFP`、`VF/lookup_favorite.part.dart`、`VF/fullscreen.part.dart`、`MV/video_settings_actions.dart`。36f 还要动 4 个 `VF/*.part.dart`，具体是哪 4 个没定位——开工时先 grep 定下来并核对没有别的组在改。
- 验证：真机拖字幕样式滑条看帧；换集保持全屏。

#### c52 `pr/srt-serialization-dedupe`（S）
- 依赖：c13 #3709、c36、c45。
- video-36o：SRT 序列化有五份。修法：时间戳格式化与块拼接收成一份，cue 类型与清洗各留各的。
- 文件：`EV/video_clip_subtitle.dart`、`EN/media/audiobook/audiobook_alignment_service.dart`、`MV/graphic_subtitle_track_ocr.dart`、`MV/video_lua_script_manager.dart`、`EV/subtitle/bilingual_subtitle_split.dart`。
- 纯清理，单测覆盖，无设备验证。

### 第 6～7 波：测量组（第一步都是实测，测出问题才改）

「达到什么数才做」：复核只给了下面写出来的四个门槛（gap-readerjs1-3、gap-remote-11、gap-disc-5、gap-vidmisc-10）；没写的条目材料里没有数值门槛，量之前要先和所有者定一个。「单次操作超过一帧预算、或在目标场景里用户可感知」是本文给的建议口径，不是复核结论。规模是改动步骤的估计，只量不改的话更小。

#### m1 `pr/measure-reader-engine`（第 6 波，M）
- 改动步骤依赖：c24、c06 #3712、c30、c48。
- novel-17e（原清单只有一句，没有单独的复核段）：`_chapterIndexForFilePath` 对每章做两次 `canonicalize`。量：上千章网文开书 / 换章时这一段的耗时。成立就开书时建路径 → 章号表。
- novel-20：进度采样时对整个阅读器页面 `setState`（节流 50 ms，实际上限低于 20 次 / 秒）。量：连续模式长章快速拖动的 build 次数与帧耗时。成立再给 `ReaderProgressState` 加 `Listenable`。
- gap-readerjs1-3 + gap-readerjs2-9：分页 shell 没有章内文本索引，开一章全章 walk 多遍；连续 shell 有三套章内偏移计算。量：10 万字单章章末一次 `fushiProgressDetails`、同章插图页上一次、6000 文本节点章的开章 `offsetsBuilt → restoreDone`。**单次低于几毫秒就只做「扫描兜底改二分」这一小块**；成立再做带 MutationObserver 判脏的共享文本索引。c05 留下的「`countCharsBeforeViewport` / `isTextOffsetBeforeViewport` 分页与连续两版合并」「一次进度采样 5 次 `getScrollContext`」并入这里。
- gap-readerjs1-5：有声书 cue 在位置恢复之前同步应用（逐字符建反查表，再把全章每句包成 span）。量：用现成的 `[chapter-perf]` 测 2000 句以上的章 `offsetsBuilt → restoreDone`。占比大就只改反查表数据结构（按节点分段的区间数组加二分），**顺序不动**。
- gap-readerjs2-2 / -5 / -7：键盘 / 手柄光标每按一次键对整章逐字量几何；VN 每句 / 每屏对整章 cue 和屏表线性扫描；VN 开章固定开销。量 VN 与光标脚本各段耗时。（弹窗侧的同类写法是有意设计，不放行。）
- gap-readerjs2-8：VN 的有声书句子定位没接共享段的「按原文在实时 DOM 重定位」。做法：VN 与共享段 cue 定位对拍；有差异再报所有者立项（结构项，L）。
- 顺带补量（第一波欠的）：c04 的 `[chapter-perf]` `sentenceAudioCues` / `audiobookBridge` 两段改动前后对比；c06 的同一插图章分页 vs VN 恢复时间。
- 装置：真机 + `ReaderChapterPerfTrace.enabled` 的 `[chapter-perf]` 日志；三种 view mode 各量。
- 成立才改的文件：`F/reader/reader_pagination_scripts.dart`、`F/reader/reader_visual_novel_scripts.dart`、`F/reader/reader_caret_scripts.dart`、`RF/webview.part.dart`、`RF/navigation.part.dart`、`F/reader/reader_progress_state.dart`、`PI/reader_fushi_page.dart`、`RF/chrome.part.dart`。

#### m2 `pr/measure-manga-runtime`（第 6 波，M）
- 改动步骤依赖：c50、c28、c09 #3702、c33。
- manga-17b：搜索、详情、页表、解题共用 2 线程。量：Android 真机全局搜索时原生池的排队时间。
- manga-20：窗口就绪后 7～9 次串行 `evaluateJavascript` 才放开翻页锁。量：`onLoadStop` 到 `_windowGate.complete` 的耗时。
- manga-28：桌面每次调 sidecar 都把整个 APK 的 base64 放进请求体。量：请求体编码与服务端解码在一次调用里的占比。**只量不改**（真改见第 5 节）。
- manga-s3-5（部分成立）：强杀 app 后 sidecar 的 JVM 是否残留。做法：`ssh mac` 上强杀 app 看 java 进程。
- gap-scanner-5：列目录与归类能否整体搬出 UI isolate。量：列目录与 `statSync` 耗时；iOS 书签在新 isolate 是否有效。
- 成立才改的文件：`MihonChannelHandler.kt`、`MG/reader/manga_fushi_page.dart`、`F/utils/misc/child_process_containment.dart`、`MG/mihon/desktop_mihon_runtime.dart`、`F/media/source_library/source_library_scanner.dart`、`F/media/source_library/source_file_system.dart`、`EN/media/source_library/book_library_prune.dart`。

#### m3 `pr/measure-video-library`（第 6 波，M）
- 改动步骤依赖：c47、c51、c23 #3714。
- video-16：库页每次刷新整表读 16 张表并全量重算，刮削进度写也会触发（这是「已经管过一轮后的剩余量」）。量：3000 行库批量刮削期间每轮刷新耗时。复核另指出一处确定的不一致：批次中的刷新是作废式的，若单轮慢于 2 秒，批次期间映射可能一直不更新。先和 #3672 对「被盖住时是否该挡」。
- video-27：库页任意 `setState` 都对整库重新过滤、折叠、排序。量：3000 条目下框选、搜索的 build。
- video-23：字幕列表每次布局对全部行拼缓存键、查收藏。量：1 万行字幕跟随播放时的 `performLayout`（普通剧集几百条时可忽略）。
- gap-subpanels-8：面板 build 里的重复派生。量：profile 下用文件最多的 Jimaku 条目量 build。
- gap-remote-11：媒体服务器 / 互联清单的大响应在主 isolate 上解码。量：500 条一页的真实响应在中端 Android 上 `jsonDecode` + `parseItemsPage` 的耗时与整库枚举期间掉帧。**超过一帧预算再做**，做的话解码与投影一起进后台 isolate。
- gap-remote-4（部分成立，只对互联成立）：首帧前开播位置与取流互不依赖却串行。量：host 离线时的起播等待。
- 成立才改的文件：`HVP`、`CORE/database_video_domain.part.dart`、`MV/video_subtitle_jump_panel.dart`、`PI/subtitle_search_panel.dart`、`PI/subtitle_collection_panel.dart`、`F/sync/jellyfin_video_client.dart`、`F/sync/interconnect_sync_backend.dart`、`VFP`。

#### m4 `pr/measure-video-media`（第 6 波，M）
- 改动步骤依赖：c44、c17 #3703、c21 #3708、c29、c46。
- video-31：HDR 片源制卡没有色调映射（播放侧有）。做法：HDR10 / HLG 样片各制一张卡与播放画面对比，并确认 mpv 截帧是否已映射。注意随包 ffmpeg 只有 Windows 构建带 zscale / libplacebo，`zscale + tonemap` 在 Android / iOS / macOS 上不可用。
- video-33：在线源 HLS 下载逐片串行。量：同一集串行对 3 并发。
- gap-disc-5：暂停 OCR 每帧走「编 PNG → 落盘 → 再读盘解码」。量：分段计时（截帧 / 编码 / 落盘 / 识别）。**PNG 编码 + 解码占比明显（比如超过 30%）再立项**（修法是 L 级的跨引擎接口改动）。
- gap-vidmisc-6：SRS 卡面片段每张卡新建一个 libmpv 播放器。量：Windows 连翻 200 张卡的 RSS 与首帧。
- gap-vidmisc-10：ffmpeg-kit 每行日志都经事件通道送到 UI isolate。量：长会话里 UI isolate 收到的日志事件数；**每秒只有几条就不做**。要做则用 `disableLogs()`，并先在真机验证 `getOutput` 与字幕流探测仍有内容（原清单的修法无效）。
- gap-webvideo-9（部分成立）：播放态快照每 250 ms 全量投递（「每拍整页重建」不成立）。量：4 Hz 快照与 nftt 双解析的开销。
- 成立才改的文件：`EN/utils/misc/desktop_audio_clipper.dart`、`F/mining/immersion_mining_engine.dart`、`MV/online/anime_episode_downloader.dart`、`MV/graphic_subtitle_ocr.dart`、`PI/srs/srs_card_video_clip.dart`、`MV/ffmpeg_kit_backend.dart`、`fushi/assets/web_video/web_video_glue.js`、`MV/web_video_bridge.dart`。

#### m5 `pr/measure-stat-facts`（第 7 波，S）
- 依赖：m1、m2、m3 有结论。
- gap-vidmisc-5 + gap-mangamisc-8：统计事实只有「全域全量」一个读口，统计中心每切一次页签、播放页 / 阅读器统计侧栏每开一次都读一遍。做法：造大库量切页签与侧栏耗时；成立再给 `loadStatFacts` 加按域 / 按书参数——单一读口不变，SQL 过滤要与 `statFactBelongsToBook` 同口径（bookKey，旧行回退 title），否则旧数据累计会少。`then` 补 `onError` 这一小项可直接做。
- 成立才改的文件：`EN/stats/stat_facts.dart`、`PI/video_statistics_page.dart`、`PI/statistics_center_page.dart`、`VF/study_stats.part.dart`、`F/reader/reader_statistics_sheet.dart`、`MG/reader/manga_fushi_page.dart`、`RF/chrome.part.dart`。
- 风险：#3672 正在动首页统计重载，改签名前先对。

---

## 3. 第一波做的过程中发现、但没处理的遗留

每条写：是什么、当时为什么没做、建议归到哪里。已经在第 2 节各组「顺带」里点过的不重复展开，只列出处。

### 小说 / 阅读器

| 出处 | 遗留 | 没做的原因 | 建议归属 |
|---|---|---|---|
| c01 | 字数口径升级后首次开在线书时，已预取但阅读器还没请求到的章，重算仍可能把书行里那一章写回占位页字数，之后不会自动更正 | 既有窗口，超出本组 | c40（同文件）或新开 bug |
| c01 | novel-10 的前台让位只在「连跳三次以上」才生效 | 实现与计划一致；让预取延后启动或可中止是另一种取舍 | 待拍板（第 5 节） |
| c02 | 旧目录阶段作品页头部没有简介 / 作者，源站回来后章节列表下移，可能误点 | 两种修法一个改持久化形态、一个改 UI | 待拍板（第 5 节） |
| c02 | 读盘失败时扩展页 / 已装源列表没有「读取失败」提示 | 要新文案，且两个 section 文件被别的分支占着 | 新开小组（i18n） |
| c02 | 阅读器里提示丢图数量、已丢图章节自动重取 | UI / 行为改变 | 待拍板（第 5 节） |
| c03 | 追踪去重只对「能报的站点都已入队」的书生效；阅读器开着时新配置站点，当前章进度要到完成章数变化才报 | 已知局限，不在返回键等待链上 | 暂不处理，记在案 |
| c03 | novel-16 的「连点两词」「抽图期间点词」只有源码守卫，没有能跑出竞态的测试 | 要真 WebView + 可控慢查词 | 真机验证时补 |
| c04 | `RF/lyrics.part.dart` 里第四处裸调高亮 | 文件被三个歌词相关 claim 占着 | c48 |
| c04、c06 | 计划要求的「先量」没做（`[chapter-perf]` 两段；分页 vs VN 恢复时间） | 要先编 Windows 包 | m1 |
| c05 | 两版视口前字数函数的合并；一次采样 5 次 `getScrollContext` | 复核认定属章内文本索引那一条 / 等实测 | m1 |
| c05 | 不经锚的位置写入者（样式 / 几何重锚 commit）在揭示帧前改了位置时，帧回调仍按揭示目标重落 | 与旧实现一致 | 暂不处理，记在案 |
| c05 | 竖排 progress 0.9 的落点在度量缓存作废后第一次与之后几次不一致（改动前后都有） | 是入口 `scrollToProgressPaged` 自己的事 | 新开 bug 调查 |
| c05、c06 | 测试跑手的同类 Sonar 问题：`T/reader/*_behavior_test.js` 里另有 6 份与新装置逐字相同的 payload 读取 + `objectLiteral`；develop 上 `T/reader` 下 30 多个既有装置共 70 条同规则命中。两组各自新建了支持模块（`paged_shell_behavior_support.js`、`vn_shell_harness_support.mjs`），互不依赖 | 既有跑手不在各组范围，部分被别的 claim 占着 | 单开一个跨组小 PR：把既有跑手迁到支持模块并把两个模块并成一个；Sonar 网页端要不要把 `fushi/test/**` 标成测试源需要项目管理员定 |
| c06 | gap-readerjs2-10 的余项：`isStandaloneImageNode` 用 computedDisplay（计划写明另开 bug）、无缝样式表按 href 缓存、`containsStandaloneMedia` 回退分支 | 计划外 / 收益未测 | 新开 bug（第一项）；其余并 m1 |
| c06 | fetch 失败的样式表在无缝挂载的邻章里缺失 | 改成原生 `<link>` 会异步加载、视口再跳一次，注释写明正因此不用 | 已知代价，真机看外观 |
| c07 | 残留清扫没挂到 app 启动，只在下一次导入 / 打开孤儿书找回时跑。后果：崩溃残留多留一阵；Android 就地重建走拷贝回退期间被杀时用户会先读到半本书 | 接线只能落在 `F/models/app_model.dart`，被多条在途 claim 占着 | 需协调方指定由谁加（`AppModel.initialise` 开库后调一次 `EpubStorage.ensureImportResidueSwept`） |
| c07 | `F/pdf/pdf_importer.dart` 仍是「目录存在即复用 + 失败无条件删」，PDF 入口并发撞同名的窗口还在 | 不在文件表 | 新开小组或并 c26 |
| c07 | 清扫进行中被登记成书的 `x.bak-<13 位数字>` 无主目录仍会按备份处置（很窄） | 删除改异步后新增的窗口 | 暂不处理，记在案 |
| c13 | 应用内 EPUB 有声书换音频对话框（`audiobook_import_dialog.dart`）与 TTS runner（`tts_render_runner.dart`）仍不带 commit，旧音频在各自写库前就删了 | 范围外；TTS runner 另有在途 PR | **需要跟进**：等那两个在途 PR 落地后单开，或并 c48 |
| c13 | 换字幕「正文已重建、随后写库失败」没有回滚；被杀进程的残留只在这本书下一次同步时收拾；「写库已提交」与「落已提交标记」之间被杀时下次同步会把旧文件挪回原名 | 窗口小 | 暂不处理，记在案 |

### 漫画

| 出处 | 遗留 | 没做的原因 | 建议归属 |
|---|---|---|---|
| c09 | manga-18b 页图空闲超时**没修到根因**：sidecar 整张读完才回响应头，真实效果只是整请求上限 45 秒 → 90 秒 | 真修要改 `third_party/m_extension_server` 的图片代理为流式并重编三端 sidecar | 待拍板（第 5 节），与 manga-28 同批 |
| c09 | 全源搜索 runner import 了 widget 文件（UI 分层退化） | 结构拆分要把 `OnlineMangaUnavailable` 从带登录页依赖的文件里拆出来 | 新开小组 |
| c09 | `video_work_acquisition_backends.dart` 里等 `initialise()` 的那处没改 | 计划外文件 | 新开小组或并 c28 |
| c10 | 过期的系统 OCR 逐页缓存会回填到后来引擎判为无文字的页 | 要定逐页缓存的失效规则（整卷落盘时清别的引擎的缓存 / 恢复时比时间或比引擎），各有代价 | 新开条目，先定规则（第 5 节） |
| c10 | manga-25 四个探测调用方只有源码守卫、没有行为测试；真实延迟没量 | 入口都要 `BuildContext` + `AppModel` 才能驱动 | 真机验证时量 |
| c08（漫画侧） | 本地页图卷的 `enumerateMangaPages`（`EN/ocr/manga_ocr_folder_job.dart`）不过滤 `._` / `@eaDir` | 文件归 c10 | c10 合入后单开或并 c38 |
| c08（漫画侧） | 漫画首扫的索引每卷新导入仍整份重写一次（随卷数平方增长） | 根治要改成逐条存储，没做也没实测 | 并 c27 |
| c11 | manga-8 的原方向（内容哈希 / host 跳过上传 / 缓存按内容键） | 拍板「做」（design-nmv-manga-ocr-content-hash）。可选清单端点 + capabilities `contentDedup`，内容缓存放任务根 `_content_cache/<引擎签名>/`，卷目录逐页缓存不动、不失效 | 已做 |
| c11 | manifest 端点的重复解析；章 `manga.json` 路径仍用私有 helper；`uploadPage` 在任务被取消后仍把状态写回 uploading | 计划外文件 / 文件被别的 claim 占着 / 既有窗口 | 新开小组 |
| c12 | 服务器恢复后、开章前没有任何其它 Kavita 请求成功时，那一次开章仍按离线放行 | 审查给了两种做法，取了第一种 | 所有者过目（第 5 节） |
| c12 | `KavitaMangaSyncSession.close()` 的 flush 吞错没加日志；`kavita_epub_sync.dart` 是否有同样的「每次等满」没看；分镜模型下载三个入口共用一个 `.part` | 不在文件清单 | 新开小组 |
| c41 | 「关互联后立刻再开」时两套模型同时在内存：新管理器的队列没接在旧管理器的执行体停下之后 | 要改 `fushi_server_controller.dart`，被两个互联相关 claim 占着 | 那两个 claim 落地后单开 |
| c41 | Windows 读者互斥只接了逐页缓存两处读；`manifest.json`、整卷中间产物、`manga.json` 的读者没改 | 范围 | 并上一条 |
| c41 | Windows 上原子写新增对 `%TEMP%` 的硬依赖（锁文件放在系统临时目录）；两个进程 `TEMP` 不同则互斥失效 | 审查后接受，写在注释与 bug 备注里 | 暂不处理，记在案 |
| c41 | 进程在写入中途被杀会留一个唯一名 `.tmp`，没有启动清扫；Lens / 系统 OCR / 外部 mokuro / 配对主机的事件流仍是 `async*` + `await for`，取消要等下一个事件才生效 | 不占模型内存，不在本条范围 | 暂不处理，记在案 |
| c41 | 跨进程互斥没有自动化测试；主机 `disposeAll` 没有真服务 + isolate 的用例 | 只有假执行体与手工探针 | 真机验证时补 |

### 视频

| 出处 | 遗留 | 没做的原因 | 建议归属 |
|---|---|---|---|
| c14 | 整轮准备步骤抛出时提示仍是「成功 0 / 失败 0」 | 补「出错」状态要新文案 | 随 gap-webvideo-6 拍板一起做 |
| c14 | 到不了的视频每次空闲仍消耗一行（标失败），失败行无重试入口 | 属 gap-webvideo-6 | 待拍板（第 5 节） |
| c14 | Android 上网页队列实际走到哪一步未核实（重放的静音采集与可捕获档是 Windows 专属路径） | 没有真机 | 真机验证 |
| c15 | 存量 done 行的清理没挂在首页启动处，改挂在两个读入口里（读方法带了一次性删除副作用）。非 Windows 且此后不再打开本地视频播放页的用户，旧 done 行会留着 | `home_page.dart` 被多个 claim 占着 | 占着 `home_page.dart` 的在途分支落地后挪回启动处（材料没点名是哪一个；c08 的同类挂点点名的是 #3534，可以一起补） |
| c15 | `web_video_fushi_page.dart` 两处注释在 c15 合入后不准 | 文件归 c14 | c29 |
| c16 | video-36k 剩余两处同形循环（`video_download_pipeline_service.dart`、`anime_download_dialog.dart`） | 计划外，前者被别的 claim 占着 | 新开小组 |
| c16 | 五条性能项都没量耗时，只有行为测试 | — | 真机验证时顺手量 |
| c17 | 本地代理连得上、代理出口不通时拿不到连接层异常，仍约 65 秒才报错 | 已知局限 | 暂不处理，记在案 |
| c18 | EUC-KR 等其它双字节编码在桌面 / 服务端会被 GBK / Big5 解成汉字（修前是整片 U+FFFD） | 根治要引入 chardetng 一类的新依赖 | 待拍板（第 5 节） |
| c18 | `platform_charset_detector.dart` 的桌面分支没删 | 要连带改被别的 claim 占着的测试文件 | 新开小组 |
| c18 | `fushi_music` 的预编译库不会因 `legacy_text.rs` 改动而重编（既有的戳记盲区，CI 出包不受影响） | 既有问题 | 新开 bug |
| c19 | 重新选同一条图形轨会重抽；判据对象挂在 `Expando` 上 | 要改 `VPC` 主文件，被三个 claim 占着 | c32 |
| c19 | 原盘导航程序自己换流时是否通知 `track-list` 只由 mpv 结构推出，没有真盘实测 | 没有真盘装置 | 真机验证（最需要验的一条） |
| c19 | 环境类失败靠对 ffmpeg 摘要做文本匹配，认不出的仍会被记到本次运行结束 | 已知边角 | 暂不处理，记在案 |
| c20 | 10 秒详情复用窗口与 2 秒清单年龄上限都是估值 | 没有实测 | 真机验证时校 |
| c21 | 最新备份坏掉、且有 options 相同的更早备份时，恢复会用更早那份的原始映射 | 从文件上分不出「写到一半」与「写完后才坏」；加用户可见提示超范围 | 暂不处理，记在案 |
| c21 | 15 种非中英语言的 21 条新文案是英文回落 | 待翻译 | 翻译批次 |
| c22 | gap-vidmisc-4 只算「代码已写」：计划要求先在真机确认 PiP 现状，没做；`:app:assembleRelease` 与 lint 本机没跑成 | 没有真机、没有签名配置 | 真机验证 + 看 PR 的 Android CI |
| c22 | 旧页 dispose 之前那一小段，小窗上的键仍作用在上一集播放器上 | 窗口小 | 暂不处理，记在案 |
| c23 | 合集面板里只有整季包、没有单集文件的来源，「下载全部」是灰的，而成员行预览写着「将从整季包中拆出」——未核实是否有意 | 写测试时发现 | 新开 bug 先验真伪 |
| c23 | 本集面板「批量下载途中重搜」没加闸；持久化失败的行文案仍是「下载失败」；对话框壳点遮罩关闭时拿不到已落盘路径；批量途中切作用域会静默中止 | 计划只点了合集面板 / 要新文案 / 生产无调用方 | 新开小组（i18n） |

### 跨域（来源扫描）

| 出处 | 遗留 | 没做的原因 | 建议归属 |
|---|---|---|---|
| c08 | gap-scanner-10 的启动清理挂点：残留临时行 / 临时目录要等下一次任意来源扫描才清 | 应挂 `home_page.dart` 首帧，被 #3534 占着 | #3534 落地后补 |
| c08 | gap-scanner-11 只修了扫描器入口与 ctl；引擎三处类型化错误没有界面消费，app / 引擎里另有十几处同一写死串 | 计划文件之外 | 新开小组（i18n） |
| c08 | 视频搬家判据更严后的漏判；名单外的通用目录名连着两层都撞上时仍可能误判 | 根治要给视频记内容指纹 | gap-scanner-6 的视频那一半，未立项（第 5 节） |
| c08 | 远端漫画来源断网后仍逐卷尝试；旧版留在系统临时目录顶层的 `m1c_scan_*` 不清；音乐来源 `mediaCount` 列写入口径没改 | 修前就是这样 | 暂不处理，记在案 |
| c08 | ctl `totalCount` 没有路由级断言；逐卷落盘抛错的分支没有自动化测试；跨进程文件锁没有真实跨进程测试 | 没有注入点 | 记在案 |

---

## 4. 待真机验证：汇总口径与建议顺序

每个 PR 的正文里有各自的「待真机验证」清单，这里不重抄，只给汇总口径和串行顺序。**24 个 PR 的清单没有一项做过**，证据只有单测、源码守卫、Node 跑手和少量探针脚本。

### 按装置归并

| 装置 | 涉及的组 | 要看什么（口径） |
|---|---|---|
| Windows 离屏集成测试（`run_windows_itest.ps1`） | c01、c04、c05；c18 已跑过 appSmoke | 现成用例保持绿：`lnreader_novel_source_itest`（c01 新增断言只编译过没执行过）、`reader_audiobook_image_late_load_itest`、`reader_audiobook_ruby_highlight_joints_itest`、`reader_audiobook_paused_chapter_back_itest`。跑之前确认屏幕亮着 |
| Windows 桌面真 app | c07、c08、c09、c12、c14、c15、c17、c18、c19、c21、c23、c13 | 导入 / 扫描后无残留目录；sidecar 取页；制卡队列（配假 AnkiConnect）；字幕面板多选与失败；PGS 片数 ffmpeg 进程；原盘菜单会话切轨 |
| Android 真机 | c22（**先验，有启动即崩的风险点**）、c09、c10、c41、c07、c02、c14、c23、c18 | PiP 现状基线与新按钮；冷启动开在线章计时；OCR 取消 / 暂停后内存峰值与 isolate 退出；目录 rename 走拷贝回退 |
| iOS / macOS（`ssh mac` 真 app） | c04、c05、c06、c18、c21 | 注入脚本的返回值序列化；WKWebView 上分页恢复落点；注音位置回归；CP932 字幕 |
| 阅读器三种 view mode | c01、c03、c04、c05、c06 | paginated / continuous / vn 各验恢复位置、换章、有声书高亮与跟读、点词查词。项目规则要求三种各验，验不了的写明原因 |
| 互联双设备 | c11、c41、c20 | 主机代跑 OCR 取消后重传命中缓存；DELETE 等 isolate 退出不超时；新旧版本互通；互联视频同步缺文件 |
| Linux 桌面与无头服务端 | c18 | Linux 开一份真实 CP932 字幕；`fushi_server` 媒体库里放同一份，客户端拉取后正文可读（服务端 bundle 要带新编的 `fushi_compute`）。这两项不在别的装置行里，单列出来免得漏 |
| 外部服务 | c20（真 Emby / Jellyfin docker、真 Plex）、c12（真 Kavita）、c02（Cloudflare 图床源）、c17（黑洞代理） | 起播请求次数；不可达时的等待时长；插图是否出得来；YouTube 出口不通到报错的时长 |
| 仅测量 | c16、c10（manga-25）、c13（大文件拷贝吞吐）、c07（300 页 PDF 的 RSS） | 没有硬性设备验证，顺手量 |

### 建议的串行顺序

1. **先看 24 个 PR 的 CI 结论**（多数推完没等）。红的先按根因修，绿了再排真机。
2. **Windows 离屏集成测试**：成本最低，一次租约内把现成用例跑完。
3. **阅读器五组（c01、c03、c04、c05、c06）合成一个临时验证分支，三种 view mode 一次验完**（这个做法是本文的建议，材料里没有）。它们改的是同一条换章 / 恢复 / 高亮链路，分开验会重复五遍，而且合起来才是 develop 上的真实组合。临时分支只用于验证，不推送。
4. **Android 真机一轮**：c22 → c09 → c10 → c41 → c07 → 其余。c22 放最前，因为接收器注册在启动路径上，抛异常就是启动即崩，且要 Android 12 及以下与 14 以上各一台。
5. **`ssh mac` 一轮**：iOS / macOS 的阅读器与字幕解码。
6. **互联双设备一轮**：c11 → c41 → c20。
7. **外部服务一轮**：Emby docker → Plex → Kavita → Cloudflare 源 → 黑洞代理。
8. 验证里量到的数字回填到对应 PR 正文与 bug 文件；c22 的 gap-vidmisc-4、c01 的 novel-1 这类「代码已写、等真机」的条目验完才算完成。

Android 真机上不卸载、不覆盖用户的 app；改 `wm size` / `density` / 旋转前记原值、测完还原。集成测试一律焦点驱动。

---

## 5. 待所有者拍板

写法：诉求 / 利弊 / 建议。按规则这些事项要进拍板台；**本轮拍板台没查成**（做计划的机器上没有拍板台的访问凭据），三份清单里 27 条待拍板事项在台上的状态未知；下面 5.1～5.3 共 24 条目前只写在本文档里，**没有登记进拍板台**，是否与台上已有事项重复也没核对。5.3 节的「建议」一栏与第 3 节的「建议归属」一栏是本文的归纳，不是复核结论。

### 5.1 没排进任何组的条目

| 事项 | 诉求 | 利 | 弊 / 风险 | 建议 |
|---|---|---|---|---|
| gap-webvideo-6 | 网页重放失败的行没有任何重试入口，也不显示（角标只数 pending，点角标直接跑队列不开列表） | 失败不再静默；c14 留下的「出错」提示可以一起做 | 新增界面与文案（M，i18n）；重复卡也是失败态，重试入口必须排除它，否则重蹈无限重试 | 做。只做「显示失败行 + 手动重试（排除重复卡）」，不加任何自动挑句 |
| gap-webvideo-11 | 网页视频两个宿主各写一套（选轨、恢复、JS 包装重复，广告处理与设置已分叉）。两案：(a) 收敛共用逻辑；(b) 删掉内置档页的窗口分支 | (a) 一处修复两边生效 | (a) 是 L；(b) 的前提没查清——发布包是否一律带补丁引擎没核对到构建产物，开发构建还要这条分支 | (a) 可立项；(b) 在确认所有发布通道的引擎之前不做 |
| gap-scanner-9 | 长扫描没有进度、不能取消；任一来源在扫时所有来源页的行操作都被锁 | 大库用户不用干等 | 属新增能力（M～L）；锁的范围是刻意设计；取消后的一轮不完整，末尾几步「以本轮结果为准做对账」的动作（音乐交接撤销、合订本回收、蓝光行回收）必须跳过，否则会按半份清单删东西 | 以后做。要做的话等 c08 合入（漫画索引逐卷落盘是前提），先只做进度，取消单独评估 |
| 合集批量下载加「停止」钮 | 合集字幕批量开始后没有任何取消入口；24 集的批量点错来源只能干等（每集要过一次内嵌轨对齐） | 小改动、明确的体验问题 | 新增交互；「批量不随工作台关闭而取消」是 BUG-4496 的刻意设计，停止钮不能改变这一点 | 做，放进 c23 之后的字幕面板小组 |
| novel-17g 插件隔离 | LNReader 插件在同一个 JS 全局里跑，任一插件可以冒用别的插件 id 读写其 storage | 真正的隔离 | 要每个插件一个独立 JS 环境（独立 WebView 或沙箱 iframe），推翻「运行时全局复用一个 WebView」的结构（L）；信任模型上插件是用户确认后装的第三方代码，与上游 LNReader 一致 | 不做，除非出现真实滥用。c02 已删掉无人使用的覆盖点 |
| gap-disc-6 Java 探测直传 | BD-J 原盘开盘时 Java 运行时探测跑两遍，第二遍是一次 PowerShell 冷启动（仅 Windows 且盘需要 Java） | 省一次几百毫秒量级的探测（经验值，没有本仓实测） | 要改 `VideoPlayerController.load` 的签名，落在被多个在途分支占着的主文件上 | 以后做，等 c32 开工时并进去 |
| manga-28 改 sidecar 协议 | 桌面每次调 sidecar 都带整个 APK 的 base64；真改是「先发哈希、未命中再发全量」 | 回环上少传几百 KB 到几 MB | 要动 vendored 服务端 overlay，重编 Windows / macOS / Linux 三端 sidecar，还有 host ABI 漂移守卫；视频在线源共用同一个 sidecar，两边都要验；实际占比没测 | 先等 m2 的测量。若要重编 sidecar，把 c09 的 manga-18b 真修（图片代理改流式）并在同一批 |

### 5.2 计划里按拍板编入、但有分歧或值得知情的（另含一条要所有者定的外部 PR）

| 事项 | 现状 | 建议 |
|---|---|---|
| video-34（c34） | 所有者定「预取下一段 + 小 LRU」；复核认为客户端已在预取，host 再预取会占并发名额 | 计划把 LRU 放前、预取放在量完单段耗时之后；量出来没收益就只留 LRU |
| video-9（c15，已做） | 按拍板「退出只提交 pending」；复核另提「按失败原因分永久 / 瞬时」没采纳。结果：Anki 没开这类瞬时失败退出后不再自动重试 | 已改（拍板 design-nmv-fyi-behavior）：确定没送到（`isUndeliveredMineFailure`）的行留作待办、记原因、这一轮停下，退出时自动再试；其余仍标失败不自动重试 |
| 新增交互（已按建议编入） | gap-vidmisc-4（PiP 加播放 / 暂停，c22 已写）、gap-subpanels-10（远端生成开放语言选择，c35）、gap-subpanels-3（多选态点行只勾选，c23 已做）、novel-d6（网页小说会话内续拉，c30，L） | 知情即可；c30 先复现章末现状再动 |
| c38 可否提前 | 被 #3670 压在第 3 波；#3670 对相关文件是纯增量 | 愿意承担合并冲突就提前。计划原话是「可提前到第 1 波」，那是在 c12 还没开 PR 时写的；现在 c38 依赖的 c12 #3701 没合，最早只能与第 2 波并行 |
| #3466 合不合 | 外部作者的 PR，OPEN；c41 #3719 已提前做完，两边 hunk 不相交 | 所有者定。合的话决定它与 #3719 的先后，后合的一方调测试装配 |
| c49 升不升 schema | 取决于随包 SQLite 带不带 JSON1，没验证 | 开工第一步先验证；带就不升 |
| 贴近掉帧方向的条目 | video-36b、gap-vidmisc-2（c32）、video-19（c46）、video-16 / video-23（m3）、gap-scanner-4（c45）、m5 的统计重载 | 各自开工前看 #3672 做没做，做了就划掉。video-1 的写入侧残量（两键合成一次写、uid 流窄投影）也等它落地后再看 |

### 5.3 第一波新冒出来、需要拍板的

| 事项 | 诉求 | 利弊 | 建议 |
|---|---|---|---|
| c09 manga-18b 真修 | 让页图空闲超时在真实 sidecar 上生效 | 利：真卡死的页不用等满 90 秒。弊：改 vendored 图片代理为流式并重编三端 sidecar | 与 manga-28 同批决定 |
| c10 逐页缓存失效规则 | 过期的系统 OCR 逐页缓存不应回填到后来引擎判为无文字的页 | 两种规则：整卷落盘时清别的引擎的缓存（丢可复用结果）；恢复时比时间或比引擎（判据更复杂） | 材料只说两种各有代价、要另定。本文倾向「恢复时比引擎」，单开条目 |
| c02 作品页头部下移 | 旧目录阶段头部缺简介，源站回来时列表下移可能误点 | 把简介等存进描述符（改持久化形态）或给头部预留高度（UI 改变） | 先在真机量下移量，够得上误点再选「预留高度」 |
| c02 丢图提示 | 阅读器里提示丢图数量、已丢图章节自动重取 | 利：用户知道缺图。弊：新增 UI 与重取行为 | 以后做；现在已有错误日志 |
| c01 预取让位 | 让未开始的预取延后启动或可中止，使「连跳两次」也变快 | 利：慢站点上更快。弊：预取命中率下降 | 先实测慢站点阻塞时长，再定 |
| c18 EUC-KR | 桌面 / 服务端把韩文等其它双字节编码解成汉字 | 根治要新依赖（chardetng 一类） | 先看有没有真实反馈；有再评估依赖 |
| c12 Kavita 恢复判定 | 「任何一次答话都结束不可达」，恢复后首次开章仍可能按离线放行 | 另一做法是探针答上来时若仍在起始页就补做对账，更复杂 | 已改（拍板 design-nmv-fyi-behavior）：探针在拉取预算内答上话就补做本章对账；采用服务器进度只在阅读器仍停在落点时跳页，否则不写 |
| c14 一行抛出后结束本轮 | 偏离计划字面的「标失败并继续」 | 利：环境性错误不会把整条队列逐行标失败（失败行没有重试入口）。弊：剩下的行要等下一次空闲或手动跑 | 认可；gap-webvideo-6 做完后可改回继续 |
| c08 搬家判据 | 比计划更严 | 利：不错绑。弊：部分真搬家另建 `X (2)` | 认可；根治走内容指纹 |
| c07 启动清扫由谁接 | 接线点在被占的 `app_model.dart` | — | 指定由下一个要动 `app_model.dart` 启动段的分支顺手加 |
| gap-scanner-6 的视频一半 | 给视频记内容指纹，解决搬家漏判 / 误判 | L，未立项 | 以后做，看 c08 合入后真实库上漏判多不多 |

---

## 6. 不做的与让出的

### 6.1 因别人在途工作让出

| 条目 | 让给谁 | 说明 |
|---|---|---|
| video-1、video-s2-1 | #3672 `pr/video-stutter` | 播放中每秒进度写引发的库页重读；保存周期所有者也定了不放宽。写入侧残量等它落地后再看 |
| video-22、video-s3-1、gap-vidmisc-3 | #3672 | 播放期逐帧开销 / 高频事件重建 |
| video-21 | #3679 `pr/embedded-sub-watched` | 内封字幕多路 ffmpeg 并发读、抽取不可取消 |

### 6.2 所有者定「不做 / 本轮不做」

| 条目 | 内容 |
|---|---|
| novel-21、novel-d2 | 排版 shell 与 VN 引擎的结构合并、引擎 JS 搬成资产（L，单独立项） |
| novel-d3 | LNReader 整本下载的形态不改 |
| video-28、video-s2-7 | 本地换集改原地换源（L，与 #3672 抢文件） |
| video-29 | 「seek 在途」四套状态收成一套（先在 media_kit 补丁上实测） |
| video-s2-4、-5、-6 | 片段导出进度与取消、后台制卡任务持久化、远端字幕下载并行化 |
| manga-d1～d10 | 广告过滤「先出页后剔除」、ask 预检前移、AI 复核并发、互联主机逐页回传、在线直读配对主机 OCR、直读页复用到下载、下载按源并行、下载进度只放内存、导入中途取消、PDF 页图格式 |

### 6.3 核实后不是问题 / 已失效

| 条目 | 结论 |
|---|---|
| manga-18c | 被反驳：每请求新建 client 是取消机制本身，复用会失去取消能力 |
| manga-bug1851、manga-bug1852 | 功能已删，条目失效；文档订正随 c10 做了 |
| novel-s3-1～4 | 核实不是问题 |
| manga-s3-1～4、manga-s3-6 | 核实不是问题 |
| video-s3-2～8、s3-10～12、s3-14、s3-15、s3-17、s3-18 | 核实不是问题（全屏不重建播放器、焦点不绕开所有权、订阅都有释放点、统计口径一致、原生拆建有上界、缩略图有 LRU、字幕解析会切 isolate、制卡抽取参数顺序正确、ED2K 可取消、媒体服务器封面带尺寸、遥控是长轮询、在线源重新取流是刻意设计等） |

### 6.4 实施时别越界的黑名单邻近项

- video-9 / gap-webvideo-6 修的是**现有手动暂存队列**的可靠性，不得加任何「自动挑候选句」。
- 漫画 AI OCR 复核是现有功能，与「阅读器接入 AI / 大模型」不是一回事；本路线图不向阅读器加任何 AI 能力。
- gap-subpanels-10 开放的是 ASR 字幕生成的语言选择，不是 AI 翻译字幕。

---

## 7. 没验证的前提（开工时先核）

- 随包 SQLite 是否带 JSON1（c49）。
- mpv `chapter-list` 在各端是否返回 JSON（c32）。
- c51 的 video-36f 具体要动哪 4 个 `VF/*.part.dart`。
- c30 的章末现状（没有实测，先复现）。
- gap-webvideo-11 (b)：各发布通道的引擎是否一律带补丁。
- 计划列过、第一波已经核掉的前提（不用再核）：`native/fushi_compute/src/hash.rs` 对长度不是块大小整数倍的文件没有备用哈希（c16 的 video-10 建在它上面，c16 实现与审查两轮都读过代码并有原生测试钉着）；c11 的 OCR 上传路由位置。c07 的启动清扫挂点、c08 的其余写死串仍未处理，见第 3 节。
- 第 2 节各组的「现象」：小说 / 漫画 / 视频条目取自原始清单并按复核结论订正，补读条目取自补读记录的标题与复核结论，没有逐条回到当前代码重新核对。novel-17e 没有单独的复核段；video-s3-13 的复核只有一小段，按计划与 video-18 合写。
- 「用户可见的行为变化都写在各自 PR 正文里」这句没有逐个 PR 核对；c41 的 PR 正文草稿写过「`disposeAll` 会挂住 `stop()`」「Windows 并发写只修一半」，后续记录显示两者都已修，#3719 线上正文是否同步更新没核对。
- #3672 对应的 bug 号材料里前后不一致，本文只引 PR 号。
- 本文的修法细节有一部分来自复核摘要而不是逐条重读代码；行号都是基准 `4c347287835` 上的。实施前回到代码重新定位，发现与本文不符以代码为准并更新本文。

---

## 8. 2026-11-20 实施结果

> 这一节是 2026-11-20 一次性把剩余 33 组做完之后回填的，**以这一节为准**；第 1～7 节保留当时的原文，其中「未合并 / 闸未解 / 待定」的说法多数已过期。

- 第 1 波 24 个 PR 与第 2 节点名的闸 PR（#3672、#3679、#3663、#3515、#3534、#3467、漫画有声四件经 #3681）在开工前都已合入 develop；#3466 仍 OPEN，已在拍板台（`pr3466`）。
- 剩余 33 组全部开了 PR，另有 5 个遗留小组和 1 个返修中发现的独立修复，共 39 个 PR，**全部 OPEN、未合并**。每组实现后都由一个独立审查者做过反驳式审查，真问题已就地修掉。
- **叠放**：后面波次的分支里并入了前置组的分支，PR 的 base 都是 develop。合并顺序照下表「先合」一栏；前置组合入后，后面 PR 的 diff 会自动缩到只剩自己的提交。
- **真机 / 真 app / 模拟器 / Windows 离屏集成测试一项都没做**（所有者定本轮不做），各 PR 正文有「未做的设备验证」清单。第 4 节的口径与顺序仍适用，范围扩大到这 39 个 PR。
- **bug 号相撞**：并行分支各自 `bug.dart new`，BUG-4984～BUG-4914 多处重号，合入后由 develop 上的 settle CI 收口；PR 标题与提交信息里的号不会跟着变。
- 协调目录的 claim 一个都没登记（实施代理被 worktree 隔离拦住，写不到共享目录）。
- c28 的 `gradlew :app:assembleRelease` 本机缺发布签名没跑成，由 PR 的 Android CI 把关。

### 8.1 实施组 c24～c52

| 组 | PR | 先合 | 条目结论 | 审查 |
|---|---|---|---|---|
| c24 | #3787 | — | 修 3、不成立 1 | 通过 |
| c25 | #3777 | — | 修 2、不成立 1 | 通过 |
| c26 | #3785 | — | 修 6、不成立 1、延后 1 | 有问题，已修 |
| c27 | #3799 | — | 修 3、量后不改 1 | 通过 |
| c28 | #3795 | — | 修 4 | 有问题，已修 |
| c29 | #3784 | — | 修 4 | 留有待定项 |
| c30 | #3805 | c25 | 修 1 | 有问题，已修 |
| c31 | #3801 | — | 修 5 | 有问题，已修 |
| c32 | #3782 | — | 修 8、量后不改 1、待拍板 1 | 通过 |
| c33 | #3812 | c27 | 修 2 | 有问题，已修 |
| c34 | #3779 | — | 修 1、量后不改 1、不成立 1 | 通过 |
| c35 | #3781 | — | 修 5 | 有问题，已修 |
| c36 | #3796 | — | 修 4 | 有问题，已修 |
| c37 | #3792 | — | 修 3 | 有问题，已修 |
| c38 | #3783 | — | 修 8 | 有问题，已修 |
| c39 | #3808 | c26 | 修 3 | 有问题，已修 |
| c40 | #3789 | — | 修 6 | 有问题，已修 |
| c42 | #3793 | — | 修 1、不成立 2 | 留有待定项 |
| c43 | #3814 | c38、c28 | 修 4 | 有问题，已修 |
| c44 | #3807 | c35 | 修 1 | 有问题，已修 |
| c45 | #3816 | c31、c36 | 修 4 | 有问题，已修 |
| c46 | #3815 | c32 | 修 3 | 通过 |
| c47 | #3817 | c31、c33、c42 | 修 6 | 有问题，已修 |
| c48 | #3813 | c37 | 修 7 | 有问题，已修 |
| c49 | #3806 | c37 | 不成立 2、修 4 | 通过 |
| c50 | #3819 | c43、c37、c28、c49 | 修 7 | 留有待定项 |
| c51 | #3821 | c45 | 修 3 | 有问题，已修 |
| c52 | #3818 | c36、c45 | 修 1 | 通过 |

审查后的返修（都已推回原分支并并进叠在上面的分支）：

- c45 #3816：c51 发现它尖端有 4 条测试红。分型结论是测试侧问题（着色器目录改异步后 widget 测试没推进真实 IO；一条守卫钉着被改掉的注释），只改了测试，生产代码没动。已并进 c51、c52。
- c42 #3793：Plex 连接探测在核对 machineIdentifier 之前就带着 token 发请求。改成身份核对一律不带凭据（`/identity` 官方文档标注无需认证，没对真 PMS 验证），登录挑线路、自动换线路、服务端 CLI 三处走同一入口。已并进 c47。
- c43 #3814：两条作品页测试并发下不稳，根因是 develop 上既有的两处竞态（刷新整条写回冲掉途中的订阅 / 选章；下载状态旧读盖新读），单开 **#3827 `pr/manga-series-refresh-lost-update`**（base develop，与 c50 #3819 修的是同一处，谁先合都行），并进了 c43、c50。

### 8.2 测量组与遗留小组

| 组 | 分支 | PR | 叠在 | 条目结论 | 审查 |
|---|---|---|---|---|---|
| m1 | `pr/measure-reader-engine` | #3830 | origin/pr/reader-chapter-prefetch-restore (#3787, c24)；origin/pr/web-novel-session-continue (#3805, c30)；origin/pr/novel-heavy-work-off-ui (#3789, c40) | 修 3、本机量不了 3、已被别处修掉 1、量后不改 4、待拍板 2、延后 1、不成立 2 | 有问题，已修 |
| m2 | `pr/measure-manga-runtime` | #3832 | #3819 pr/manga-series-entry-state（c50，内含 c43 #3814、c28 #3795、c38 #3783、c37 #3792、c49 #3806），上一轮叠的；#3817 pr/remote-stream-timeouts-resume（c47，内含 c27 #3799、c33 #3812），本轮叠的，因为 source_library_scanner.dart 被 c27/c33/c47 改过 | 量后不改 1、修 2、本机量不了 3、不成立 1 | 通过 |
| m3 | `pr/measure-video-library` | #3829 | #3784 pr/web-video-builtin-host (c29)；#3817 pr/remote-stream-timeouts-resume (c47, contains c31/c42)；#3821 pr/video-page-rebuild-trims (c51, contains c31/c36/c45)；#3818 pr/srt-serialization-dedupe (c52) | 待拍板 1、量后不改 2、修 2、本机量不了 1、不成立 1 | 有问题，已修 |
| m4 | `pr/measure-video-media` | #3828 | — | 修 1、待拍板 2、量后不改 3 | 通过 |
| m5 | `pr/measure-stat-facts` | #3835 | pr/measure-manga-runtime (#3832, m2；已含 c38 pr/manga-reader-hotpath、c43 pr/manga-reader-settings-session、c49 pr/shelf-slim-read、c50 pr/manga-series-entry-state)——因为 manga_fushi_page.dart 被这几个分支改过 | 修 3、不成立 1 | 通过 |
| L1 失败提示文案 | `pr/nmv-leftover-error-surfaces` | #3825 | #3784 pr/web-video-builtin-host (c29) | 修 6、不成立 1 | 有问题，已修 |
| L2 漫画杂项 | `pr/nmv-leftover-manga-misc` | #3833 | #3814 pr/manga-reader-settings-session（已含 #3783 pr/manga-reader-hotpath、#3795 pr/manga-download-control、#3827 pr/manga-series-refresh-lost-update） | 已被别处修掉 2、修 14 | 有问题，已修 |
| L3 视频杂项 | `pr/nmv-leftover-video-misc` | #3831 | #3821 (pr/video-page-rebuild-trims, contains #3801/#3796/#3816)；#3815 (pr/video-controller-mpv-batch, contains #3782)；#3784 (pr/web-video-builtin-host) | 修 13、不成立 1 | 有问题，已修 |
| L4 小说 / 启动挂点 | `pr/nmv-leftover-novel-startup` | #3824 | #3805 pr/web-novel-session-continue (c30, contains #3777 c25)；#3808 pr/manga-import-dialog-async (c39, contains #3785 c26)；#3792 pr/book-delete-cleanup (c37) | 修 8、已被别处修掉 3 | 有问题，已修 |
| L5 阅读器引擎 JS 与 Node 跑手 | `pr/nmv-leftover-reader-js` | #3826 | #3787 pr/reader-chapter-prefetch-restore (c24) | 修 3、不成立 1 | 有问题，已修 |

遗留小组收的是第 3 节标「新开小组 / 新开 bug / 需协调方指定」的行，加上 c24～c52 各组新留下的；逐条处理表在各自 PR 正文里。第 3 节里标「暂不处理，记在案」「真机验证时补」的行没有动。`tts_render_runner.dart` 换音频不带 commit 的那一半仍没做（在途 PR #3794 占着文件）。

### 8.3 测量结果

测量只用了开发机上能自动化的装置（Node / headless Chrome 驱动生产 JS、Dart 合成基准、本机 ffmpeg 与 libmpv、桌面 sidecar），**没有任何手机 / 真 app 数字**。没给门槛的条目按「单次超过一帧预算或用户可感知」判。

**m1（#3830）**

- gap-readerjs1-3: 100k-char chapter (4749 text nodes), paged vertical, one fushiProgressDetails at chapter end, 5 runs × 30 calls: median 18.3 → 0.0 ms, P95 19.9 → 0.1 ms; fixed with the shared text index
- gap-readerjs1-3: paged horizontal chapter end: 18.2 → 0.0 ms (P95 20.1 → 0.1)
- gap-readerjs1-3: illustration page, horizontal (scan fallback, 3000 getClientRects): 50.2 → 0.1 ms (P95 54.9 → 0.2); vertical 9.0 → 0.0 ms
- gap-readerjs1-3: single firstVisibleCharOffsetByScanPaged call: 41.9 → 0.0 ms, getClientRects calls 3000 → 12
- gap-readerjs1-3: first sample after opening a chapter (includes index build): 19.5–20.5 → 20.5–21.1 ms, same order as before
- gap-readerjs1-3: chapter open with 6599 text nodes, offsetsBuilt→restoreDone, 7 runs: paged 40.3 → 36.1 ms; continuous 36.4 → 46.3 ms (index build moved into restore, so the first sample saves ~20 ms)
- gap-readerjs2-9: continuous mode at chapter end after BUG-2903: steady 0.1–0.2 ms (P95 0.3), first call 19–22 ms; already fixed
- gap-readerjs2-2: 100k-char chapter, paged vertical caret line move: left 605 → 16.8 ms, right 576 → 14.2 ms; getClientRects per move 113,892 → 3,922; fixed
- gap-readerjs2-2: continuous vertical caret line move: left 513 → 12.9 ms, right 479 → 11.9 ms; first-entry P95 623 → 12 ms; small chapter 7.6 → 2.3 ms
- novel-17e: AOT, 31 runs per round × 5 rounds, linear lookup of the last chapter: 1000 chapters median 3.3–10 ms (P95 4.9–18.6), 3000 chapters median 12.4–23 ms (P95 14.7–30.7); after: table built once (1000 ch 4.0–4.4 ms, 3000 ch 11–13 ms), then lookups <0.001 ms; fixed
- gap-readerjs1-5: 2100-cue chapter, offsetsBuilt→restoreDone, 7 runs: paged with cues 261.7 ms (P95 290.4) vs without 37.0; continuous 240.4 vs 39.3; reverse table 15.5 ms (P95 19.1) ≈ 7%, span wrapping dominates; no change
- gap-readerjs2-5: VN 2100 screens: paginate at chapter start 4.4 / P95 6.4 ms, near chapter end 4.2 / 6.4 ms; at chapter end screenIndexForSentenceAudioCue 3.7 / 4.4 ms, highlight 8.1 / 10.7 ms; under one frame, no change
- gap-readerjs2-7: VN open, small chapter 34.8 vs paged 41.8 ms; large chapters 410 vs 193, 367 vs 169 ms (about 2×); listed for the owner
- gap-readerjs2-8: 105 sampled cues, hint exact / +3 / +30 characters: shared path errors 0/0/0, VN 0/105/105; reported to the owner
- c06: chapter with 60 paragraphs and 4 illustrations restored to 0.5, 7 runs: paged 52.5 / P95 57.3 ms, VN 64.6 / 66.1 ms
- c05: getScrollContext about 0.004 ms per call (100 calls 0.3–0.4 ms), 3–5 calls per sample; no change
- 本机量不了：novel-20 —— Measuring build count and frame time from progress sampling needs a profile build plus a real WebView timeline. ReaderFushiPage cannot be mounted in flutter_test (InAppWebView platform view). Upper bound from the code: 50 ms throttle plus in-flight coalescing,
- 本机量不了：c04-chapter-perf —— The sentenceAudioCues and audiobookBridge segments are on the Dart side (database reads plus WebView IPC). Measuring them needs the real app, an audiobook and a WebView. The JS-side cue cost is covered under gap-readerjs1-5.
- 本机量不了：c06-stylesheet-cache —— Needs a rig with seamless continuous mode where EPUB stylesheets come through the fushi.local interceptor. The headless harness blocks .local resolution.

**m2（#3832）**

- gap-scanner-5（第二步，本轮）：用 flutter_test（JIT）量合成漫画来源（200 系列 × 10 个 cbz + 100 系列 × 10 卷 × 30 页 = 3.2 万文件），预热 1 次、实测 5 次。修前过滤 + 归类同步占住 UI isolate，中位 273 ms、P95 286 ms。修后放进 Isolate.run：调用方的同步段（spawn + 消息拷贝）中位 3.15 ms、P95 4.1 ms；用 1 ms 周期定时器量事件循环最长间隔，中位 16 ms、P95 17 ms，正好是 Windows 定时器精度下限；墙钟中位 282 ms，和同步版相当。结论：成立，已修。
- gap-scanner-5（第一步，上一轮）：同一规模下引擎 planMangaFolders 是平方级，AOT 中位 2886 ms、P95 3523 ms，修后 101 ms、P95 109 ms。JIT 下 exclude + planScanFromFileList 中位 3149 → 220 ms。listFiles 墙钟中位 373～429 ms，事件循环最长停顿 18～45 ms（主要是最后给 3.2 万条排序）。逐卷 statSync 3000 次共 121～130 ms，约 40 µs/次。
- manga-28（上一轮）：探针用和 sidecar 同版本的 NanoHTTPD 2.3.1 + Jackson，跑本机 127 个真实扩展 APK（中位 61 KB、P90 83 KB、最大 152 KB），每档预热 50 次、实测 200 次。中位 APK 带 APK 的往返中位 2.35 ms、P95 3.03 ms，不带是 0.57 / 0.90 ms；UI isolate 上序列化中位 0.32 ms、P95 0.52 ms。最大 APK 往返中位 3.61 ms，序列化 0.84 / 1.16 ms。结论：不改。
- BUG-4914（上一轮）：探针发 2000 次请求，NanoHTTPD 删临时文件失败 1942 次；本机 %TEMP% 里已经残留 504 个 NanoHTTPD-* 文件（40 MB）和 13 个 mextensionserver* 目录（10 MB）。修后跑 3 次、每次 100 个请求，%TEMP% 新增 0 个，JVM 退出后 sidecar-tmp 下剩 0 项。
- manga-s3-5 Windows（上一轮）：用生产版 ChildProcessContainment 强杀宿主 5 次，子进程 5/5 被带走，宿主死后 35～56 ms（中位 48 ms）消失。结论：Windows 上不成立。
- 本机量不了：manga-s3-5 —— Windows 一半已量，不成立：强杀宿主 5 次，子进程 5 次都被带走，宿主死后中位 48 ms 消失。macOS 一半量不了，要在 mac 上强杀 app 看 java 进程有没有残留。代码上看，非 Windows 平台的子进程收容是空操作。
- 本机量不了：manga-17b —— 要 Android 真机：全局搜索时在原生池上打排队时间日志。
- 本机量不了：manga-20 —— 要真 WebView（Android 真机，或 Windows WebView2 的真 app），在 onLoadStop 和 _windowGate.complete 两处打时间戳。代码上数过，中间串行 6～8 次 evaluateJavascript。

**m3（#3829）**

- video-16: real library copy 1247 videos, one _refresh round (listForShelf + 15 full-table queries + aggregation) x20: wall median 103 ms / P95 123 ms, longest UI-isolate stall median 10.0 ms / P95 11.8 ms
- video-16: scaled library 3000 videos x20: wall median 171 ms / P95 205 ms, aggregation sync section median 9.8 ms, longest UI-isolate stall median 19.8 ms / P95 35.3 ms. Over the 16 ms frame budget; a round is far below 2 s, so the 'invalidating refresh never lands' case does not trigger (desktop 9800X3D JIT)
- video-27: synthetic 300 vs 3000 items, debug JIT, x30 setState frames: series 62.6 -> 50.3 ms, all videos 47.9 -> 54.2 ms (within noise); search per keystroke x27: series 55.2 -> 68.8 ms, all videos 51.3 -> 65.4 ms; growth with item count <=14 ms, no change
- video-23 before: 10000 lines M3E, cue-change frame median 168 ms / P95 372 ms, follow-scroll frame median 120 ms / P95 286 ms, favorites predicate 126102 calls/frame; classic layout 72.7 / 45.6 ms; 300 lines M3E 44.9 / 5.9 ms (60 cue changes, 180 follow frames, debug JIT)
- video-23 after: 10000 lines M3E 37.5 / 3.9 ms (predicate 5070 calls/frame); classic layout 26.1 / 3.6 ms; 300 lines M3E 43.7 / 1.9 ms, classic 22.8 / 1.7 ms. Fixed
- gap-subpanels-8: search panel per-build derivations, 300 candidates median 0.94 ms; 1500 candidates median 3.27 ms / P95 15.5 ms (buildSubtitleVersionGroups alone median 2.71 ms), x30, no change
- gap-remote-11: desktop only, 500-item Jellyfin page 742 KB x40: utf8+jsonDecode median 6.8 ms / P95 52 ms, parseItemsPage median 1.6 ms, total median 8.3 ms / P95 59.6 ms. The mid-range Android threshold cannot be measured on this machine
- gap-remote-4: host offline, never resolved (accepts TCP, never answers): serial 4026 ms -> parallel 2006 ms; unroutable address 4008 -> 2077 ms; resolved, then host stops answering 17017 -> 15027 ms (startPositionFor 15014 ms + stream fetch re-probe 2003 ms). Fixed by running them in parallel
- 本机量不了：gap-remote-11 —— The threshold is 'over one frame on a mid-range Android device', which this machine cannot measure; it needs a mid-range Android phone and a profile build. Desktop reference only: a synthetic 500-item Jellyfin page (742 KB), utf8+jsonDecode median 6.8 ms, pars

**m4（#3828）**

- video-33：生产 AnimeEpisodeDownloader，公网 Mux 720p（64 片 / 177 MB），各跑 3 次。改前 80.1 / 85.7 / 97.1 s（中位 85.7 s），改后（3 片在途）49.2 / 52.3 / 59.3 s（中位 52.3 s）。成立，已改（PR #3828）。
- video-33 前置探针：同一条流的 1080p 版（40 片 / 305 MB），两批各 3 轮。串行中位约 41 s（25.9～165 s），3 片在途中位约 16.5 s（12.2～22.5 s）。
- video-31：真实 1080p 片段转出 HDR10 / HLG 样片（x265 10-bit，白点 203 nit），对比 YAVG / YMAX / SATAVG：SDR 原帧 137 / 235 / 16.9；生产 ffmpeg 抽帧 HDR10 109 / 155 / 5.6，HLG 120 / 199 / 9.9；mpv screenshot（gpu-next，d3d11）HDR10 和 HLG 都是 131 / 236。结论：ffmpeg 制卡路径没有色调映射，成立；mpv 截帧已映射。修法待拍板。
- gap-disc-5：1080p 帧加日文字幕，AOT 跑 11 次。像素循环 55 ms，encodePng 934 ms（p95 1140 ms），写盘 4 ms，读盘 0.5 ms；Windows.Media.Ocr 解码 25 ms、识别 48 ms（各 11 次）。PNG 编码 + 解码约占 95%，超过 30% 门槛，报立项。只降压缩档：level 1 + sub 为 300 ms，level 1 + none 为 361 ms。
- gap-vidmisc-10：桌面 ffmpeg 代测 kit 的命令形状，各 3 次，按行数计（事件数的下限）。探测 89 行 / 0.07 s，字幕抽取 127 行 / 0.59 s，制卡音频 64 行 / 0.12 s，抽帧 75 行 / 0.19 s，120 s 转码 91 行 / 5.4 s（约 17 行/s，其中表头约 70 行，之后每秒约 2 行）。每秒只有几条，不做。
- gap-webvideo-9：headless Edge，8100 节点合成页，2000 次 tick，网页档和播放器档各 3 次。Netflix tick 中位 0.8～1.0 ms、p95 1.1～1.4 ms，每条 2.3 KB；YouTube 中位 0.2～0.3 ms，每条 0.8 KB。Dart 侧 jsonDecode 中位 26 µs、parseWebVideoStatePayload 中位 10 µs（20000 次）。不做。
- gap-vidmisc-6：真 libmpv（vo=null），720p 6 s 片段，200 张卡。每张新建 Player：首帧中位 24.1 ms（p95 30.5 ms），RSS 每张约 +52 MB，200 张时 8.3 GB，结束 5 s 后 251 MB（dispose 推迟 5 s 销毁）。复用一个 Player：首帧中位 18.6 ms，RSS 211～265 MB。不改；GPU 纹理那层没量。

**m5（#3835）**

- 装置：flutter test 里的 Dart 基准（JIT debug 模式），DB 与生产同形（createInBackground 临时文件），每场景热身 2 次后跑 15 次；指标是墙钟耗时和主 isolate 最长同步段（零延时 timer 链取最大间隔，空闲基线 3～7 ms）。REAL = 本机用户库的只读备份（8,338 段 / 75 个活跃日，收藏句偏好 425 KB）；Y1 = 按 REAL 节奏合成一年（40,515 段）；L = 21,900 段 + 1,500 本书 + 15,000 计数 + 5,000 收藏；XL = 60,225 段 + 3,000 本书 + 30,000 计数 + 10,000 收藏。
- gap-vidmisc-5/gap-mangamisc-8 统计侧栏（loadStatFacts + summarizeReaderBookStats），中位数 / P95：REAL 改前耗时 96.9/114.1 ms、主 isolate 38.5/46.7 ms → 改后 10.9/12.0 ms、1.2/2.8 ms；成立，已改
- 统计侧栏 Y1：改前 290.7/316.5 ms、主 isolate 67.1/81.1 ms → 改后 17.5/34.0 ms、1.9/8.7 ms
- 统计侧栏 L：改前 217.0/329.0 ms、主 isolate 30.7/56.3 ms → 改后 9.0/10.7 ms、1.0/1.7 ms
- 统计侧栏 XL：改前 543.9/623.6 ms、主 isolate 98.4/116.8 ms → 改后 16.5/20.3 ms、0.9/2.5 ms
- gap-vidmisc-5 统计中心「观看」页签（每切一次都重载）：REAL 改前 113.1/126.4 ms、主 isolate 39.6/45.2 ms → 改后 64.8/74.3 ms、43.1/47.3 ms（主 isolate 被收藏句 JSON 解码卡住，没降）
- 「观看」页签 Y1：改前 449.6/568.9 ms、主 isolate 158.3/227.9 ms → 改后 143.1/214.8 ms、39.5/76.8 ms；L：331.5/373.5 ms、108.1/123.7 ms → 132.6/161.6 ms、13.2/20.4 ms；XL：814.6/896.8 ms、287.4/335.9 ms → 287.8/308.0 ms、42.6/48.0 ms
- 统计中心「总览」页签（需要全域，没改），耗时 / 主 isolate 中位数：Y1 345.9 / 121.3 ms，L 290.3 / 90.7 ms，XL 719.8 / 249.8 ms，REAL 86.3 / 30.6 ms
- 主 isolate 时间来源（REAL）：收藏句偏好整段 jsonDecode（425 KB）27.6 ms 同步；getStudySegments 行映射 13.4 ms（Y1 38.7 ms，XL 62.7 ms）；其余各表都不到 2 ms。includeCounters 让 loadStatFacts 的主 isolate 时间从 5.1 ms 涨到 31.2 ms
- 按书读口的下界（只读本书段 + 本书计数）：Y1 6.0 ms，L 5.3 ms，XL 9.2 ms，主 isolate < 1 ms

### 8.4 待拍板

第 5 节的事项与这一轮新冒出的取舍已登记进拍板台（<https://rank.fushi.moe/dev/decisions>），共 31 条，id 前缀 `design-nmv-`，其中 7 条附了设计图。登记时按现状改写或剔除了几条：c49 不用升 schema（随包 SQLite 带 JSON1，#3806 已验证）；c34 实测单段转码耗时是段长的 22～55%，只做了 LRU，台上问的是「是否仍要 host 预取」；「c38 可否提前」「开工前先看 #3672」已无意义；启动清扫接线、演职员头像解码上限、互联 host 侧删书清理、Plex 探测发 token 四件已直接做掉，不上台。第 5 节原文不再维护，以拍板台为准。

### 8.5 第 7 节前提的核对结果

- 随包 SQLite 带 JSON1（c49 已验证，不升 schema）。
- mpv `chapter-list`：生产路径读 `track-list` / `demuxer-cache-state` 时已按 JSON 解析同一种 node 属性，c32 据此改成一次读；各端真机没核。
- c51 的 video-36f 涉及的 part 文件已在 #3821 定位并改完。
- c30 的章末现状已在测试层复现后才动（#3805）。
- gap-webvideo-11 (b) 的前提（各发布通道的引擎是否一律带补丁）仍没核，事项在拍板台。

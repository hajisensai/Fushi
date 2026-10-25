# BD / DVD 原盘交互改造（任务交接）

状态：交接文档（2026-10-24，需求方提供），原文照录。

任务交接：BD / DVD 原盘交互改造
背景与目标

仓库：Fushi（Melos workspace），Flutter app 在 fushi/。
开工前：先读根目录 CLAUDE.md 和 docs/agent/fast-workflow.md，遵守 worktree、i18n、动效、设计系统、验证、提交等全部规则。
目标：把原盘入口从「系列 → 合集 → 原盘菜单」三层缩短到卡片和详情页一步直达；增加 BD / UHD / DVD 规格标签和筛选；把原盘播放做成类似 Steam 大屏模式的沉浸式会话；支持 DVD 识别、导入和菜单；最后再做远端原盘。
现状事实（已核实）

BD 盘导入后，一张盘是一个合集，每条入选的 MPLS 是一个成员。
盘判据在 packages/fushi_engine/lib/media/video/bluray/bluray_disc.dart：看 BDMV/PLAYLIST 是否存在，目录名大小写精确匹配。
成员路径反推盘根用 blurayDiscRootForPlaylistPath，它是纯函数。
导入逻辑在 fushi/lib/src/media/source_library/source_library_scanner.dart 的 _importBlurayDiscs。
现在只有单条播放列表卡的长按菜单有「进入原盘菜单」（fushi/lib/src/pages/implementations/home_video_page.dart 约 3584 行，_showVideoMenu），合集卡没有这一项。
合集详情页的原盘按钮，是选集标题上方的一排描边按钮（media_collection_detail_page.dart 的 _buildDiscMenuEntries），只在传了 onOpenDiscMenu 回调时显示。
video_work_detail_page.dart:194 传了这个回调。
从「相关作品」进入的路径（media_collection_detail_page.dart 的 _openRelatedCollection，约 1274 行）没有传，所以从这里进去看不到按钮。
单作品详情页的原盘按钮是次按钮（video_work_detail_page.dart 约 413 行，key 为 video-work-disc-menu）。
打开原盘菜单的入口是 openLocalVideoBook(..., openBlurayMenu: true) / VideoFushiPage(openBlurayMenu: true)。
播放侧在 fushi/lib/src/media/video/video_player_controller.dart，以及 fushi/lib/src/pages/implementations/video_fushi/disc_menu.part.dart。
菜单栏、输入、焦点分别在 fushi/lib/src/media/video/bluray_disc_menu_bar.dart、bluray_disc_menu_input.dart、bluray_disc_menu_focus_host.dart。
导航状态在 video_disc_menu.dart，由 libmpv 补丁 third_party/media_kit_libs_windows_video/patches/disc-navigation-state.patch 提供（stream_bluray.c）。
原有原盘菜单设计见 docs/specs/2026-10-08-bluray-original-menu.md。要点：Android / Apple 安装包不带 JVM，BD-J 盘在这些平台开不了菜单；Windows 有可选的 BD-J 组件。
DVD 现在完全不支持：扫描器不认 VIDEO_TS，.vob 在视频扩展名里，所以一张 DVD 会被拆成一堆散装 VOB 条目。
刮削侧对 BD 盘已经有专门处理（packages/fushi_engine/lib/media/video/metadata/video_source_work_planner.dart 约 88 行：盘名当片名，特典挂在正片下）。本任务不涉及刮削。
详情页里，带云朵角标的剧集是互联对端（远端）上的资源。libbluray 需要本地文件系统，所以远端的盘目前开不了菜单。
已拍板的设计决策

标签和菜单能力分开：标签只按文件结构判断，必须能确证；能不能开菜单是运行时能力（平台制品、BD-J 运行时、AACS），两者不混。按钮在开不了菜单时照样显示，点了说明原因。
规格判据：
BD = BDMV/PLAYLIST/*.mpls
UHD BD = BD 且 BDMV/index.bdmv 版本号为 0300
DVD = VIDEO_TS/VIDEO_TS.IFO
Android 和 iOS 不做 BD-J：遇到 BD-J 盘时，主按钮退回普通「播放」，副标题写「此盘菜单为 BD-J，本平台不支持」。HDMV 菜单的盘在两端照常可用。
远端流式不强制：缓冲严重时只弹一条可关闭的提示，建议下载到本机，并提供「不再提示」，绝不强制切换。
点空白呼出控制栏，按层级处理：
如果当前开着任何浮层（盘自己的弹出菜单、我们的音轨/字幕面板、控制栏），这次点击只负责关掉它，不再切换控制栏。
点在盘菜单的按钮上，交给盘处理。
只有点在真正的空白处，才切换悬浮控制栏。
第一期
第 0 步：命中判定探针（先做，决定第 7 项怎么实现）

在 Windows 上用真实的 HDMV 测试盘，实测 libbluray 鼠标选中的返回值，确认能不能区分「点中按钮」和「点在空白」。
能区分：在现有的 disc-navigation-state.patch 里把命中结果透出给 Dart。
不能区分：在 libbluray 的图形控制器里加一个小补丁回报命中结果，三端原生库一起重编。
BD-J 盘拿不到按钮的几何信息，降级方案：点屏幕顶部 10% 的条带、或者双指点击，来呼出控制栏。
把结论写进 spec，再做第 7 项。

#### 第 0 步结论（2026-10-24 实测）：能区分，不改原生

**源码语义**（libbluray 1.5.0，与 Windows 随包 `fbdbluray-4.dll` / MSYS2 `libbluray-4.dll` 同版本）：

- `bd_mouse_select` → HDMV 走 `_run_gc(GC_CTRL_MOUSE_MOVE)` → `graphics_controller.c` 的 `_mouse_move`：
  落在某个可选按钮（SELECTED 态对象）矩形内返回 `1`（`valid_mouse_position = 1`）；
  菜单已绘制但没落在任何按钮上返回 `0`；IG 未绘制（`!gc->ig_drawn`）、按钮动画进行中、页面不存在返回 `-1`。
- `bd_user_input(BD_VK_MOUSE_ACTIVATE)` 在 `valid_mouse_position == 0` 时直接返回 `-1`（`_user_input` 开头），否则按 ENTER 激活。
- BD-J 标题走 `_bdj_event(BDJ_EVENT_MOUSE)`，返回值是 Xlet 监听器的接收与否，**没有按钮几何**。

**现有补丁已经透出**：`disc-navigation-state.patch` 的 `STREAM_NAV_MOUSE_CLICK` 分支把
`bd_mouse_select < 0` 与 `bd_user_input < 0` 都转成 `STREAM_ERROR`，`cmd_discnav` 再转成命令失败
（`MPV_ERROR_COMMAND = -12`）。于是 `discnav mouse-click x y`：点中按钮 = 成功；点空白 = select 得 0、
activate 被拒 = `-12`。Dart 侧 `runVideoDiscInputCommand` 早已把它当「盘未接收」返回 `false`。

**实测**（只读：Python ctypes 直接调 libbluray 与随包 libmpv，盘为 `D:/video/Cosmic Princess Kaguya/Disc 2 - Fushi menu test`，HDMV；Disc 1 是 AACS 加密副本，无 libaacs 时读不出画面，不计入）：

| 层 | 操作 | 结果 |
|---|---|---|
| libbluray 1.5.0 | 菜单出现后 IG 绘制 4 个按钮，矩形 `(294,918) (642,918) (990,918) (1338,918)` 各 292×85 | — |
| libbluray | `bd_mouse_select` 于 (2,2)、(1917,1077)、(2,1077) | `0`、`0`、`0` |
| libbluray | 空白处之后 `bd_user_input(BD_VK_MOUSE_ACTIVATE)` | `-1` |
| libbluray | 按钮中心 (440,960)、(788,960) | `1`；再次同点仍为 `1` |
| libbluray | 按钮上 `BD_VK_MOUSE_ACTIVATE` | `1` |
| libbluray | 1920×1080 按 120 px 网格扫描 | 只有底行按钮带为 `1`，其余全 `0` |
| 随包 libmpv `v0.41.0-1109-g36abaa32d`（`D:/APP/Hibiki/libmpv-2.dll`，只加载不写入、不启动 app） | `discnav mouse-click` 于 (0.001,0.002)、(0.99,0.046)、(0.5,0.5) | `-12`、`-12`、`-12` |
| 随包 libmpv | `discnav mouse-click 0.2292 0.8889`（按钮 1），紧接着点按钮 2 两次 | `0`、`0`、`0` |

**第 7 项按「能区分」实现，不改 `disc-navigation-state.patch`、不 bump 快照版本**：命中结果已经是命令返回值，
再在快照里加字段只会让三端预编译制品（Android / Darwin 的 `provenance.json` 钉了补丁 SHA256、Windows 钉了运行时归档）
全部失配、必须重编，却不带来新信息。Dart 规则（`fushi/lib/src/media/video/disc/disc_session_controls.dart`）：

- 先关浮层（页面浮层 → 控制栏），这一下不再做别的；
- HDMV：把点击交给盘，盘接收 = 点中按钮；未接收时，导航标题在 1..65534（正片上的弹出菜单）→ 发 `popup` 关掉盘的弹出菜单，
  否则（顶层菜单 / first-play）→ 呼出控制栏；点在黑边上直接算空白；
- BD-J（快照 `bdj-detected`）：点击一律交给盘、从不推断空白；屏幕顶部 10% 条带或双指点击呼出控制栏。

**残余歧义（已知、未消除）**：按钮动画进行中（`button_effect_running`）的点击也返回 `-1`，会被当成空白。
本盘实测连续快速点按钮都返回成功，未触发；有按钮动画的盘上可能偶发一次误呼出控制栏（只显示控制栏，不会误操作盘）。
真要消除得给快照加 `pointer-hit`（区分 0 / -1）并三端重编，留给 DVD 补丁那次重编时一起评估。
第 1–10 项

盘规格模型：在引擎侧（packages/fushi_engine/lib/media/video/bluray/ 或同级的 disc 目录）新建 DiscFormat { bluray, uhdBluray, dvd }，用纯路径判据，禁止 import Flutter（纯度守卫）。BD 规格直接从成员路径推，不改 schema。
DVD 识别和导入：扫描器认出 VIDEO_TS，整张盘作为一个合集，盘内 VOB 不再拆成散装条目；按 IFO 的标题表选正片和各集，思路参照 BD 的筛选链。新增 dvd_disc.dart 并配测试。
库页卡片角标：在合集卡和单作品卡的封面左上角显示 BD / UHD / DVD，一个合集里有多张盘时显示 BD ×3。MD3 和 Apple 两套设计系统都要接，样式复用现有 chip。
右键/长按菜单：合集卡菜单的第一项加「进入原盘菜单」，多张盘时展开成选盘子菜单（按盘号或目录名排序）。右键和长按已经共用 ContextMenuTrigger。
详情页主按钮：
原盘合集和原盘作品的主按钮（FAB）改成「播放原盘」，打开菜单；次按钮是「继续观看 xx:xx」或「直接播放正片」。
多张盘时，主按钮打开最近看过的那张，旁边加选盘按钮。
删掉 _buildDiscMenuEntries 那排按钮。
修好 _openRelatedCollection 没传回调的问题，让所有路径进来的详情页都有原盘入口。
菜单开不了时（远端资源、移动端 BD-J、缺组件），主按钮退回普通「播放」，副标题写明原因。
原盘会话：
启动动画：封面从卡片位置放大铺满屏幕，再淡入盘菜单，约 0.8 秒。时长一律取 fushiMotionDuration / FushiMotion，墨水屏和「减弱动态效果」下自动归零。
自动全屏：仅桌面端。进入原盘会话时窗口切到全屏，退出时恢复进入前的窗口状态（最大化、尺寸、位置）。
macOS：改用应用自己的无边框全屏，不用系统原生全屏，否则 Esc 会被系统抢走。
悬浮控制栏：
呼出：点空白（按上面的层级规则）、单按 Esc / Android 返回 / 手柄 B；iOS 左边缘右滑也只呼出控制栏，不直接退出。
退出：控制栏打开时再按一次，退出原盘回到详情页；长按 Esc 或手柄 B 约 1 秒直接退出，按住时显示圆环进度；macOS 上 Cmd+W 直接退出。
鼠标：移到屏幕顶部时也显示控制栏；没有操作 3 秒后自动收起。
栏内功能：顶层菜单、弹出菜单、章节、音轨/字幕、退出全屏、退出原盘。复用 FushiFloatingTopBar 的 adaptiveOverflow（默认全部铺开，放不下才收进「⋯」）。
焦点：遵守 docs/agent/focus-ownership.md。
设置项：在视频设置里加三项，「播放原盘时自动全屏」「原盘启动动画」「原盘默认进入菜单」，默认都开。第三项关掉后，主按钮变回直接播正片。i18n key 一律用 fushi/tool/i18n_sync.dart --add 添加，再跑 dart run slang 并 format。
规格筛选：视频库页的筛选面板在「看完状态」后面加「规格」组：BD 原盘 / UHD BD / DVD / 普通文件，可额外加 4K / HDR（数据来自现有 VideoSpecsService），多选。合集里任意一个成员满足就算命中。分段控件只能用设计系统组件，禁止裸 SegmentedButton。
说明原因的文案：远端资源、移动端 BD-J、缺 BD-J 组件这三种情况都要有明确提示。
第一期验证

定向 widget 测试：角标、菜单项、主按钮切换、相关作品入口；点击层级规则（先关浮层，这一下不切换控制栏）；DVD 盘判据和 IFO 标题选择的单元测试。
Windows 集成测试一律用焦点驱动，禁止坐标点击，走完整条原路径：进菜单 → 呼出控制栏 → 退出 → 窗口恢复。
Android 优先用真机，实测触屏点空白和返回键。
Mac 上实测前，要先在 Mac 上装好 Flutter 3.47.6。
推送前唯一的本地门：在 fushi/ 下跑 dart tool/heavy.dart -- flutter analyze --no-pub。推送后看 PR CI 的结论。
DVD 菜单
按需求方另附的方案执行，本交接文档不做设计。前提是第一期的第 2 项（DVD 识别和导入）已经完成。
第二期：远端原盘（按这个顺序做）

遥控 PC 打开菜单：复用现有遥控通道，手机端按钮显示为「在 PC 上打开」。
下载整张盘到本机：按目录整体传输，复用现有下载队列。
流式播放：
host 端：提供需鉴权、支持 Range 的只读盘目录服务（含 BDMV/，加密盘再带 AACS/），并附一份文件清单。
客户端：在 libmpv 的 stream_bluray.c 补丁里接一层 libbluray 自定义文件访问（读文件走 HTTP Range，列目录用清单），三端原生库重编。
带宽：BD 峰值约 40 Mbps，UHD 可以超过 100 Mbps；局域网可行，公网或 P2P 可能会卡。
缓冲提示：反复缓冲时给出非强制提示（见拍板决策）。
加密盘：客户端也要有 KEYDB。

#### 第二期实现记录（2026-10-24）

**host：只读盘目录共享**（`packages/fushi_engine/lib/media/video/disc/disc_share_manifest.dart`、
`packages/fushi_engine/lib/sync/disc_share_routes.dart`）

- `GET /api/library/videos/<id>/disc`（Basic 鉴权，`<id>` 是盘上任一条标题）签发会话：
  `{token, baseUrl, manifest, titles}`。`titles` 是 host 库里落在这张盘上的行（bookUid + 相对盘根的
  成员路径），供整盘下载落地后认领。
- `GET /api/library/disc/<token>/manifest.json` 与 `/files/<相对路径>` 豁免 Basic（libmpv 里的
  libbluray 发不了 Authorization），门是路径里的不透明 token：空闲 30 分钟作废、签发起 12 小时作废、
  最多 32 个；文件只认清单里列出的路径（白名单），支持 Range，ETag 取当前文件 size/mtime。
- 清单：BD 收 `BDMV/` + `CERTIFICATE/`，**仍有 AACS 密文码流时**才带 `AACS/`（明文副本带着它会让
  client 的 libbluray 去加载 libaacs）；DVD 收 `VIDEO_TS/`；ISO 是单文件。能力位
  `liveLibrary.discShareV1`，host 接口 `VideoDiscShareHost`。

**第 1 项 遥控 PC 打开菜单**：视频遥控 `openVideo` 加 `discMenu: true`；host 快照声明
`openDiscMenu` 才发（老 host 会把标题当普通视频播）。详情页远端原盘多一个「在 PC 上打开」
（`remote_disc_host_open.dart`），host 侧走同一条媒体切换队列进原盘会话
（`video_remote_library_port.dart`）。

**第 2 项 整盘下载**：复用 `InterconnectDownloadManager`（互联下载的那套任务 / 暂停 / 继续 / 取消 /
下载中心），**不是** `video_download_jobs`——后者是 torrent / 直链队列，表结构是磁力与发现身份，
放不进互联整盘任务，硬塞要改 schema。一张盘一个任务（键 `disc:<discKey>`），按清单逐个文件 `.part`
+ 验证器续传，已完整落地的文件跳过；每次起跑重新签发会话（暂停很久后旧 token 已过期），盘身份变了
按失败报。落点 `<documents>/remote_videos/discs/<discKey 前 12 位>/<盘名>`，落地后把 host 的标题行
按同一 bookUid 认领成本机行（成员路径指向本机盘根），合集归属照 host。**限制**：整盘任务没有
续传清单，进程被杀后要用户再点一次下载（已落地的文件不会重下）。

**第 3 项 流式播放**

- libmpv：`disc-navigation-state.patch` 在 v2 上加远端访问（快照仍是 v2）——`bluray-device` 是 URL 时
  用 `bd_open_files()`，每个文件是一个 mpv stream（HTTP Range，走 app 的 `http-proxy` 中继，TLS
  钉扎仍只在 Dart），目录按清单列；`dvd-device` 是 URL 时按块读 DVD 镜像（`dvdnav_open_stream2`）；
  只读属性 `disc-remote-access` 供 app 判断运行时能力。
- **DVD 评估结论**：libdvdnav 7.0 只有 `dvdnav_open_stream`（块级，适合 ISO）；libdvdread 7.1 的
  `DVDOpenFiles` 能读文件夹，但 libdvdnav 没有入口用它，且它明确不支持 CSS。所以远端 DVD **镜像**
  可以流式开菜单，**VIDEO_TS 文件夹**不行（主按钮退回普通播放，写明原因，建议下载）。要支持得给
  libdvdnav 加 `dvdnav_open_files` 补丁，未做。
- 加密盘：client 从共享读 `AACS/Unit_Key_RO.inf`，用**本机** KEYDB 按盘 ID 取 VUK 注册给
  `fushi_aacs`（与本地加密盘同一策略）；`fushi_aacs` 新导出 libaacs 0.11 的
  `aacs_init` / `aacs_set_fopen` / `aacs_open_device`，经 libbluray 的文件层读 AACS 文件——
  `bd_open_files` 打开的盘没有本地路径，旧的 `aacs_open2(path)` 读不到。无钥时打开前报 KEYDB 提示。
  加密远端盘**未用真实加密盘实测**（本机测试盘 Disc 1 无 KEYDB）。
- 会话：`VideoFushiPage.neutralizedRemoteDisc`，标题不绑本机库行、不写进度、不制卡
  （`remote-disc-extraction`）。
- 缓冲提示：起播后 2 分钟内 3 次「播放中 → 缓冲」弹一条可关闭提示（下载到本机 / 不再提示 /
  关闭），一个会话至多一次，绝不切换。

**第 4 项 第一期退回逻辑**：详情页对远端原盘签发一次共享再判：能流式就「播放原盘」；否则主按钮
退回普通播放，副标题给确切原因——对端版本过低（`remoteHostTooOld`）、DVD 文件夹（`remoteDvdFolder`）、
连不上（`remoteUnreachable`）、移动端 BD-J（同本地）、非互联远端源（`remote`）。本机播放组件不支持
（Android / Apple 产物重编前）要会话起来查 `disc-remote-access` 才知道，届时报
`video_disc_menu_unavailable_remote_runtime`。

**实测（Windows，2026-10-24）**：`tool/bluray/build_libmpv.ps1` 编出 `…-dvd1-rdisc1` 运行时并全部验证；
`packages/fushi_engine/tool/disc_share_host_probe.dart` 起真实 `FushiSyncServer` 共享
`Disc 2 - Fushi menu test`（46 个文件 / 7.5 GB），`verify_menu_render.py --remote-disc` 经 loopback HTTP：
18 s 进 HDMV IG 菜单（与本地同），`right` 移到チャプター，right×3 + select×2 进 title 2（00002.mpls）并
实时播放；对照同一动作序列本地与远端状态一致（全編再生的 select 两边都回菜单）。证据在
`.codex-test/remote-disc/`。**未实测**：Fushi app 内端到端（没编 app）、Android / Apple、BD-J 盘、加密盘、
DVD 镜像流式、公网 / P2P 带宽。
不做

在 Android / iOS 上跑 BD-J，只说明原因。
主要风险

第 0 步如果拿不到命中结果，就得给 libbluray 打补丁、三端重编，第一期工期会明显拉长。
BD-J 盘只能用降级的呼出方式。
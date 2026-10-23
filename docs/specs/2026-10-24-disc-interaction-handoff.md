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
不做

在 Android / iOS 上跑 BD-J，只说明原因。
主要风险

第 0 步如果拿不到命中结果，就得给 libbluray 打补丁、三端重编，第一期工期会明显拉长。
BD-J 盘只能用降级的呼出方式。
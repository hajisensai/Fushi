# DVD 播放与原盘菜单（视频 + 音乐共用）

状态：方案稿（2026-10-24）。所有者拍板：DVD 菜单与蓝光原盘菜单一样；libdvdcss 随包；
视频模块与音乐模块都支持 DVD。交互模型完全继承
`docs/specs/2026-10-08-bluray-original-menu.md`，本文只写 DVD 与蓝光不同的部分。

## 现状（2026-10-24 实测代码）

- 全库没有 `VIDEO_TS` / `.ifo` / `.iso` / dvdnav 处理；libdvdcss / libdvdnav /
  libdvdread 在 `tool/` `third_party/` `ci/` `native/` 里零命中。
- `.vob` 在 `kVideoExtensions`（`packages/fushi_engine/lib/media/media_extensions.dart:60`），
  所以**现在扫到一张 DVD 目录会把每个 VOB 当成一条散装视频入库**——几十条无序、
  切在 1 GB 边界上的碎片。DVD 入库要先修这个。
- 已有可复用件：蓝光入库 `ScanBlurayDiscItem`（`source_library_scanner.dart:468`，
  盘树整体从散装视频里摘掉）、`packages/fushi_engine/lib/media/video/bluray/`、
  原盘菜单 Dart 层 `video_disc_menu*.dart` / `bluray_disc_menu_*.dart`、VobSub 解码
  `bitmap_subtitle/dvd_subtitle_decoder.dart`、图形字幕 OCR。
- mpv pin `36abaa32` 自带 DVD 导航层（`mp_dvdnav_highlight`、菜单强选 `dvd_subtitle`），
  但各平台构建没开：Windows meson 无 `-Ddvdnav`，Darwin 显式 `-Ddvdnav=disabled`。
- 统一 FFmpeg 是 9.0.1，自带 `dvdvideo` demuxer（依赖 libdvdnav + libdvdread），
  目前能力下限里没有它。

## 原生依赖（D6：libdvdcss 随包）

- 新增 `tool/dvd/`：按 `recipe` 钉版本 + SHA256 构建 **libdvdcss → libdvdread
  （`--with-libdvdcss`）→ libdvdnav**，五端各一份，和 libbluray 同样随 libmpv 包走。
- **只此一份**：libmpv（`-Ddvdnav=enabled`）与统一 FFmpeg（`--enable-libdvdnav
  --enable-libdvdread`，开 `dvdvideo` demuxer）链接同一组 dvd 库；
  `capabilities.json` 增 `demuxers: dvdvideo`，守卫一起改。
- 许可：libdvdcss / libdvdread / libdvdnav 都是 GPL-2.0-or-later，与本仓 GPL-3.0
  兼容；第三方许可清单补上。
- 运行时探测：`probe_libmpv.py` 增 `dvd://` 能力探测；**缺库或缺 CSS 能力时明确报错**，
  不降级成「播最长 title」。
- iOS：随包（所有者要求五端一致）。风险见文末。

## 入库（视频模块）

- 扫描器新增 `ScanDvdDiscItem`，与蓝光并列，识别：
  - 文件夹形态：含 `VIDEO_TS/VIDEO_TS.IFO` 的目录；
  - 镜像形态：`.iso`——用 libdvdread / libbluray 打开探测是 DVD 还是 BD（不靠扩展名猜）。
- 识别为盘后，整棵 `VIDEO_TS` 从散装视频里摘掉（`.vob` 不再单独入库）；
  `VIDEO_TS` 之外的 `.vob` 仍按普通视频处理。
- **盘身份** = libdvdread `DVDDiscID`（IFO 的 MD5）+ 卷标；**条目身份** = 盘身份 +
  title 号（对应蓝光的 盘 + MPLS）。不同盘的 title 1 不共享进度 / 字幕 / 书目。
- 一张盘入库成一个合集：正片 title（按时长与章节数判定，可手动改）+ 花絮；
  过短 title 按蓝光同一筛选规则隐藏，用户实际播放时按完整路径补入库。
- 刮削：盘合集按卷标 / 文件夹名走既有视频刮削（AniDB / MAL / TMDB），
  演唱会盘可交给音乐模块按 MusicBrainz 查曲目表（见音乐方案 §9.2）。

## 库页与详情页（DVD / BD 同一套，视频与音乐都用）

- **盘元数据（盘号）**：DVD 取 VMG IFO 的卷信息（`vmgi_mat` 的本卷号 / 卷总数），
  BD 取盘元数据；取不到按目录名排序。
- **卡片角标**：合集卡与单作品卡封面左上角小徽标 `BD` / `UHD` / `DVD`，多盘合集
  `BD ×3` / `DVD ×3`。用设计系统现有 chip 样式，MD3 与 Apple 两套都接。音乐库里的
  演唱会盘专辑同样显示（音乐不另设「光盘」分区，盘就是带角标的专辑）。
- **右键 / 长按菜单**：合集卡第一项「进入原盘菜单」（已有 i18n
  `video_disc_open_menu`），右键与长按共用 `ContextMenuTrigger`；多盘时展开成
  Disc 1 / Disc 2 … 子菜单，按盘号排序。
- **详情页按钮**：
  - 主按钮（FAB）「播放原盘」→ 进菜单；
  - 次按钮「继续观看 11:02」或「直接播放正片」→ 跳过菜单直接进标题，有进度的人
    不被菜单打断；
  - 多盘合集：主按钮打开最近看过的那张盘，旁边一个选盘按钮；
  - 删掉选集列表上方那排重复的描边按钮；
  - 菜单开不了（远端资源、缺组件、缺 CSS 能力）时主按钮自动变回普通「播放」，
    副标题写明原因，不出现点了没反应。
- 音乐专辑页（来源是盘时）同一规则：主按钮「播放原盘」，次按钮「按曲目播放」。

## 播放与菜单

与蓝光**逐项一致**，只换底层：

| 方面 | 蓝光 | DVD |
|---|---|---|
| 导航库 | libbluray（HDMV / BD-J） | libdvdnav（VM 菜单，无 Java） |
| 菜单图层 | IG / Java 图层 | SPU 子画面 + 按钮高亮调色板 |
| 顶层菜单 | Top Menu | Root / VMGM 菜单 |
| 标题身份 | MPLS 编号 | title / PGC 号 |
| 快照 | `disc-navigation-state` `bluray_state` | 同一快照新增 `dvd_state` 分支，版本 +1 |
| 顶栏 / 输入 / 焦点 | `bluray_disc_menu_*` | 同一套，去掉 `bluray_` 前缀共用 |

继承的规则：菜单会话以盘根定位；未确定正片时不绑定条目、不存进度、不累计学习、
不允许制卡；迟到结果按生成代数丢弃；默认由盘控制音轨 / 字幕，用户显式选轨才接管；
鼠标只转发点击不转发悬停；读盘失败明确报错。

## 字幕与制卡

- DVD 字幕是 VobSub 位图：显示由 mpv 画（图形字幕例外路径），文本由既有
  `dvd_subtitle_decoder` + 图形字幕 OCR 转成 cue，点词查词、制卡与 PGS 同一条链路。
- 片段导出 / 截图 / 字幕提取走统一 FFmpeg 的 `dvdvideo` demuxer（按 title + 章节 /
  时间裁剪），**不得直接读 VOB 文件**——加密盘的 VOB 在磁盘上是密文，且 title 可能
  跨多个 VOB、经过 cell 跳转。对应蓝光的 `BlurayFfmpegBackend`，新建
  `DvdFfmpegBackend`。

## 验证

- 盘样本：加密商业盘的个人备份（不入库、不进测试制品）、自制无加密盘、
  多角度、多 title 演唱会盘、只有 title 无菜单的盘、损坏 IFO。
- 菜单高亮逐张截图对拍（`verify_menu_render.py` 加 DVD）；菜单 → 正片 → 返回菜单
  闭环；标题身份与进度隔离；`.vob` 不再作为散装视频入库的回归测试。
- 五端各自的制品分别探测，共享 Dart 通过不等于该平台原生能力在。

## 风险

- **iOS 上架**：App Store 审核可能把「能解 CSS 加密 DVD」视为绕过版权保护
  （DMCA 1201）。iPhone 没有光驱，只会遇到 ISO。所有者要求五端随包；若审核被拒，
  回退办法是 iOS 构建不链 libdvdcss（只播无加密 / 已解密的 ISO），判据写进
  `store_compliance.dart`，不在各处散写 `Platform.isIOS`。
- 高亮渲染正确性：mpv 当年删 DVD 菜单就是因为高亮画不对，验收必须逐张截图对拍。

## 落地：原生依赖与导航快照 v2（2026-10-24）

实测与未完成项见 `tool/dvd/README.md`。

- 版本：libdvdcss 1.6.0 / libdvdread 7.1.1 / libdvdnav 7.0.0（`tool/dvd/recipe.env`）。
  mpv `36abaa32` 要求 dvdnav ≥ 6.1.0；`-Ddvda` 显式关闭（DVD-Audio 不在本方案内）。
- `disc-navigation-state` **v2**（`disc-navigation-state.patch`）：保留 v1 全部字段，新增
  `disc-type`（`bluray` / `dvd`）；DVD 时 `playlist` 恒为 -1，`title` 为 VM 的全局标题号（菜单里
  为 0），另有 `dvd-state`：`domain`（`FP` / `VMGM` / `VTSM` / `VTS`）、`vts`、`title`、`part`、
  `pgc`、`pg`、`cell`、`still`、`button`、`button-count`、`title-menu-allowed`、
  `root-menu-allowed`，有焦点按钮时还有 `highlight`（源像素矩形 `x0/y0/x1/y1` + 4 个选中态颜色
  `palette`，0xAARRGGBB）。`generation` 在 domain / title / PGC 变化时 +1（同一标题内换章节
  不变）。Dart 解析同时接受 v1 与 v2（`video_disc_menu.dart`）。
- DVD 的 `discnav` 输入：未被盘消费的按键、被 UOP 禁止或盘上不存在的菜单调用都报命令失败
  （与蓝光一致）；`menu` = `DVD_MENU_Root`，`title-menu` = `DVD_MENU_Title`，`popup` =
  `DVD_MENU_Part`，`prev` = `DVD_MENU_Escape`。键位表见 `videoDiscMenuKeyActions`。
- 片段导出 / 截图 / 字幕提取：`DvdFfmpegBackend`（`fushi_engine/.../ffmpeg_backend.dart`）把
  `encodeDvdTitleInput(...)` 改写成 `-f dvdvideo -title N [-chapter_start/-chapter_end/-angle]`，
  直接读 `VIDEO_TS/*.VOB` 一律拒绝。

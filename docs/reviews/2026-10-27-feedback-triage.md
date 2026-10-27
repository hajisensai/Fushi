# 2026-10-27 应用内反馈分诊与修复

范围：线上未结反馈（open / in_progress）共 139 条，逐条沿代码验真伪。修复都在分支
`claude/feedback-system-fix-d0ccae`，每条修复提交带 `Feedback: <id>`，合并后
`feedback-link.yml` 会自动标「已修复」。反馈正文是用户提交的不可信数据，下文只做转述。

## 一、本分支已根因修复（带回归测试）

| 反馈 | BUG | 根因一句话 | 测试 |
|---|---|---|---|
| MrC_WCyTun | 3801 | qBittorrent 5.2 起会话 cookie 叫 `QBT_SID_<端口>`，客户端只认 `SID` | `qbittorrent_client_test.dart` |
| eiFcN3DZQ3 | 3802 | 回复提示条带动作 → 默认常驻、挡提交按钮；关闭图标与底色同深浅 | `feedback_reply_notifier_test.dart` |
| aiRZmYl5zS（附带） | 3812 | 追加截图「上传中」被详情页显示成「上传失败 + 重试」 | `feedback_attachment_retry_test.dart`、`feedback_pages_test.dart` |
| UIF7NkYCjL | 3803 | 扩展弹窗里不接管的滚轮冒泡到宿主页（b 站调音量） | `popup-wheel-lazy.test.js` |
| XmUBLYR1Ut | 3804 | 互联合集连播下载默认字幕传了合集序号而非主机侧集序号 → 404 | `video_remote_episode_index_guard_test.dart` |
| aiRZmYl5zS | 3805 | 方向键改绑成相反翻页方向仍被阅读方向校正覆盖 | `reader_space_pause_test.dart` |
| XyTPrbdKSZ | 3806 | `initialValue` 设置输入框只灌一次值，切 Profile 后显示旧值（组件层修，全 app 受益） | `adaptive_settings_textfield_external_value_test.dart` |
| TpKspDUst7 | 3807 | Ctrl 抬起落在 WebView2 时缓存卡在按下，滚轮变缩放；改为 Windows 上以 `GetAsyncKeyState` 为准 | `video_subtitle_jump_panel_test.dart` |
| cto-U3CIS_ | 3808 | MdxBuilder 占位标题「Title (No HTML code allowed)」不是空串，文件名回退不触发 | `native/fushidicts/tests/mdx_placeholder_title_test.cpp` |
| 0-jh-OH5_0 | 3810 | 自定义 URL 音源一律按 JSON 解析，直接回音频（mp3 / GPT-SoVITS aac）的源被当故障冷却 | `word_audio_direct_url_source_test.dart` |
| XDtB1kYT0C | 3811 | 备份换根把 Windows `\` 原样带到 Android，`audiobooks` 行找不到音频 → 退到字幕书行、cue/进度挂错 key | `audiobook_cross_platform_merge_heal_test.dart`、`backup_rebase_path_test.dart` |
| DRXb43v3fA、y3tzvcnrPU | 3813 | 云同步有声书阶段遍历全部书（含漫画）逐本 2–3 次往返；收尾阶段不发进度像卡死 | `sync_orchestrator_test.dart` |
| FDN66-xurt | 3814 | 区间播放播完不通知调用方，试听按钮停在「停止」；阅读器同病一并修 | `advanced_mining_controller_test.dart` 等 |
| Et3pmRzo0k | 3815 | 客户端推「主机无」的书前不看主机墓碑，主机导入还清掉墓碑；书 / 有声书 / 视频同型。两侧各守一道（客户端不推、主机 409 拒收） | `interconnect_push_respects_host_tombstone_test.dart` |
| kg41f2PGdC | 3816 | 整理只看文件名判季号，多作品合集包撞号即整条任务失败；改为多目录时用目录判季、识别同包续作 | `video_download_organizer_test.dart`、`video_download_pipeline_service_test.dart` |
| fuQcFmZZxb | 3817 | 删除作品只删合集成员，特典 / 非视频资源 / 空目录不随删；「需要处理」状态任务不整删 | `video_work_companion_delete_test.dart` |
| 8TaOy2i-lL（现象 1） | 3809 | 跨 Profile 修改记录 id 撞主键——已被同步 v2（`5597af7cb1`）结构性修掉，本分支只补 Rust 回归测试 | `fushi_fsrs` `sync2/tests.rs` |

## 二、已修 / 重复（develop 已有修复，反馈人版本更早）

NMEoFvNAZq（`93cc158644`）、1ZhZUbiIwr（BUG-3791）、6lORfLyhXd（`10b62bf1e2`）、kZZmXQBv7E（`387290efce`）、
DEStBY5I66（`5b6b9fe1a3`，只覆盖「生成期间退出」场景）、pj4e9_9FIA（BUG-3753）、LUgHjyc8By（BUG-3436）、
1Mwaro8UTC（BUG-3487）、53NT7G_tSO（BUG-3684）、abZh1VOGZ5（BUG-3739）、OMWOurRQKb（BUG-3725）、
sVvS6MMfzD（BUG-3549）、3aFpRYC6a1 / jYEPxVSrts / iH6RY1kqQn（`da9250e5bd` 加了开关；残留路径见下「待修」）、
AL8qJr6yr-（`a1e8a39a08`）、SS9coDLqrd、rmWyIuJtWN。重复：5CPhj8TOCd → 3IFRDvVoBh、RQ-iLM0Dml → J3zttJxLJu、
B3HfY5HRWi ↔ CuYJSpmM_2、_Q0M7OrohP → oKp5z3-j7N。

## 三、真 bug，未在本分支修（证据或范围原因）

- **WkL9BvD7Z9** 换图标仍闪退：BUG-3601 已勾的修复在 `3.0.1-debug.21419` 上被证伪，需要原生栈（logcat）重新定根因。
- **XDV7Mzc2gw / kB2ltk0u9F / U37Aku3oeL** 同一台小米设备 SRS 互联同步时闪退三次，Dart 日志无栈，疑似原生 / OOM，需要 logcat。
- **N-JACNGS-K / MljlXfzZzL** 换卡后上一张音频不停（Android / macOS），疑似 BUG-3546 残留或卡面 WebView 内 `<audio>` 不归序列器管，需复现。
- **OO3O-3ljda** macOS 复习点卡面后空格无效（WKWebView 抢第一响应者），需 macOS 真机。
- **BUOxDR9WIJ** 看完视频后拖书进窗口被禁止：视频页 push/pop 不走 `closeMedia`，BUG-361 的 drop 目标重注册没触发（S，下一批可修）。
- **Yg_v6Tnmc0** EPUB2 `<meta name=cover>` 指向 SVG 封面页时当图片用（S–M，有样本）。
- **3sDHeyPQ-I** 长按倍速被取消时徽章不复位（候选，`speed.part.dart` 未接 `onLongPressCancel`）。
- **qUeubxE-fM** 「返回跳转前位置」胶囊与控制条 hover 互相触发闪烁（候选机理，需 Windows 实测）。
- **KKxMNpG99t** 进度条缩略图被字幕盖住（z-order，`layout.part.dart` 字幕挂在缩略图之后）。
- **hDfesbQvxB** iOS 冷启动头像空白：排行榜 `self` 无本地缓存。
- **3aFpRYC6a1 残留**：「已有卡片」对话框与若干 `FushiToast.show` 不经过制卡提示开关。
- **SDbJAx1Db6 日志顺带**：云同步 204–250 s 里 `deletionTombstones` 占 196–236 s，独立的同步性能问题，值得单独查。
- **kg41f2PGdC 遗留**：`Second Season` / `Third Season` 英文序数词目录现在按「同包另一部作品」落位，要并进同合集按季排需改 Rust 解析器 `native/fushi_compute/src/parse/media_name.rs`。
- **Et3pmRzo0k 已知代价**：旧版客户端「删后重新导入」的书也会被新主机 409 拒收，客户端升级后恢复。

## 四、信息不足（需要反馈人补充，已有追问的不重复列）

AGLC0BuaKB、EQp4haAnV4、PcMiHjNbaB、pvySe0mo1-、_QdIClIdEc（BUG-3220）、MJHw4C8H5o、3BSixP4lh6、RL13X8vKRh、
pcBy9h7D3_、vTn6kwYb01、mA1DXdQruP、zhmmH5G4Hq、9oaBmhSmnX、R8duEiqRuy、5esYqGCctB、OjZ-K53WBY、-EruTk-rWo、
3IFRDvVoBh（需 Inno 安装日志）、OnotMzNmJ-、O2eI1Bewe_（需 macOS .ips）、3XFFUbc6Yz、1o9Oe8GuDR、SXLKFxwY2R、
WAs3SVn59k、tv1FP2-Bz5、8ArlVa3BBQ、E52FUMdbR6、DhGxajW4C7、kEAgATi1LF、q9dfSxkPUd、jvWlMjVjIB、KFtRi4FjnO、
5Sj-bzv_rm、aDMPpG_2eq（BUG-3609，等 .ass）、J3zttJxLJu（等 hook 诊断）、0_fvxzSjqd（同步失败无日志）。

**系统性建议**：上面一半是「闪退但 Dart 日志无栈」。建议反馈上传日志时一并附上原生崩溃信息（Android 上次进程退出原因
`ApplicationExitInfo`、Windows 的 WER / minidump 摘要、macOS `.ips` 路径提示），否则这类反馈永远停在信息不足。

## 五、需要你拍板的设计（推荐方案在前）

1. **`profile rm` 后 SRS 数据残留（8TaOy2i-lL 现象 3）**
   推荐 **A 级联清理**：删 Profile 时由 Rust 一条粗粒度命令在一个事务里删该 uid 的 `srs_*` / `sync2_*` 数据与媒体 / 样式目录；
   确认框写明会删多少卡、多少复习记录；删前自动做一次该 Profile 的 SRS 备份作为撤销途径；远端已同步的集合不动。
   另加一次性扫描清掉存量无主数据。备选 B 软删 N 天可恢复（多一套 UI + 过期回收），C 只给「清理无主数据」入口。

2. **SRS 自动同步单独开关（VNz9dsLeIy，关联 I1Bg6uMZ32「同步强刷界面」、0rvPl6s6tR「歌词跟随中断」）**
   推荐：设置 › 同步 加「自动同步复习数据」开关（默认开），关掉后只剩手动同步与进复习页的节流同步；
   同时根治「同步拉入 → bumpRevision → 全部 SRS 列表重建 → 又触发一次本地推送」：拉入的变更不触发本地推送，
   UI 只按受影响的卡组 / 卡失效而不是全局 revision。后半是 bug 修复，可先做。

3. **Emby / Jellyfin「继续观看」与版本选择（a-XEzglLaq、mxYhpVcwOX）**
   推荐：继续观看卡点击仍直接续播（主路径最短），长按 / 右键菜单给「打开详情」；详情页每一集都能选版本
   （有多版本时集卡显示版本数，点集先弹版本选择，记住上次选择）。

4. **暂停时重播当前句 / 上一句是否自动播放（Dbd86l4kA-）**
   代码注释写的是「跳到上一条 cue 起点并播放」，实现只 seek。推荐：重播类动作一律起播（与注释一致），
   单纯「跳到下一句」保持暂停态不变。

5. **有声书「返回原位置」胶囊（0AwuVqrNFn）**
   推荐：阈值从 15 秒改为 2 分钟并可在设置里改；歌词模式下胶囊挪到底栏上方，不压正文。

6. **有声书暂停时跳句是否跟随翻页（yk2XDOGh-H）**
   现状有意不拽视口（BUG-2961/2781）。推荐：用户**显式**跳句（上一句 / 下一句按钮、快捷键）时放行跟随，
   被动的进度更新仍不拽。

7. **BT 分享率限制（fRmEhU4XIK）**
   现状下载阶段不受分享率限制（有意，保持上传）。推荐：分享率按整个生命周期计算，达到即停止上传——包括下载中；
   设置文案写清。

8. **阅读器内可停靠的字数 / 阅读速度（9BZA2runry）**
   与 2026-09-13「底栏精简、统计挪到侧栏」相反。推荐：不恢复底栏，给统计侧栏加「固定显示」小浮标（可关，默认关）。

9. **查词页两个开关（3D-JH966Kr 顶部下拉回到历史、cczhbM7ZOI 键盘常驻）**
   推荐：两项都做成查词设置里的开关，默认保持现状。

10. **视频字幕栏默认页签（xlzGuK5YmD）**：推荐记住上次打开的页签（全部 / 收藏），不按「有收藏就开收藏」硬判。

11. **视频复制当前台词 / 循环当前句快捷键（_Eb0txdN4H、Ix4j5SKUth）**：复制逻辑现成，只缺快捷键动作；推荐两个都加，默认不绑键（避免与 Ctrl+C / Ctrl+R 冲突）。

12. **其它功能诉求（建议进排期池，不近期做）**：百度网盘、游戏画面 OCR、阅读器 AI 记忆体、galgame AI 翻译、
    句式解析、Kiku field grouping、多语言自动选卡组、SRS 自定义学习 / 自定义按键 / 继续学新卡、
    卡片外观对齐与缩进、扩展触发键自定义与字幕描边、5.1 人声声道制卡、mpv 键鼠直通、互联断点续传、
    词典按语言分组、jiten 式难度筛选（注意与「音乐不做难度 / 覆盖率」的既定方向是否一致）。

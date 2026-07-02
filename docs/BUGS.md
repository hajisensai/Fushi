# Bug 跟踪

> 约定（Claude/Codex 必须遵守）：用户报一个 bug → **先沿真实代码路径验真伪**（复现或定位根因）。
>
> **数据结构：一 bug 一文件。** 每条 bug 是 `docs/bugs/BUG-NNN[-slug].md` 一个独立文件；
> 本文件（`docs/BUGS.md`）只是「头部约定 + 自动生成的索引表」，索引区**勿手改**。
> 这样并发 agent 各写各的文件，永不在同一处产生 git 冲突；撞号也只是两个不同文件名，
> 改个名即可，不再有冲突标记手术。
>
> 新建一条：`dart run tool/bug.dart new <slug> [标题...]`（自动取下一个空号、生成骨架、重建索引）。
> 改完某条 bug 文件后：`dart run tool/bug.dart reindex` 重建下面的索引表。
>
> 每条 bug 文件里：
> - **是真 bug** → 记报告日期、根因 `file:line`，然后：
>   - **① 修复**（根因修，不补丁），完成后把 `[ ] ①` 改成 `[x] ①`，记提交哈希。
>   - **② 增加自动化测试**（最强可落地层：真 widget 行为 / CSS 生成器 / 源码扫描守卫；
>     纯视觉像素只能设备截图兜底并注明），完成后把 `[ ] ②` 改成 `[x] ②`，记测试文件。
> - **不是真 bug / 无法复现** → 也建一条，标「未复现」并说明，不勾 ① ②。
> - reader/WebView/导入/播放/布局类修复：代码正确 + 单测无回归后，仍需**设备肉眼复测原始失败路径**
>   （CLAUDE.md 验证纪律）；未做的在「备注」标注待补。
>
> 分层测试选型见 [docs/specs/2026-06-03-test-flow-refactor-*.md] 与各守卫测试范式
> （源码扫描：`test/pages/reader_paginate_lyrics_guard_static_test.dart` 的 `_functionSource`；
> CSS 生成器：`test/reader/reader_content_styles_test.dart`；widget 行为：`test/settings/`）。

---

<!-- BUGS-INDEX:BEGIN（自动生成，勿手改；改完跑 `dart run tool/bug.dart reindex`）-->

> 共 517 条。点号进各自文件。

| BUG | 修复 | 测试 | 标题 |
|---|:--:|:--:|---|
| [BUG-531](bugs/BUG-531-ios-image-picker-usage-desc.md) | ✅ | ✅ | iOS 制卡取图缺 Info.plist 权限键硬崩 |
| [BUG-530](bugs/BUG-530-netflix-extension-wrong-server.md) | ✅ | ✅ | 网飞扩展查词/制卡断: 扩展指向 yomitan server(19633) 但端点只在 sync server |
| [BUG-529](bugs/BUG-529-ffmpeg-url-input-exists-guard.md) | ✅ | ✅ | 制卡 ffmpeg 抽取器 existsSync 守卫拦 http(s) 流 URL + 无网络韧性致 GIF 间歇失败 |
| [BUG-528](bugs/BUG-528-youtube-stream-403-caption-resolve.md) | ✅ | ✅ | 油管播放/制卡: 默认 client 流 URL 403 + 字幕接口空 body 炸掉整个 resolve + 防盗链 header 迟发致黑屏 |
| [BUG-527](bugs/BUG-527-macos-data-root-restart-sandbox-crash.md) | ✅ | ✅ | macOS 数据迁移后自动重启崩溃 |
| [BUG-526](bugs/BUG-526-dictionary-download-catalog-stale.md) | ✅ | ✅ | 推荐词典下载链接失效 |
| [BUG-525](bugs/BUG-525-settings-log-count-stale.md) | ✅ | ✅ | 清除日志后系统页计数不刷新 |
| [BUG-524](bugs/BUG-524-audiobook-exit-overlay-layout.md) | ✅ | ✅ | Audiobook退出快捷设置后红屏 |
| [BUG-523](bugs/BUG-523-lookup-window-white-empty.md) | ✅ | ✅ | 查词窗白色无内容 |
| [BUG-522](bugs/BUG-522-backup-export-null-save-success.md) | ✅ | ✅ | 备份导出未选择位置也提示成功 |
| [BUG-521](bugs/BUG-521-macos-file-picker-entitlements.md) | ✅ | ✅ | macOS 文件选择器不弹出 |
| [BUG-520](bugs/BUG-520-popup-div-inline-linebreak-regression.md) | ✅ | ✅ | 查词弹窗分行全坏+图标重合（BUG-478一刀切display:inline回归） |
| [BUG-519](bugs/BUG-519-shelf-srt-edit-title.md) | ✅ | ✅ | 书架编辑 SRT 书名不生效 + 长按无封面 |
| [BUG-518](bugs/BUG-518-global-lookup-hotkey-unregister.md) | ✅ | ✅ | Windows 应用外全局查词唤不出来（热键被全局 unregisterAll 误伤） |
| [BUG-517](bugs/BUG-517-updates-installer-not-recycled.md) | ✅ | ✅ | 更新安装包安装成功后未回收 |
| [BUG-516](bugs/BUG-516-vn-mode-mask-tiny-image.md) | ✅ | ✅ | VN模式常驻遮罩且图片极小 |
| [BUG-515](bugs/BUG-515-media-sources-rescan-scope.md) | ✅ | ✅ | 媒体来源重扫跨async读已销毁ProviderScope崩溃 |
| [BUG-514](bugs/BUG-514-error-log-noise.md) | ✅ | ✅ | 报错日志混入更新镜像失败与WGC取证噪声 |
| [BUG-513](bugs/BUG-513-cover-runtime-disappear.md) | ✅ | ✅ | 封面运行期探测竞态消失重启恢复 |
| [BUG-512](bugs/BUG-512-media-binding-missing-video.md) | ✅ | ✅ | TODO-1063 配置方案「媒体类型绑定」缺少 video 选项（视频毕业后未补齐） |
| [BUG-511](bugs/BUG-511-global-hotkey-config.md) | ✅ | ✅ | TODO-1066 app 外查词（桌面全局查词）的快捷键没办法设置 |
| [BUG-510](bugs/BUG-510-dict-autoupdate-gate.md) | ✅ | ✅ | TODO-1075 词典自动更新 isUpdatable gate 在 catalog 导入路径恒空档 |
| [BUG-509](bugs/BUG-509-floating-lyric-first-cue.md) | ✅ | ✅ | TODO-1065 悬浮字幕首句空窗 / 每句要等上一句播完才出现 |
| [BUG-508](bugs/BUG-508-desktop-overlay-nested-popup.md) | ✅ | ✅ | 桌面app外全局查词覆盖窗嵌套弹窗:缺关闭X/不能滑关/点父不关子/子弹窗闪烁/点第一层关全部 |
| [BUG-507](bugs/BUG-507-mobile-popup-washout.md) | ✅ | ✅ | TODO-1065 悬浮字幕查词弹窗<html>不透明泛白 |
| [BUG-506](bugs/BUG-506-video-controls-autohide-button-misclick.md) | ✅ | ✅ | TODO-1059 菜单播放按钮时自动隐藏误触 |
| [BUG-505](bugs/BUG-505-subtitle-bg-light-theme-washout.md) | ✅ | ✅ | TODO-1059 字幕背景浅色泛白+缺调节控件 |
| [BUG-504](bugs/BUG-504-debug-rolling-prerelease.md) | ✅ | ✅ | TODO-1049 debug版滚动prerelease不占Release位 |
| [BUG-503](bugs/BUG-503-win-global-lookup-popup-flaky.md) | ✅ | ✅ | TODO-1079 win外查词弹窗偶发不出 |
| [BUG-502](bugs/BUG-502-space-scroll-not-audiobook-pause.md) | ✅ | ✅ | TODO-1078 空格滚动而非暂停有声书 |
| [BUG-501](bugs/BUG-501-image-chapter-load-blocking.md) | ✅ | ✅ | TODO-1074 图片章加载慢 |
| [BUG-500](bugs/BUG-500-profile-dict-metadata-not-followed.md) | ✅ | ✅ | TODO-1077 切换Profile词典设置不跟随 |
| [BUG-499](bugs/BUG-499-srt-floating-lyric-menu.md) | ✅ | ✅ | SRT/有声书卡长按缺悬浮字幕菜单项 |
| [BUG-498](bugs/BUG-498-video-tap-bottom-deadzone.md) | ✅ | ✅ | video: bottom/bottom-right tap cannot toggle controls (TODO-1073) |
| [BUG-497](bugs/BUG-497-floating-lyric-hint-vague.md) | ✅ | ✅ | 悬浮字幕设置描述文案含糊 |
| [BUG-496](bugs/BUG-496-floating-lyric-toggle-inverted.md) | ✅ | ✅ | 悬浮字幕总开关不即时且与书内翻转显隐反相 |
| [BUG-495](bugs/BUG-495-floating-lyric-fontsize-live.md) | ✅ | ✅ | 悬浮字幕字号改值不即时生效 |
| [BUG-494](bugs/BUG-494-favorite-phantom-identity-collapse.md) | ✅ | ✅ | 收藏身份键坍缩致幻影收藏未收藏句被点亮 |
| [BUG-493](bugs/BUG-493-favorite-progress-hidden-reanchor.md) | ✅ | ✅ | 重锚时序竞态致进度概率不显示查词100%逼出 |
| [BUG-492](bugs/BUG-492-favorite-wrong-section.md) | ✅ | ✅ | 收藏/制卡写错 sectionIndex 致跳错章看不到收藏句 |
| [BUG-491](bugs/BUG-491-shelf-gamepad-nav.md) | ✅ | ✅ | 首页手柄方向键选不中书籍且右跳越过导入图标 |
| [BUG-490](bugs/BUG-490-clip-text-render-null.md) | ✅ | ✅ | 有声书剪辑导出renderAudiobookClipTextToPng返null |
| [BUG-489](bugs/BUG-489-audio-source-failure-cooldown.md) | ✅ | ✅ | 查词发音死源无冷却导致刷屏与串行拖累 |
| [BUG-488](bugs/BUG-488-toc-chapter-name-wrap.md) | ✅ | ✅ | 手机端TOC章节名被截断不换行 |
| [BUG-487](bugs/BUG-487-imageonly-chapter-skip.md) | ✅ | ✅ | 有声书跨章跳过纯图片章节,图片等待对独立成章的图片页失效 |
| [BUG-486](bugs/BUG-486-cover-race.md) | ✅ | ✅ | 导入有声书封面竞态被吞 (m4b 内嵌封面异步抽取未 await) |
| [BUG-485](bugs/BUG-485-local-audio-reference-path.md) | ✅ | ✅ | 添加本地音频库被复制到C盘，应支持引用原路径 |
| [BUG-484](bugs/BUG-484-handoff-success-idempotent.md) | ✅ | ✅ | Windows 每次启动弹出已更新至 xxx 对话框 |
| [BUG-483](bugs/BUG-483-audio-folder-sort.md) | ✅ | ✅ | 有声书整文件夹导入音频排序乱(全角/汉数字/零填充) |
| [BUG-482](bugs/BUG-482-popup-close-blocks-continuous-lookup.md) | ✅ | ✅ | 查词框关闭逻辑堵塞连续查词 |
| [BUG-481](bugs/BUG-481-dblclick-native-select-hijack.md) | ✅ | ✅ | 阅读器双击原生框选打扰查词 |
| [BUG-480](bugs/BUG-480-update-channel-mixing.md) | ✅ | ✅ | 更新渠道混推：稳定版收到调试/测试版同基版本推送 + 同基跨通道未当成同版本 |
| [BUG-479](bugs/BUG-479-update-check-cache.md) | ✅ | ✅ | 更新检查时快时慢=无结果缓存每次冷查 GitHub（TODO-1024） |
| [BUG-478](bugs/BUG-478-popup-quote-misplace-non-anchor.md) | ✅ | ✅ | 查词弹窗明鏡补足行开引号被inline float/position推到右上角错位(BUG-435同根·非<a>元素未覆盖回归) |
| [BUG-477](bugs/BUG-477-popup-webview-double-context-menu.md) | ✅ | ✅ | 查词弹窗右键同时弹WebView2原生菜单与自定义菜单(双菜单·BUG-468同根·弹窗WebView漏修) |
| [BUG-476](bugs/BUG-476-restart-cold-start-black-window.md) | ✅ | ✅ | 迁移重启新进程冷启动黑屏 |
| [BUG-475](bugs/BUG-475-export-crosschapter-false-positive.md) | ✅ | ✅ | 选区导出误报跨章 |
| [BUG-474](bugs/BUG-474-ankidroid-svg-fileprovider-root.md) | ✅ | ✅ | AnkiDroid外字SVG制卡FileProvider找不到根 |
| [BUG-473](bugs/BUG-473-updates-cache-not-cleaned.md) | ✅ | ✅ | 更新包缓存不清理 |
| [BUG-472](bugs/BUG-472-audiobook-clip-export-silent.md) | ✅ | ✅ | 有声书片段导出失败且无任何错误日志 |
| [BUG-471](bugs/BUG-471-audiobook-progress-lan-sync-missing.md) | ✅ | ✅ | 有声书互联(LAN)进度同步缺失 |
| [BUG-470](bugs/BUG-470-reader-top-progress-first-load-gap.md) | ✅ | ✅ | 首屏顶部进度 inset 缺口（正文首行被进度条压住） |
| [BUG-469](bugs/BUG-469-collection-date-hidden.md) | ✅ | ✅ | 窄屏收藏列表收藏日期被书名/章节挤出可见区看不见 |
| [BUG-468](bugs/BUG-468-double-context-menu.md) | ✅ | ✅ | Windows 阅读器右键同时弹原生与自定义两个菜单 |
| [BUG-467](bugs/BUG-467-vertical-text-bottom-overflow.md) | ✅ | ✅ | 竖排正文文字溢出到底栏区域 |
| [BUG-466](bugs/BUG-466-scroll-arrow-remap.md) | ✅ | ✅ | 滚动模式方向键改绑有声书句子无效仍翻页 |
| [BUG-465](bugs/BUG-465-android-video-flash-blank.md) | ✅ | ✅ | Android video flashes then shows blank (no picture) |
| [BUG-464](bugs/BUG-464-audio-highlight-theme-coupling.md) | ✅ | ✅ | 音频高亮颜色只在自定义主题生效·非自定义主题恒用主色 |
| [BUG-463](bugs/BUG-463-video-topbar-covered.md) | ✅ | ✅ | 视频播放页顶栏按钮被状态栏/刘海遮挡 |
| [BUG-462](bugs/BUG-462-favorite-words-missing-in-collections.md) | ✅ | ✅ | 收藏的单词不在收藏列表显示 |
| [BUG-461](bugs/BUG-461-favorite-sentence-jump-page-boundary.md) | ✅ | ✅ | 收藏句跳转整句显示不全（「五五开」切句尾）——根因在「滚动(连续)模式」，非分页边界 |
| [BUG-460](bugs/BUG-460-ffmpeg-clip-muxer.md) | ✅ | ✅ | 有声书片段导出 ffmpeg exit -22（捆绑 ffmpeg 缺 mov/m4a muxer） |
| [BUG-459](bugs/BUG-459-favorite-jump-char-anchor.md) | ✅ | ✅ | 收藏句/制卡历史跳原文跳错位置(恒跳章首)+跳后阅读进度丢失 |
| [BUG-458](bugs/BUG-458-gap-word-sentence-audio-residue.md) | ✅ | ✅ | 句子音频gap词残留 |
| [BUG-457](bugs/BUG-457-webmessage-uaf.md) | ✅ | ✅ | WebView2 事件 handler 析构后回调 UAF |
| [BUG-456](bugs/BUG-456-srt-book-null-mediasource.md) | ✅ | ✅ | SRT书绕过openMedia致currentMediaSource为null收藏制卡无句子 |
| [BUG-455](bugs/BUG-455-favorite-sentence-rightclick.md) | ✅ | ✅ | 右键查词弹窗顶栏收藏句子误报未选择句子 |
| [BUG-454](bugs/BUG-454-backup-import-clears-dict.md) | ✅ | ✅ | 导入备份清空未导出的词典 |
| [BUG-453](bugs/BUG-453-win-global-lookup-render-mismatch.md) | ✅ | ✅ | Windows 全局查词弹窗渲染与 app 内不一致(竖排级联硬编码) |
| [BUG-452](bugs/BUG-452-android-focus-highlight-stuck.md) | ✅ | ✅ | Android 焦点高亮手柄/滑动消不掉 |
| [BUG-451](bugs/BUG-451-scroll-caret-follow.md) | ✅ | ✅ | 连续模式滚动焦点环不跟随可视区 |
| [BUG-450](bugs/BUG-450-home-lookup-webview-uaf.md) | ✅ | ✅ | 首页查词连点 Windows 崩溃（inappwebview 拦截 deferral UAF） |
| [BUG-449](bugs/BUG-449-continuous-progress-bar-first-frame.md) | ✅ | ✅ | 连续模式进度条初次不显示·滑动一下才出来 |
| [BUG-448](bugs/BUG-448-log-line-tap-crash.md) | ✅ | ✅ | 点击调试日志文字崩溃 |
| [BUG-447](bugs/BUG-447-dict-download-ratio-guard.md) | ✅ | ✅ | 在线下载多本词典只成功第一本 |
| [BUG-446](bugs/BUG-446-audio-db-import-swallowed-error.md) | ✅ | ✅ | 添加音频数据库失败文案无信息（吞异常） |
| [BUG-445](bugs/BUG-445-audio-source-reorder-overflow.md) | ✅ | ✅ | 管理音频来源排序对话框出框无法滚动且弹窗过小 |
| [BUG-444](bugs/BUG-444-favorites-word-export-empty.md) | ✅ | ✅ | 收藏词导出为空+制卡句缺失 |
| [BUG-443](bugs/BUG-443-folder-import-book-dedup.md) | ✅ | ✅ | 文件夹导入书籍缺去重 |
| [BUG-442](bugs/BUG-442-clipboard-long-text-crash.md) | ✅ | ✅ | 剪贴板超长文本闪退 |
| [BUG-441](bugs/BUG-441-audiobook-shelf-badge-subtitle.md) | ✅ | ✅ | EPUB有声书卡角标变字幕图标 |
| [BUG-440](bugs/BUG-440-webview-create-fail.md) | ✅ | ✅ | Windows 反复开关书后 Cannot create InAppWebView 打不开书籍 |
| [BUG-439](bugs/BUG-439-bad-epub-import-orphan-and-fake-delete.md) | ✅ | ✅ | 坏EPUB导入留孤儿壳行+删除假成功 |
| [BUG-438](bugs/BUG-438-gamepad-reconnect-loading.md) | ✅ | ✅ | 手柄重连后阅读器无限 loading |
| [BUG-437](bugs/BUG-437-reader-init-hang-no-timeout.md) | ✅ | ✅ | 打开书籍偶发永久卡加载不恢复 |
| [BUG-436](bugs/BUG-436-interconnect-host-autosync.md) | ✅ | ✅ | 互联host模式不应显示自动同步开关 |
| [BUG-435](bugs/BUG-435-dict-glossary-link-misplaced.md) | ✅ | ✅ | 查词弹窗词典释义内链接错位跑到旁边 |
| [BUG-434](bugs/BUG-434-in-app-nested-popup-parent-tap.md) | ✅ | ✅ | app内查词父弹窗点击不关子弹窗 |
| [BUG-433](bugs/BUG-433-ass-millisecond-timecode.md) | ✅ | ✅ | 外挂ASS毫秒精度时间码加载失败误报不支持 |
| [BUG-432](bugs/BUG-432-disabled-dict-still-in-mining.md) | ✅ | ✅ | 禁用词典制卡时仍附带该词典释义 |
| [BUG-431](bugs/BUG-431-subtitle-track-uaf.md) | ✅ | ✅ | selectSubtitleTrack libmpv UAF (回退/关字幕闪退) |
| [BUG-430](bugs/BUG-430-win-ime-shortcut-fallback.md) | ✅ | ✅ | Windows IME 激活时全表面快捷键失效 |
| [BUG-429](bugs/BUG-429-video-dismiss-guard-stale.md) | 🚧 | 🚧 | video _onDismissBarrierTap 守卫期望 _topVisiblePopupIndex 但 TODO-834 已改回 _popNestedPopupAt(0) |
| [BUG-428](bugs/BUG-428-shortcut-key-capture-focus.md) | ✅ | ✅ | 快捷键录制单键经常没反应 (TODO-838) |
| [BUG-427](bugs/BUG-427-install-permission-retry.md) | ✅ | ✅ | Android install permission granted then cannot resume/retry install |
| [BUG-426](bugs/BUG-426-empty-entry-shell.md) | ✅ | ✅ | 隐藏词典致空正文壳卡（TODO-833） |
| [BUG-425](bugs/BUG-425-mouse-tracker-concurrent-modification.md) | ✅ | ✅ | 视频页合成 hover 在 MouseTracker 遍历期重入致 Concurrent modification 崩溃 |
| [BUG-423](bugs/BUG-423-log-select-freeze.md) | ✅ | ✅ | 调试日志框选拖拽未响应卡死 |
| [BUG-422](bugs/BUG-422-rail-right-focus.md) | ✅ | ✅ | 平板宽屏 rail 焦点右键应进内容区（TODO-814） |
| [BUG-421](bugs/BUG-421-meikyo-atrule-scope.md) | ✅ | ✅ | 明鏡第三版 styles.css @media at-rule 被作用域前缀污染导致整块失效 |
| [BUG-420](bugs/BUG-420-local-audiobook-sentence-audio.md) | ✅ | ✅ | 本地有声书查词制卡无句子音频 (TODO-811) |
| [BUG-419](bugs/BUG-419-disabled-dict-still-in-lookup.md) | ✅ | ✅ | 禁用词典后查词仍显示该词典释义 |
| [BUG-418](bugs/BUG-418-reader-continuous-snap-chapter-start.md) | ✅ | ✅ | 连续模式书籍历史恒回章首(reflow非自愿归零·795/797未修好) |
| [BUG-417](bugs/BUG-417-interconnect-book-progress-no-sync.md) | ✅ | ✅ | 互联立即同步不同步书籍进度(host不回灌reader_positions·书籍无进度live端点) |
| [BUG-416](bugs/BUG-416-remote-card-longpress-download.md) | ✅ | ✅ | 长按远端书/视频卡直接下载(应出选项面板) |
| [BUG-415](bugs/BUG-415-mining-audio-token-expiry.md) | ✅ | ✅ | 制卡音频静默丢(复用查词缓存的过期token URL) |
| [BUG-414](bugs/BUG-414-audiobook-download-bookkey-404.md) | ✅ | ✅ | 远端有声书下载404(client重算bookKey丢弃host真实key) |
| [BUG-413](bugs/BUG-413-error-log-open-lag.md) | ✅ | ✅ | 打开错误日志卡顿(单TextField全量512KB无虚拟化) |
| [BUG-412](bugs/BUG-412-video-shift-hover-lookup.md) | ✅ | ✅ | 视频Shift鼠标悬停不查词(自绘overlay未接reader的shift-hover) |
| [BUG-411](bugs/BUG-411-episode-number-clip.md) | ✅ | ✅ | 选集列表两位数序号大字号下换行被裁(leading固定宽24不随字号) |
| [BUG-410](bugs/BUG-410-video-nested-popup-dismiss.md) | ✅ | ✅ | 视频嵌套查词点外不关顶层(字幕命中抢先replaceStack) |
| [BUG-409](bugs/BUG-409-dict-manage-truncate.md) | ✅ | ✅ | 手机词典管理词典名显示不全(trailing控件串挤死窄屏title·749+751) |
| [BUG-408](bugs/BUG-408-video-space-key.md) | ✅ | ✅ | 视频空格无反应(c152fcd91全局吞裸空格+视频失焦) |
| [BUG-407](bugs/BUG-407-anki-error-garble.md) | ✅ | ✅ | AnkiConnect错误提示乱码(socket/http原文透传+http latin1误解码) |
| [BUG-406](bugs/BUG-406-sync-audiobook-download.md) | ✅ | ✅ | 互联下载有声书丢音频(下载侧只导EPUB不接音频包) |
| [BUG-405](bugs/BUG-405-pagination-cumulative-offset.md) | ✅ | ✅ | 竖排翻页累积偏移(pageStep名义值≠真实渲染列周期) |
| [BUG-404](bugs/BUG-404-illustration-viewer-no-esc-no-arrow.md) | ✅ | ✅ | 插画全屏画廊ESC退不出且无方向键切换 |
| [BUG-403](bugs/BUG-403-popup-tap-outside-closes-all-layers.md) | ✅ | ✅ | 点查词弹窗外面一次关掉整个嵌套栈（应只关最顶层一层） |
| [BUG-402](bugs/BUG-402-reader-desktop-cannot-copy-selection.md) | ✅ | ✅ | 桌面阅读器选中文字后无法复制（Ctrl+C / 右键复制无效） |
| [BUG-401](bugs/BUG-401-desktop-cannot-shrink-to-phone-layout.md) | ✅ | ✅ | 桌面窗口缩不进手机底栏布局 |
| [BUG-400](bugs/BUG-400-floating-lyric-current-line-blank.md) | ✅ | ✅ | 悬浮字幕开启后当前句空白(Android,开启后像没出现) — 并入 TODO-707 |
| [BUG-399](bugs/BUG-399-reader-window-resize-no-repaginate.md) | ✅ | ✅ | 拖窗口边框后阅读器不重排文字错乱 |
| [BUG-398](bugs/BUG-398-focus-ring-residue-on-switch.md) | ✅ | ✅ | 焦点高亮切界面残留+无导航键也出现 |
| [BUG-397](bugs/BUG-397-settings-exit-sync-warning.md) | ✅ | ✅ | 设置页退出100%弹同步进行中 |
| [BUG-396](bugs/BUG-396-reader-theme-role-colors-system-accent.md) | ✅ | ✅ | 默认(system)主题下阅读器sasayaki/选区/链接色不吃强调色(落硬编码默认) |
| [BUG-395](bugs/BUG-395-srt-sasayaki-highlight-setup-skipped.md) | ✅ | ✅ | SRT书匹配EPUB后逐句高亮不显示(setup早退跳过applySasayakiCues) |
| [BUG-394](bugs/BUG-394-update-segmented-stuck-zero.md) | ✅ | ✅ | 自动更新分片下载卡0%(TODO-596回归) |
| [BUG-393](bugs/BUG-393-video-mining-title-tag.md) | ✅ | ✅ | 「自动添加书名到标签」配置视频制卡未生效 |
| [BUG-392](bugs/BUG-392-video-mining-subtitle-delay.md) | ✅ | ✅ | 视频制卡未应用字幕调轴(delay)到音频/封面裁剪时间 |
| [BUG-391](bugs/BUG-391-subtitle-list-cursor-hidden.md) | 🚧 | 🚧 | 视频字幕列表侧栏鼠标光标消失 |
| [BUG-390](bugs/BUG-390-reader-lookup-eval-missingplugin.md) | ✅ | ✅ | 阅读器查词高亮 evaluateJavascript 在半销毁 WebView 上抛 MissingPluginException 崩溃 |
| [BUG-383](bugs/BUG-383-video-seekbar-siderail-insets.md) | ✅ | ✅ | 手势导航/圆角手机视频进度条偏高+底栏侧边大留白(viewPadding不归零·SafeArea双重内缩) |
| [BUG-382](bugs/BUG-382-jimaku-result-truncated-episode.md) | ✅ | ✅ | Jimaku 自动获取字幕结果项文件名单行截断，集数被省略号吃掉看不见 |
| [BUG-381](bugs/BUG-381-image-copy-menu-uiscale.md) | ✅ | ✅ | 书籍图片右键复制图片菜单位置不跟界面缩放(坐标未经Overlay变换链映射) |
| [BUG-380](bugs/BUG-380-scroll-progress-only-on-settle.md) | ✅ | ✅ | 滚动模式阅读进度只在滑动停下才更新(JS纯尾沿200ms去抖) |
| [BUG-379](bugs/BUG-379-lyrics-progress-bar-in-footer.md) | ✅ | ✅ | 歌词模式进度条跑进底栏(歌词WebView全屏无底栏预留,CSS滚动条钻进底栏) |
| [BUG-378](bugs/BUG-378-subtitle-list-jump-skip.md) | ✅ | ✅ | 字幕列表点句多跳一句(skipToCue seek 在途瞬态越过目标句被采纳) |
| [BUG-377](bugs/BUG-377-mobile-remote-book-download.md) | ✅ | ✅ | 手机无法下载对端配对设备书籍(Android明文HTTP被network_security_config拦截) |
| [BUG-376](bugs/BUG-376-mobile-shelf-top-gap.md) | ✅ | ✅ | 手机首页页头顶距过大(标题离顶部空一行) |
| [BUG-375](bugs/BUG-375-mobile-update-host-lookup.md) | ✅ | ✅ | 手机自动更新 Failed host lookup ghproxy.homeboyc.cn |
| [BUG-374](bugs/BUG-374-button-edge-tap-pause-passthrough.md) | ✅ | ✅ | 点视频控制按钮边缘穿透到底层 tap 误暂停/播放 |
| [BUG-373](bugs/BUG-373-subtitle-delay-no-instant-feedback.md) | ✅ | ✅ | 字幕调整（音画延迟）没有即时反馈 |
| [BUG-371](bugs/BUG-371-subtitle-list-hides-side-controls.md) | ✅ | ✅ | 打开字幕列表侧边栏时左侧控制按钮全部消失 |
| [BUG-370](bugs/BUG-370-remote-video-subtitle-seekbar-position.md) | ✅ | ✅ | 手机看远端视频字幕字体/阴影偏大、进度条位置偏高 |
| [BUG-369](bugs/BUG-369-scroll-mode-early-prev-chapter.md) | ✅ | ✅ | 滚动模式向上滚未到章首就提前切上一章 |
| [BUG-368](bugs/BUG-368-paged-mouse-paging.md) | ✅ | ✅ | 分页模式鼠标正文横向拖动无法翻页(桌面) |
| [BUG-367](bugs/BUG-367-remote-book-card.md) | ✅ | ✅ | 远端书卡缺类型徽章+尺寸变小 |
| [BUG-366](bugs/BUG-366-audiobook-sasayaki-highlight-jsfold.md) | ✅ | ✅ | 有声书正文逐句高亮完全不显示（JS 归一化未折叠 + 缺观测日志） |
| [BUG-365](bugs/BUG-365-ci-android-emulator-flake.md) | ✅ | ✅ | CI android 模拟器集成 job boot flake 致整 workflow 恒红 |
| [BUG-364](bugs/BUG-364-vertical-scroll-smoothness.md) | ✅ | ✅ | 竖排连续(滚动)模式刷新率低/一格一格跳不顺 (TODO-629 ②) |
| [BUG-363](bugs/BUG-363-popup-ruby-zoom-furigana.md) | ✅ | ✅ | 词典字号放大后释义振假名(ruby furigana)显示异常（飘高/与上行挤压） |
| [BUG-362](bugs/BUG-362-video-topbar-title-buttons.md) | ✅ | ✅ | 视频顶栏标题挡按钮+按钮太多 |
| [BUG-361](bugs/BUG-361-webview2-steals-drop.md) | ✅ | ✅ | WebView2抢占主窗口drop致拖放禁止光标 |
| [BUG-360](bugs/BUG-360-download-progress-overflow.md) | ✅ | ✅ | 更新分片下载进度超100%加闪烁 |
| [BUG-359](bugs/BUG-359-fav-cache-stale.md) | ✅ | ✅ | 收藏后字幕列表favorites档延迟 |
| [BUG-358](bugs/BUG-358-dict-selection-oneshot.md) | ✅ | ✅ | 制卡词典选择粘连应一次性 |
| [BUG-357](bugs/BUG-357-mining-race.md) | ✅ | ✅ | 制卡并发race媒体/句子错配 |
| [BUG-356](bugs/BUG-356-picture-subtitle-lookup-blocked-by-list-barrier.md) | ✅ | ✅ | 画面字幕在字幕列表开启时查不了词（barrier 遮挡） |
| [BUG-355](bugs/BUG-355-dict-reorder-cache.md) | ✅ | ✅ | 词典重排后查词顺序不即时生效（重启才正常） |
| [BUG-354](bugs/BUG-354-home-popup-fullwindow.md) | ✅ | ✅ | 首页查词弹窗被结果子区域clamp跳不出搜索框/页边距(嵌套层坐标系不一致偏移) |
| [BUG-353](bugs/BUG-353-taskbar-flash-foreground-residue.md) | ✅ | ✅ | TODO-615 剪贴板查词在主窗前台时误触任务栏高亮 |
| [BUG-352](bugs/BUG-352-nested-lookup-crash-evidence.md) | ✅ | ✅ | 嵌套查词闪退后错误日志一片空白（无可上传证据） |
| [BUG-351](bugs/BUG-351-reader-image-wheel-pagination.md) | ✅ | ✅ | PC阅读遇插画滚轮翻不了下一页 |
| [BUG-350](bugs/BUG-350-hoshidicts-upstream-batch1.md) | ✅ | ✅ | hoshidicts 上游同步批1（score double / freq 排序 / c++23 兼容） |
| [BUG-349](bugs/BUG-349-swipe-sensitivity-misclassified-reading.md) | ✅ | ✅ | TODO-625 滑动关闭灵敏度错置阅读分类应归查词 |
| [BUG-348](bugs/BUG-348-mixed-dict-classify.md) | ✅ | ✅ | 混合词典误判kanji划词查词全失踪(detect_type kanji优先) |
| [BUG-347](bugs/BUG-347-todo-618-exit-hard-error-phase1.md) | ✅ | ✅ | 打开动画状态直接关 Hibiki 弹 Unknown Hard Error（TODO-618 相位1：fix1+fix3） |
| [BUG-346](bugs/BUG-346-video-clip-export-audio-map.md) | ✅ | ✅ | 视频片段导出 ffmpeg 执行失败：音轨映射越界硬失败 + stderr 被吞 |
| [BUG-345](bugs/BUG-345-popup-glossary-ruby-hspacing.md) | ✅ | ✅ | 查词弹窗释义逐字振假名横向字间距被撑开参差 |
| [BUG-344](bugs/BUG-344-subtitle-import-native-crash.md) | ✅ | ✅ | 导入字幕原生崩溃 0xc0000005 flutter_windows.dll AV |
| [BUG-343](bugs/BUG-343-desktop-audio-player-already-exists.md) | ✅ | ✅ | Windows 桌面本地音频/查词自动发音偶发没声 Player already exists |
| [BUG-342](bugs/BUG-342-update-launcher-openprocess-fatal.md) | ✅ | ✅ | 自更新 launcher OpenProcess(parent) 非 INVALID_PARAMETER 失败被当致命错误放弃安装 |
| [BUG-341](bugs/BUG-341-video-speed-menu-guard-red.md) | ✅ | ✅ | develop 倍速菜单守卫陈旧致预存红 (TODO-601) |
| [BUG-340](bugs/BUG-340-settings-row-stack-breakpoint.md) | ✅ | ✅ | 设置行 <360 竖排堆叠断点过宽（全 App 设置行观感退化） |
| [BUG-339](bugs/BUG-339-video-v2-hidden-key-migration.md) | ✅ | ✅ | 视频控制v2迁移隐藏键静默移除 |
| [BUG-338](bugs/BUG-338-reader-drag-direction.md) | ✅ | ✅ | 阅读器左键拖动翻页方向反·应与手机触屏跟手一致 |
| [BUG-337](bugs/BUG-337-todo-563-fullscreen-volume-hud.md) | ✅ | ✅ | TODO-563 滑动手势音量/亮度 HUD 桌面与全屏也应显示（不止手机窗口） |
| [BUG-336](bugs/BUG-336-todo-564-screenshot-filename.md) | ✅ | ✅ | TODO-564 视频截图文件名太长，改成视频名+播放时刻更语义化 |
| [BUG-335](bugs/BUG-335-remote-video-grid.md) | ✅ | ✅ | 手机远端视频显示成横条应改网格 |
| [BUG-334](bugs/BUG-334-todo-572-embedded-subtitle-first-load.md) | ✅ | ✅ | TODO-572: 视频内封字幕首次打开常加载不出来，需重开一次 |
| [BUG-333](bugs/BUG-333-floating-lyric-bg-opacity.md) | ✅ | ✅ | 悬浮歌词/字幕条背景不透明度太高挡视野，应可调并降低默认值 (TODO-576) |
| [BUG-332](bugs/BUG-332-video-cue-skip-overshoot.md) | ✅ | ✅ | 视频上一句/下一句跳转跳过头（TODO-571） |
| [BUG-331](bugs/BUG-331-video-settings-categories-topbar.md) | — | — | video settings big categories shown in the left pane, not a top bar |
| [BUG-330](bugs/BUG-330-mpv-extra-options-title-clip.md) | ✅ | ✅ | 视频mpv高级『额外mpv选项』标题文本显示不全 |
| [BUG-329](bugs/BUG-329-mobile-subtitle-reserve-pushup.md) | ✅ | ✅ | 手机端字幕条被顶飞 / 位置不对·reserve 误用进度条触摸热区全高（TODO-568） |
| [BUG-328](bugs/BUG-328-video-subtitle-list-favorite-star-slow.md) | ✅ | ✅ | 视频字幕列表已收藏句星标加载慢（要等一会才出现） |
| [BUG-327](bugs/BUG-327-video-subtitle-list-timestamp-overflow.md) | ✅ | ✅ | 视频字幕列表左侧时间戳被下一条字幕遮挡 / 溢出 |
| [BUG-326](bugs/BUG-326-video-folder-drag-import.md) | ✅ | ✅ | 视频拖放扩展名不全 + 书架拖入视频不自动切视频导入 |
| [BUG-325](bugs/BUG-325-video-speed-popover-slot-position.md) | ✅ | ✅ | 视频倍速浮层在顶栏/侧栏时仍往上弹（位置与按钮脱节） |
| [BUG-324](bugs/BUG-324-remote-video-jimaku-fetch-missing.md) | ✅ | ✅ | 远端视频字幕轨菜单里「自动获取字幕(Jimaku)」入口消失 |
| [BUG-323](bugs/BUG-323-video-subtitle-stroke-residual.md) | ✅ | ✅ | TODO-569 视频字幕描边/残留黑字「一点没修好」（8 层模糊 Shadow glyph 拷贝伪描边） |
| [BUG-322](bugs/BUG-322-subtitle-list-click-highlight-offbyone.md) | ✅ | ✅ | 视频字幕列表点击高亮 off-by-one（点第N行高亮N-1） |
| [BUG-321](bugs/BUG-321-remote-video-resume.md) | ✅ | ✅ | 远端视频断点恢复失效每次从0开始 |
| [BUG-320](bugs/BUG-320-shelf-card-cover-badge.md) | ✅ | ✅ | TODO-552 书架卡片封面变形+有声书徽章过小 |
| [BUG-319](bugs/BUG-319-longpress-dialog-cover.md) | ✅ | ✅ | TODO-557 长按书卡对话框封面消失 |
| [BUG-318](bugs/BUG-318-todo-562-video-f12-fullscreen.md) | ✅ | ✅ | TODO-562: 视频按 F12 切全屏无反应（老用户快捷键快照覆盖新增默认键） |
| [BUG-317](bugs/BUG-317-paged-touch-swipe.md) | ✅ | ✅ | TODO-553: 分页模式触摸滑动无法翻页（890378f19 回归） |
| [BUG-316](bugs/BUG-316-todo-549-win-update-mutex-deadlock.md) | — | — | Windows 自更新 AppMutex 死结：新安装器被旧 app mutex 阻止替换文件 |
| [BUG-315](bugs/BUG-315-todo-522-526-video-control-settings-layout.md) | ✅ | ✅ | TODO-522/523/525/526: video controls removal persisted removed buttons and video settings text was clipped |
| [BUG-314](bugs/BUG-314-todo-524-windows-drag-drop-import.md) | ✅ | ✅ | TODO-524: Windows desktop drag-drop import can miss targets or fail silently |
| [BUG-313](bugs/BUG-313-todo-521-video-chapters-first-load.md) | ✅ | ✅ | TODO-521: 视频章节首次加载缺失 |
| [BUG-312](bugs/BUG-312-todo-520-lookup-window-no-text.md) | ✅ | ✅ | TODO-520: 0.9.24-debug.5191 查词窗口没文字 |
| [BUG-311](bugs/BUG-311-video-episode-start-intent-near-end.md) | ✅ | ✅ | TODO-518: video episode switch resumes near end then immediately auto-advances |
| [BUG-310](bugs/BUG-310-todo-495-498-reader-drag-scroll.md) | ✅ | ✅ | TODO-495/TODO-498: 连续模式正文文字处鼠标拖拽被原生选区接管 |
| [BUG-309](bugs/BUG-309-todo-488-cover-regression.md) | ✅ | ✅ | TODO-488: linked SRT shelf card loses EPUB cover fallback |
| [BUG-308](bugs/BUG-308-todo-478-0-9-15-install-residual.md) | ✅ | ✅ | TODO-478: 0.9.15 installer can leave old running build installed |
| [BUG-307](bugs/BUG-307-ffmpeg-mining-invalid-image.md) | ✅ | ✅ | Windows ffmpeg invalid-image breaks mining audio and GIF extraction (TODO-458) |
| [BUG-306](bugs/BUG-306-ankiconnect-addnote-unknown-commit.md) | ✅ | ✅ | AnkiConnect addNote 响应断开后 popup 先失败再后验成功 |
| [BUG-305](bugs/BUG-305-video-playlist-autoplay-subtitle-loading.md) | ✅ | ✅ | 播放列表不会自动连播且下一集字幕列表初始空 |
| [BUG-304](bugs/BUG-304-android-versioncode-overflow.md) | ✅ | ✅ | Android versionCode 经 ×1,000,000 公式溢出 int32/超 21 亿上限，beta/release 包建不出 |
| [BUG-303](bugs/BUG-303-playlist-subtitle-menu-empty.md) | ✅ | ✅ | m3u8 播放列表首集字幕菜单「一个字幕没有」 |
| [BUG-302](bugs/BUG-302-video-next-cue-current.md) | ✅ | ✅ | 视频「下一句」跳到当前句（应排除当前句） |
| [BUG-301](bugs/BUG-301-pgs-subtitle-delay.md) | ✅ | ✅ | 字幕同步滑条对 PGS/图形内封字幕无效（从不调 mpv sub-delay）(TODO-402 档①) |
| [BUG-300](bugs/BUG-300-reader-sasayaki-highlight-missing.md) | ✅ | ✅ | 有声书文字跟随高亮在阅读器里完全不显示 |
| [BUG-299](bugs/BUG-299-popup-textselect-triggers-swipe-close.md) | ✅ | ✅ | 查词弹窗在WebView正文框选文本误触滑动关闭 |
| [BUG-298](bugs/BUG-298-mirror-update-check-redirect.md) | ✅ | ✅ | 更新检查走 github.com release 302 跳转使镜像无代理可用（TODO-404 方案A） |
| [BUG-297](bugs/BUG-297-mining-sentence-draft-cross-contamination.md) | ✅ | ✅ | 查词制卡句子草稿跨词串味：换词查询不清草稿 + 热槽 WebView 角标残留 |
| [BUG-296](bugs/BUG-296-sentence-audio-mining-investigation.md) | ✅ | ✅ | ひびき/Lapis 卡组制卡缺句子音频根因调查（TODO-390） |
| [BUG-295](bugs/BUG-295-video-immersion-button-hover-vanish.md) | ✅ | ✅ | 视频沉浸(锁)按钮鼠标悬停时消失 |
| [BUG-294](bugs/BUG-294-update-proxy-system.md) | ✅ | ✅ | 更新检查/下载 HttpClient 不走系统/环境代理（开了代理也连不上 GitHub） |
| [BUG-293](bugs/BUG-293-remine-crash-bridge.md) | ✅ | ✅ | 删卡后再制同词闪退（mineEntry/updateEntry 桥接处理器异常逃逸到原生 JS-handler 边界） |
| [BUG-292](bugs/BUG-292-update-check-proxy-api-rejected.md) | ✅ | ✅ | 更新检查代理镜像全失败：gh-proxy 公共镜像不代理 api.github.com（结构性 + 部分用户网络侧） |
| [BUG-291](bugs/BUG-291-mine-sentence-undo-clarity.md) | ✅ | ✅ | 查词弹窗「+句」语义不明且不可撤销；字幕列表「选入词卡」用途不明 |
| [BUG-290](bugs/BUG-290-log-upload-ci-not-injected.md) | ✅ | ✅ | 错误日志上传按钮在 CI 构建版（含 Windows）全平台不显示 |
| [BUG-289](bugs/BUG-289-dcomp-compositor-atexit-failfast.md) | ✅ | ✅ | Windows 退出时 dcomp Compositor::CleanupSession FailFast（BUG-255 受控释放修复未生效） |
| [BUG-288](bugs/BUG-288-dict-folder-import-conf-noise.md) | ✅ | ✅ | 「导入文件夹词典」选到只含无关文件（QQ 下载的随机名 .conf）的目录报含糊错（TODO-379） |
| [BUG-287](bugs/BUG-287-video-replay-previous-subtitle.md) | ✅ | ✅ | 恢复「重播上一句」并区分「上一句字幕」(TODO-378) |
| [BUG-286](bugs/BUG-286-floating-lyric-lookup-into-clipboard-route.md) | ✅ | ✅ | 悬浮字幕点词复用剪贴板查词出口而非主app内浮层 |
| [BUG-285](bugs/BUG-285-reader-charoffset-clobber.md) | ✅ | ✅ | 音频跟随退化到章节粒度：位置保存把 -1 覆盖精确字符锚（TODO-375） |
| [BUG-284](bugs/BUG-284-video-control-rail-flicker-cursor-vanish.md) | ✅ | ✅ | 视频右侧控制按钮闪烁 + 鼠标放字幕上光标消失 (TODO-373) |
| [BUG-283](bugs/BUG-283-bundled-ffmpeg-empty-output-fallback.md) | ✅ | ✅ | Bundled ffmpeg 跑起来却空输出时不回退 PATH 致内封字幕枚举静默失败 |
| [BUG-282](bugs/BUG-282-audiobook-highlight-offset-regression.md) | ✅ | ✅ | 有声书播放高亮按句漂移：不可命中cue回落污染单调游标，后续可命中cue被推偏(TODO-366 BUG-060跟进) |
| [BUG-281](bugs/BUG-281-subtitle-avoid-direction-race.md) | ✅ | ✅ | 字幕避让方向反/竞态：避让与控制条可见性未用同一真相源 |
| [BUG-280](bugs/BUG-280-lyrics-continuous-lookup.md) | ✅ | ✅ | 歌词模式查完一个词无法继续查下一个 |
| [BUG-279](bugs/BUG-279-jimaku-dialog-list-no-scroll.md) | ✅ | ✅ | 移动端 Jimaku 自动获取字幕对话框候选列表太矮且吞滚动 |
| [BUG-278](bugs/BUG-278-audiobook-exit-not-stopped.md) | ✅ | ✅ | 退出阅读后有声书仍在播放（dispose 未先 stop 播放器） |
| [BUG-277](bugs/BUG-277-updatechecker-mirror-fallback.md) | ✅ | ✅ | 更新检查端点单点不可达就整体失败(缺多镜像回退/不可测) |
| [BUG-276](bugs/BUG-276-delete-disk-not-reclaimed.md) | ✅ | ✅ | 删除书/视频只删DB行不回收磁盘(TODO-365·13GB泄漏) |
| [BUG-275](bugs/BUG-275-bundled-ffmpeg-launch-fallback.md) | ✅ | ✅ | Bundled ffmpeg.exe invalid 时字幕枚举静默失败(TODO-336) |
| [BUG-274](bugs/BUG-274-video-favorite-cross-episode.md) | ✅ | ✅ | 视频收藏句子面板跨集/跨视频污染（缺 bookKey 过滤） |
| [BUG-273](bugs/BUG-273-multicue-mining-reader.md) | ✅ | ✅ | 查词窗口多句合一制卡(书籍/有声书·乙方案草稿累积) |
| [BUG-272](bugs/BUG-272-backup-win-tempdir-delete-race.md) | ✅ | ✅ | 备份导出Win临时目录删除竞争errno145 |
| [BUG-271](bugs/BUG-271-shader-download-mirror-anime-only.md) | ✅ | ✅ | 画质增强切到「中」下载失败一个 + 说明只说动画（误导真人/电视剧） |
| [BUG-270](bugs/BUG-270-reader-open-and-cross-chapter-speed.md) | ✅ | ✅ | 开书/跨章提速（懒解析章节 + 跨章 LRU 缓存预取） |
| [BUG-268](bugs/BUG-268-subtitle-list-actions-persistent.md) | ✅ | ✅ | 字幕列表行操作按钮应常驻 |
| [BUG-267](bugs/BUG-267-subtitle-list-favorite-highlight.md) | ✅ | ✅ | 收藏字幕在列表和底栏应有标记 |
| [BUG-266](bugs/BUG-266-subtitle-list-lookup-nowrap.md) | ✅ | ✅ | 字幕列表无法查词且长文本换行 |
| [BUG-264](bugs/BUG-264-dead-configurable-shortcut-actions.md) | ✅ | ✅ | 快捷键设置每个选项是否都生效（死项审计 + 完整性守卫） |
| [BUG-263](bugs/BUG-263-focus-vs-shortcut-arrow-dispatch.md) | ✅ | ✅ | 焦点遍历与方向键快捷键互抢（按下/重复分属两套焦点引擎） |
| [BUG-262](bugs/BUG-262-remove-rightclick-shader-compare.md) | ✅ | ✅ | 删除视频右键菜单的对比原画项 |
| [BUG-261](bugs/BUG-261-rightclick-popup-coord-uiscale.md) | ✅ | ✅ | 调界面大小后视频右键菜单位置不在鼠标处 |
| [BUG-260](bugs/BUG-260-popup-wheel-scroll-granularity.md) | ✅ | ✅ | 查词弹窗滚轮滚动粒度太粗 |
| [BUG-259](bugs/BUG-259-cue-seek-preroll-precision.md) | ✅ | ✅ | 视频上/下一句字幕容易漏掉开头 0.x 秒（句首被关键帧吸附吃掉） |
| [BUG-258](bugs/BUG-258-immersive-cursor-hide-over-chrome.md) | ✅ | ✅ | 沉浸/锁屏鼠标放字幕/面板上不隐藏 |
| [BUG-257](bugs/BUG-257-video-play-center-seek-labels.md) | ✅ | ✅ | play 按钮不居中 + seek 按钮看不懂 |
| [BUG-256](bugs/BUG-256-subtitle-list-push-aside.md) | ✅ | ✅ | 字幕列表应挤画面到左（非浮层遮挡） |
| [BUG-255](bugs/BUG-255-dcomp-compositor-cleanup-exit-crash.md) | ✅ | ✅ | 进程退出时 dcomp Compositor::CleanupSession FailFast 崩溃（TODO-313 Family B） |
| [BUG-254](bugs/BUG-254-video-panel-remove-x-tap-outside-close.md) | ✅ | ✅ | 视频侧栏面板删右上角 X、改点左侧 / 空白关闭 |
| [BUG-253](bugs/BUG-253-video-panel-controls-still-show.md) | ✅ | ✅ | 视频侧栏面板打开后背景控制条 / 右侧 rail 仍冒出来 |
| [BUG-252](bugs/BUG-252-collection-audio-play-silent-fail.md) | ✅ | ✅ | 收藏夹播放按钮抽音失败时静默无反馈（「点了没用」）+ 视频收藏句缺播放按钮 |
| [BUG-251](bugs/BUG-251-import-row-tap-dead.md) | ✅ | ✅ | 导入对话框点文字标题没反应，只有右边图标可点 |
| [BUG-250](bugs/BUG-250-tag-selection-back-exits-app.md) | ✅ | ✅ | 书架/视频标签多选模式按返回键直接退出 App（TODO-306） |
| [BUG-249](bugs/BUG-249-reader-font-size-cap-64.md) | ✅ | ✅ | 阅读器正文字号最大只能调到 64（TODO-299「为什么字体大小只有64最大」） |
| [BUG-248](bugs/BUG-248-video-volume-squeeze-and-duplicate-settings.md) | ✅ | ✅ | 桌面音量按钮挤走全屏键 + 顶栏设置入口与右栏重复 (TODO-283) |
| [BUG-247](bugs/BUG-247-video-bottom-bar-tooltips.md) | ✅ | ✅ | 视频底栏 5 个按钮缺 tooltip (TODO-282) |
| [BUG-246](bugs/BUG-246-video-settings-triggers-fullscreen.md) | ✅ | ✅ | 调视频设置侧栏时误触发全屏 (TODO-275) |
| [BUG-245](bugs/BUG-245-video-subtitle-list-double-title.md) | ✅ | ✅ | 视频字幕列表侧栏出现两个标题 (TODO-280) |
| [BUG-244](bugs/BUG-244-reader-audio-buttons-md3-frame.md) | ✅ | ✅ | 阅读器有声书音频控制键被改成扁平样式，需还原「图标 + 圆框 md3」旧观感（TODO-297） |
| [BUG-242](bugs/BUG-242-video-category-tag-naming.md) | ✅ | ✅ | 制卡「添加来源分类标签」开关提示把视频写成 anime/动漫 |
| [BUG-241](bugs/BUG-241-ankidroid-collection-unavailable.md) | ✅ | ✅ | 从 AnkiDroid 获取时显示 "collection is not available" |
| [BUG-240](bugs/BUG-240-paged-mode-cross-chapter.md) | ✅ | ✅ | 分页模式未到章节末页就意外跨章 |
| [BUG-239](bugs/BUG-239-continuous-mode-no-pageturn.md) | ✅ | ✅ | 连续/滚动模式滑动无法翻页（手势轴向与原生滚动冲突） |
| [BUG-238](bugs/BUG-238-subtitle-overlap-progressbar.md) | ✅ | ✅ | 进度条出现时字幕只往上动一点点、仍被进度条遮挡（移动端） |
| [BUG-237](bugs/BUG-237-shelf-badge-top-right.md) | ✅ | ✅ | 书架卡片类型徽章应放在右上角（TODO-284） |
| [BUG-236](bugs/BUG-236-android-settings-back-exits-app.md) | ✅ | ✅ | 安卓大屏在设置 tab 按返回键直接退出 app（应切回来源 tab） |
| [BUG-235](bugs/BUG-235-seekbar-onpointerup-uaf.md) | ✅ | ✅ | 拖动视频进度条松手崩溃（seek bar onPointerUp 解引用已 dispose 的 context） |
| [BUG-234](bugs/BUG-234-popup-i18n-mojibake.md) | ✅ | ✅ | 查词弹窗「底部停靠」等 zh-CN 文案乱码（GBK→Latin1）（TODO-289） |
| [BUG-233](bugs/BUG-233-todo-267-card-crash-winlog.md) | ✅ | ✅ | Reader card mining fails when bundled ffmpeg is invalid |
| [BUG-232](bugs/BUG-232-video-favorite-cue-loop.md) | ✅ | ✅ | 视频收藏句缺少字幕锚点和收藏页跳回闭环（TODO-176/TODO-177） |
| [BUG-231](bugs/BUG-231-video-doubletap-seek.md) | ✅ | ✅ | 视频缺双击左右快进 + 步长设置（TODO-173） |
| [BUG-230](bugs/BUG-230-video-vertical-gesture-sensitivity.md) | ✅ | ✅ | 视频亮度/音量竖滑手势太敏感（TODO-172） |
| [BUG-229](bugs/BUG-229-video-subtitle-list-polish-and-aspect-ratio.md) | ✅ | ✅ | 字幕列表仿asbplayer精致度 + 引入画面比例设置 (TODO-152) |
| [BUG-228](bugs/BUG-228-video-subtitle-dodge-too-high.md) | ✅ | ✅ | 进度条出来字幕往上顶太高（抄B站只让进度条上缘） |
| [BUG-227](bugs/BUG-227-floating-lyric-toggle-in-booklongpress-and-notification.md) | ✅ | ✅ | 悬浮字幕开关加到长按书籍菜单+通知栏 |
| [BUG-226](bugs/BUG-226-video-subtitle-hover-dodge-clipped.md) | ✅ | ✅ | 桌面 hover 视频时字幕被避让顶飞「消失」（底部+右侧列表都不见） |
| [BUG-225](bugs/BUG-225-reader-inchapter-progress-diag-logs.md) | ✅ | ✅ | 章内滚动进度链路三点诊断日志(TODO-151/164) |
| [BUG-224](bugs/BUG-224-reader-system-theme-book-background-white.md) | ✅ | ✅ | 默认主题书籍正文背景不吃背景色(恒白) |
| [BUG-223](bugs/BUG-223-shelf-book-settings-buttons-uneven-wrap.md) | ✅ | ✅ | 书籍设置弹窗三按钮换行参差 |
| [BUG-222](bugs/BUG-222-video-subtitle-shadow-offset-detached.md) | ✅ | ✅ | 视频字幕阴影单向下投影像残留/不跟随 |
| [BUG-221](bugs/BUG-221-video-remove-portrait-fullscreen-orientation.md) | ✅ | ✅ | 删除视频竖屏模式+双击暂停+返回手势直接退出 |
| [BUG-220](bugs/BUG-220-shelf-author-not-shown-editable.md) | ✅ | ✅ | 书架作者导入后不回显不可编辑+tag竖排参差 |
| [BUG-219](bugs/BUG-219-video-statusbar-not-persistent-immersive.md) | ✅ | ✅ | 视频沉浸状态栏不持续隐藏（后台返回残留） |
| [BUG-218](bugs/BUG-218-video-mobile-seekbar-touch-target.md) | ✅ | ✅ | 移动端进度条触摸热区太小难命中 |
| [BUG-217](bugs/BUG-217-video-mobile-seekbar-above-buttons.md) | ✅ | ✅ | 移动端进度条没在播放按钮上方 |
| [BUG-216](bugs/BUG-216-video-side-lock-icon-semantics.md) | ✅ | ✅ | 视频侧边锁按钮图标语义反了 |
| [BUG-215](bugs/BUG-215-video-controls-poke-dedup.md) | ✅ | ✅ | 连按快进时控件自动隐藏计时器不刷新 |
| [BUG-214](bugs/BUG-214-android-popup-lookup-charindex-regression.md) | ✅ | ✅ | Android 悬浮字幕条查词退化：点哪都查句首+弹键盘 |
| [BUG-213](bugs/BUG-213-reader-inchapter-progress-stale.md) | ✅ | ✅ | 阅读器章内滚动进度不更新 |
| [BUG-212](bugs/BUG-212-theme-custom-palette-icon-dark-invisible.md) | ✅ | ✅ | 自定义主题调色盘图标深色主题消失 |
| [BUG-211](bugs/BUG-211-book-stats-charcount-inflated.md) | ✅ | ✅ | 书籍统计字数明显过高 |
| [BUG-210](bugs/BUG-210-reader-paging-jumps-chapter-start.md) | ✅ | ✅ | 阅读器翻页跳回章节开头 |
| [BUG-209](bugs/BUG-209-wgc-graphics-capture-crash.md) | ✅ | ✅ | 手机闪退实为Windows WGC FramePool teardown崩溃 |
| [BUG-208](bugs/BUG-208-reader-bg-ignores-system-light-theme.md) | ✅ | ✅ | 阅读器背景在 system-theme/light-theme 下不吃主题(恒白) |
| [BUG-207](bugs/BUG-207-shortcut-load-before-source-init.md) | ✅ | ✅ | 自定义快捷键重启后丢失/不生效(loadShortcutRegistry早于source.initialise) |
| [BUG-206](bugs/BUG-206-lookup-highlight-multi-select.md) | ✅ | ✅ | 手机查词高亮多选/少选字（错位） |
| [BUG-205](bugs/BUG-205-desktop-floating-strip-drag-dead.md) | ✅ | ✅ | Windows悬浮字幕条拖不动/无锁按钮/无法缩放 |
| [BUG-204](bugs/BUG-204-todo-137-chrome-focus-space-no-pause.md) | ✅ | ✅ | 底栏焦点点空格不暂停音频 |
| [BUG-203](bugs/BUG-203-todo-133-android-exit-resume-drift.md) | ✅ | ✅ | 安卓退出重进恢复点漂移在前面好几页 |
| [BUG-202](bugs/BUG-202-delete-remote-book-stale-folder-cache.md) | ✅ | ✅ | 删远端书后无法复传（陈旧 folder 缓存指向已删/trashed 文件夹） |
| [BUG-201](bugs/BUG-201-sync-exit-kill-false-conflict.md) | ✅ | ✅ | 退出书后杀后台重开总弹假冲突(baseline 与远端进度传输非原子) |
| [BUG-200](bugs/BUG-200-no-subtitle-prev-button-stuck.md) | ✅ | ✅ | 转场/无字幕段「上一句字幕」按钮没反应回退不了 |
| [BUG-199](bugs/BUG-199-lookup-reblurs-subtitle.md) | ✅ | ✅ | 查词时模糊字幕又变模糊 |
| [BUG-198](bugs/BUG-198-subtitle-eats-mouse.md) | ✅ | ✅ | 字幕吞鼠标 hover/控制条不唤起 |
| [BUG-197](bugs/BUG-197-video-playback-crash-audit.md) | ✅ | ✅ | 视频播放高频闪退全平台根因排查 (TODO-116) |
| [BUG-196](bugs/BUG-196-focus-nav-volume-gate.md) | ✅ | ✅ | 焦点导航/音量键开关未真正 gate 输入（Tab 仍遍历 + 音量键出焦点框） |
| [BUG-195](bugs/BUG-195-android-system-focus-highlight.md) | ✅ | ✅ | 三星 OneUI 6.5 系统默认焦点框与 app 自绘焦点环双重重叠 |
| [BUG-194](bugs/BUG-194-languages-late-init.md) | ✅ | ✅ | LateInitializationError: languages map accessed before populateLanguages during init |
| [BUG-193](bugs/BUG-193-popup-engine-inappwebview-blank.md) | ✅ | ✅ | 外部查词弹窗结果空白（popup 引擎漏注册 inappwebview） |
| [BUG-192](bugs/BUG-192-fast-exit.md) | ✅ | ✅ | 桌面 app 退出慢（几秒~十几秒） |
| [BUG-191](bugs/BUG-191-video-autoread-setting.md) | ✅ | ✅ | 关闭查词时自动阅读后视频字幕查词仍自动阅读 |
| [BUG-190](bugs/BUG-190-video-subtitle-layer.md) | ✅ | ✅ | 禁用 media_kit 内置 SubtitleView：字幕透明/查词坏/横竖屏残留黑字 |
| [BUG-189](bugs/BUG-189-no-subtitle-next-jump.md) | ✅ | ✅ | 视频OP无字幕时按下一句字幕按钮不前进（用户感知「跳回开头」） |
| [BUG-188](bugs/BUG-188-video-card-sentence-audio-gap.md) | ✅ | ✅ | 视频制卡字幕gap时缺真实句子音频 |
| [BUG-187](bugs/BUG-187-anki-handlebar-picker-too-small.md) | ✅ | ✅ | Anki 字段映射「选值」弹窗太小（选项区被死压在屏高 24% / 封顶 320px） |
| [BUG-186](bugs/BUG-186-anki-real-card-status.md) | ✅ | ✅ | 制卡按钮态在查词时检测 Anki 真实卡存在性（删卡后可重制） |
| [BUG-185](bugs/BUG-185-video-seek-arrow-vs-ctrl.md) | ✅ | ✅ | 视频普通箭头改时间seek/Ctrl箭头改句子seek+上句太远回退3s |
| [BUG-184](bugs/BUG-184-android-video-seekbar-bottom.md) | ✅ | ✅ | 安卓视频进度条贴屏幕最底(移动控制条丢失底部留白margin) |
| [BUG-183](bugs/BUG-183-font-backup-path-stale.md) | ✅ | ✅ | 备份恢复后自定义字体不生效（字体文件未打包+配置绝对路径未重定位） |
| [BUG-182](bugs/BUG-182-video-subtitle-font-fallback.md) | ✅ | ✅ | 视频字幕里「の」等字字形与周围字不一致(逐字Text缺CJK fontFamilyFallback) |
| [BUG-181](bugs/BUG-181-android-portrait-statusbar-overlap.md) | ✅ | ✅ | 手机竖屏常驻状态栏挤压首页右上角图标（TODO-097） |
| [BUG-180](bugs/BUG-180-video-subtitle-default-covers-bar.md) | ✅ | ✅ | 视频字幕默认位置遮挡底部进度条 |
| [BUG-179](bugs/BUG-179-android-video-resume.md) | ✅ | ✅ | 安卓视频退出重进不从上次位置继续（恢复 seek 失败时守护永久挡住整程位置写入） |
| [BUG-178](bugs/BUG-178-disabled-freq-dict-shows.md) | ✅ | ✅ | 已禁用的词频辞典查词时仍出现 + 声调与词频间距太小遮挡 |
| [BUG-177](bugs/BUG-177-illustration-viewer-copy-share.md) | ✅ | ✅ | 插画查看器无法右键复制(win)/长按分享(android) |
| [BUG-176](bugs/BUG-176-video-sentence-seek-origin.md) | ✅ | ✅ | 视频句子快进打回原点 / 进度条圆点闪开头 / 控制条不保持 |
| [BUG-175](bugs/BUG-175-clipboard-lookup-tiny-centered.md) | ✅ | ✅ | 剪贴板查词显示文字太小且居中 (应像 yomitan 正常字号左对齐) |
| [BUG-174](bugs/BUG-174-win-update-installer-crash.md) | ✅ | ✅ | Windows 自动更新启动安装器崩溃/静默消失 |
| [BUG-173](bugs/BUG-173-subtitle-drop-video-card.md) | ✅ | ✅ | 字幕拖到主页视频卡未挂到该视频（重复导入建副本） |
| [BUG-172](bugs/BUG-172-reader-card-sentence-audio-tts-fallback.md) | ✅ | ✅ | 有声书制卡词落 cue 空隙时句子音频静默为空（Lapis SentenceAudio 空） |
| [BUG-171](bugs/BUG-171-dict-delete-engine-stale.md) | ✅ | ✅ | 删除词典后查词仍命中已删词典(引擎实例未reload/dispose,需重启) |
| [BUG-170](bugs/BUG-170-nested-popup-white-flash.md) | ✅ | ✅ | 第二个嵌套查词弹窗出现白屏一瞬 |
| [BUG-169](bugs/BUG-169-reader-scroll-skips-two-pages.md) | ✅ | ✅ | 阅读器滚轮/翻页有时一次翻两页（misaligned scroll 经 round 跳页） |
| [BUG-168](bugs/BUG-168-video-folder-import-no-recursion.md) | ✅ | ✅ | 导入视频文件夹显示无视频(非递归扫描+缺m2ts) |
| [BUG-167](bugs/BUG-167-nhk-pitch-glossary-not-pitch.md) | 🚧 | 🚧 | NHK发音辞典被读成释义词典（实为glossary格式·无pitch数据·非bug） |
| [BUG-166](bugs/BUG-166-mining-slow-serial-media.md) | ✅ | ✅ | 制卡慢（约 6 秒）+ 每张卡自动打 hibiki tag |
| [BUG-165](bugs/BUG-165-episode-subtitle-no-follow.md) | ✅ | ✅ | 播放列表换集字幕不自动跟随对应集 |
| [BUG-164](bugs/BUG-164-video-shortcuts-dead-after-overlays.md) | ✅ | ✅ | 视频快捷键失灵：设置/导入/点外部/全屏后空格等失效 |
| [BUG-163](bugs/BUG-163-desktop-card-crash-late-frame.md) | ✅ | ✅ | 桌面制卡闪退：WebView2 捕获帧迟到事件打进已拆除 delegate |
| [BUG-162](bugs/BUG-162-reader-restore-charoffset.md) | ✅ | ✅ | 书籍退出再进位置漂移（持久化恢复走粗粒度进度分数而非精确字符偏移） |
| [BUG-161](bugs/BUG-161-reader-focus-nav-switch-ignored.md) | ✅ | ✅ | 阅读器键盘/手柄焦点导航不跟随「键盘/手柄焦点导航」开关 |
| [BUG-160](bugs/BUG-160-server-enabled-persist.md) | ✅ | ✅ | 同步服务器开关每次启动重置为关闭 |
| [BUG-159](bugs/BUG-159-dictionary-clipboard-panel-overlap.md) | ✅ | ✅ | 外部查词文本面板不应覆盖查词结果 |
| [BUG-158](bugs/BUG-158-interconnect-remote-book-manual-download.md) | ✅ | ✅ | Hibiki互联无法下载对端独有书籍 |
| [BUG-157](bugs/BUG-157-interconnect-remote-video-url.md) | ✅ | ✅ | Hibiki互联远端视频URL被当成本地文件加载 |
| [BUG-156](bugs/BUG-156-sync-upload-content-no-auto-pull.md) | ✅ | ✅ | 自动同步书籍和有声书文件开关误拉远端独有内容 |
| [BUG-155](bugs/BUG-155-reader-exit-position.md) | ✅ | ✅ | 书籍退出重进仍回到上一页 |
| [BUG-154](bugs/BUG-154-yomitan-api-token-auth.md) | ✅ | ✅ | Yomitan API token authentication rejects compatible clients |
| [BUG-153](bugs/BUG-153-dictionary-pull-clears-query.md) | ✅ | ✅ | 查词结果下拉释放应清空搜索且保持输入态 |
| [BUG-152](bugs/BUG-152-reader-toc-chapter-jump.md) | ✅ | ✅ | 阅读器目录页偶发消失且继续读可能跳章节 |
| [BUG-151](bugs/BUG-151-floating-lyric-initial-theme.md) | ✅ | ✅ | 悬浮字幕首次开启先显示默认底色 |
| [BUG-150](bugs/BUG-150-floating-lyric-lock-control.md) | ✅ | ✅ | 悬浮字幕锁定位置误锁播放控制 |
| [BUG-149](bugs/BUG-149-book-card-sentence-audio-tail.md) | ✅ | ✅ | 书籍制卡整句音频句尾被截断 |
| [BUG-148](bugs/BUG-148-video-controls-width.md) | ✅ | ✅ | 视频底栏压缩不应只限定移动端 |
| [BUG-147](bugs/BUG-147-video-mobile-bottom-width.md) | ✅ | ✅ | 手机视频宽屏底栏不应丢失10秒跳转 |
| [BUG-146](bugs/BUG-146-android-popup-registrant-dev-plugin.md) | ✅ | ✅ | Android release 构建把 integration_test 注册进 popup 引擎 |
| [BUG-145](bugs/BUG-145-video-mobile-controls-no-more.md) | ✅ | ✅ | 手机视频控制条取消三点并压缩底栏按钮 |
| [BUG-144](bugs/BUG-144-audiobook-mining-audio.md) | ✅ | ✅ | 有声书查词制卡词条音频复用旧词且句子音频/句子上下文错位 |
| [BUG-143](bugs/BUG-143-floating-lyric-lock-icon.md) | ✅ | ✅ | 浮动歌词锁定态显示开锁图标 |
| [BUG-142](bugs/BUG-142-desktop-clipboard-foreground.md) | ✅ | ✅ | 桌面剪贴板自动查词在未开始真实搜索前抢前台 |
| [BUG-141](bugs/BUG-141-dictionary-popup-scroll-reset.md) | ✅ | ✅ | 查词弹窗下次查词滚动位置未重置 |
| [BUG-140](bugs/BUG-140-interconnect-live-export-invalid-items.md) | ✅ | ✅ | Hibiki互联导出书籍包结构错误且有声书列表暴露孤儿行 |
| [BUG-139](bugs/BUG-139-focus-popup-navigation.md) | ✅ | ✅ | 查词弹窗焦点系统跳过 header 按钮且 reader caret 绕过总开关 |
| [BUG-138](bugs/BUG-138-sync-server-note-padding.md) | ✅ | ✅ | 同步服务端提示卡底部留白过多 |
| [BUG-137](bugs/BUG-137-interconnect-sync-not-visible.md) | ✅ | ✅ | Hibiki互联同步后手机端内容不刷新且失败缺少明细 |
| [BUG-136](bugs/BUG-136-reader-esc-after-gesture-pageturn.md) | ✅ | ✅ | 翻页(手势/滚轮)后 ESC 不退出书籍 |
| [BUG-135](bugs/BUG-135-video-warm-popup-eats-touches.md) | ✅ | ✅ | 手机热WebView吞掉视频控制条触摸（顶栏/底栏点了没反应） |
| [BUG-134](bugs/BUG-134-video-mobile-topbar-overflow.md) | ✅ | ✅ | 手机视频顶栏竖屏溢出（自适应布局） |
| [BUG-133](bugs/BUG-133-video-subtitle-drag-noop.md) | ✅ | ✅ | 视频画面拖入字幕无反应 |
| [BUG-132](bugs/BUG-132-video-playlist-subtitle-lost.md) | ✅ | ✅ | 退出后导入的字幕未绑定视频丢失 |
| [BUG-131](bugs/BUG-131-video-import-keyboard-focus.md) | ✅ | ✅ | 导入字幕后键盘快捷键失灵 |
| [BUG-130](bugs/BUG-130-video-tap-pause.md) | ✅ | ✅ | 视频点击屏幕不暂停 |
| [BUG-129](bugs/BUG-129-popup-nested-covers-word.md) | ✅ | ✅ | 嵌套查词弹窗遮挡被查的词 |
| [BUG-125](bugs/BUG-125-ruby-highlight-mask-erase.md) | ✅ | ✅ | 高亮遮挡振假名/基字 + 查词音频重叠双重高亮 |
| [BUG-124](bugs/BUG-124-android-ffmpegkit-launch-crash.md) | ✅ | ✅ | Android 16 启动闪退：ffmpeg_kit 原生库不兼容 API 36 |
| [BUG-123](bugs/BUG-123-vertical-ruby-lookup-highlight-overflow.md) | ✅ | ✅ | 竖排查词高亮溢出到振假名列(双重高亮) |
| [BUG-122](bugs/BUG-122-pgs-graphic-sub.md) | ✅ | ✅ | PGS图形内封字幕标错内嵌+点了转圈/打不开 |
| [BUG-121](bugs/BUG-121-exit-video-redscreen.md) | ✅ | ✅ | 退出视频闪红屏（deactivate 期根 Overlay 浮层重建做失效祖先查找） |
| [BUG-120](bugs/BUG-120-fullscreen-episode-switch.md) | ✅ | ✅ | 全屏下切集黑屏 00:00 + 左上标题不刷新（media_kit 全屏独立路由快照） |
| [BUG-119](bugs/BUG-119-log-panel-select-scroll.md) | ✅ | ✅ | 日志页（错误日志/调试日志）按住鼠标选区想上滑复制时视口被拽回 |
| [BUG-118](bugs/BUG-118-anki-gaiji-card-image-missing.md) | ✅ | ✅ | 视频/书内查词制卡：词义外字(gaiji)图在 AnkiConnect 卡片上不显示 |
| [BUG-117](bugs/BUG-117.md) | ✅ | ✅ | 书内跳转超链接点击「只加遮罩、不跳转」（Windows fork 不触发 shouldOverrideUrlLoading） |
| [BUG-116](bugs/BUG-116.md) | ✅ | ✅ | gamepads_windows 手柄插件 teardown 崩溃 + 后台线程调 channel |
| [BUG-115](bugs/BUG-115.md) | ✅ | ✅ | texthooker WebSocket 连接失败异常逃逸 zone（错误日志刷屏） |
| [BUG-114](bugs/BUG-114.md) | ✅ | ✅ | 桌面剪贴板被占用时未捕获 PlatformException 逃逸 zone |
| [BUG-113](bugs/BUG-113.md) | ✅ | ✅ | 查词点制卡按钮闪退（Windows，看视频/有声书时高频） |
| [BUG-112](bugs/BUG-112.md) | ✅ | ✅ | 有声书暂停后点「前进/后退」(按句模式) 会跳两次（下一句跳回当前句、上一句乱跳） |
| [BUG-111](bugs/BUG-111.md) | ✅ | ✅ | 桌面端放大「界面大小」后进阅读器，正文初始只铺半边（需手动 resize 才铺满） |
| [BUG-110](bugs/BUG-110.md) | ✅ | ✅ | 竖排书有声书跟随/查词高亮在振假名(ruby)字上出现深色带遮字 |
| [BUG-109](bugs/BUG-109.md) | ✅ | ✅ | 阅读器切换主题/字体时正文「翻页」（当前阅读位置跳到相邻页） |
| [BUG-108](bugs/BUG-108.md) | ✅ | ✅ | 查词弹窗义项里的振假名(ruby)与漢字重叠 |
| [BUG-107](bugs/BUG-107.md) | ✅ | ✅ | 查词弹窗点图片放大后关不掉 |
| [BUG-106](bugs/BUG-106.md) | ✅ | ✅ | 桌面端视频播放鼠标光标不自动隐藏 |
| [BUG-105](bugs/BUG-105.md) | ✅ | ✅ | 视频字幕把 ASS 标签当文本显示（`{\an8}` 等控制码漏出），应解析渲染其语义 |
| [BUG-104](bugs/BUG-104.md) | ✅ | ✅ | 大容器（27GB BluRay REMUX）切换内嵌字幕「点了没切换过去」 |
| [BUG-103](bugs/BUG-103.md) | ✅ | ✅ | 视频统计纵坐标恒显示「0m 0m 0m 0m 0m」（观看时长不足 1 分钟时被整除成 0） |
| [BUG-102](bugs/BUG-102.md) | ✅ | ✅ | 视频播放页有两条顶栏（Scaffold AppBar + media_kit 视频内顶栏），重复无意义 |
| [BUG-101](bugs/BUG-101.md) | ✅ | ✅ | 点「立即同步」时若已有后台同步在跑，只弹「同步进行中」吐司、不显示进度条 |
| [BUG-100](bugs/BUG-100.md) | ✅ | ✅ | 阿拉伯语（及一切空格分词语言）查词把单词从中间砍出无关词头：搜 "أمنيات العيد" 出来 "أم"(母亲) |
| [BUG-099](bugs/BUG-099.md) | ✅ | ✅ | 阅读器翻页方向键不跟随阅读方向（竖排 RTL 书「下一页」错绑成右箭头） |
| [BUG-098](bugs/BUG-098.md) | ✅ | ✅ | 查词弹窗遮挡被查的词（空间不足时弹窗顶边被拉到选区之上） |
| [BUG-097](bugs/BUG-097.md) | ✅ | ✅ | 书内跳转超链接点击后白屏、不跳转（内部链接被当外部链接交给系统浏览器） |
| [BUG-096](bugs/BUG-096.md) | ✅ | ✅ | 书内设置（宽窗 master-detail）整张一块滚动、左父菜单不固定 |
| [BUG-095](bugs/BUG-095.md) | ✅ | ✅ | 视频里查词仍每次白屏（白屏≈发音音频时长）：视频走另一套弹窗系统，BUG-093 没覆盖到 |
| [BUG-094](bugs/BUG-094.md) | ✅ | ✅ | 视频 tab 页头标题字号 / 动作按钮位置与书架、词典不统一 |
| [BUG-093](bugs/BUG-093.md) | ✅ | ✅ | 阅读器/视频查词弹窗每次都先「白屏一下」再出内容（每次查词都冷启动 WebView） |
| [BUG-092](bugs/BUG-092.md) | ✅ | ✅ | 宽屏设置：详情面板设置项少时整体垂直居中（应靠上） |
| [BUG-091](bugs/BUG-091.md) | ✅ | ✅ | 制卡偶发「Write failed errno 10053」失败（Anki 正常）：陈旧 keep-alive 连接上 addNote 不重试 |
| [BUG-090](bugs/BUG-090.md) | ✅ | ✅ | Windows 启动时「系统主题」不吃系统主题色（恒落到硬编码 teal，从不跟随 OS 强调色） |
| [BUG-089](bugs/BUG-089.md) | ✅ | ✅ | 制卡（Anki 导出）失败时原因全丢：toast 只显示通用「导出卡片失败」、错误日志页也查不到 |
| [BUG-088](bugs/BUG-088.md) | ✅ | ✅ | 书籍 epub 内容从不上传到云端（磁盘无 .epub，`epubPath` 是纯文件名恒不存在） |
| [BUG-087](bugs/BUG-087.md) | ✅ | ✅ | Google Drive 同步大文件「进度一点没动 / 超时 / 永远传不完」（单次 multipart 而非分块续传） |
| [BUG-086](bugs/BUG-086.md) | ✅ | ✅ | 同步进度里出现「不存在的词典」+ 内网同步特别慢（词典暂存区孤儿被反复重拉） |
| [BUG-085](bugs/BUG-085.md) | ✅ | ✅ | Hibiki 互联服务端：切出「同步与备份」界面就把服务端关掉了 |
| [BUG-084](bugs/BUG-084.md) | ✅ | ✅ | 本机作为 Hibiki 服务端时点「立即同步」误报「请先设置同步后端」 |
| [BUG-083](bugs/BUG-083.md) | ✅ | ✅ | 同步进行中弹出/打开「本地 vs 远端」对比会打断同步、并卡加载甚至连接超时 |
| [BUG-082](bugs/BUG-082.md) | ✅ | ✅ | 批量导入词典时每个失败项阻塞约 3 秒、无统一汇总 |
| [BUG-081](bugs/BUG-081.md) | ✅ | ✅ | 视频运行时手动加载字幕后，重进视频字幕丢失、要再手动加载 |
| [BUG-080](bugs/BUG-080.md) | ✅ | ✅ | 查词弹窗渲染慢（WebView 冷加载串行排在 FFI 查询之后） |
| [BUG-079](bugs/BUG-079.md) | ✅ | ✅ | 某些日文 EPUB（Kadokawa/BookWalker 导出）正文整页空白 |
| [BUG-078](bugs/BUG-078.md) | ✅ | ✅ | 非第一个词典/音频来源无法拖到第一位（等高行的拖拽中点判定漏掉索引 0） |
| [BUG-077](bugs/BUG-077.md) | ✅ | ✅ | 制卡「+」点击后永久卡在加号、无任何提示（查词浮窗） |
| [BUG-076](bugs/BUG-076.md) | ✅ | ✅ | .m3u8/.m3u 播放列表无法拖动导入（桌面拖放被静默忽略） |
| [BUG-075](bugs/BUG-075.md) | ✅ | ✅ | 降级（旧版装到新版之上）路径在 foreign_keys=ON 下 DROP 表崩溃 + 非原子半删毁库 |
| [BUG-074](bugs/BUG-074.md) | ✅ | ✅ | 视频字幕播放完不消失，一句播完到下一句开始前一直挂着 |
| [BUG-073](bugs/BUG-073.md) | ✅ | ✅ | TrueHD 音轨的电影（及有声书）播放无声音（全平台 media_kit libmpv 缺 TrueHD 解码器） |
| [BUG-072](bugs/BUG-072.md) | ✅ | ✅ | 视频查词暂停后，关闭查词窗不自动续播 |
| [BUG-071](bugs/BUG-071.md) | ✅ | ✅ | 视频切换「内封字幕」无字幕显示，外挂字幕正常 |
| [BUG-070](bugs/BUG-070.md) | ✅ | ✅ | 桌面端（Windows/media_kit）拖动有声书播放速度滑条闪退（进程级崩溃） |
| [BUG-069](bugs/BUG-069.md) | ✅ | ✅ | 查词弹窗「从本句播放」跨多章，书籍文字第一次只跟一章、第二次才到位 |
| [BUG-068](bugs/BUG-068.md) | ✅ | ✅ | Windows（及所有 Material 平台）中文等非日语 UI 字体发怪：整个 app 界面被钉死用日语字体 + ja locale 渲染，汉字显示成日文字形 |
| [BUG-067](bugs/BUG-067.md) | ✅ | ✅ | 桌面端（Windows）拖动重排必须长按左键等 ~500ms 才生效（词典 / 音频源 / 字体 / 同步 URL 列表），鼠标按住即拖不响应 |
| [BUG-066](bugs/BUG-066.md) | 🚧 | ✅ | 一次性导入大量词典（~50 本）整个 app 崩溃 |
| [BUG-065](bugs/BUG-065.md) | ✅ | ✅ | 桌面端 Anki「获取牌组/模型」秒报错 `Cannot connect to AnkiConnect: ClientException with SocketException: Write failed (errno=10053)`（常驻 http.Client 复用 keep-alive 死连接） |
| [BUG-064](bugs/BUG-064.md) | ✅ | ✅ | 导出本地备份时 UI 卡死「未响应」+ 备份里根本没有 epub 书籍/有声书文件（同步 ZipEncoder 在 UI isolate 全内存压缩；备份只打 db） |
| [BUG-063](bugs/BUG-063.md) | ✅ | ✅ | Google Drive 同步在 access token 过期约 1 小时后报 `同步错误：Access was denied (... error="invalid_token")`，自动刷新永不触发，需手动重登 |
| [BUG-062](bugs/BUG-062.md) | ✅ | ✅ | 阅读器有声书场景下按空格翻页（应为播放/暂停） |
| [BUG-061](bugs/BUG-061.md) | ✅ | ✅ | 「从本句播放」音频先跳到音频开头→章节开头→才到正确位置（三段跳） |
| [BUG-060](bugs/BUG-060.md) | ✅ | ✅ | 有声书音频高亮随阅读累积偏移（~1 万字处偏 2 字） |
| [BUG-059](bugs/BUG-059.md) | ✅ | ✅ | 导入文件夹词典时被「强制 ZIP64」打包的词典报 `Exception: unsupported format or failed to open file`（native 手写 ZIP 解析器不支持 per-entry ZIP64 扩展字段） |
| [BUG-058](bugs/BUG-058.md) | ✅ | ✅ | 词典管理某类型 tab 无该类型词典时的空状态样式与「完全无词典」不一致（左对齐灰卡 vs 居中带图标提示） |
| [BUG-057](bugs/BUG-057.md) | ✅ | ✅ | wty-ja-en 等 Wiktionary 非词目（non-lemma / alt-of）释义显示成乱码 `时Hyōgai时alt-of时alternative时kanji`（未识别的 `[词, [标签]]` 数组 glossary 被平坦化成无间隔裸文本） |
| [BUG-056](bugs/BUG-056.md) | ✅ | ✅ | 视频制卡（及 Windows 阅读器/词典制卡）不带单词发音音频（Anki 媒体落库路径漏判 Windows 盘符本地路径，与 BUG-046 同源） |
| [BUG-055](bugs/BUG-055.md) | ✅ | ✅ | 调整界面大小后，视频内查词弹窗的字发糊（查词浮层在缩放小画布栅格化再被拉大） |
| [BUG-054](bugs/BUG-054.md) | ✅ | ✅ | 调整「界面大小」后词典查词结果文字发糊（词典 WebView 漏接界面缩放中和器，与阅读器 BUG-039 同因） |
| [BUG-053](bugs/BUG-053.md) | ✅ | ✅ | 导入本地音频后「没了」/不生效（「管理音频来源」对话框导入只入内存，仅底部「关闭」按钮才落盘，点遮罩/返回退出即丢失） |
| [BUG-052](bugs/BUG-052.md) | ✅ | ✅ | 词典弹窗里词典名（折叠条 `▼` 标签）显示成一堆乱码 `▼������`（native `add_dict` 对 glaze 零拷贝 `string_view` 的 use-after-free） |
| [BUG-051](bugs/BUG-051.md) | ✅ | ✅ | app 外查词弹窗的「下钻子弹窗好小」+「横滑关闭子弹窗会把整张卡片一起平移」（嵌套层复用阅读器小浮卡 + 外层 Listener 横滑冒泡） |
| [BUG-050](bugs/BUG-050.md) | ✅ | ✅ | Windows 批量导入词典中途报 `PathAccessException: Rename failed … (OS Error: 拒绝访问。, errno = 5)`（AV/索引器瞬时锁住刚写盘的词典目录，发布 rename 失败） |
| [BUG-049](bugs/BUG-049.md) | ✅ | ✅ | 「本地 vs 远端」对比框总有一条「可下载」却永远下不下来（远端文件夹只剩同步元数据、无 .epub 内容） |
| [BUG-048](bugs/BUG-048.md) | ✅ | ✅ | 设置页文本框（Anki 设置 Host 等）聚焦后按「↓」焦点向上跳而非到下一行（设置文本框没注册成方向导航锚点） |
| [BUG-047](bugs/BUG-047.md) | ✅ | ✅ | 安卓端谷歌云盘「检查账户」显示「未登录」/「已登录」却没有账户名（移动端从不 signInSilently 恢复会话） |
| [BUG-046](bugs/BUG-046.md) | ✅ | ✅ | Windows 上查词点「♪」播放本地音频没声音、按钮变「✕」（播放分发漏判 Windows 盘符路径） |
| [BUG-045](bugs/BUG-045.md) | ✅ | ✅ | Windows 上导入日文命名词典 / 含日文名的推荐词典报「unsupported format or failed to open file」（native 把 UTF-8 路径当 ANSI 解码） |
| [BUG-044](bugs/BUG-044.md) | ✅ | ✅ | 词典管理页长按拖拽重排时拖拽浮层向右下漂移、飞离原位（界面缩放下 SDK ReorderableListView 坐标错配） |
| [BUG-043](bugs/BUG-043.md) | ✅ | ✅ | 阅读器内按 Esc / 手柄 B 不退出书籍，反而切换底栏（Esc 被「切底栏」抢占） |
| [BUG-042](bugs/BUG-042.md) | ✅ | ✅ | 手机阅读器设置弹窗「布局与显示」子页没法上下滑动（嵌入式 shrinkWrap ListView 吃掉触摸拖动） |
| [BUG-041](bugs/BUG-041.md) | ✅ | ✅ | 「Local vs Remote」对比对话框点 Apply 不下载远端独有书 |
| [BUG-040](bugs/BUG-040.md) | ✅ | ✅ | 点「编辑书籍 CSS」画面卡好久才出来（initState 在 UI 线程同步递归遍历整个解压书目录） |
| [BUG-039](bugs/BUG-039.md) | ✅ | ✅ | 放大「界面大小」后阅读器正文/划词弹窗/选区高亮发糊 |
| [BUG-038](bugs/BUG-038.md) | ✅ | ✅ | 桌面端书架卡片只能长按弹上下文菜单，鼠标右键无效（PC 用户惯例是右键） |
| [BUG-037](bugs/BUG-037.md) | ✅ | ✅ | 设置「同步与备份」页手机触摸上下滑动会跳跃 |
| [BUG-036](bugs/BUG-036.md) | ✅ | ✅ | 手机端谷歌云盘「立刻同步」开有声书文件/词典同步时 OOM 闪退 + UI 卡死 |
| [BUG-035](bugs/BUG-035.md) | ✅ | ✅ | Hibiki 互联：主机可达却报「No reachable Hibiki server address」（新开启服务器从未创建 WebDAV 根目录） |
| [BUG-034](bugs/BUG-034.md) | ✅ | ✅ | 谷歌云盘（Google Drive 同步）桌面端重启后掉登录 |
| [BUG-033](bugs/BUG-033.md) | ✅ | ✅ | 书架右上图标按钮按方向键「下」焦点跳到左侧导航栏（而非下方内容） |
| [BUG-032](bugs/BUG-032.md) | ✅ | ✅ | 歌词模式播放中进程被杀，音频进度归零 |
| [BUG-031](bugs/BUG-031.md) | ✅ | ✅ | 有声书音量调完退出重开书后不保存（恒回 1.0） |
| [BUG-030](bugs/BUG-030.md) | ✅ | ✅ | 「管理音频来源」对话框里光标停在 URL 输入框时按方向键上下移不动焦点 |
| [BUG-029](bugs/BUG-029.md) | ✅ | ✅ | 「管理音频来源」本地库行「调整」按钮与开关列错位 + 缩放后长按拖拽排序飞出屏幕 |
| [BUG-028](bugs/BUG-028.md) | ✅ | ✅ | 阅读器快捷设置弹窗底部动作行右侧溢出 3.3px（RenderFlex overflow） |
| [BUG-027](bugs/BUG-027.md) | ✅ | ✅ | 有声书进度区「音频总长度」恒显示 0 |
| [BUG-026](bugs/BUG-026.md) | ✅ | ✅ | 快速连点底栏「调整」会弹出两个面板（重入无守卫） |
| [BUG-025](bugs/BUG-025.md) | ✅ | ✅ | 固定布局 EPUB 封面（SVG）在阅读器里右贴边不居中、且无法点击放大 |
| [BUG-024](bugs/BUG-024.md) | ✅ | ✅ | 阅读器底栏「调整」面板打开慢半拍（开面板前空跑设置同步风暴） |
| [BUG-023](bugs/BUG-023.md) | ✅ | ✅ | 阅读器内调整字体大小后页面错位、最上一行被裁切 |
| [BUG-022](bugs/BUG-022.md) | ✅ | ✅ | 调大/调小界面大小后点不到底栏（及右侧）按钮——缩小时整片命中死区 |
| [BUG-021](bugs/BUG-021.md) | ✅ | ✅ | 反转阅读器底栏把 ⏮⏯⏭ 前进后退也镜像了，方向操作颠倒 |
| [BUG-020](bugs/BUG-020.md) | ✅ | ✅ | 阅读器切换底栏时 `_chromeFocusScope.nextFocus()` 空指针崩（scheduler 异常） |
| [BUG-019](bugs/BUG-019.md) | ✅ | ✅ | Windows 上打开「带有声书的 EPUB」阅读器永久白屏（内容空白、窗口可动） |
| [BUG-018](bugs/BUG-018.md) | ✅ | ✅ | 词典弹窗字级光标焦点环落在空盒子/细条上（与图标错位） |
| [BUG-017](bugs/BUG-017.md) | ✅ | ✅ | 歌词模式当前行被放大后溢出左右边框、文字贴边裁切 |
| [BUG-016](bugs/BUG-016.md) | ✅ | ✅ | 同步设置「立即同步/导出/导入」手柄键盘到不了，Compare Data 按下跳到左侧导航 |
| [BUG-015](bugs/BUG-015.md) | ✅ | ✅ | 外观设置「反转底栏方向」开关按左键焦点跳到「主题」色块 |
| [BUG-014](bugs/BUG-014.md) | ✅ | ✅ | 同步对比对话框把「良性跳过」误报成「同步错误：<书名>」 |
| [BUG-013](bugs/BUG-013.md) | ✅ | ✅ | 非 Android 平台「更新」设置是可见但失效的死开关 |
| [BUG-012](bugs/BUG-012.md) | ✅ | 🚧 | md3 静态守卫扫已删除的 `_buildRailLeading()`（stale 测试，非产品 bug） |
| [BUG-011](bugs/BUG-011.md) | ✅ | ✅ | 手柄屏幕键盘「右」键落到右下对角键而非同行邻居 |
| [BUG-010](bugs/BUG-010.md) | ✅ | ✅ | 错误日志通知器在无绑定时抛异常，反噬「损坏 JSON 优雅降级」 |
| [BUG-009](bugs/BUG-009.md) | ✅ | ✅ | 桌面端「外观→iOS(Cupertino)」设置页崩坏：三栏拥挤 + 右下角 RenderFlex 溢出 + 无返回出口 |
| [BUG-008](bugs/BUG-008.md) | ✅ | ✅ | 外观设置「设计系统/深色模式」分段选项位置错乱、右侧选项被切掉 |
| [BUG-007](bugs/BUG-007.md) | ✅ | ✅ | 有声书「遇到图片暂停播放几秒」开了无效（假功能） |
| [BUG-006](bugs/BUG-006.md) | ✅ | ✅ | 改 String 型 segmented 设置（书写方向/视图模式/振假名/跨页）渲染器崩溃 |
| [BUG-005](bugs/BUG-005.md) | ✅ | ✅ | 阅读器 live 设置 hook 异步异常逃逸 zone |
| [BUG-004](bugs/BUG-004.md) | ✅ | ✅ | 设置页向下滑动会自动跳回上面，得再滑一下 |
| [BUG-003](bugs/BUG-003.md) | ✅ | ✅ | 阅读器竖排模式下部分文本显示在刘海/notch 区域 |
| [BUG-002](bugs/BUG-002.md) | ✅ | ✅ | 阅读器切章时底栏（bottom chrome）闪烁 |
| [BUG-001](bugs/BUG-001.md) | ✅ | ✅ | 给书本打标签后封面展示异常 |

<!-- BUGS-INDEX:END -->

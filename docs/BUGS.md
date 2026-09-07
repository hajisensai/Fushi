# Bug 跟踪

> 约定（Claude/Codex 必须遵守）：用户报一个 bug → **先沿真实代码路径验真伪**（复现或定位根因）。
>
> **数据结构：一 bug 一文件。** 每条 bug 是 `docs/bugs/BUG-NNN[-slug].md` 一个独立文件；
> 本文件（`docs/BUGS.md`）只是「头部约定 + 自动生成的索引表」，索引区**勿手改**。
> 这样并发 agent 各写各的文件，永不在同一处产生 git 冲突；撞号也只是两个不同文件名，
> 改个名即可，不再有冲突标记手术。
>
> 新建一条：`dart run tool/bug.dart new <slug> [标题...]`（跨本地+远端分支取下一个空号、生成骨架、重建索引）。
> 撞号了：`dart run tool/bug.dart renumber <old> <new>`（文件名 + 正文 H2 + 代码/测试引用一把改 + 自校验；
> 别手改——只改文件名不改正文 H2 会让 `bugs_per_file_guard_test` 变红）。
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

> 共 2063 条。点号进各自文件。

| BUG | 修复 | 测试 | 标题 |
|---|:--:|:--:|---|
| [BUG-2230](bugs/BUG-2230-video-web-and-work-detail-loading-no-exit.md) | ✅ | ✅ | 网页流媒体页与作品详情页的加载态没有返回入口，且 init 异常无归宿 |
| [BUG-2229](bugs/BUG-2229-video-missing-resource-no-back.md) | ✅ | ✅ | 视频资源缺失态没有返回入口，进入后无法退出 |
| [BUG-2203](bugs/BUG-2203-update-installer-self-kill-taskkill-tree.md) | ✅ | ✅ | 应用内更新静默失败：安装器被自己的 taskkill /T 连同祖先树一起杀掉，且被误诊为 app_mutex_running |
| [BUG-2202](bugs/BUG-2202-clip-export-tx3g-unplayable-in-im.md) | ✅ | ✅ | 内封 tx3g 字幕轨让导出的片段在 QQ 等 IM 里整个不可播 |
| [BUG-2201](bugs/BUG-2201-video-pending-scrape-has-no-visible-surface.md) | ✅ | ✅ | 待确认身份的作品在视频页零提示用户无从知道要去确认 |
| [BUG-2200](bugs/BUG-2200-clip-export-moov-at-tail-qq-cannot-play.md) | ✅ | ✅ | 导出的视频片段 moov 在文件末尾，QQ 等 IM 判无法播放 |
| [BUG-2199](bugs/BUG-2199-scrape-sweep-process-once-misses-new-imports.md) | ✅ | ✅ | 自动补刮以进程为幂等键致本会话新入库作品永不补刮 |
| [BUG-2198](bugs/BUG-2198-subtitle-hide-pause-reveal.md) | ✅ | ✅ | 隐藏字幕在暂停/查词时不恢复显示 |
| [BUG-2197](bugs/BUG-2197-asr-isolate-android-ffmpeg-kit-event-channel.md) | ✅ | ✅ | Android 上 ASR 后台 isolate 因 ffmpeg_kit 订阅 EventChannel 崩溃 |
| [BUG-2196](bugs/BUG-2196-reader-newline-splits-sentence.md) | ✅ | ✅ | 阅读器把源码换行当句子分隔符，制卡拿到半截句、音频漏词 |
| [BUG-2195](bugs/BUG-2195-ankidroid-parallel-build-invisible.md) | ✅ | ✅ | AnkiDroid 并行版（com.ichi2.anki.A）不被识别、权限框从不弹出 |
| [BUG-2194](bugs/BUG-2194-youtube-caption-track-cap-drops-original.md) | ✅ | ✅ | 扩展 YouTube 轨枚举被 12 条上限截掉原语言英语轨 |
| [BUG-2193](bugs/BUG-2193-backup-export-drops-all-dicts-on-one-ghost-row.md) | ✅ | ✅ | 本地备份导出：一条幽灵词典元数据行让全部词典静默不打包 |
| [BUG-2192](bugs/BUG-2192-netflix-clip-black-border.md) | ✅ | ✅ | 网飞录屏制卡的动图/静帧四周带播放器黑边 |
| [BUG-2191](bugs/BUG-2191-netflix-ttml-ruby-reading-leaks-into-cue.md) | ✅ | ✅ | 网飞 TTML 振假名读音混进字幕正文与制卡句子 |
| [BUG-2190](bugs/BUG-2190-anki-gaiji-alt-text-overlap.md) | ✅ | ✅ | 制卡释义外字退化 alt 文本沿用图片盒几何与正文重叠 |
| [BUG-2189](bugs/BUG-2189-netflix-batch-mine-word-audio-token-expired.md) | ✅ | ✅ | 网飞批量制卡单词音频落空：入队冻结的短命 token URL 生成时已过期 |
| [BUG-2188](bugs/BUG-2188-dict-download-failure-reason-swallowed.md) | ✅ | ✅ | 词典下载失败原因被吞：单行标题截断 + 摘要措辞错成导入失败 + 无镜像回退 |
| [BUG-2187](bugs/BUG-2187-custom-theme-reader-colors-dead.md) | ✅ | ✅ | 自定义主题的正文/背景/选区/链接色在阅读器里永远不生效（key 严格等值 + 读已停写的旧扁平偏好） |
| [BUG-2170](bugs/BUG-2170-netflix-batch-intro-overlay.md) | ✅ | ✅ | Netflix 批量自动制卡切集后把片头年龄分级 overlay 录进卡片 |
| [BUG-2169](bugs/BUG-2169-sync-non-drive-transient-no-retry.md) | 🚧 | 🚧 | 非 Google Drive 云后端瞬时网络错误零重试 |
| [BUG-2168](bugs/BUG-2168-cf-download-redirects-to-github.md) | ✅ | ✅ | 下载页选 Cloudflare 镜像却被 302 到 GitHub |
| [BUG-2167](bugs/BUG-2167-windows-exit-abort-gamepads-static-thread.md) | ✅ | ✅ | Windows 每次退出 fail-fast 崩溃 0xc0000409：gamepads 全局对象析构 joinable std::thread |
| [BUG-2166](bugs/BUG-2166-lookup-popup-border-hidden-by-webview.md) | ✅ | ✅ | 查词浮层四边描边被 WebView 盖住（只剩顶栏和圆角弧可见） |
| [BUG-2165](bugs/BUG-2165-pack-download-no-visible-progress.md) | ✅ | ✅ | 推荐包后台下载没有任何看得见的地方，半截包重启后既看不见也续不上 |
| [BUG-2164](bugs/BUG-2164-asr-pcm-mov-chapter-track-noise.md) | ✅ | ✅ | ASR PCM 抽取 mov 容器混入章节 text 轨，奇数字节标题的整章解成白噪声 |
| [BUG-2163](bugs/BUG-2163-asr-match-start-anchor-colophon.md) | ✅ | ✅ | ASR 字幕匹配起点被片头出版社名钉到书尾版权页，整本匹配率 0% |
| [BUG-2162](bugs/BUG-2162-schema-drift-v95-missing-columns.md) | ✅ | ✅ | 用户库 user_version=95 却缺 v52/v57/v87/v88 台阶产物，导入书撞 epub_books 无 language 列 |
| [BUG-2161](bugs/BUG-2161-mdx-loose-asset-scan-and-size-limits.md) | 🚧 | 🚧 | MDX 松散资源两条上限缺口：img src 只扫前 50 条词条、zip 全取无总量上限 |
| [BUG-2160](bugs/BUG-2160-mdx-import-oom-ios.md) | ✅ | ✅ | iOS 导入大 MDX 词典闪退：整本词典在内存里物化，jetsam 直接杀进程 |
| [BUG-2159](bugs/BUG-2159-netflix-ext-mine-audible-playback.md) | ✅ | ✅ | 网飞扩展批量制卡期间扬声器出声 |
| [BUG-2158](bugs/BUG-2158-dict-collapse-missing-explicit-expand-state.md) | ✅ | ✅ | 词典折叠只有两个态：点「展开」对自动展开窗口外的词典毫无反应 |
| [BUG-2157](bugs/BUG-2157-plain-mode-inline-fs-overrides-user-font-size.md) | ✅ | ✅ | 关闭尊重字幕自带样式后行内 fs 仍覆盖用户字号，字号滑块整条失效 |
| [BUG-2156](bugs/BUG-2156-video-subtitle-list-font-cap-too-low.md) | ✅ | ✅ | 字幕列表字号上限还是不够（BUG-878 抬到 2.0× 后的第二次反馈） |
| [BUG-2155](bugs/BUG-2155-anki-pitch-tags-overflow-card-header.md) | ✅ | ✅ | 音标标签框撑爆卡头：60dvw 视口上限 + 单行不换行，窄卡上把封面顶出视口 |
| [BUG-2154](bugs/BUG-2154-gal-lookup-verified-unreachable.md) | ✅ | ✅ | 内嵌查词对每个游戏都恒需手动「确认点击风险」：shield 的 Verified 状态在 hook 里无任何生产者、结构上不可达 |
| [BUG-2153](bugs/BUG-2153-gal-exe-level-identity-gates.md) | ✅ | ✅ | galgame 引擎身份判据绑死单个 exe（文件名/SHA-256/硬编码 RVA），改名或换版本即整个 adapter 不被认领 |
| [BUG-2152](bugs/BUG-2152-anki-mined-ipa-duplicated.md) | ✅ | ✅ | 英语制卡音标重复两遍 —— 同一 PitchEntry 的 transcriptions 数组内没有去重 |
| [BUG-2151](bugs/BUG-2151-anki-pitch-tags-ol-markup.md) | ✅ | ✅ | Anki 卡片音标黑框巨大且无分隔符 —— popup.js 产出 `<ol>`，Lapis `#pitch-tags` 样式契约是 `ul` |
| [BUG-2150](bugs/BUG-2150-ios-ankimobile-pasteboard-read-inactive.md) | ✅ | ✅ | iOS AnkiMobile 配置回传读不到剪贴板：URL 回调跑在 .inactive 阶段 |
| [BUG-2149](bugs/BUG-2149-gal-adapter-diagnostics-write-only.md) | ✅ | ✅ | AdapterDiagnostics 是只写接口：运行期没有消费方，任何引擎都读不出 adapter 是否命中并安装 |
| [BUG-2148](bugs/BUG-2148-korean-deinflection-never-fires.md) | ✅ | ✅ | 韩语词形还原一条都点不着火：ko.json 用兼容字母而引擎不拆谚文，划词只剩 1 个音节 |
| [BUG-2147](bugs/BUG-2147-mdx-loose-sibling-assets-dropped.md) | ✅ | ✅ | MDX 松散兄弟资源（sound.png / 图标字体）从不进 media store，发音按钮渲染成 0x0 破图 |
| [BUG-2146](bugs/BUG-2146-episode-in-season-block.md) | ✅ | ✅ | 括号块内「季 - 集」形态解不出集数，下载任务报 unable to determine episode number |
| [BUG-2145](bugs/BUG-2145-gal-kirikiri2-no-export-table-and-late-loadlibrary-hook.md) | ✅ | ✅ | KiriKiri2 无导出表 + 插件早于 LoadLibrary hook link：两条 exporter 路径同时静默落空，游戏内查词整条不装 |
| [BUG-2144](bugs/BUG-2144-gal-kirikiri2-bcb-exception-escapes-msvc-catch.md) | ✅ | ✅ | KiriKiri2/BCB 上 TJS 抛的 Borland 异常穿透 MSVC catch(...)，注入的每帧求值把游戏打成致命错误框并强制写快速存档 |
| [BUG-2143](bugs/BUG-2143-attached-status-without-reason-undiagnosable.md) | ✅ | 🚧 | attached 状态机十二处 `needsRiskAcceptance` / `needsCalibration` / `waitingForBodyThread` 不带 reason，真机上无法定位是哪条分支 |
| [BUG-2142](bugs/BUG-2142-attached-provider-claim-livelock.md) | ✅ | ✅ | 被抢占的旧轮次撤回 attached provider 认领，与注入侧 registry 形成活锁 |
| [BUG-2141](bugs/BUG-2141-attached-risk-accepted-but-status-traps.md) | ✅ | 🚧 | profile 里风险已接受时 `needsRiskAcceptance` 变成死局：不生成 request、按钮不渲染、也没有恢复触发点 |
| [BUG-2140](bugs/BUG-2140-attached-first-lookup-disarms-shield-click-passes-through.md) | — | ✅ | 第一次查词后 attached 表面再也武装不起来，之后每次点击都穿透并推进剧情 |
| [BUG-2139](bugs/BUG-2139-attached-body-thread-recovery-edge-only.md) | ✅ | ✅ | attached 从 `waitingForBodyThread` 的恢复只挂在「正文从无到有」这一次性边沿上 |
| [BUG-2138](bugs/BUG-2138-attached-dwrite-baseline-breaks-japanese-clusters.md) | ✅ | 🚧 | attached 子面 DirectWrite 基线硬编码 0.8em，日文正文必然上溢版面框，字形簇永远建不出来 |
| [BUG-2137](bugs/BUG-2137-attached-noglyphclusters-withdraws-claim.md) | ✅ | ✅ | attached 子面回 `noGlyphClusters` 时撤回了跨轮次共享的 provider 认领，与 BUG-2142 是同一个活锁的另一道门 |
| [BUG-2136](bugs/BUG-2136-hunex-body-glyph-coords-are-logical-layer-local.md) | ✅ | ✅ | WoH 正文字形 render x/y 是「1920×1080 逻辑空间的文本层局部坐标」，客户区映射已实测成立，只差层原点 |
| [BUG-2135](bugs/BUG-2135-hunex-body-render-has-no-compose-layer.md) | ✅ | 🚧 | WoH 正文渲染没有合成层，HUNEX 几何模型的三级 compose 假设不成立 |
| [BUG-2134](bugs/BUG-2134-hunex-compose-wrapper-anchor-never-called.md) | ✅ | ✅ | HUNEX 投影链的 compose wrapper 锚点在 WoH 上从未被调用，整条几何证据无从产生 |
| [BUG-2133](bugs/BUG-2133-hunex-deferred-selected-read-masks-failure.md) | ✅ | ✅ | HUNEX 延迟选中文本读的空窗口覆盖掉第一次读的真实失败码，且候选计数被丢弃无法分型 |
| [BUG-2132](bugs/BUG-2132-hunex-projection-chain-diagnostic-blind-spots.md) | ✅ | ✅ | HUNEX 投影链段 3/段 4 的拒绝路径无诊断，真机读不出断在哪一环 |
| [BUG-2131](bugs/BUG-2131-hunex-loopback-ack-timeout-kills-text-hook.md) | ✅ | ✅ | native loopback allow 的确认超时中止注入，导致 LunaHook 文本 hook 永不安装 |
| [BUG-2130](bugs/BUG-2130-gal-resource-late-pending-loopback-freeze-wait.md) | ✅ | ✅ | game_resource 行先 pending 后被资源匹配，制卡仍白等一个被丢弃的 loopback 冻结窗 |
| [BUG-2129](bugs/BUG-2129-woh-hunex-realmachine-lookup-boundary.md) | 🚧 | 🚧 | 真机 WoH(HUNEX)合并构建:拉起/hook/音频/文本/风险确认均通过,原生几何 fail-closed 退到 attached 需标定 |
| [BUG-2128](bugs/BUG-2128-kirikiri-ingame-click-advances-no-card.md) | 🚧 | 🚧 | 真机:KiriKiri(Limelight)游戏内单击文字推进对白而非弹查词卡,悬停高亮正常 |
| [BUG-2127](bugs/BUG-2127-gal-mining-audio-before-utterance-settles.md) | ✅ | ✅ | 台词一出就制卡只拿到句子音频的开头（引擎 PCM 收敛 / loopback 冻结未收口） |
| [BUG-2126](bugs/BUG-2126-galgame-locale-launch-early-injection-kills-kirikiri.md) | ✅ | ✅ | 转区（Locale Emulator）拉起 + 早注入让 x86 KiriKiri 游戏进程随即死亡，退回附着才可用 |
| [BUG-2125](bugs/BUG-2125-gal-attached-popup-outside-click-passthrough.md) | ✅ | ✅ | attached 校准表面弹出的桌面查词卡点外关闭时点击透传给游戏推进台词 |
| [BUG-2124](bugs/BUG-2124-video-wall-hover-lift-lags-scroll.md) | ✅ | ✅ | 视频墙格滚动时放大态残留在已滚走的卡上 |
| [BUG-2123](bugs/BUG-2123-global-lookup-first-frame-topleft-flash.md) | ✅ | ✅ | app 外全局查词弹窗首帧先闪在屏幕左上角再飞到光标 |
| [BUG-2122](bugs/BUG-2122-pitch-duplicate-rows.md) | ✅ | ✅ | 音调区同一音调型被多本词典重复渲染成多行 |
| [BUG-2121](bugs/BUG-2121-gal-main-window-owned-by-hidden-vcl-owner.md) | ✅ | ✅ | FindGameMainWindow 排除所有有 owner 的窗口：BCB VCL 窗体被隐藏 TApplication own，KiriKiri2 查词安装 / exe 直取门 / overlay owner 整局静默失败 |
| [BUG-2120](bugs/BUG-2120-desktop-oauth-no-manual-link.md) | ✅ | ✅ | 桌面云盘 OAuth 登录无「复制链接/重开/取消」兜底，浏览器页失败只能等 5 分钟超时 |
| [BUG-2119](bugs/BUG-2119-sqlite-busy-statement-poisons-connection-exit-trap.md) | ✅ | ✅ | 视频页 Esc/返回退不出去：写语句 SQLITE_BUSY 后未 reset 毒化整条连接，退出被落库绑架 |
| [BUG-2118](bugs/BUG-2118-gal-kirikiri2-exporter-called-before-static-init.md) | ✅ | ✅ | 启动期过早调用 TVPGetFunctionExporter 抢在引擎静态构造之前，导出表随后被构造函数重置致插件链接全失败 |
| [BUG-2117](bugs/BUG-2117-shortcut-scope-order.md) | ✅ | ✅ | 快捷键设置页 scope 卡片顺序是枚举累加顺序而非通用→页面→设备 |
| [BUG-2116](bugs/BUG-2116-gal-classic-kag3-class-patch-invisible-to-instances.md) | ✅ | ✅ | 经典 KAG3 游戏内查词传感器给 TJS 类对象打补丁对实例永远不可见 |
| [BUG-2115](bugs/BUG-2115-kirikiri-voice-stream-filter-captures-se-bgm.md) | ✅ | ✅ | KiriKiri 资源流语音过滤按裸 .ogg/.opus 后缀把 SE/BGM/脚本当语音并配给旁白 |
| [BUG-2114](bugs/BUG-2114-kirikiri-direct-route-term-highlight-missing.md) | ✅ | ✅ | KiriKiri 直连路由下被查整词不高亮，只亮点击的单字 |
| [BUG-2113](bugs/BUG-2113-kirikiri-ingame-card-mining-text-generation-mismatch.md) | ✅ | ✅ | KiriKiri 点击载荷 text_generation 填成 TJS 提交序号，游戏内「+」制卡恒失败 |
| [BUG-2112](bugs/BUG-2112-gal-thread-picker-artifact-thread-looks-clean.md) | ✅ | ✅ | 游戏文本线程选择器把全伪影线程当干净线程展示，选中后永远 0 行且无提示 |
| [BUG-2111](bugs/BUG-2111-context-menu-hardwired-secondary-button.md) | ✅ | ✅ | 右键菜单硬绑鼠标次按钮，把动作绑到右键会双触发 |
| [BUG-2110](bugs/BUG-2110-dict-mass-import-startup-crash.md) | ✅ | ✅ | 一次性导入大量词典后启动转圈中途闪退 |
| [BUG-2109](bugs/BUG-2109-recommended-pack-never-deleted.md) | ✅ | ✅ | 推荐包 9.5GB zip 导入后永不删除（清理钩子挂在不再执行的引导页 initState） |
| [BUG-2108](bugs/BUG-2108-video-rewatch-counted.md) | ✅ | ✅ | 视频回放/重看被重复计入观看时长 |
| [BUG-2107](bugs/BUG-2107-onboarding-pack-pick-bare-filepicker.md) | ✅ | ✅ | 引导选本地包走裸 pickFiles：安卓整份复制进 cache，失败静默无提示 |
| [BUG-2106](bugs/BUG-2106-backup-validating-overlay-destroys-caller-route.md) | ✅ | ✅ | 备份 validating 遮罩换根摧毁调用方路由：引导选包后引导蒸发且无提示 |
| [BUG-2105](bugs/BUG-2105-fullscreen-episode-switch-mobile-orientation.md) | ✅ | ✅ | 移动端换集后掉出全屏：旧页 dispose 无条件放开横屏锁并清空系统栏回调 |
| [BUG-2104](bugs/BUG-2104-release-event-ships-debug-apk-on-formal.md) | ✅ | ✅ | 手动发 GitHub Release 会把 debug APK 捎带上正式版 |
| [BUG-2103](bugs/BUG-2103-video-editable-slots-dead-truth-source.md) | ✅ | ✅ | 视频控制条可编辑槽真相源零消费且与真实能力矛盾 |
| [BUG-2102](bugs/BUG-2102-video-volume-slot-order-ignored.md) | ✅ | ✅ | 视频底栏音量按钮的槽内顺序被渲染端丢弃：拖动无效 |
| [BUG-2101](bugs/BUG-2101-manga-reader-no-exit-on-load-failure.md) | ✅ | ✅ | 漫画阅读器加载失败时返回键一起消失：iOS 上无系统返回键 = 只能杀进程 |
| [BUG-2100](bugs/BUG-2100-ios-container-path-drift.md) | ✅ | ✅ | iOS 每次更新后全库绝对路径失效：书架全部「找不到书籍文件」 |
| [BUG-2099](bugs/BUG-2099-android-saf-mdx-greyed.md) | ✅ | ✅ | 安卓文件选择器把 .mdx/.dsl/.ifo/.ass 置灰选不中 |
| [BUG-2098](bugs/BUG-2098-ankidroid-permission-not-awaited.md) | ✅ | ✅ | AnkiDroid 权限申请不等结果 + 错误码域不通导致英文原文外泄 |
| [BUG-2097](bugs/BUG-2097-onboarding-pack-download-cancelled-on-leave.md) | ✅ | ✅ | 新手引导推荐包下载在离开向导时被静默取消，且没有任何看进度的地方 |
| [BUG-2096](bugs/BUG-2096-storage-category-detail-gap.md) | ✅ | ✅ | 存储页词典/书籍类目明细不覆盖总量 10.7GB 不可见 |
| [BUG-2095](bugs/BUG-2095-video-subtitle-hidden-no-hover-reveal.md) | ✅ | ✅ | 字幕隐藏后鼠标悬停/点击无法临时显形 |
| [BUG-2094](bugs/BUG-2094-secondary-subtitle-import-not-listed.md) | ✅ | ✅ | 导入的副字幕在字幕列表里消失，但画面仍在渲染它 |
| [BUG-2093](bugs/BUG-2093-subtitle-row-copy-check-vanishes.md) | ✅ | ✅ | 字幕列表行复制的 ✓ 反馈在播放头离开该行时提前消失 |
| [BUG-2092](bugs/BUG-2092-video-lookup-popup-title-bar-offset.md) | ✅ | ✅ | 视频页查词弹窗在 Windows 窗口模式整栈下移一个标题栏高压住被查词 |
| [BUG-2091](bugs/BUG-2091-video-subtitle-lookup-highlight.md) | ✅ | ✅ | 视频字幕查词后被查词在字幕上无高亮 |
| [BUG-2090](bugs/BUG-2090-overlay-hover-highlight-brush-leak.md) | ✅ | ✅ | overlay 悬浮高亮窗口类每次重建都漏一个 GDI brush |
| [BUG-2089](bugs/BUG-2089-inapp-mining-payload-bool-cast-crash.md) | ✅ | ✅ | 应用内制卡全部失败：「导出卡片失败: Invalid card data (payload parse failed): type 'String' is not a subtype of type 'bool?' in type cast」 |
| [BUG-2088](bugs/BUG-2088-release-notes-never-reach-update-dialog.md) | ✅ | ✅ | 正式版更新公告进不了应用内更新弹窗，用户看到的是一行占位符 |
| [BUG-2087](bugs/BUG-2087-sgre-looked-up-term-not-highlighted.md) | ✅ | ✅ | SGRE 游戏内查词点击后被查的词在台词里没有高亮：直连路径不把高亮区间发给 hook |
| [BUG-2086](bugs/BUG-2086-sgre-hover-glyph-highlight-missing.md) | ✅ | 🚧 | SGRE 游戏内查词鼠标悬浮在字上没有高亮反馈：只有 KiriKiri 在引擎图层画高亮 |
| [BUG-2085](bugs/BUG-2085-sgre-ingame-card-mining-text-generation-mismatch.md) | ✅ | ✅ | SGRE 游戏内卡片制卡恒失败：点击载荷 text_generation 填的是查词捕获代数而非文本行序号 |
| [BUG-2084](bugs/BUG-2084-gal-workbench-fold-breaks-on-interleaved-threads.md) | ✅ | ✅ | 工作台渐进折叠只看缓冲区尾巴，同句两次重绘之间被其它线程插队就断链 |
| [BUG-2083](bugs/BUG-2083-sgre-lookup-metrics-gate-pinned-to-4k.md) | ✅ | ✅ | SGRE 精确文本与查词几何只在 4K 全屏出现：台词面判据把行高钉死为 80，窗口模式 1080p 全断 |
| [BUG-2082](bugs/BUG-2082-gal-ingame-card-anchored-by-cap-height.md) | ✅ | ✅ | galgame 游戏内查词卡片翻到台词上方时按上限高度定位，实际卡片与台词之间留空隙 |
| [BUG-2081](bugs/BUG-2081-mihon-unit-reply-crash.md) | ✅ | ✅ | Mihon Android 通道 void 方法回 kotlin.Unit 触发 StandardMessageCodec 崩溃，Discover/Import 打开即崩 |
| [BUG-2080](bugs/BUG-2080-netflix-ext-mining-clip-timestamp-hardcoded-zero.md) | ✅ | ✅ | 浏览器扩展 Netflix 制卡的片段时间窗恒为 0，卡上永远显示不出时间 |
| [BUG-2079](bugs/BUG-2079-nyaa-search-missing-timeout.md) | ✅ | ✅ | NyaaClient.search 无超时，订阅检查可被单个慢响应挂住 |
| [BUG-2078](bugs/BUG-2078-texthooker-fastforward-fold-merges-sentences.md) | 🚧 | 🚧 | Ctrl 快进时渐进折叠把多句连同选项文本折成一条超长台词 |
| [BUG-2077](bugs/BUG-2077-web-video-mining-no-sentence.md) | ✅ | ✅ | 网页视频制卡：卡里没有例句、没有封面 |
| [BUG-2076](bugs/BUG-2076-leaf-structure-gate-reads-hooked-memory.md) | ✅ | ✅ | 白2 身份结构门扫的是被 LunaHook 改写过的进程内存，导致点击穿透+语音降级 |
| [BUG-2075](bugs/BUG-2075-macos-data-root-channel-unregistered.md) | ✅ | ✅ | macOS 更改数据位置失败：data_root_access 通道未注册 |
| [BUG-2074](bugs/BUG-2074-leaf-identity-latched-unmeasured-exe.md) | ✅ | ✅ | 白2 一次瞬时的 exe 摘要测量失败被钉成永久身份拒绝，整场语音降级 Loopback |
| [BUG-2073](bugs/BUG-2073-macos-icloud-data-root-rename-timeout.md) | ✅ | ✅ | macOS iCloud Documents 迁移到本地目录时 rename 超时并回滚 |
| [BUG-2072](bugs/BUG-2072-data-root-rollback-misses-inflight-plan.md) | 🚧 | 🚧 | 数据根迁移回滚：搬移途中抛错的 plan 从未进 done，已 rename 的顶层项随新根被删 |
| [BUG-2071](bugs/BUG-2071-data-root-rollback-skips-mixed-deferred-plan.md) | 🚧 | 🚧 | 数据根迁移回滚：混合 rename+copy 的选择性 plan 被整条跳过，已 rename 的顶层项随新根被删 |
| [BUG-2070](bugs/BUG-2070-kirikiri-wuopus-voice-degrades-to-loopback.md) | 🚧 | 🚧 | KiriKiri Z + wuopus 语音（ATRI）整句音频恒降级为系统混音 |
| [BUG-2069](bugs/BUG-2069-gal-mining-animation-shorter-than-sentence.md) | ✅ | ✅ | galgame 制卡动图固定 1.25 秒不覆盖整句语音 |
| [BUG-2068](bugs/BUG-2068-gal-engine-exact-thread-manual-select.md) | ✅ | ✅ | 引擎精确文本线程首次启动需手动选择 |
| [BUG-2067](bugs/BUG-2067-gal-workbench-folded-line-stale-words.md) | ✅ | ✅ | 工作台实时台词折叠后仍显示中间态前缀 |
| [BUG-2066](bugs/BUG-2066-gal-card-size-not-independent.md) | ✅ | ✅ | 游戏内查词卡尺寸不可独立配置，且上界用画布像素夹屏幕像素被系统性压小 |
| [BUG-2065](bugs/BUG-2065-gal-ingame-card-canvas-upscale.md) | ✅ | ✅ | 游戏内查词卡在放大运行的游戏里模糊且过大：直连覆盖窗被 1:1 闸门挡掉，回退成画布内位图合成 |
| [BUG-2064](bugs/BUG-2064-ios-share-position-origin.md) | ✅ | ✅ | iOS 截图分享缺 sharePositionOrigin 锚点导致 PlatformException |
| [BUG-2063](bugs/BUG-2063-dict-bundled-scripts-never-run.md) | ✅ | ✅ | 词典自带的 JS 从不执行 |
| [BUG-2062](bugs/BUG-2062-subtitle-workbench-scope-extra-row.md) | ✅ | ✅ | 字幕工作台作用域开关独占一行：挂在 AppBar.bottom 上，标题行右半边全空 |
| [BUG-2061](bugs/BUG-2061-subtitle-collection-download-all-not-pinned.md) | ✅ | ✅ | 合集字幕面板「下载全部」不贴底：两个 Flexible 分份额，用不满的部分落成死白 |
| [BUG-2060](bugs/BUG-2060-subtitle-collection-no-source-picker.md) | ✅ | ✅ | 「整个合集」字幕面板无法选取字幕：未绑 AniList 的合集不发首搜，来源选择区整块隐藏 |
| [BUG-2059](bugs/BUG-2059-mdd-empty-encoding-media-lost.md) | ✅ | ✅ | mdd 的 Encoding 为空时整个媒体库丢失 |
| [BUG-2058](bugs/BUG-2058-non-latin-script-chars-zero.md) | ✅ | ✅ | 非拉丁非CJK文字字数恒0：统计为0且章内进度退化成章号 |
| [BUG-2057](bugs/BUG-2057-subtitle-list-row-min-extent.md) | ✅ | ✅ | 字幕列表行高被历史固定行高 56×字号档钉死，单行（尤其英文译文）上下留白特别大 |
| [BUG-2056](bugs/BUG-2056-en-apostrophe-word-scan.md) | ✅ | ✅ | 英文缩合形/所有格查不到词：撇号被当扫描终点 + 撇号写法不归一 |
| [BUG-2055](bugs/BUG-2055-update-blocked-by-own-voice-hook.md) | ✅ | ✅ | 应用内更新被 Fushi 自己注入游戏的 voice hook 挡住，报错却称占用者为「非 Fushi 程序」 |
| [BUG-2054](bugs/BUG-2054-nested-lookup-anchor-multiline.md) | ✅ | ✅ | 嵌套查词弹窗锚在选区首行下方遮住跨行选区的第二行 |
| [BUG-2053](bugs/BUG-2053-yomitan-zip-wrapper-directory.md) | ✅ | ✅ | 带顶层文件夹的 Yomitan zip 导入失败 |
| [BUG-2052](bugs/BUG-2052-mdx-linked-css-name-mismatch.md) | ✅ | ✅ | MDX 附属 CSS 与 mdx 不同名时样式完全不生效 |
| [BUG-2051](bugs/BUG-2051-anki-open-in-anki-not-same-source.md) | ✅ | ✅ | 点已制卡 ↗ 在 Anki 中打开：反查判据与查重判据不同源，跨笔记类型的卡查不到 |
| [BUG-2050](bugs/BUG-2050-ocr-directml-availability-never-probed.md) | ✅ | ✅ | Windows OCR 从不探测 DirectML 可用性，每次任务白付一次注定失败的建会话 |
| [BUG-2049](bugs/BUG-2049-popup-disclosure-toggle-shifts-header.md) | ✅ | ✅ | 查词弹窗词典分组展开/收起时卡头位移且卡片凭空增高 |
| [BUG-2048](bugs/BUG-2048-galgame-hunex-native-structural-complexity.md) | 🚧 | 🚧 | HUNEX 原生适配层 9 处结构性复杂度待清（认知复杂度 55/44/43/40/35、24 字段类、13/12/8 参函数） |
| [BUG-2047](bugs/BUG-2047-gal-locale-auto-need.md) | ✅ | ✅ | 转区 auto 档把工程限制当判据：中文系统上 32 位游戏全转区，需要按证据判定是否需要 |
| [BUG-2046](bugs/BUG-2046-gal-luna-startup-deadlock.md) | ✅ | ✅ | 9/2 构建 fushi_voice_hook 与 LunaHook 装 hook 时同一临界区死锁：游戏启动无窗口（用户报「转区后 DLL 注入失败」） |
| [BUG-2045](bugs/BUG-2045-mihon-desktop-host-abi-drift.md) | ✅ | ✅ | 桌面 Mihon sidecar 用漫画源搜在线漫画报错（500） |
| [BUG-2044](bugs/BUG-2044-deletion-prompt-readd-arbitration.md) | ✅ | ✅ | 删除墓碑确认弹窗把本机删后重加的收藏句当成其他设备已删除 |
| [BUG-2043](bugs/BUG-2043-fullscreen-episode-switch-native-bounce.md) | ✅ | ✅ | 全屏换集先退再进原生全屏抖动、字幕列表丢失 |
| [BUG-2042](bugs/BUG-2042-grammar-tooltip-zoom-double-scaled.md) | ✅ | ✅ | 语法说明浮层定位未按内容 zoom 折算，zoom!=1 时双重缩放偏移 |
| [BUG-2041](bugs/BUG-2041-grammar-description-two-surfaces.md) | ✅ | ✅ | 语法说明有 hover 浮层和点击全屏卡片两套呈现，交互不统一 |
| [BUG-2040](bugs/BUG-2040-video-subtitle-list-steals-shortcuts.md) | ✅ | ✅ | 字幕列表打开后方向键等视频快捷键失效 |
| [BUG-2039](bugs/BUG-2039-popup-render-tail-jitter.md) | ✅ | ✅ | 查词弹窗渲染尾巴逐帧掉块、卡片跳位、高度反复变 |
| [BUG-2038](bugs/BUG-2038-grammar-description-not-localized.md) | ✅ | ✅ | 词形变化语法说明只有英文，未随界面语言本地化 |
| [BUG-2037](bugs/BUG-2037-grammar-tooltip-transparent.md) | ✅ | ✅ | 查词弹窗语法说明浮层背景半透明，透出下方词典正文 |
| [BUG-2036](bugs/BUG-2036-epub-guard-follows-plugin-symlink-loop.md) | ✅ | ✅ | 目录枚举守卫跟随 .plugin_symlinks 自指链，worktree 全量测试必崩两条 |
| [BUG-2035](bugs/BUG-2035-video-download-lease-tests-wallclock-flaky.md) | 🚧 | 🚧 | 下载租约续期测试对宿主调度抖动零容差，本机并发下必红 |
| [BUG-2034](bugs/BUG-2034-ocr-directml-fallback-utf8.md) | ✅ | ✅ | 本地漫画 OCR 因 DirectML 初始化失败 + native 错误串非 UTF-8 而整卷失败 |
| [BUG-2033](bugs/BUG-2033-header-leading-align.md) | ✅ | ✅ | 页头返回箭头与标题垂直未对齐 |
| [BUG-2032](bugs/BUG-2032-lua-scripts-unusable.md) | ✅ | ✅ | mpv Lua 脚本导入后不生效：Android libmpv 未编 Lua、导入不启用、脚本报错零诊断、osd-level=0 吞掉 osd_message |
| [BUG-2031](bugs/BUG-2031-mouse-binding-all-scopes.md) | ✅ | ✅ | 鼠标绑定只有部分动作/页面支持 |
| [BUG-2030](bugs/BUG-2030-video-keyboard-cue-skip-wakes-osc.md) | ✅ | ✅ | 键盘上/下一句字幕会把隐藏的控制条(OSC)整个弹出来 |
| [BUG-2029](bugs/BUG-2029-audiobook-download-only-audio.md) | ✅ | ✅ | 下载有声书只落孤立音频:成不了书且原因谎报 |
| [BUG-2028](bugs/BUG-2028-krkr-risk-acceptance-entry-focus-loss.md) | ✅ | ✅ | KRKR 风险确认入口在切回 Fushi 后消失 |
| [BUG-2027](bugs/BUG-2027-gal-native-input-admission-transaction.md) | 🚧 | 🚧 | Gal 原生查词风险未授权时仍吞输入，事务瞬态会拆半 |
| [BUG-2026](bugs/BUG-2026-hunex-capture-bridge-test-dead-and-racy.md) | ✅ | ✅ | hunex_gge_capture_bridge_test 的 79 条 assert 在 Release 下空跑，唤醒后 TestWorkerNeverReadsATornSnapshot 50% 概率红 |
| [BUG-2025](bugs/BUG-2025-galgame-assert-liveness-guard-unregistered.md) | ✅ | ✅ | generic_input_shield_test.cpp 的 47 条 assert 在 Release 下整批空跑（守卫写了但没接进 run_guards.ps1） |
| [BUG-2024](bugs/BUG-2024-hunex-single-click-lookup-passthrough.md) | 🚧 | ✅ | WoH/HUNEX 单击文字无法查词且点击穿透到游戏 |
| [BUG-2023](bugs/BUG-2023-torrent-ffi-listen-port-zero-ci-flake.md) | 🚧 | 🚧 | PR#1129 windows job FFI 测试 13 条红：全部 listen_port=0（未复现） |
| [BUG-2022](bugs/BUG-2022-schema-v94-test-assertions-stale.md) | ✅ | ✅ | 刮削 P1 升 schema 到 94 但漏改 43 处测试断言，堆叠 PR 拿不到真单测门导致一路合进 develop |
| [BUG-2021](bugs/BUG-2021-libtorrent-ci-compile-gate.md) | ✅ | ✅ | libtorrent native 构建在 PR 阶段无编译门（Android 侧从未在 CI 编译过） |
| [BUG-2020](bugs/BUG-2020-identity-json-path-rebase-unregistered.md) | ✅ | ✅ | 刮削 P1 新增的 identityJson 两列漏登记 kPathRebaseColumns，合入即把 develop 打红 |
| [BUG-2019](bugs/BUG-2019-sgre-ingame-lookup-provider-admission.md) | ✅ | ✅ | SGRE 游戏内查词命中被原生提供者准入门静默丢弃 |
| [BUG-2018](bugs/BUG-2018-manga-7z-archive-mokuro-ignored.md) | 🚧 | 🚧 | RAR/CBR/CB7 漫画包内嵌与旁挂 mokuro OCR 不被识别 |
| [BUG-2017](bugs/BUG-2017-epub-selfclosing-script-empty-plaintext.md) | ✅ | ✅ | EPUB 自闭合 script 标签吞掉正文导致章节纯文本为空、有声书匹配率 0 |
| [BUG-2016](bugs/BUG-2016-galgame-gate-red-on-develop.md) | ✅ | ✅ | develop 上 galgame 守卫门长期红：engine-support.yaml 缺逗号 + dll_main 行数棘轮被 include 顶破 |
| [BUG-2015](bugs/BUG-2015-reader-continuous-chapter-scroll.md) | ✅ | ✅ | 连续阅读跨章由惯性误触且整页黑屏跳转 |
| [BUG-2013](bugs/BUG-2013-reader-vertical-scroll-height-ignores-scrollbar.md) | ✅ | ✅ | 竖排滚动模式 body 高度未扣水平滚动条，末行文字被裁 |
| [BUG-2012](bugs/BUG-2012-epub-opf-namespace-prefix.md) | ✅ | ✅ | 带 opf: 前缀的 OPF 导致 manifest/spine 解析为空、EPUB 导入失败 |
| [BUG-2011](bugs/BUG-2011-clip-export-container-portability.md) | ✅ | ✅ | 视频片段导出产物只有 mpv 能播，进度条显示整集时长 |
| [BUG-2009](bugs/BUG-2009-desktop-wheel-scroll-speed-halved.md) | ✅ | ✅ | 桌面滚轮平滑修复把滚动速度砍半 |
| [BUG-2008](bugs/BUG-2008-subtitle-collection-panel-guessed-identity.md) | ✅ | ✅ | 合集字幕批量搜索只用合集名与裸 anilistId，无视已刮削的规范身份 |
| [BUG-2007](bugs/BUG-2007-organize-multi-movie-extras-swallow.md) | ✅ | ✅ | 多部电影一个种子时仅最大文件算正片，其余被扔进 Extras 不入库不刮削 |
| [BUG-2006](bugs/BUG-2006-win-fullscreen-top-accent-border.md) | ✅ | ✅ | Windows 上视频最顶部有一条 1px 强调色线（窗口铺满屏幕时） |
| [BUG-2005](bugs/BUG-2005-recent-added-portrait-slot.md) | ✅ | ✅ | 首页「最近添加」行视频卡恒竖槽，横版截帧被模糊垫底成白条 |
| [BUG-2004](bugs/BUG-2004-download-scrape-inverted-forcing.md) | ✅ | ✅ | 下载管线对错命名空间身份强制刮削致歧义卡死，无身份反而直接完成 |
| [BUG-2003](bugs/BUG-2003-download-identity-dropped-at-enqueue.md) | ✅ | ✅ | 发现页完整身份在入队时被降维，刮削/字幕只剩显示名与单 id |
| [BUG-2002](bugs/BUG-2002-video-home-cards-hover-lift.md) | ✅ | ✅ | 视频首页横滚卡/合集墙卡/远端卡缺悬停放大效果 |
| [BUG-2001](bugs/BUG-2001-scrape-planner-playlist-extras-works.md) | ✅ | ✅ | 计划器把播放列表合集与无集号特典当独立作品刮削 |
| [BUG-2000](bugs/BUG-2000-scrape-unscraped-series-never-auto.md) | ✅ | ✅ | 未刮削系列没有任何自动刮削入口，存量库永远无资料 |
| [BUG-1999](bugs/BUG-1999-scrape-source-enabled-not-exposed.md) | ✅ | ✅ | 来源刮削 enabled 开关未暴露，用户无法关闭强制刮削 |
| [BUG-1998](bugs/BUG-1998-scrape-manual-bind-worknotfound.md) | ✅ | ✅ | 手动指定作品对已不在计划的作品裸抛 VideoSourceScrapeWorkNotFound 进 UI |
| [BUG-1997](bugs/BUG-1997-dark-scrollbar-covers-list-trailing-actions.md) | ✅ | ✅ | 深色主题滚动条 8px 盖住并吞掉列表右侧操作按钮 |
| [BUG-1996](bugs/BUG-1996-mihon-extension-install-metadata-mismatch.md) | ✅ | ✅ | 漫画扩展装不上：METADATA_MISMATCH（根因未定位） |
| [BUG-1995](bugs/BUG-1995-video-mouse-side-button-dismiss-dict.md) | ✅ | ✅ | 视频页鼠标侧键关词典无效（video scope 无鼠标通道） |
| [BUG-1994](bugs/BUG-1994-profile-switch-prunes-dictionary-metadata.md) | ✅ | ✅ | 切换 profile 会删掉其他 profile 导入的词典元数据行 |
| [BUG-1993](bugs/BUG-1993-daily-goal-study-scope.md) | ✅ | ✅ | 首页每日目标只算阅读域纯视频游戏日显示零 |
| [BUG-1991](bugs/BUG-1991-subtitle-track-bottom-drawer.md) | ✅ | ✅ | 字幕轨入口误开底部字幕调整抽屉而非右侧设置栏 |
| [BUG-1990](bugs/BUG-1990-mokuro-cbz-embedded-ocr.md) | ✅ | ✅ | Mokuro CBZ 导入丢弃内嵌 OCR 文字层 |
| [BUG-1989](bugs/BUG-1989-all-video-uniform-grid.md) | ✅ | ✅ | 全部视频横竖混排导致缩略图比例不一致并在宽屏留下大块空白 |
| [BUG-1988](bugs/BUG-1988-remote-mining-error-unlocalized.md) | ✅ | ✅ | 互联远端制卡不可达错误未本地化 |
| [BUG-1987](bugs/BUG-1987-manga-image-folder-source-scan.md) | ✅ | ✅ | 漫画来源扫描支持纯图片目录 |
| [BUG-1986](bugs/BUG-1986-resource-episode-span-summary.md) | ✅ | ✅ | 资源版本卡把非连续集号显示成连续范围 |
| [BUG-1985](bugs/BUG-1985-apibay-cjk-hot-list.md) | ✅ | ✅ | apibay 把 CJK 查询退化为热门榜 |
| [BUG-1984](bugs/BUG-1984-focus-ring-registered-geometry.md) | ✅ | ✅ | 复合控件焦点环读取内部 Focus context 导致边界错位 |
| [BUG-1983](bugs/BUG-1983-gal-layout-whitespace-fold.md) | ✅ | ✅ | Gal 同句换行快照未原地折叠导致换行错乱 |
| [BUG-1982](bugs/BUG-1982-global-lookup-stale-route-flash.md) | 🚧 | ✅ | 全局查词首帧落在工作区角上再闪回光标处 |
| [BUG-1981](bugs/BUG-1981-hook-overlay-dead-window-reopen.md) | ✅ | ✅ | Hook 浮窗 HWND 失效后自动与手动打开都无窗口 |
| [BUG-1980](bugs/BUG-1980-proxy-mode-auth.md) | ✅ | ✅ | 网络代理无法显式禁用且不支持认证 |
| [BUG-1979](bugs/BUG-1979-storage-backup-cleanup.md) | ✅ | ✅ | 存储页备份被隐藏且无法清理 |
| [BUG-1978](bugs/BUG-1978-hunex-toolbar-thread-merged.md) | ✅ | ✅ | HUNEX 顶部控制栏线程被并入剧情台词 |
| [BUG-1977](bugs/BUG-1977-hunex-hfa-voice-resource-pairing.md) | 🚧 | ✅ | HUNEX HFA/HW 源语音未与台词配对 |
| [BUG-1976](bugs/BUG-1976-lookup-webview-text-blur.md) | ✅ | ✅ | Windows 查词 WebView 被超分通路无条件重采样导致字体发糊 |
| [BUG-1975](bugs/BUG-1975-webpage-video-ffmpeg-cover.md) | ✅ | ✅ | 网页视频导入不应让 FFmpeg 抽 HTML 页面封面 |
| [BUG-1974](bugs/BUG-1974-video-resource-unknown-group.md) | ✅ | ✅ | 资源搜索把未知发布组跨季误聚为合集 |
| [BUG-1973](bugs/BUG-1973-sync-progress-ordinal-fraction.md) | ✅ | ✅ | 同步进度文案到 2/2 时进度条仍停在一半 |
| [BUG-1972](bugs/BUG-1972-selected-glossary-mining.md) | ✅ | ✅ | 桌面选中释义制卡丢失选区 |
| [BUG-1971](bugs/BUG-1971-library-tabs-overflow-cue.md) | ✅ | ✅ | 库页顶栏横向标签缺少后续内容提示 |
| [BUG-1970](bugs/BUG-1970-onboarding-feature-tile-height.md) | ✅ | ✅ | 新手引导功能选中态高度变化 |
| [BUG-1969](bugs/BUG-1969-organizer-filename-extra-collision.md) | ✅ | ✅ | 剧集整理把平铺 NCED 文件当正片，与同集正片撞号 |
| [BUG-1968](bugs/BUG-1968-windows-manga-ocr-directml-runtime.md) | ✅ | ✅ | Windows 漫画 OCR detector 未实际启用 DirectML |
| [BUG-1967](bugs/BUG-1967-dictionary-order-render-contract.md) | ✅ | ✅ | 词典管理顺序未约束弹窗释义卡顺序 |
| [BUG-1966](bugs/BUG-1966-flutter-error-context-description.md) | ✅ | ✅ | Flutter 错误日志显示 ErrorDescription 实例名 |
| [BUG-1965](bugs/BUG-1965-ankiconnect-bundled-addon-missing-modules.md) | ✅ | ✅ | 内置 AnkiConnect 插件包漏打 web/edit/util 三个模块，装上必 ImportError |
| [BUG-1964](bugs/BUG-1964-ankiconnect-port-busy-timeout-misleading.md) | ✅ | ✅ | AnkiConnect 端口被占用时只报超时，提示指向防火墙且泄漏裸 TimeoutException |
| [BUG-1963](bugs/BUG-1963-windows-titlebar-focus-ring-offset.md) | ✅ | ✅ | Windows 自定义标题栏下焦点环整体向下错位 |
| [BUG-1962](bugs/BUG-1962-windows-icon-shortcuts.md) | ✅ | ✅ | Windows 换图标未同步固定任务栏且启动后快捷方式不自愈 |
| [BUG-1960](bugs/BUG-1960-app-wheel-scroll-jump.md) | ✅ | ✅ | App 桌面滚轮滚动逐事件瞬移不流畅 |
| [BUG-1959](bugs/BUG-1959-dashboard-activity-scroll-jank.md) | ✅ | ✅ | Windows/Linux 粗鼠标滚轮一格跳动范围过大 |
| [BUG-1958](bugs/BUG-1958-online-manga-local-ocr.md) | ✅ | ✅ | 在线漫画点击查词无视已下载本地模型并强制 Google Lens |
| [BUG-1957](bugs/BUG-1957-galgame-xwma-card-audio.md) | ✅ | ✅ | Galgame 制卡把 xWMA 原样写入卡片，手机无法播放 |
| [BUG-1956](bugs/BUG-1956-downloads-center-sections-global-search.md) | ✅ | ✅ | 下载中心四分区被移除且资源页发现入口失去模块复用 |
| [BUG-1955](bugs/BUG-1955-selective-download-backend-target.md) | ✅ | ✅ | 选择性下载仍调用已删除的后端身份接口导致 Windows 构建失败 |
| [BUG-1954](bugs/BUG-1954-downloads-dropdown-back-button.md) | ✅ | ✅ | 下载页展开下拉框时左上角误显返回键 |
| [BUG-1953](bugs/BUG-1953-torrent-detail-missing-live-data-layout.md) | ✅ | ✅ | Torrent 详情缺少实时数据时空态布局失衡 |
| [BUG-1952](bugs/BUG-1952-gal-progressive-line-fold.md) | ✅ | ✅ | 一句台词分多次显示时工作台重复出现且字数重复统计（Zato） |
| [BUG-1951](bugs/BUG-1951-webview2-cookie-expires-seconds-as-ms.md) | ✅ | ✅ | WebView2 fork getCookies 把 CDP 的秒级 expires 当毫秒回给 Dart：环境间复制 cookie 一律 1970 过期被丢弃、cf_clearance 落库即判过期 |
| [BUG-1950](bugs/BUG-1950-sgre-single-hash-gate-no-attempt.md) | ✅ | ✅ | STEINS;GATE RE:BOOT 内嵌查词对非首日构建静默失效：SGRE 适配把单个 exe 哈希当准入门，从不尝试其它构建 |
| [BUG-1949](bugs/BUG-1949-netflix-bridge-timedtext-zero-hits.md) | ✅ | ✅ | netflix-bridge 整集字幕轨在当前 Netflix 上零命中（JSON.parse 钩子看不到 timedtexttracks） |
| [BUG-1948](bugs/BUG-1948-video-watch-tracker-stop-double-activity.md) | ✅ | ✅ | VideoWatchTracker.stop 在 await 后才清零累计器：dispose 与进程退出并发各写一条活动行 |
| [BUG-1947](bugs/BUG-1947-video-stats-sync-title-collapse.md) | ✅ | ✅ | 视频统计同步按 title 塌缩：分集裸集号跨作品相加、per-uid 行被删成无身份行 |
| [BUG-1946](bugs/BUG-1946-sukebei-rss-namespace-rejected.md) | ✅ | ✅ | Sukebei 发现源结果恒空：NyaaClient 严格解析硬编码 nyaa.si 命名空间，sukebei RSS 的 sukebei.nyaa.si/xmlns/nyaa 被判 invalidNamespace |
| [BUG-1945](bugs/BUG-1945-video-fullscreen-exit-deactivated-context.md) | ✅ | ✅ | 视频取消全屏短暂闪现 deactivated widget 红屏 |
| [BUG-1944](bugs/BUG-1944-mokuro-retry-cancel-test-wall-clock-race.md) | ✅ | ✅ | mokuro 退避取消测试拿真时钟当同步原语，CI 上偶发红 |
| [BUG-1943](bugs/BUG-1943-subtitle-ruby-flattened.md) | ✅ | ✅ | 字幕振假名被当成正文与文字同级 |
| [BUG-1942](bugs/BUG-1942-extension-lookup-no-auto-read.md) | ✅ | ✅ | 浏览器扩展查词不自动播放单词音频 |
| [BUG-1941](bugs/BUG-1941-subtitle-row-blank-click-no-seek.md) | ✅ | ✅ | 点字幕行内空白不跳转只弹未识别提示 |
| [BUG-1940](bugs/BUG-1940-page-lookup-close-click-leaks.md) | ✅ | ✅ | 关弹窗的点击与 Esc 漏给站点 |
| [BUG-1939](bugs/BUG-1939-side-panel-lookup-popup-placement.md) | ✅ | ✅ | 侧栏查词弹窗不跟随位置且遮挡内容 |
| [BUG-1938](bugs/BUG-1938-live-cue-seek-duplicate.md) | ✅ | ✅ | 实时采集轨在来回跳转后同一句重复入轨 |
| [BUG-1937](bugs/BUG-1937-download-tasks-kind-filter.md) | ✅ | ✅ | 下载任务面板缺少类型筛选 |
| [BUG-1936](bugs/BUG-1936-downloads-discovery-queue-invisible.md) | ✅ | ✅ | 发现页直链下载（游戏等）提示已加入下载，下载页任务 tab 却不显示 |
| [BUG-1935](bugs/BUG-1935-gal-ingame-lookup-no-engine-gating.md) | ✅ | ✅ | 内嵌查词在 Siglus/白2 上 hash 钉定不中时静默失效且无任何提示 |
| [BUG-1934](bugs/BUG-1934-tombstone-partial-read-baseline.md) | ✅ | ✅ | 远端删除墓碑单条读失败被跳过，基线照常推进 → 该条删除永久不再提示 |
| [BUG-1933](bugs/BUG-1933-win-fullscreen-white-flash.md) | ✅ | ✅ | 全屏与取消全屏时闪一帧白色 |
| [BUG-1932](bugs/BUG-1932-lookup-pending-dismiss-freezes-popup.md) | ✅ | ✅ | 挂起期关栈后查词界面卡死、播放控件再也唤不回 |
| [BUG-1931](bugs/BUG-1931-backup-archive-cannot-be-deleted.md) | ✅ | ✅ | 导出的备份包无法删除，且移动端从不清理 |
| [BUG-1930](bugs/BUG-1930-backup-export-cancelled-by-collapse.md) | ✅ | ✅ | 折叠「本地备份」分区会取消进行中的备份 |
| [BUG-1929](bugs/BUG-1929-backup-export-no-progress.md) | ✅ | ✅ | 导出备份没有进度，只有一个转圈 |
| [BUG-1928](bugs/BUG-1928-peer-delete-confirm-says-local-kept.md) | ✅ | ✅ | 远端卡「从远端删除」文案谎称本地数据保留 |
| [BUG-1927](bugs/BUG-1927-mokuro-catalog-series-blank.md) | ✅ | ✅ | mokuro.moe 目录点进系列后一片空白 |
| [BUG-1926](bugs/BUG-1926-gal-overlay-toolbar-not-following-drag.md) | ✅ | ✅ | 穿透态 galgame 浮窗：拖正文时顶栏不跟随 |
| [BUG-1925](bugs/BUG-1925-sync-collections-resurrect-flaky.md) | 🚧 | 🚧 | 全量下 sync_orchestrator_collections 的 peer-republish 用例偶发红（4 次全量红 2 次，单跑绿） |
| [BUG-1924](bugs/BUG-1924-manga-shelf-locked-to-first-chapter.md) | ✅ | ✅ | 漫画加入书架后只能看第一章：书架没有作品页、阅读器不换章 |
| [BUG-1923](bugs/BUG-1923-lookup-popup-plus-optical-center.md) | ✅ | ✅ | 查词弹窗静息加号可见位置比同排图标低 |
| [BUG-1922](bugs/BUG-1922-macos-aidoku-runtime-not-bundled.md) | ✅ | ✅ | macOS 发布包缺 Aidoku runtime，删除再添加 Aidoku 仓库报 RUNTIME_MISSING |
| [BUG-1921](bugs/BUG-1921-settings-module-labels-mismatch.md) | ✅ | ✅ | 设置里的功能模块开关名字与底栏/侧栏对不上 |
| [BUG-1920](bugs/BUG-1920-app-icon-rail-live-sync.md) | ✅ | ✅ | 应用图标切换未同步到主侧栏 |
| [BUG-1919](bugs/BUG-1919-desktop-fullscreen-read-escapes-try.md) | ✅ | ✅ | Linux/macOS 上桌面全屏读写的异常逃出 try，漫画页 widget test 在 CI 上全红 |
| [BUG-1918](bugs/BUG-1918-dict-style-preview-crash.md) | ✅ | ✅ | 打开词典样式可视化编辑器闪退（Windows） |
| [BUG-1917](bugs/BUG-1917-win-resize-heatmap-repaint.md) | ✅ | ✅ | Windows 拖边缩放帧率低：首页仪表盘每步重画整张热力图 |
| [BUG-1916](bugs/BUG-1916-win-resize-backdrop-layer.md) | ✅ | ✅ | 窗口缩放时露出深青底色层 |
| [BUG-1915](bugs/BUG-1915-anki-dup-check-cross-model.md) | ✅ | ✅ | 查词弹窗查重与制卡判重不同源：跨笔记类型的重复卡画成可制卡 + |
| [BUG-1914](bugs/BUG-1914-mine-button-lost-text-marker-restore.md) | ✅ | ✅ | 制卡按钮被加回 inline-action-button 基类，三条 TODO-1325 还原守卫在 develop 上已红 |
| [BUG-1913](bugs/BUG-1913-wa2-directsound-audio-timeline.md) | ✅ | ✅ | WA2 DirectSound 制卡炸音且未取得 VOICE.PAK 源语音 |
| [BUG-1912](bugs/BUG-1912-gal-ingame-same-line-replay-destroys-selection.md) | ✅ | ✅ | KiriKiri 人物动画重发同句时销毁游戏内查词 WebView 选区 |
| [BUG-1911](bugs/BUG-1911-gal-download-library-placeholder.md) | ✅ | ✅ | 下载中的游戏不在库里占位：看不出到底加没加进来 |
| [BUG-1910](bugs/BUG-1910-gal-discovery-localization-filter.md) | ✅ | ✅ | gal 下载缺少生肉/熟肉筛选：分类只以一句硬编码中文存在 |
| [BUG-1909](bugs/BUG-1909-gal-hook-code-paste.md) | ✅ | ✅ | gal 特殊码只能靠手拼七列 TSV 导入：缺少粘贴入口与归一化 |
| [BUG-1908](bugs/BUG-1908-gal-mining-failure-silent.md) | ✅ | ✅ | gal 浮窗制卡失败完全没有提示：回程只传布尔，失败分支没有 else |
| [BUG-1907](bugs/BUG-1907-subtitle-list-search-and-export.md) | ✅ | ✅ | 字幕列表缺少搜索（Ctrl+F）与导出收藏语句 |
| [BUG-1906](bugs/BUG-1906-export-panel-cannot-pick-collection.md) | ✅ | ✅ | 收藏夹导出面板挤在 bottom sheet、文案写死书籍、且没法按合集导出 |
| [BUG-1905](bugs/BUG-1905-ios-storage-total-undercounts.md) | ✅ | ✅ | 存储统计漏算缓存根与白名单外顶层项：app 内 6.9GB vs 系统 13.68GB |
| [BUG-1904](bugs/BUG-1904-dict-import-entry-cap-silent-truncation.md) | ✅ | ✅ | 词条数撞 100 万每 bank 上限被静默截断，仍报导入成功 |
| [BUG-1903](bugs/BUG-1903-dict-zip-multi-mdx-only-first-imported.md) | ✅ | ✅ | 一个压缩包内含多本 MDX 词典时只导入第一本，其余静默丢弃且报成功 |
| [BUG-1902](bugs/BUG-1902-onboarding-anki-missing-deck-controls.md) | ✅ | ✅ | 新手引导配置 Anki 缺少创建 Lapis 卡组/刷新/选牌组 |
| [BUG-1901](bugs/BUG-1901-discovery-detail-title-not-selectable.md) | ✅ | ✅ | 番剧详情页标题不能选中复制：全页只有 2/15 个文本可选 |
| [BUG-1900](bugs/BUG-1900-anki-empty-note-message-misleading.md) | ✅ | ✅ | AnkiConnect 制卡把字段映射不匹配报成 cannot create note because it is empty |
| [BUG-1899](bugs/BUG-1899-custom-data-root-reported-as-db-damaged.md) | ✅ | ✅ | 自定义数据安装位置启动即 Database damaged：派生根目录从没被创建 |
| [BUG-1898](bugs/BUG-1898-touching-ruby-units-overlap.md) | ✅ | ✅ | 紧邻的两个带注音基字振假名重叠：明鏡四字熟語糊成一团 |
| [BUG-1897](bugs/BUG-1897-dict-css-double-scales-ruby.md) | ✅ | ✅ | 词典自带 rt 字号与注音盒相乘，小学館十二版振假名只剩 0.3em |
| [BUG-1896](bugs/BUG-1896-video-episode-picker-unordered.md) | ✅ | ✅ | 播放器选集横排缩略图乱序：番剧下载入库从不重排合集 |
| [BUG-1895](bugs/BUG-1895-lookup-popup-plus-short.md) | ✅ | ✅ | 查词弹窗静息加号比相邻操作图标矮 |
| [BUG-1894](bugs/BUG-1894-theme-edit-button-duplicates-new.md) | ✅ | ✅ | 主题行铅笔按钮在无活跃自定义主题时退化成第二个新建入口 |
| [BUG-1893](bugs/BUG-1893-storage-audiobook-size-missing-in-entries.md) | ✅ | ✅ | 存储页书籍条目不显示有声书音频大小 |
| [BUG-1892](bugs/BUG-1892-galgame-attach-mode-no-play-session.md) | ✅ | ✅ | galgame 附着模式不记录游玩时长，停止捕获也不结算 |
| [BUG-1891](bugs/BUG-1891-jellyfin-emby-full-library-enumeration.md) | ✅ | ✅ | Emby/Jellyfin 一进视频页就全库递归枚举且带 MediaSources 重字段 |
| [BUG-1890](bugs/BUG-1890-gal-hook-text-vertical-align-forced-center.md) | ✅ | ✅ | gal 台词浮窗文字放得下时被强制垂直居中，无法选择顶部对齐 |
| [BUG-1889](bugs/BUG-1889-gal-hook-outline-8way-stamping-aliasing.md) | ✅ | ✅ | gal 台词浮窗描边是 8 向偏移叠印伪描边，边缘粗细不均有锯齿感 |
| [BUG-1888](bugs/BUG-1888-manga-top-chrome-no-hide.md) | ✅ | ✅ | 漫画阅读器顶栏无任何隐藏方式，也没有全屏入口 |
| [BUG-1887](bugs/BUG-1887-windows-location-in-use.md) | ✅ | ✅ | Windows 显示 Fushi 正在使用定位（permission_handler_windows 启动即开定位会话） |
| [BUG-1886](bugs/BUG-1886-global-fullscreen-gated-by-experimental-focus-nav.md) | ✅ | ✅ | F11 窗口全屏被实验性焦点导航开关门控，默认安装上按 F11 无反应 |
| [BUG-1885](bugs/BUG-1885-conjugation-description-popup.md) | ✅ | ✅ | 动词变形说明弹窗样式异常且跨查询残留 |
| [BUG-1884](bugs/BUG-1884-mihon-source-preferences-save.md) | ✅ | ✅ | Mihon 来源偏好没有保存按钮，未提交文本会丢失 |
| [BUG-1883](bugs/BUG-1883-fushidicts-ffi-dll-missing-on-user-machine.md) | 🚧 | ✅ | 用户机报 Failed to load dynamic library 'fushidicts_ffi.dll' (126)，app 卡在初始化 |
| [BUG-1882](bugs/BUG-1882-gal-ingame-outside-click-through.md) | ✅ | ✅ | 游戏内查词点外关闭时同一点击穿透到游戏推进台词 |
| [BUG-1881](bugs/BUG-1881-galgame-debug-stale-helper-artifact.md) | ✅ | ✅ | Windows Debug 构建残留旧 helper 导致 SGRE 内嵌查词坐标回退 |
| [BUG-1880](bugs/BUG-1880-video-resource-search-backend-gate.md) | ✅ | ✅ | 搜索资源被下载后端运行时前置门禁阻断 |
| [BUG-1879](bugs/BUG-1879-download-category-in-backend-identity.md) | ✅ | ✅ | 改 qBittorrent 分类后全部在途下载任务卡死 needsAttention |
| [BUG-1878](bugs/BUG-1878-lookup-popup-surface-forced-pure-white-black.md) | ✅ | ✅ | 查词弹窗底色被钉成纯白/纯黑，不跟随 MD3 主题 |
| [BUG-1877](bugs/BUG-1877-cover-backfill-never-completes.md) | 🚧 | 🚧 | 封面回填永远跑不完：单条两次 ffmpeg 各 30s 上限 + 失败账本只在内存 + 每轮从头串行扫 |
| [BUG-1876](bugs/BUG-1876-aidoku-ios-cloudflare-no-passthrough.md) | ✅ | ✅ | iOS Aidoku 源遇 Cloudflare 挑战无过盾能力只报 JsonParseError |
| [BUG-1875](bugs/BUG-1875-mihon-store-github-no-mirror.md) | ✅ | ✅ | Mihon 扩展仓库索引拉取直连 GitHub 超时无镜像回退 |
| [BUG-1874](bugs/BUG-1874-settings-downloads-open-page-subtitle-duplicate.md) | ✅ | ✅ | 「下载」设置分类里的下载页入口副标题也叫「下载设置」 |
| [BUG-1873](bugs/BUG-1873-manga-discovery-loading-rows-bare-lines.md) | ✅ | ✅ | 漫画发现页来源热门行加载态是一排无标签的裸横线 |
| [BUG-1872](bugs/BUG-1872-video-discovery-no-managed-source-snackbar.md) | ✅ | ✅ | 视频发现搜索资源/订阅在缺受管视频来源时只弹「暂无来源」snackbar |
| [BUG-1871](bugs/BUG-1871-manga-global-search-empty-state-no-import-cta.md) | ✅ | ✅ | 漫画全源搜索空态文案指向不存在的「扩展」且无导入引导按钮 |
| [BUG-1870](bugs/BUG-1870-storage-usage-db-snapshots-unlabeled-undeletable.md) | ✅ | ✅ | 存储页「数据库与内部数据」把几十个数据库快照残留按原始文件名逐条列出且无法删除 |
| [BUG-1869](bugs/BUG-1869-data-root-migration-progress-exceeds-total.md) | ✅ | ✅ | 数据迁移进度「已复制 623 / 620」超过总数：选择性搬移的顶层单文件只加分子不加分母 |
| [BUG-1868](bugs/BUG-1868-lookup-popup-slow.md) | ✅ | ✅ | 查词弹窗慢，尤其嵌套查词 |
| [BUG-1867](bugs/BUG-1867-cover-backfill-hollow-m2ts.md) | ✅ | ✅ | 封面回填把 best-effort 失败刷进用户错误日志，且对未落盘文件仍走 ffmpeg |
| [BUG-1866](bugs/BUG-1866-resolve-public-indexer-needs-network.md) | ✅ | ✅ | 公共索引器重解析非要联网重搜，搜不中就把活资源误报 notFound |
| [BUG-1865](bugs/BUG-1865-organizer-numbered-extras.md) | ✅ | ✅ | 剧集整理把带编号的特典当正片，与真正片撞号整批失败 |
| [BUG-1864](bugs/BUG-1864-video-fullscreen-space-pause-panel.md) | ✅ | ✅ | 视频字幕列表持焦后整张快捷键表失效 |
| [BUG-1863](bugs/BUG-1863-video-resume-gray-static-areas.md) | ✅ | ✅ | 从后台切回视频静止区域变成灰色 |
| [BUG-1862](bugs/BUG-1862-video-esc-skips-overlay-dismiss.md) | ✅ | ✅ | 视频页 Esc/返回键在侧栏等前台浮层打开时直接退出页面，未逐级关闭 |
| [BUG-1861](bugs/BUG-1861-video-subtitle-imported-not-listed.md) | ✅ | ✅ | 获取的字幕能应用上却不出现在字幕轨列表里 |
| [BUG-1860](bugs/BUG-1860-gal-overlay-scrollbar-not-draggable.md) | ✅ | ✅ | gal 查词浮窗滚动条只是指示条：按住拖 thumb 变成拖窗 |
| [BUG-1859](bugs/BUG-1859-gal-overlay-passthrough-wheel-gate.md) | ✅ | ✅ | gal 查词浮窗穿透态滚轮不滚：ScrollBy 的 pass_through_ 门是 WS_EX_TRANSPARENT 时代遗物 |
| [BUG-1858](bugs/BUG-1858-settings-form-field-width.md) | ✅ | ✅ | 设置页输入框宽度三套并存：下载设置 480 / 在线服务 560 / 其余撑满 |
| [BUG-1857](bugs/BUG-1857-gal-overlay-resize-card-does-not-follow-drag.md) | ✅ | ✅ | 查词浮窗拖右下角调大小时卡片不跟手，松手才跳到位 |
| [BUG-1856](bugs/BUG-1856-jimaku-dialog-search-button-unreachable-phone-landscape-keyboard.md) | ✅ | ✅ | Jimaku 获取字幕对话框在手机横屏弹键盘时只看得见「取消」，搜索按钮藏在可滚区不可达 |
| [BUG-1855](bugs/BUG-1855-home-continue-row-drops-collection-after-episode-complete.md) | ✅ | ✅ | 视频首页「继续观看」一集看完退出后合集消失，只有中途退出才在 |
| [BUG-1854](bugs/BUG-1854-gal-mining-capture-includes-title-bar.md) | ✅ | ✅ | 制卡截图把游戏窗口标题栏截进去了，应裁到客户区 |
| [BUG-1853](bugs/BUG-1853-gal-passthrough-glyph-holes-fall-through.md) | ✅ | ✅ | 穿透态点到文字笔画镂空处直接透给游戏，碰撞箱应为行矩形 |
| [BUG-1852](bugs/BUG-1852-manga-region-rescan-lookup-action-removed.md) | 🚧 | 🚧 | 框选区域重识别移除了旧「框选查词」直通词典的入口 |
| [BUG-1851](bugs/BUG-1851-manga-region-rescan-auto-engine-mix.md) | 🚧 | 🚧 | auto 引擎偏好下区域重识别可能与整卷用不同引擎，页内混引擎且 ocr 元数据仍写旧引擎 |
| [BUG-1850](bugs/BUG-1850-settings-destination-itest-vacuous-selected-row.md) | ✅ | ✅ | 集成测试用恒真的选中行谓词当设置分类打开判据 |
| [BUG-1849](bugs/BUG-1849-jimaku-live-action-no-tmdb-key.md) | ✅ | ✅ | Jimaku 真人剧检索没有权威关联键：TMDB id 被解析器丢弃，只能靠标题模糊命中 |
| [BUG-1848](bugs/BUG-1848-playlist-subtitle-restore-no-fallback.md) | ✅ | ✅ | 合集里下载的字幕退出再进就没了：恢复链只走一支、零兜底 |
| [BUG-1847](bugs/BUG-1847-manual-subtitle-search-missing-file-hash.md) | ✅ | ✅ | 播放页手动检索字幕不带 OSDb 文件哈希，精确匹配分支永远走不到 |
| [BUG-1846](bugs/BUG-1846-opensubtitles-zh-language-code.md) | ✅ | ✅ | OpenSubtitles 搜索传裸 zh 语言码，中文字幕永远搜不到 |
| [BUG-1845](bugs/BUG-1845-subtitle-download-filename-path-traversal.md) | ✅ | ✅ | 在线字幕落盘直接拼远端文件名，可路径穿越写出目标目录 |
| [BUG-1844](bugs/BUG-1844-jimaku-download-error-hidden-behind-dialog.md) | ✅ | ✅ | 下载失败提示被对话框盖住且没有原因 |
| [BUG-1843](bugs/BUG-1843-jimaku-series-list-cleared-before-refetch.md) | ✅ | ✅ | 填集数再搜后系列列表消失且搜不出结果 |
| [BUG-1842](bugs/BUG-1842-jimaku-search-uses-display-name.md) | ✅ | ✅ | Jimaku 搜索拿显示名去猜，刮削存下的 AniList ID 从没被用过 |
| [BUG-1841](bugs/BUG-1841-custom-theme-edit-persists-blank-draft.md) | ✅ | ✅ | 自定义主题「+新建」和「编辑」图标进编辑页前就落库空主题 |
| [BUG-1840](bugs/BUG-1840-settings-custom-item-left-baseline.md) | ✅ | ✅ | 视频设置页 Jimaku/OpenSubtitles 块贴边，比标准设置行更靠左 |
| [BUG-1838](bugs/BUG-1838-ankiconnect-installer-launcher-not-found.md) | 🚧 | 🚧 | AnkiConnect 一键代装误报 Anki 没运行：新版 launcher 下找不到入口 exe |
| [BUG-1837](bugs/BUG-1837-anki-open-foreground-pid-launcher.md) | ✅ | ✅ | 制卡后在 Anki 中打开仍不到前台：新版 Anki launcher 下进程识别失效 |
| [BUG-1836](bugs/BUG-1836-manual-install-rescue-reports-failure.md) | ✅ | ✅ | 手动跑安装包救援成功后仍必报更新失败（Inno 日志判据拿不到证据） |
| [BUG-1835](bugs/BUG-1835-gal-ingame-nested-card-placement.md) | 🚧 | ✅ | 游戏内嵌套查词子卡未按选词正上正下布局 |
| [BUG-1834](bugs/BUG-1834-gal-lookup-nested-source-frame.md) | ✅ | ✅ | 游戏内嵌套查词丢失来源层导致子卡挂错谱系 |
| [BUG-1833](bugs/BUG-1833-gal-ingame-webview-png-scroll-jank.md) | 🚧 | ✅ | 游戏内 WebView 查词卡 PNG 全帧重采导致弹出与滚动卡顿 |
| [BUG-1832](bugs/BUG-1832-youtube-client-fallback-missing-android.md) | ✅ | ✅ | YouTube 部分视频打不开：兜底 client 链缺 android |
| [BUG-1831](bugs/BUG-1831-win-update-launcher-vanished.md) | ✅ | ✅ | 改名让路后新 launcher 被回滚删除，安装目录再无 launcher，自更新永久卡死 |
| [BUG-1830](bugs/BUG-1830-mokuro-volume-subdir.md) | ✅ | ✅ | mokuro 卷子目录布局导入必失败（img_path 裸文件名） |
| [BUG-1829](bugs/BUG-1829-reader-wheel-chapter-cooldown-starvation.md) | ✅ | ✅ | 快速拨滚轮永远跨不了章：跨章冷却窗被每次被拦输入自我续期 |
| [BUG-1828](bugs/BUG-1828-reader-image-wrapper-swallows-empty-tap.md) | ✅ | ✅ | 阅读器大图两侧留白被判成点中图片，底栏永远唤不出来 |
| [BUG-1827](bugs/BUG-1827-popup-phonetic-overflows-card.md) | ✅ | ✅ | 查词弹窗释义里的不可断短语溢出词典卡 |
| [BUG-1826](bugs/BUG-1826-mihon-loading-gate-blocks-store-edit.md) | 🚧 | 🚧 | 漫画扩展页 loading 一位两义：初始化联网刷新期间连添加/编辑仓库都点不动 |
| [BUG-1825](bugs/BUG-1825-lyrics-itest-concrete-activation.md) | ✅ | ✅ | 歌词模式实测未激活具体reader-action焦点节点 |
| [BUG-1824](bugs/BUG-1824-dictionary-overlay-dispose-without-remove.md) | ✅ | ✅ | 查词页根Overlay卸载时先dispose仍登记的OverlayEntry |
| [BUG-1823](bugs/BUG-1823-comprehensive-imports-dictionary-tab-index-drift.md) | ✅ | ✅ | 综合导入实测按固定索引误把书架当查词 |
| [BUG-1822](bugs/BUG-1822-comprehensive-imports-ios-font-fixture.md) | ✅ | ✅ | 综合导入实测在iOS找不到字体fixture |
| [BUG-1821](bugs/BUG-1821-itest-fresh-install-onboarding-hides-home.md) | ✅ | 🚧 | 实机集成测试把首次引导前的短暂首页误判为可用 |
| [BUG-1820](bugs/BUG-1820-ios-media-sources-scrape-actions-hidden.md) | 🚧 | 🚧 | iOS视频来源页隐藏全部刮削与任务入口 |
| [BUG-1819](bugs/BUG-1819-observe-capture-ios-unwritable-relative-dir.md) | ✅ | ✅ | 实机截图helper在iOS写相对codex-test目录失败 |
| [BUG-1818](bugs/BUG-1818-video-library-section-focus-lost.md) | 🚧 | 🚧 | 视频库切分区后分段导航焦点丢失 |
| [BUG-1817](bugs/BUG-1817-video-source-itest-section-type-drift.md) | ✅ | ✅ | 视频来源实测仍按旧两段库页导航驱动 |
| [BUG-1816](bugs/BUG-1816-focus-driver-scope-fallback-nonmac.md) | ✅ | ✅ | FocusDriver Scope 兜底掩盖非 macOS Tab 回归 |
| [BUG-1815](bugs/BUG-1815-lyrics-load-guard-stale-finalizer-test.md) | ✅ | ✅ | 歌词文档守卫静态测试未跟随 finalizer 重构 |
| [BUG-1814](bugs/BUG-1814-main-window-focus-gate-nonwindows-test.md) | ✅ | ✅ | Windows 焦点闸门单测在非 Windows 误红 |
| [BUG-1813](bugs/BUG-1813-macos-popup-viewport-teardown.md) | ✅ | ✅ | macOS 词典弹窗视口注入销毁竞态 |
| [BUG-1812](bugs/BUG-1812-ios-reader-zero-vh-vw-margins.md) | ✅ | ✅ | iOS阅读器WebView视口单位为零导致四边页边距失效 |
| [BUG-1811](bugs/BUG-1811-ios-interconnect-remote-audio-unpinned-player.md) | ✅ | ✅ | iOS互联远端音频绕过证书钉扎导致无法播放 |
| [BUG-1810](bugs/BUG-1810-comprehensive-imports-never-opens-books.md) | ✅ | ✅ | 综合导入实测未打开书架导致已导入图书不可见 |
| [BUG-1809](bugs/BUG-1809-ios-lyrics-load-data-no-load-stop.md) | ✅ | ✅ | iOS歌词loadData返回后不触发onLoadStop导致永不ready |
| [BUG-1808](bugs/BUG-1808-video-home-row-card-tags.md) | ✅ | ✅ | 视频首页横滚行卡不显示标签（拆 section 后首页只剩横滚卡，标签层只画在墙格卡上） |
| [BUG-1807](bugs/BUG-1807-url-keyboard-missing-across-app.md) | ✅ | ✅ | 全仓 10 处 URL/host 输入框漏声明 keyboardType，与 BUG-1804 同族 |
| [BUG-1806](bugs/BUG-1806-mihon-store-url-not-editable.md) | ✅ | ✅ | 扩展仓库地址不可编辑，只能删了重加 |
| [BUG-1805](bugs/BUG-1805-mihon-store-zero-extensions-silent.md) | ✅ | ✅ | 仓库拉到 0 条扩展时静默空列表，无任何提示 |
| [BUG-1804](bugs/BUG-1804-mihon-store-url-fullwidth-rejected.md) | ✅ | ✅ | 添加扩展仓库输入框无 URL 键盘类型，中文输入法全角标点被拒 INVALID_URL |
| [BUG-1803](bugs/BUG-1803-sgre-layout-argument-forwarding.md) | ✅ | ✅ | SGRE 查词 detour 丢失布局参数导致游戏控制码不转义 |
| [BUG-1802](bugs/BUG-1802-sgre-lookup-glyph-position.md) | ✅ | ✅ | SGRE 内嵌查词读取错误字形坐标导致命中错位 |
| [BUG-1801](bugs/BUG-1801-sgre-lookup-stale-line.md) | ✅ | ✅ | SGRE 内嵌查词保留旧台词导致查询不实时 |
| [BUG-1800](bugs/BUG-1800-sgre-shift-tap-missed.md) | ✅ | ✅ | SGRE 内嵌查词短按 Shift 在轮询间隙被漏掉 |
| [BUG-1799](bugs/BUG-1799-texthooker-mined-badge-never-revalidated.md) | ✅ | ✅ | galgame 台词列表「已制卡」徽章是单向内存 latch，Anki 删卡后永不复核 |
| [BUG-1798](bugs/BUG-1798-video-lookup-controls-autohide-race.md) | ✅ | ✅ | 查词浮层与控制条自动显隐竞态 |
| [BUG-1797](bugs/BUG-1797-reader-padding-hit-leak.md) | ✅ | ✅ | 阅读器页边距能点到相邻页的词查词（不可见却可命中） |
| [BUG-1794](bugs/BUG-1794-video-scrape-cleanup-entry-hidden.md) | ✅ | ✅ | 视频导入页看不到清理全部刮削记录入口 |
| [BUG-1793](bugs/BUG-1793-gal-ingame-lookup-hides-clipboard-history.md) | ✅ | ✅ | 游戏浮窗查词不应显示复制历史入口 |
| [BUG-1792](bugs/BUG-1792-recommended-dictionary-font-size-cap.md) | ✅ | ✅ | 推荐字体超过8MiB导致词典字体静默不生效 |
| [BUG-1791](bugs/BUG-1791-recommended-font-library-reentry.md) | ✅ | ✅ | 推荐字体重进字体库显示未持久化 |
| [BUG-1790](bugs/BUG-1790-gal-resource-poll-freeze.md) | ✅ | ✅ | 资源语音待匹配全量轮询导致 Fushi 与浮窗冻结 |
| [BUG-1789](bugs/BUG-1789-pdf-import-whitelists.md) | ✅ | ✅ | PDF 导入白名单三处漏抄：漫画框选不中、拖放不认、文件夹扫描跳过 |
| [BUG-1788](bugs/BUG-1788-popup-kanji-chip-row-never-deleted.md) | ✅ | ✅ | 查词弹窗词头下方的单字 chip 行仍在渲染：删除提交从未合并进 develop |
| [BUG-1787](bugs/BUG-1787-font-library-scope-target-dead-param.md) | ✅ | ✅ | 字体库作用域参数不生效：从游戏入口导入的字体挂到小说正文 |
| [BUG-1786](bugs/BUG-1786-win-update-launcher-self-lock.md) | ✅ | ✅ | 自更新永远装不上 app.so：launcher 占着自己的文件让 Inno 整包回滚 |
| [BUG-1785](bugs/BUG-1785-download-organize-tv-preview-blocks-batch.md) | ✅ | ✅ | TV 整理被无集号特典文件整批卡死 |
| [BUG-1784](bugs/BUG-1784-download-nyaa-retry-loses-magnet.md) | ✅ | ✅ | 下载重试丢失已选 magnet 致 nyaa notFound |
| [BUG-1783](bugs/BUG-1783-chapter-markers-safearea-basis-mismatch.md) | ✅ | ✅ | 移动端章节标记与进度条基准分叉：标记层多套一层 SafeArea，刘海横屏下整排斜切错位 |
| [BUG-1782](bugs/BUG-1782-jimaku-anilist-silent-degrade-cross-season.md) | ✅ | ✅ | Jimaku 搜索时好时坏：AniList 失败被静默吞成空结果，退化成跨季文本搜索 |
| [BUG-1780](bugs/BUG-1780-android-local-manga-ocr-gate.md) | ✅ | ✅ | 安卓本地漫画 OCR 不可用：整卷平台白名单漏掉 Android，模型下载入口被同一闸门连坐关闭 |
| [BUG-1779](bugs/BUG-1779-anki-media-filename-hibiki-prefix.md) | ✅ | ✅ | 制卡媒体文件名仍带 hibiki 旧名前缀 |
| [BUG-1778](bugs/BUG-1778-ruby-overhang-compacts-glossary-base-spacing.md) | ✅ | ✅ | 振假名横向预留拉开正文汉字间距 |
| [BUG-1777](bugs/BUG-1777-emphatic-full-collapse-phantom-match.md) | ✅ | ✅ | 查词促音丢失：强调折叠full模式常开产生吞字幻影匹配压过原形 |
| [BUG-1776](bugs/BUG-1776-subtitle-list-adjacent-chain-dup.md) | ✅ | ✅ | 字幕列表不折叠同文本时间相接的卡拉OK交替事件 |
| [BUG-1775](bugs/BUG-1775-ass-clip-cue-frame-anchor.md) | ✅ | ✅ | 带clip的ASS事件按容器基线定位与帧空间裁剪几何脱节 |
| [BUG-1774](bugs/BUG-1774-xaudio-codec-trampoline-collision.md) | ✅ | ✅ | XAudio2 WMA Hook 覆盖 ADPCM trampoline 导致游戏静音 |
| [BUG-1773](bugs/BUG-1773-phrase-lookup-truncated-at-word-end.md) | ✅ | ✅ | 点英文单词查词把查询串截到词尾导致短语词条永不匹配 |
| [BUG-1772](bugs/BUG-1772-libtorrent-2-1-drift-breaks-native-build.md) | ✅ | ✅ | vcpkg 未钉版，libtorrent 2.0→2.1 漂移打断 Windows DLL 与 Android .so 构建 |
| [BUG-1771](bugs/BUG-1771-alist-search-parent-base-path.md) | ✅ | ✅ | AList 搜索结果路径带 base_path 前缀，目录打不开、文件下不了 |
| [BUG-1770](bugs/BUG-1770-discovery-total-failure-shown-as-empty.md) | ✅ | ✅ | 发现页整源失败被显示成「无结果」 |
| [BUG-1769](bugs/BUG-1769-gal-utterance-all-sources-concat.md) | ✅ | ✅ | 非16bit游戏语音把所有音源拼成一句（卡顿重复） |
| [BUG-1768](bugs/BUG-1768-discovery-folder-infinite-nesting.md) | ✅ | ✅ | 发现页搜索后点文件夹无限自嵌套（query 压过 path） |
| [BUG-1767](bugs/BUG-1767-manga-detail-lateinit-url.md) | ✅ | ✅ | 点开漫画作品报 RUNTIME_FAILURE：详情解析结果被当完整条目读 lateinit url |
| [BUG-1766](bugs/BUG-1766-download-priority-menu-not-md3.md) | ✅ | ✅ | 排队优先级菜单未走MD3共享原语 |
| [BUG-1765](bugs/BUG-1765-download-source-subtitle-row-misaligned.md) | ✅ | ✅ | 下载来源与字幕下拉底边不对齐 |
| [BUG-1764](bugs/BUG-1764-audiobook-next-page-first-cue-no-turn.md) | ✅ | ✅ | 有声书跟随：下一页第一句不自动翻页 |
| [BUG-1763](bugs/BUG-1763-video-subtitle-chars-paused-seek.md) | ✅ | ✅ | 视频字幕字数暂停拖进度条也计无播放停留判据 |
| [BUG-1762](bugs/BUG-1762-epub-jump-and-arrival-chars-inflate.md) | ✅ | ✅ | EPUB字数到达即计且四类跳转不播种水位整段前缀误计 |
| [BUG-1761](bugs/BUG-1761-manga-stats-recount-on-reopen.md) | ✅ | ✅ | 漫画统计重开书重复计页170页卷记成400页 |
| [BUG-1760](bugs/BUG-1760-manga-wheel-zoomed-misturn.md) | ✅ | ✅ | 漫画放大态滚轮误翻页应页内平移贴边才翻 |
| [BUG-1759](bugs/BUG-1759-manga-zoom-out-aliasing.md) | ✅ | ✅ | 漫画缩放低于100%锯齿严重需放大到150%才恢复清晰 |
| [BUG-1758](bugs/BUG-1758-manga-resize-stale-projection.md) | ✅ | ✅ | 漫画阅读器调整窗口大小后显示错误跨页直到翻页 |
| [BUG-1757](bugs/BUG-1757-popup-close-latch-native-callback-race.md) | ✅ | ✅ | 安卓独立查词窗连续查词后卡死关不掉——原生关闭回调被销毁中的旧 Activity 清掉，Dart 闭锁随即锁死 |
| [BUG-1756](bugs/BUG-1756-dict-delete-mmap-lock.md) | ✅ | ✅ | 词典删除/覆盖更新失败：引擎 mmap 未卸载就删目录 |
| [BUG-1755](bugs/BUG-1755-ass-wrap-width-anchored-to-window.md) | ✅ | ✅ | 字幕换行宽度锚在窗口而非视频画面，最大化后排版突变（BUG-1730 续） |
| [BUG-1754](bugs/BUG-1754-drop-video-folder-ignored.md) | ✅ | ✅ | 视频页拖入文件夹完全静默 |
| [BUG-1753](bugs/BUG-1753-drop-multi-video-only-first.md) | ✅ | ✅ | 拖入多个视频只导入第一个 |
| [BUG-1752](bugs/BUG-1752-drop-fires-on-hidden-tabs.md) | ✅ | ✅ | 拖放同时命中隐藏 tab：视频页拖文件夹弹出「导入漫画」 |
| [BUG-1751](bugs/BUG-1751-manga-wheel-zoom-step-unpredictable.md) | ✅ | ✅ | 漫画滚轮缩放步进取决于本机 deltaY，与右键菜单不同口径 |
| [BUG-1750](bugs/BUG-1750-manga-rtl-slide-direction-inverted.md) | ✅ | ✅ | 漫画 RTL 翻页滑动动画方向与输入语义相反 |
| [BUG-1749](bugs/BUG-1749-extension-hidden-dict-still-shown.md) | ✅ | ✅ | 浏览器扩展里被关闭的词典仍然出释义 |
| [BUG-1748](bugs/BUG-1748-browser-extension-page-no-back.md) | ✅ | ✅ | 浏览器扩展页被设置 push 进来时没有返回键 |
| [BUG-1747](bugs/BUG-1747-subtitle-source-settings-width-tear.md) | ✅ | ✅ | 字幕来源设置三种行各有一套左右边界 |
| [BUG-1746](bugs/BUG-1746-subscription-never-retries-failed-episode.md) | ✅ | ✅ | 订阅只看 jobId 存在就跳过，故障集永久卡死不再下载 |
| [BUG-1745](bugs/BUG-1745-trackpad-vertical-wheel-multi-page.md) | ✅ | ✅ | 纵向触摸板惯性绕过手势闸门，一次滑动连翻多页 |
| [BUG-1744](bugs/BUG-1744-macos-reader-fullscreen-top-band.md) | ✅ | ✅ | macOS 阅读器全屏下顶部残留 28pt 拖拽横带 |
| [BUG-1743](bugs/BUG-1743-vn-scroll-to-search-match-missing.md) | ✅ | ✅ | VN 缺 scrollToSearchMatch 且调用点无存在性守卫 |
| [BUG-1742](bugs/BUG-1742-vn-non-sasayaki-audiobook-follow.md) | ✅ | ✅ | VN 模式下非 sasayaki 书的有声书自动跟随失效 |
| [BUG-1741](bugs/BUG-1741-interconnect-pair-probe-reason-lost.md) | ✅ | ✅ | 互联配对报错文案完全误导：三层静默吞异常 + TLS host 回落 v1 死路 |
| [BUG-1740](bugs/BUG-1740-collection-card-continue-label-clock.md) | ✅ | ✅ | 合集卡续播标签没用统一时钟与详情页差一集 |
| [BUG-1739](bugs/BUG-1739-scan-resurrects-deleted-collection.md) | ✅ | ✅ | 来源重扫按自然键复活用户已删除的playlist合集 |
| [BUG-1738](bugs/BUG-1738-download-proxy-kills-pipeline.md) | ✅ | ✅ | 自定义下载代理未填时切换发现网络永久杀死下载管线 |
| [BUG-1737](bugs/BUG-1737-popup-dict-masonry-dead-branch.md) | ✅ | ✅ | 查词弹窗词典方框在支持原生masonry的WebKit上塌成行对齐grid |
| [BUG-1736](bugs/BUG-1736-audiobook-stop-deadlock-darwin.md) | ✅ | ✅ | 播放中退出有声书音频永不停止且无法手动关闭 |
| [BUG-1735](bugs/BUG-1735-artifact-thread-indistinguishable-in-picker.md) | 🚧 | 🚧 | 伪影文本线程在选择器里与健康线程无法区分，预览还被折叠成干净句子 |
| [BUG-1734](bugs/BUG-1734-ingame-mining-silent-failure.md) | ✅ | ✅ | 游戏内卡片制卡拿不到台词行时静默失败，无任何提示 |
| [BUG-1733](bugs/BUG-1733-kirikiriz-thread-lines-never-ingested.md) | 🚧 | 🚧 | 选中 KiriKiriZ 文本线程后实时台词恒 0，且没有任何东西告诉用户这条线程不可能产出台词 |
| [BUG-1732](bugs/BUG-1732-manga-ocr-engine-picker-and-model-accounting.md) | ✅ | ✅ | manga-ocr-engine-picker-and-model-accounting |
| [BUG-1731](bugs/BUG-1731-host-video-progress-reverse-sync.md) | ✅ | ✅ | 互联子端看片进度不反向推进 host 的继续观看/下一集 |
| [BUG-1730](bugs/BUG-1730-ass-word-wrap-midword-break.md) | ✅ | ✅ | ass 字幕英文单词中间断行（Wrap 逐字符换行无词边界） |
| [BUG-1729](bugs/BUG-1729-waveform-cue-strip-overlap.md) | ✅ | ✅ | 波形对轴弹窗字幕条带重叠cue叠画 |
| [BUG-1728](bugs/BUG-1728-ext-netflix-fulltrack-fetch.md) | ✅ | ✅ | Netflix 字幕列表只剩「实时采集」——整轨拦截静默失败 |
| [BUG-1727](bugs/BUG-1727-ext-popup-masonry-overlap.md) | ✅ | ✅ | 扩展弹窗渲染中间态多卡片重叠 |
| [BUG-1726](bugs/BUG-1726-ext-popup-viewport-clip.md) | ✅ | ✅ | 扩展查词弹窗超出视口底部被截断 |
| [BUG-1725](bugs/BUG-1725-i18n-sync-swallows-extra-args.md) | ✅ | ✅ | i18n_sync 多个 --remove 只生效第一个，多余参数被静默吞掉 |
| [BUG-1724](bugs/BUG-1724-kirikiri-lookup-install-off-main-thread.md) | ✅ | ✅ | kirikiri-lookup-install-off-main-thread |
| [BUG-1723](bugs/BUG-1723-android-predictive-back-gesture-freezes-taps.md) | ✅ | ✅ | 安卓侧滑返回后全屏点击失效 |
| [BUG-1722](bugs/BUG-1722-manga-default-store-needs-network.md) | ✅ | ✅ | 默认 keiyoushi 扩展仓库绑死在首次启动能连上 github，手机上永远看不到 |
| [BUG-1721](bugs/BUG-1721-scrape-history-no-rescrape-entry.md) | ✅ | ✅ | 后台任务历史条目无法重新刮削或手动指定作品 |
| [BUG-1720](bugs/BUG-1720-scrape-pending-confirmation-no-entry.md) | ✅ | ✅ | 视频刮削「待确认 N」没有任何确认入口 |
| [BUG-1719](bugs/BUG-1719-capture-workbench-topbar-sink.md) | ✅ | ✅ | 游戏捕获工作台顶栏分段条下沉跳动 |
| [BUG-1718](bugs/BUG-1718-browser-extension-missing-dictionary-css.md) | ✅ | ✅ | 浏览器扩展查词拿不到词典自带 CSS 与词典内嵌图片，mdx 词典在插件里样式全失效 |
| [BUG-1717](bugs/BUG-1717-manga-default-keiyoushi-store.md) | — | — | 漫画缺少默认 keiyoushi 扩展仓库（核查：develop 已内置） |
| [BUG-1716](bugs/BUG-1716-mihon-store-remove-no-confirm.md) | ✅ | ✅ | 删除漫画扩展仓库没有确认提示，一点即删 |
| [BUG-1715](bugs/BUG-1715-desktop-extension-icons-bypass-proxy.md) | ✅ | ✅ | 桌面漫画扩展列表不显示图标：图标请求绕过应用代理出口 |
| [BUG-1714](bugs/BUG-1714-subtitle-policy-required-wrong-string.md) | ✅ | ✅ | 「附带字幕 · 必选」选项复用播放器控件文案，选项读不通 |
| [BUG-1713](bugs/BUG-1713-resource-search-empty-state-hides-missing-indexer.md) | ✅ | ✅ | 未配置索引器时资源/字幕搜索显示「没有匹配的作品」，把配置缺失伪装成搜不到 |
| [BUG-1712](bugs/BUG-1712-external-subtitle-sources-missing-jimaku.md) | ✅ | ✅ | 「外部资源与字幕来源」只列用户自配项，Jimaku 与内置 Nyaa 全不可见 |
| [BUG-1711](bugs/BUG-1711-discovery-all-sources-shows-single-source.md) | ✅ | ✅ | 发现页「全部源」透出单个源的目录列表 |
| [BUG-1710](bugs/BUG-1710-manga-duplicate-discover-tabs.md) | ✅ | ✅ | 漫画库两个 tab 都叫「发现」 |
| [BUG-1709](bugs/BUG-1709-mihon-install-uses-stale-index-snapshot.md) | ✅ | ✅ | 默认 keiyoushi 仓库安装扩展报 STORE_HTTP_404：安装用的是过期索引快照 |
| [BUG-1708](bugs/BUG-1708-update-blocked-by-self-held-files.md) | ✅ | ✅ | 自更新被自己造成的文件占用挡住且失败后 app 不回来 |
| [BUG-1707](bugs/BUG-1707-mihon-store-legacy-index-v2.md) | ✅ | ✅ | Mihon 扩展仓库填 index.min.json 后安装必 404（legacy 分支吞掉 repo.json 的 index_v2） |
| [BUG-1706](bugs/BUG-1706-downloads-resource-gate-message.md) | ✅ | ✅ | 下载页资源标签把「无受管视频来源」误报成「请先配置下载后端」 |
| [BUG-1705](bugs/BUG-1705-qb-login-204.md) | ✅ | ✅ | qBittorrent 5.2+ 登录成功返回 204 被判成登录失败 |
| [BUG-1704](bugs/BUG-1704-interconnect-collection-detail-remote-members.md) | ✅ | ✅ | 互联客户端打开合集详情显示「合集为空」：详情页只认本地视频行，丢弃 host 侧成员 |
| [BUG-1703](bugs/BUG-1703-manga-extension-error-truncated-toast.md) | ✅ | ✅ | 扩展安装/加载失败的根因被 Android 原生 toast 截成 2 行，用户永远看不到 |
| [BUG-1702](bugs/BUG-1702-mihon-r8-kotlin-keep.md) | ✅ | ✅ | release APK 的 R8 混淆掉宿主 Kotlin 运行时，所有 Mihon 漫画扩展 LOAD_FAILED |
| [BUG-1701](bugs/BUG-1701-manga-webtoon-pinch-vs-scroll.md) | ✅ | ✅ | 手机端漫画条漫模式捏合缩放与上下滚动互相干扰 |
| [BUG-1700](bugs/BUG-1700-subtitle-default-language-not-video-language.md) | ✅ | ✅ | 自动下字幕的默认语言是「不限」，实际拿到的语言随缘，不跟视频自身语言 |
| [BUG-1699](bugs/BUG-1699-interconnect-collections-not-grouping.md) | ✅ | ✅ | 互联对端合集在客户端库页不成组显示 |
| [BUG-1698](bugs/BUG-1698-subtitle-backfill-after-scrape.md) | ✅ | ✅ | 刮削解析出的规范身份没被字幕侧使用，且自动配字幕能力对用户完全不可见 |
| [BUG-1697](bugs/BUG-1697-subtitle-content-never-verified.md) | ✅ | ✅ | 自动下载的字幕从不校验内容，整季合并文件被当成单集装上去 |
| [BUG-1696](bugs/BUG-1696-subscription-blocks-download-without-subtitle.md) | ✅ | ✅ | 番剧订阅：当集 Jimaku 字幕还没上传就整条不下载，生肉早于字幕导致订阅长期不动 |
| [BUG-1695](bugs/BUG-1695-jimaku-batch-wrong-episode-fallback.md) | ✅ | ✅ | 合集批量字幕：集号一条都对不上时静默取第一个文件，整季挂同一个错字幕 |
| [BUG-1694](bugs/BUG-1694-jimaku-anime-filter.md) | ✅ | ✅ | Jimaku 搜索永不传 anime 参数，真人剧/日剧字幕永远 0 结果 |
| [BUG-1693](bugs/BUG-1693-interconnect-peer-offline-misreported-as-network-error.md) | ✅ | ✅ | 互联对端关闭时误报为网络错误 |
| [BUG-1692](bugs/BUG-1692-macos-lookup-popup-webview-ignores-pointer.md) | ✅ | ✅ | macOS 查词浮层 WebView 完全收不到指针事件（点击/拖拽全失效，Flutter 外壳正常） |
| [BUG-1691](bugs/BUG-1691-gal-japanese-locale-invisible.md) | ✅ | ✅ | 转区静默生效解坏多语言版游戏文字，用户无从发现 |
| [BUG-1690](bugs/BUG-1690-startup-audio-warmup-interrupts-music.md) | ✅ | ✅ | 启动静音预热在音频设备上开流,打断其他应用正在播放的音乐 |
| [BUG-1689](bugs/BUG-1689-lookup-grip-activates-main-window.md) | ✅ | ✅ | 点剪贴板查词面板把 Hibiki 主界面抬到用户窗口之上 |
| [BUG-1688](bugs/BUG-1688-vn-chrome-inset-viewport.md) | ✅ | ✅ | VN 模式忽略 chrome inset 与页面尺寸，正文被顶栏/底栏与刘海压住（iOS 最严重） |
| [BUG-1687](bugs/BUG-1687-qb-category-legacy-hibiki.md) | 🚧 | 🚧 | 存量 qBittorrent 分类仍是改名前的 hibiki |
| [BUG-1686](bugs/BUG-1686-video-home-rows-not-interconnected.md) | ✅ | ✅ | 视频首页「下一集」「最近添加」两行不含互联远端条目 |
| [BUG-1685](bugs/BUG-1685-video-subtitle-fetch-two-implementations.md) | ✅ | ✅ | 播放页找字幕只搜 Jimaku，与下载管线的统一 registry 是两套实现 |
| [BUG-1684](bugs/BUG-1684-outbound-user-agent-still-hibiki.md) | ✅ | ✅ | 对外 User-Agent 仍报旧名 Hibiki |
| [BUG-1683](bugs/BUG-1683-interconnect-service-config-misses-bangumi-token.md) | ✅ | ✅ | 互联不同步 Bangumi 追番令牌与刮削/字幕/索引器凭据 |
| [BUG-1682](bugs/BUG-1682-remote-mining-media-dedup-delegates-local.md) | ✅ | ✅ | 制卡到已配对设备时媒体去重委派本地仓库，手机上整区隐藏 |
| [BUG-1681](bugs/BUG-1681-ankiconnect-remote-media-dedup-phantom-section.md) | ✅ | ✅ | 手机连局域网 AnkiConnect 时显示一个必然不可用的媒体存储优化区 |
| [BUG-1680](bugs/BUG-1680-ankidroid-note-type-editing.md) | ✅ | ✅ | AnkiDroid 能改已存在 note type，Lapis 样式区却在手机上整区隐藏 |
| [BUG-1679](bugs/BUG-1679-audiobook-audio-replace-stale-position.md) | ✅ | ✅ | 换音频后沿用旧时间轴的播放进度导致不响/乱跳页 |
| [BUG-1678](bugs/BUG-1678-audiobook-reimport-wipes-existing-audio.md) | ✅ | ✅ | 有声书换字幕时把现有音频删光并中止导入 |
| [BUG-1677](bugs/BUG-1677-expansiontile-outline-label-clipped.md) | ✅ | ✅ | 折叠区首个下拉框的浮动标签被展开动画的 ClipRect 削掉上半截 |
| [BUG-1676](bugs/BUG-1676-anki-gloss-image-overflows-card.md) | ✅ | ✅ | 制卡词典插图撑出卡片跑到屏幕右外 |
| [BUG-1675](bugs/BUG-1675-gal-helper-stale-after-locked-update.md) | ✅ | ✅ | galgame 捕获组件 protocol_mismatch：更新时游戏开着导致 helper 被静默跳过 |
| [BUG-1674](bugs/BUG-1674-mining-still-format.md) | ✅ | ✅ | 视频卡片图片：描述不准，且静态截图格式不可选 |
| [BUG-1673](bugs/BUG-1673-ext-side-panel-click-lookup-lost.md) | ✅ | ✅ | 侧边栏行内点击查词在迁移原生 Side Panel 时丢失 |
| [BUG-1672](bugs/BUG-1672-ext-paste-blocked-by-selection-clear.md) | ✅ | ✅ | 开着浏览器扩展时网页粘贴间歇性失效 |
| [BUG-1671](bugs/BUG-1671-ext-side-panel-subtitle-incomplete.md) | ✅ | ✅ | 浏览器扩展侧边栏获取字幕不全 |
| [BUG-1670](bugs/BUG-1670-ext-pause-on-lookup-no-resume.md) | ✅ | ✅ | 浏览器扩展查词不暂停视频且关闭弹窗不恢复播放 |
| [BUG-1669](bugs/BUG-1669-ext-side-panel-lookup-stuck-loading.md) | ✅ | ✅ | 浏览器扩展侧边栏高频查词后「正在查词」永久卡死 |
| [BUG-1668](bugs/BUG-1668-macos-ffmpeg-arm64-only.md) | ✅ | ✅ | macOS 随包 ffmpeg 是 arm64-only 瘦二进制，Intel Mac 上制卡/封面/内封字幕全线失效 |
| [BUG-1667](bugs/BUG-1667-local-audio-android-db-import-double-copy.md) | ✅ | ✅ | 安卓上用 android.db 配本地音频跑不通：导入被复制两次（cache + 库目录），峰值需 2 倍体积 |
| [BUG-1666](bugs/BUG-1666-anki-card-crossref-links-localhost.md) | ✅ | ✅ | 制卡后卡片释义交叉引用链接跳向127本地地址 |
| [BUG-1665](bugs/BUG-1665-english-mining-term-not-lemma.md) | ✅ | ✅ | 英语查词制卡词头不还原原形（MDX 重定向别名词条盖过原形） |
| [BUG-1664](bugs/BUG-1664-mine-abort-root-cause.md) | ✅ | ✅ | 制卡中止只报症状不报根因（macOS 缺 ffmpeg 时批量制卡整批失败且不可诊断） |
| [BUG-1663](bugs/BUG-1663-ios-update-lands-on-github-not-testflight.md) | ✅ | ✅ | iOS「检查更新」把 TestFlight 用户送到 GitHub 未签名 ipa |
| [BUG-1662](bugs/BUG-1662-collection-rescrape-entry.md) | ✅ | ✅ | 合集缺重新刮削入口：详情页无刮削项、单集无条目信息、菜单文案不含刮削 |
| [BUG-1661](bugs/BUG-1661-corretto-x64-sha256-typo.md) | ✅ | ✅ | macOS 构建挂在「下载 pinned JDK 失败」，真因是 sha256 抄成 65 位 |
| [BUG-1660](bugs/BUG-1660-aidoku-image-reader-compat.md) | ✅ | ✅ | Aidoku 图源图片与章节兼容及阅读器返回入口缺失 |
| [BUG-1659](bugs/BUG-1659-inline-level-box-scan-boundary.md) | ✅ | ✅ | 查词浮窗 glossary 里带振假名的词只能查到第一个汉字 |
| [BUG-1658](bugs/BUG-1658-module-settings-header-inset.md) | ✅ | ✅ | 模块设置子页顶栏与其他子页边距不一致 |
| [BUG-1657](bugs/BUG-1657-angle-surface-fallback-loses-shaders.md) | ✅ | ✅ | 画质增强/超分静默失效：ANGLE device-backed display 之后任一步失败即掉软件渲染，而 SW 路径下 glsl-shaders 完全不生效 |
| [BUG-1656](bugs/BUG-1656-apple-manga-reader-images.md) | ✅ | ✅ | Apple 漫画阅读器图片黑屏 |
| [BUG-1655](bugs/BUG-1655-ruby-double-scale.md) | ✅ | ✅ | 查词浮窗振假名显示过小（疑双重 0.5em 缩放） |
| [BUG-1653](bugs/BUG-1653-popup-dictionary-itest-desktop-drift.md) | ✅ | ✅ | popup_dictionary 应用级测试在桌面端因平台与导航假设失效 |
| [BUG-1652](bugs/BUG-1652-windows-webview-click-stale-cursor.md) | ✅ | ✅ | Windows WebView 点击使用旧光标坐标导致词条操作无响应 |
| [BUG-1651](bugs/BUG-1651-popup-auto-fit-height.md) | ✅ | ✅ | 查词弹窗忽略内容高度导致底部大面积留白 |
| [BUG-1650](bugs/BUG-1650-sync-pulled-progress-stale-until-restart.md) | ✅ | ✅ | 同步拉回更远进度后首页继续与书架不刷新须重启 |
| [BUG-1649](bugs/BUG-1649-manga-folder-epub-import.md) | ✅ | ✅ | 漫画页选文件夹导入：目录内是 epub 卷时报 Manga image folder has no pages |
| [BUG-1648](bugs/BUG-1648-embedded-torrent-idle-discovery.md) | ✅ | ✅ | 已完成任务恢复后 DHT 常驻导致网关周期性高延迟 |
| [BUG-1647](bugs/BUG-1647-bangumi-sync-stuck-in-backoff.md) | ✅ | ✅ | Bangumi 同步失败后卡在退避窗口且无自动重试，只能手动同步 |
| [BUG-1646](bugs/BUG-1646-manosaba-scene-switch-subtitle-lane.md) | ✅ | 🚧 | 魔法少女的魔女审判切换场景后字幕线程断开 |
| [BUG-1645](bugs/BUG-1645-nested-latin-lookup.md) | ✅ | ✅ | 嵌套查词查不了英语单词（跨节点粘连成拉丁串） |
| [BUG-1644](bugs/BUG-1644-d3d11va-zero-copy-interop.md) | ✅ | ✅ | Windows 视频硬解走 d3d11va-copy：ANGLE 用自己的隐藏 D3D11 device，mpv d3d11-egl interop 加载不了 |
| [BUG-1643](bugs/BUG-1643-settings-width-cap.md) | ✅ | ✅ | 设置页宽屏被 960px 强制限宽 |
| [BUG-1642](bugs/BUG-1642-favorite-unfavorite-never-propagates.md) | ✅ | ✅ | 取消收藏词句不跨端传播对端永远删不掉 |
| [BUG-1641](bugs/BUG-1641-anki-open-not-foreground.md) | ✅ | ✅ | 制卡后「在 Anki 中打开」只闪任务栏，Anki 不到前台 |
| [BUG-1640](bugs/BUG-1640-interconnect-manga-bad-package-and-noise.md) | ✅ | ✅ | 互联把EPUB转化漫画打成坏包且漫画行每轮刷推送错误 |
| [BUG-1639](bugs/BUG-1639-hwdec-nvdec-cuda-crash.md) | ✅ | ✅ | Windows+NVIDIA 起播闪退：hwdec=auto-safe 在 GL 渲染路径下必然回退 nvdec(CUDA)，nvcuda64 空指针整进程崩（BUG-1545 未根治） |
| [BUG-1638](bugs/BUG-1638-dashboard-remote-continue-dead-end-card.md) | ✅ | ✅ | 首页远端继续卡对不可下载条目是死路 |
| [BUG-1637](bugs/BUG-1637-standalone-srt-audiobook-position-never-syncs.md) | ✅ | ✅ | 纯SRT有声书听书进度跨设备完全不同步 |
| [BUG-1636](bugs/BUG-1636-remote-audio-track-not-persisted.md) | ✅ | ✅ | 互联远端视频音轨选择不持久化 |
| [BUG-1635](bugs/BUG-1635-gal-ingame-nested-popup-height-clipped.md) | ✅ | ✅ | 游戏内嵌套查词卡被父弹窗锚点空间裁短 |
| [BUG-1634](bugs/BUG-1634-gal-ingame-card-capture-includes-popup.md) | ✅ | 🚧 | 游戏内查词制卡截图包含查词框 |
| [BUG-1633](bugs/BUG-1633-gal-ingame-popup-input-rendering.md) | ✅ | 🚧 | 游戏内查词位图卡渲染错位且滚轮、按钮与制卡失效 |
| [BUG-1632](bugs/BUG-1632-gal-ingame-native-popup-ownership.md) | ✅ | ✅ | 游戏内查词离屏卡被钳回桌面导致重复弹窗 |
| [BUG-1631](bugs/BUG-1631-gal-ingame-kag-anchor-primary-coordinates.md) | ✅ | ✅ | 游戏内查词把 KAG 消息锚点误判为脱离 primary 导致字形恒不命中 |
| [BUG-1620](bugs/BUG-1620-interconnect-remote-delay-not-persisted.md) | ✅ | ✅ | 互联远端视频字幕偏移不持久化（退出重进归 0） |
| [BUG-1619](bugs/BUG-1619-panel-drag-steals-foreground.md) | ✅ | ✅ | 拖剪贴板查词面板顶栏把主窗抢到前台 |
| [BUG-1613](bugs/BUG-1613-apple-coreml-ep-detector-empty.md) | ✅ | ✅ | Apple CoreML EP 上 int8 检测模型静默返回空结果且更慢 |
| [BUG-1610](bugs/BUG-1610-bangumi-search-rating-null.md) | ✅ | ✅ | Bangumi 搜索候选评分恒空：映射器读扁平 score，真实响应只有嵌套 rating.score |
| [BUG-1609](bugs/BUG-1609-global-lookup-card-right-corners-square.md) | ✅ | ✅ | app 外全局查词卡片右上/右下圆角变方角 |
| [BUG-1608](bugs/BUG-1608-mobile-ankiconnect-ios-missing-and-silent-fallback.md) | ✅ | ✅ | iOS 没接 AnkiConnect（Lapis 区永远隐藏）；移动端清空 API key 后开关静默失效 |
| [BUG-1607](bugs/BUG-1607-danmaku-exit-relayout.md) | ✅ | ✅ | 弹幕退场时其余弹幕整屏重排 |
| [BUG-1606](bugs/BUG-1606-gal-ingame-lookup-card-dismissed-by-other-text-layer.md) | ✅ | ✅ | gal 游戏内查词卡片被无关文本层重绘打掉（说话人切换时闪没） |
| [BUG-1605](bugs/BUG-1605-gal-multi-voice-resources-single-pick.md) | ✅ | ✅ | gal 制卡：同句多个语音资源只取一个（多角色同时说话丢声） |
| [BUG-1604](bugs/BUG-1604-sync-channel-isolation-remaining-loops.md) | ✅ | ✅ | 合集同步与退出书同步的通道循环仍无逐通道隔离：云通道抛异常，互联通道整轮不跑 |
| [BUG-1603](bugs/BUG-1603-srt-subtitle-shadow-directional-offset.md) | ✅ | ✅ | SRT 字幕柔和投影方向性偏下，真机上观感为阴影错位 |
| [BUG-1596](bugs/BUG-1596-release-sequence-workdir.md) | ✅ | ✅ | release.yml 序号脚本在 working-directory: fushi 下解析成不存在路径，恢复自动发布首跑 exit 127 |
| [BUG-1595](bugs/BUG-1595-dict-update-not-replacing.md) | ✅ | ✅ | 词典更新入口遇新包标题变化仍判新增两版并存 |
| [BUG-1594](bugs/BUG-1594-ring-probe-readonly-map-crash.md) | ✅ | ✅ | ring_probe 只读映射下枚举文本槽必崩（Interlocked 写只读页） |
| [BUG-1593](bugs/BUG-1593-gal-utterance-head-clipped.md) | ✅ | ✅ | galgame 制卡语音每句都少一截开头（提交时刻 vs 播放时刻） |
| [BUG-1592](bugs/BUG-1592-secondary-subtitle-mining-black-cover.md) | ✅ | ✅ | 只开副字幕时制卡：无区间→封面抽片头黑帧 |
| [BUG-1591](bugs/BUG-1591-download-priority-has-no-write-entry.md) | ✅ | ✅ | priority 列参与排序却无写入口，排队退化成先来后到 |
| [BUG-1590](bugs/BUG-1590-subscription-candidate-list-not-aggregated.md) | ✅ | ✅ | 订阅候选列表按发布逐条列，与订阅生效单位不一致 |
| [BUG-1589](bugs/BUG-1589-windows-release-build-red-and-invisible.md) | ✅ | ✅ | Windows 发布构建固定红，且真错误被 MSBuild 折叠得看不见 |
| [BUG-1588](bugs/BUG-1588-tmdb-key-missing-in-release-builds.md) | ✅ | ✅ | 发布 workflow 漏注入 TMDB key，发出去的包 TMDB 恒未配置 |
| [BUG-1587](bugs/BUG-1587-download-queued-reported-as-torrent-missing.md) | ✅ | ✅ | 排队等槽位的下载任务被误报成「torrent 已不在引擎中」 |
| [BUG-1586](bugs/BUG-1586-release-seq-floor-after-history-rewrite.md) | ✅ | ✅ | 历史重写让发布序号倒退，全部已装用户永久收不到更新 |
| [BUG-1585](bugs/BUG-1585-golden-cross-platform-raster-false-red.md) | ✅ | ✅ | golden 基准图跨平台光栅必红：非 Windows 开发机全量套件恒 33 条伪红 |
| [BUG-1584](bugs/BUG-1584-ios-archive-strip-drops-ffi-exports.md) | ✅ | ✅ | iOS archive 的 STRIP_STYLE=all 抹掉 fushidicts FFI 导出符号，上架包启动即 Initialisation failed |
| [BUG-1583](bugs/BUG-1583-manga-ocr-test-platform-gate.md) | ✅ | ✅ | manga OCR 编排测试硬读 Platform，macOS/iOS 宿主上结构性必红 |
| [BUG-1582](bugs/BUG-1582-log-panel-longpress-blank-line-crash.md) | ✅ | ✅ | 错误日志面板长按空行崩溃（选区端点空断言） |
| [BUG-1581](bugs/BUG-1581-fushi-rename-residual-brand-labels.md) | ✅ | ✅ | 互联设备名与下载文件名仍播报 Hibiki 品牌词 |
| [BUG-1580](bugs/BUG-1580-interconnect-cooldown-and-hash-shared.md) | ✅ | ✅ | 同步冷却戳与聚合快照哈希共用：一条通道压住另一条 |
| [BUG-1579](bugs/BUG-1579-interconnect-baselines-shared-across-channels.md) | ✅ | ✅ | 合集与删除墓碑因果基线三方共用：对端移出被自己另一条通道撤销 |
| [BUG-1578](bugs/BUG-1578-interconnect-auth-error-cross-channel-signout.md) | ✅ | ✅ | 互联 401 登出的是云会话：鉴权错误不带通道身份 |
| [BUG-1577](bugs/BUG-1577-audio-package-missing-resource-silent.md) | ✅ | ✅ | 有声书资产包缺资源被两侧静默 fail-open 掩盖（导出跳过 + 导入编 basename 路径） |
| [BUG-1576](bugs/BUG-1576-interconnect-folder-cache-cross-backend.md) | ✅ | ✅ | 互联/云双通道共用 folder 缓存：跨后端串味 + 凭据外发到对端主机 |
| [BUG-1575](bugs/BUG-1575-srt-path-rebase-missing.md) | ✅ | ✅ | 合并导入不 rebase srt_books 路径：迁移后有声书有字幕没声音 |
| [BUG-1574](bugs/BUG-1574-srt-audio-picker-const-list.md) | ✅ | ✅ | 书架「重新定位 SRT 音频」取消选择器崩溃：pickRealFilePaths 返回不可变常量空列表，调用方 sort 抛 UnsupportedError |
| [BUG-1573](bugs/BUG-1573-server-lifecycle-manual-isolation.md) | ✅ | ✅ | 互联 host 启动前段异常逃逸 + dispose 顺序 + 手动同步通道未隔离 |
| [BUG-1572](bugs/BUG-1572-aggregate-push-tombstone.md) | ✅ | ✅ | 聚合上行快照不过墓碑导致已删统计/收藏复活 |
| [BUG-1571](bugs/BUG-1571-prompt-queue-cross-channel.md) | ✅ | ✅ | 双通道同步弹窗单飞槽跨通道丢候选 |
| [BUG-1570](bugs/BUG-1570-remote-lookup-drops-fields.md) | ✅ | ✅ | 远端查词响应的 truncated/headwordCount/kanjiResults 被 client 丢弃 |
| [BUG-1569](bugs/BUG-1569-sync-auto-trigger-lifecycle.md) | ✅ | ✅ | 互联自动同步触发层三缺口：离线探测零退避·合集观察者关库不卸载·sweep 丢弃退出书同步 |
| [BUG-1568](bugs/BUG-1568-video-stream-token-unbounded.md) | ✅ | ✅ | 视频流 token 签发侧无上限无过期清理 |
| [BUG-1567](bugs/BUG-1567-interconnect-request-timeouts.md) | ✅ | ✅ | 互联小型请求普遍缺超时且挂死请求占住远端清单缓存槽 |
| [BUG-1566](bugs/BUG-1566-interconnect-channel-consumers-cloud-only.md) | ✅ | ✅ | 词典删除只传播云通道、比较对话框只解析云后端：只开互联的用户两条路都断 |
| [BUG-1565](bugs/BUG-1565-remote-book-delete-partial-no-refresh.md) | ✅ | ✅ | 远端书删除半成功不刷新列表：书已删仍留幽灵卡，提示语与实情相反 |
| [BUG-1564](bugs/BUG-1564-cover-backfill-m3u8-churn.md) | ✅ | ✅ | 封面回填对m3u8清单反复ffmpeg抽帧失败重试白烧CPU |
| [BUG-1563](bugs/BUG-1563-interconnect-host-failure-swallowed.md) | ✅ | ✅ | 互联 host 换 token/开 TLS 的重启结果被丢弃、设为备份后端无 catch，失败静默把 host 打没 |
| [BUG-1562](bugs/BUG-1562-interconnect-client-panel-stale-and-race.md) | ✅ | ✅ | 互联客户端面板：已连接状态不刷新、手动配对探测窗口无忙态可并发、弹窗返回后无 mounted 守卫 |
| [BUG-1561](bugs/BUG-1561-interconnect-download-failure-invisible.md) | ✅ | ✅ | 互联下载失败态只写进内存永不上屏，任务表只增不减、页面 dispose 后零提示 |
| [BUG-1560](bugs/BUG-1560-interconnect-enable-toggle-stale-cache.md) | ✅ | ✅ | 来源页互联开关绕过设置页状态：模块级缓存永不重读，设置页开关与 section 显隐显示旧值到重启 |
| [BUG-1559](bugs/BUG-1559-interconnect-restore-auth-resets-resolved-address.md) | ✅ | ✅ | restoreAuth 把已解析地址打回候选[0] 而 _sessionResolved 仍为 true，不再重探 |
| [BUG-1558](bugs/BUG-1558-interconnect-paired-peer-list-stale.md) | ✅ | ✅ | 配对成功后已配对设备列表不刷新（controller 落库不通知） |
| [BUG-1557](bugs/BUG-1557-interconnect-tofu-fingerprint-check-order.md) | ✅ | ✅ | TOFU 指纹比对顺序倒置 + 编辑地址留旧指纹且无清除入口 |
| [BUG-1556](bugs/BUG-1556-interconnect-pair-session-ttl-before-approval.md) | ✅ | ✅ | 配对会话 TTL 从审批前起算：host 审批慢就必配不上，且过期被报成「对端拒绝」 |
| [BUG-1555](bugs/BUG-1555-interconnect-v1-pair-pin-bypass.md) | ✅ | ✅ | v1 /api/pair 绕过 PIN 强制：公网入站一次「允许」即拿到权限最大的共享 token |
| [BUG-1554](bugs/BUG-1554-lan-discovery-browser-orphan.md) | ✅ | ✅ | LAN 发现 startDiscovery 无幂等/无 dispose 守卫，重扫与关页竞态留下孤儿 Bonsoir browser |
| [BUG-1553](bugs/BUG-1553-interconnect-pair-failure-reason-lost.md) | ✅ | ✅ | 配对失败原因被压平：限速 429 / TLS 指纹不符 / 超时全说成「配对失败」且不留日志 |
| [BUG-1552](bugs/BUG-1552-sync-channel-failure-cascades.md) | ✅ | ✅ | 云备份通道抛异常直接终止通道循环，互联通道整轮不跑（「并存互不干扰」不成立） |
| [BUG-1551](bugs/BUG-1551-interconnect-server-start-race.md) | ✅ | ✅ | 互联服务开关竞态：并发 start 抢同一端口、catch 清掉别人的句柄，host 在跑却显示已停止且关不掉 |
| [BUG-1550](bugs/BUG-1550-interconnect-peer-token-single-slot.md) | ✅ | ✅ | 互联配对第二台对端后整体瘫痪：per-peer token 只有一个全局槽 + 401 株连全部候选 |
| [BUG-1549](bugs/BUG-1549-anki-toast-empty-deckname.md) | ✅ | ✅ | AnkiConnect 制卡成功 toast 牌组名为空——成功结果不带实际落卡牌组名，调用点事后从 selectedDeckName 猜 |
| [BUG-1548](bugs/BUG-1548-resource-search-wrong-season-ranking.md) | ✅ | ✅ | 资源搜索结果错季混排：结果只按 seeders 排序，无标题/季号相关度 |
| [BUG-1547](bugs/BUG-1547-tmdb-unconfigured-scrape-all-fails.md) | ✅ | ✅ | TMDB 未配置时全部刮削整批失败：resolver 不回退到零密钥的 Bangumi/AniList，且错误是英文裸串 |
| [BUG-1546](bugs/BUG-1546-settings-width-text-truncation.md) | ✅ | ✅ | 设置页限宽与描述/集标题截断显示不全 |
| [BUG-1545](bugs/BUG-1545-kon-collection-detail-crash.md) | ✅ | ✅ | 视频起播时 hwdec=auto 抢先下发，CUDA 硬解初始化崩溃整个进程（Windows/NVIDIA） |
| [BUG-1544](bugs/BUG-1544-episode-number-follow-parsed.md) | ✅ | ✅ | 选集卡片序号用导入顺位号而非文件名解析出的真实集数 |
| [BUG-1543](bugs/BUG-1543-season-split-not-splitting.md) | ✅ | ✅ | 合集分季识别吃不下「标题 2 - 集号」形态，多季全挤进第 1 季 |
| [BUG-1542](bugs/BUG-1542-collection-continue-wrong-episode.md) | ✅ | ✅ | 合集继续播放选错集：选条目层只按位置取最靠后有痕迹成员，忽略最近播放时刻 |
| [BUG-1541](bugs/BUG-1541-gamepad-bt-idle-dead.md) | ✅ | ✅ | 蓝牙手柄待机断连后按键永久失效，必须重启 app |
| [BUG-1540](bugs/BUG-1540-download-task-error-detail.md) | ✅ | ✅ | 下载任务卡错误展示：英文裸串整句铺开、无点击详情、chip 未本地化 |
| [BUG-1539](bugs/BUG-1539-resource-search-button-dead.md) | ✅ | ✅ | 下载资源页手动搜索按钮禁用但无任何原因提示 |
| [BUG-1538](bugs/BUG-1538-download-proxy-default-direct.md) | ✅ | ✅ | 下载域默认走系统代理而非直连，发现聚合来源需钉死不随代理分叉 |
| [BUG-1537](bugs/BUG-1537-settings-subtitle-ellipsis-single-line.md) | ✅ | ✅ | 设置行说明文字被压成单行省略号（ellipsis + maxLines:null） |
| [BUG-1536](bugs/BUG-1536-horizontal-row-steals-vertical-wheel.md) | ✅ | ✅ | 视频首页横滚行抢走整页纵向滚动（应 Shift+滚轮才横滚） |
| [BUG-1535](bugs/BUG-1535-download-task-details-service-unavailable.md) | ✅ | ✅ | 下载服务未启动时任务详情打不开 |
| [BUG-1534](bugs/BUG-1534-download-task-detail-path-overflow.md) | ✅ | ✅ | 下载任务详情长路径溢出 |
| [BUG-1533](bugs/BUG-1533-video-discovery-filter-height.md) | ✅ | ✅ | 视频发现筛选控件高度不一致 |
| [BUG-1532](bugs/BUG-1532-download-task-details-offline-backend.md) | ✅ | ✅ | 下载任务详情被离线原后端阻断 |
| [BUG-1531](bugs/BUG-1531-video-discovery-long-anime-movie-dedup.md) | ✅ | ✅ | 发现页同一单集长篇动画电影被重复展示 |
| [BUG-1530](bugs/BUG-1530-mihon-cover-disk-cache.md) | ✅ | ✅ | Mihon 在线漫画封面刷新重复下载 |
| [BUG-1529](bugs/BUG-1529-video-discovery-genre-facet-pollution.md) | ✅ | ✅ | 视频发现页类型菜单混入年份日期 |
| [BUG-1528](bugs/BUG-1528-video-discovery-cover-disk-cache.md) | ✅ | ✅ | 视频发现与系列页封面刷新重复下载 |
| [BUG-1527](bugs/BUG-1527-video-discovery-card-overflow-year-input.md) | ✅ | ✅ | 视频发现卡片溢出且年份下拉过长 |
| [BUG-1526](bugs/BUG-1526-extension-side-panel-row-seek.md) | ✅ | ✅ | 浏览器侧边栏字幕行点击不能跳转 |
| [BUG-1525](bugs/BUG-1525-extension-side-panel-lookup-latency.md) | ✅ | ✅ | 浏览器侧边栏查词存在可感知延迟 |
| [BUG-1524](bugs/BUG-1524-download-task-delete-pause.md) | ✅ | ✅ | Task deletion is blocked when backend pause fails |
| [BUG-1523](bugs/BUG-1523-download-task-resume.md) | ✅ | ✅ | Cancelled download tasks cannot be resumed |
| [BUG-1522](bugs/BUG-1522-torrent-tracker-utf8.md) | ✅ | ✅ | Tracker detail JSON rejects localized backend errors |
| [BUG-1521](bugs/BUG-1521-torrent-tracker-refresh-coupled.md) | ✅ | ✅ | 详情Tracker刷新被其他请求阻塞 |
| [BUG-1520](bugs/BUG-1520-torrent-detail-dropped-tab-refresh.md) | ✅ | ✅ | 下载详情切换标签时Tracker刷新被丢弃 |
| [BUG-1519](bugs/BUG-1519-video-download-missing-embedded-recovery.md) | ✅ | ✅ | 内置下载任务丢失后无法重新入队 |
| [BUG-1518](bugs/BUG-1518-download-task-delete-service-unavailable.md) | ✅ | ✅ | 下载服务未启动时任务删除无效 |
| [BUG-1517](bugs/BUG-1517-download-detail-missing-backend-task.md) | ✅ | ✅ | 下载详情未区分后端任务已丢失 |
| [BUG-1516](bugs/BUG-1516-update-manifest-dead-asset-404.md) | ✅ | ✅ | 更新清单保留已被 prune 的资产条目，客户端下载必 404 |
| [BUG-1515](bugs/BUG-1515-parent-extras-split-series.md) | ✅ | ✅ | 父作品短篇被错误拆成独立系列卡 |
| [BUG-1514](bugs/BUG-1514-subscription-episode-selection-order.md) | ✅ | ✅ | 订阅选集季号错误、重复下载且顺序按完成时间乱序 |
| [BUG-1513](bugs/BUG-1513-subscription-first-episode-skipped.md) | ✅ | ✅ | 发现订阅跳过所选首集 |
| [BUG-1512](bugs/BUG-1512-download-task-empty-overlay-metrics.md) | ✅ | ✅ | 下载任务空态遮挡且缺少实时指标 |
| [BUG-1511](bugs/BUG-1511-subscription-embedded-backend-missing.md) | ✅ | ✅ | 订阅创建后因内置下载引擎缺失而全部卡在需处理 |
| [BUG-1510](bugs/BUG-1510-migration-import-completion-pref-on-closed-db.md) | 🚧 | 🚧 | 导入完成标志写已关闭的 drift 连接：合并其实成功却谎报『校验未通过已保留待重传』，而批次文件已被删 |
| [BUG-1509](bugs/BUG-1509-jimaku-dialog-size-search-jank.md) | ✅ | ✅ | Jimaku 字幕框偏小且搜索首帧卡顿 |
| [BUG-1508](bugs/BUG-1508-migration-v79-legacy-video-tag-column.md) | ✅ | ✅ | v79 标签迁移不兼容旧 video_book_uid 列导致启动失败 |
| [BUG-1507](bugs/BUG-1507-video-shader-nested-cards.md) | ✅ | ✅ | 视频画质增强嵌入设置重复嵌套卡片 |
| [BUG-1506](bugs/BUG-1506-video-drag-seek-guard-stale-anchor.md) | ✅ | ✅ | 视频横滑 seek 守卫锚点在 BUG-1485 后失效 |
| [BUG-1505](bugs/BUG-1505-migration-import-failure-force-restart.md) | 🚧 | 🚧 | 迁移导入失败被强制重启带走：页面与失败原因一起消失，错误日志 0 条 |
| [BUG-1504](bugs/BUG-1504-subtitle-drop-attach-silent-failure.md) | ✅ | ✅ | 拖放字幕到视频卡失败无任何提示 |
| [BUG-1503](bugs/BUG-1503-sync-push-book-no-display-title.md) | ✅ | ✅ | 本端把书 push 给 host 时不带显示名（裸 epub 上传无元数据） |
| [BUG-1502](bugs/BUG-1502-sync-override-title-lww.md) | ✅ | ✅ | 书改名跨端合并无时刻列做不了 LWW（第二次改名传不到子设备） |
| [BUG-1501](bugs/BUG-1501-video-episode-click-outside-close.md) | ✅ | ✅ | 选集横轨只能点 X 关闭，点击视频区域无效 |
| [BUG-1500](bugs/BUG-1500-dict-concurrent-import-temp-race.md) | ✅ | ✅ | 词典手动下载与静默自动更新无互斥，共用 import_temp 互相删除 |
| [BUG-1499](bugs/BUG-1499-dict-download-no-cancel-no-background.md) | ✅ | ✅ | 词典下载进度框无法取消也无法后台化 |
| [BUG-1498](bugs/BUG-1498-outbound-links-bypass-app-proxy.md) | ✅ | ✅ | 多条出站链路绕过统一代理层 |
| [BUG-1497](bugs/BUG-1497-remote-download-progress-fake-importer-no-db-row.md) | ✅ | ✅ | 远端书下载进度回填测试假 importer 不落库，v82 uid 闸门后回填永不发生 |
| [BUG-1496](bugs/BUG-1496-collection-member-entrykey-uid-test-stale.md) | ✅ | ✅ | 合集详情焦点测试用 bookKey 加成员，v83 entryKey 切 uid 后合集行不渲染 |
| [BUG-1495](bugs/BUG-1495-dashboard-drift-watch-teardown-timer.md) | ✅ | ✅ | 首页 dashboard widget 测试全挂：drift .watch() 隔离清单漏了新增消费方 |
| [BUG-1494](bugs/BUG-1494-mining-guards-stale-addminingcount.md) | ✅ | ✅ | 制卡记账守卫仍钉 addMiningCount，P4 写侧收敛后把红带进 develop |
| [BUG-1493](bugs/BUG-1493-dict-download-no-proxy-no-progress.md) | ✅ | ✅ | 词典下载不走系统代理、无超时，且下载/导入阶段无可归因进度 |
| [BUG-1492](bugs/BUG-1492-dict-update-stale-lookup-cache.md) | ✅ | ✅ | 词典覆盖导入/在线更新后查词缓存不失效，更新完的词典查不到词 |
| [BUG-1491](bugs/BUG-1491-anki-dedup-serial-delete.md) | ✅ | ✅ | Anki 媒体去重逐个删除过慢 |
| [BUG-1490](bugs/BUG-1490-desktop-non-utf8-subtitle-unsupported.md) | ✅ | ✅ | 桌面端非 UTF-8 字幕全被误报为不支持 |
| [BUG-1489](bugs/BUG-1489-media-kind-guard-frozen-migration.md) | ✅ | ✅ | MediaKind 复合键守卫误判迁移冻结字面量 |
| [BUG-1488](bugs/BUG-1488-sync-book-rename-display-title.md) | ✅ | ✅ | 母设备重命名的书同步到子设备仍显示原书名 |
| [BUG-1487](bugs/BUG-1487-ios-popup-furigana-webkit.md) | ✅ | ✅ | iOS 查词弹窗振假名渲染异常 |
| [BUG-1486](bugs/BUG-1486-waveform-align-strip-list-out-of-sync.md) | ✅ | ✅ | 波形对轴面板上下字幕不一致 |
| [BUG-1485](bugs/BUG-1485-mobile-video-drag-seek-sensitivity.md) | ✅ | ✅ | 移动端视频横滑 seek 灵敏度过高 |
| [BUG-1484](bugs/BUG-1484-subtitle-list-follow-nearest-cue.md) | ✅ | ✅ | 字幕列表打开时未定位到最近字幕 |
| [BUG-1483](bugs/BUG-1483-webview2-userdata-readonly-install.md) | ✅ | ✅ | Windows 装进不可写目录后 WebView2 数据目录建不出来（启动必弹错 + 更新失败） |
| [BUG-1482](bugs/BUG-1482-video-resource-dropdown-overflow.md) | ✅ | ✅ | 资源搜索对话框下拉框横向溢出 |
| [BUG-1481](bugs/BUG-1481-rolling-channel-shared-across-products.md) | ✅ | ✅ | fushi 与 hibiki 共用同一套发布通道，hibiki 自更新被结构性阻断 |
| [BUG-1480](bugs/BUG-1480-gal-passthrough-click-lookup.md) | ✅ | ✅ | 穿透态点不了文字查词：整窗 WS_EX_TRANSPARENT 让字和背景一视同仁 |
| [BUG-1479](bugs/BUG-1479-gal-lookup-card-covered-by-game.md) | ✅ | ✅ | gal 查词卡被游戏盖住：置顶只设一次、永不重申 |
| [BUG-1478](bugs/BUG-1478-gal-workbench-char-level-lookup.md) | ✅ | ✅ | 捕获工作台只能点整词、点不了单个字；加载更多按 glossary 行递增上限 |
| [BUG-1477](bugs/BUG-1477-gal-japanese-locale-no-switch.md) | ✅ | ✅ | 汉化版被强制转区后启动即闪退：转区没有开关，判据把「32 位」当成「日文原版」 |
| [BUG-1476](bugs/BUG-1476-migration-settings-never-merged.md) | ✅ | ✅ | 跨包名迁移不搬任何设置：merge 引擎从不消费 settings 类别 |
| [BUG-1475](bugs/BUG-1475-gal-utterance-settle-drops-closing-tail.md) | ✅ | ✅ | 切句时收敛裸 return，最后 250ms 已进环的 PCM 从未被读走 |
| [BUG-1474](bugs/BUG-1474-gal-picker-dialog-cramped-and-single-line-preview.md) | ✅ | ✅ | hook 选择弹窗过小/标题截断/预览只有一句 |
| [BUG-1473](bugs/BUG-1473-gal-mining-serial-capture-and-raw-png.md) | ✅ | ✅ | gal 制卡慢：画面与语音串行 + 静态截图全分辨率 PNG 直送 Anki |
| [BUG-1472](bugs/BUG-1472-lookup-term-budget-counts-glossaries.md) | ✅ | ✅ | 查词只出一个读音：maximumTerms 按 glossary 行计预算吃掉其它读音 |
| [BUG-1471](bugs/BUG-1471-gal-overlay-gesture-state-stuck.md) | ✅ | ✅ | galgame 浮窗跑久了失去点击响应：手势事务只认 WM_LBUTTONUP 一个终止条件 |
| [BUG-1470](bugs/BUG-1470-gal-selected-thread-publish-filter.md) | ✅ | ✅ | 选中台词线程后工作台正文为空：发布期过滤器丢掉同 hook 面兄弟行 |
| [BUG-1469](bugs/BUG-1469-futamata-kirikiri-launch-av.md) | ✅ | ✅ | 恋爱成双由 Hibiki 早注入后 Access Violation |
| [BUG-1468](bugs/BUG-1468-video-home-card-footer-spacing.md) | ✅ | ✅ | 视频主页卡片底部信息留白过多 |
| [BUG-1467](bugs/BUG-1467-video-home-badge-semantics.md) | ✅ | ✅ | 视频主页角标语义不一致 |
| [BUG-1466](bugs/BUG-1466-re-zero-metadata-match.md) | ✅ | ✅ | Re Zero 罗马字标题无法通过 TMDB 严格识别 |
| [BUG-1465](bugs/BUG-1465-video-series-poster.md) | ✅ | ✅ | 系列页未使用规范作品竖版海报 |
| [BUG-1464](bugs/BUG-1464-video-re0-scrape-planning.md) | ✅ | ✅ | re0 特典误作作品且主剧季标题识别失败 |
| [BUG-1463](bugs/BUG-1463-video-series-detail-layout.md) | ✅ | ✅ | 系列详情重复、底部窄栏与首页播放目标错误 |
| [BUG-1462](bugs/BUG-1462-mushoku-metadata-backfill.md) | ✅ | ✅ | 无职转生严格匹配无法人工确认且详情与剧集标题未回填 |
| [BUG-1461](bugs/BUG-1461-himouto-tmdb-localized-title.md) | ✅ | ✅ | Himouto 罗马字标题被 TMDB 本地化结果严格门控拒绝 |
| [BUG-1460](bugs/BUG-1460-win-installer-legacy-delete-rollback.md) | ✅ | ✅ | Windows 升级中途失败后 app 彻底消失：[InstallDelete] 先删旧名二进制且不可回滚 |
| [BUG-1459](bugs/BUG-1459-installer-appdir-process-lock.md) | ✅ | ✅ | 安装器无法替换被残留子进程锁定的文件 |
| [BUG-1458](bugs/BUG-1458-sync-collections-tombstone-day-red.md) | 🚧 | 🚧 | 集合同步墓碑用例在develop稳定红-疑日期敏感 |
| [BUG-1457](bugs/BUG-1457-ai6-clean-voice.md) | ✅ | ✅ | AI6 制卡误用混合 BGM |
| [BUG-1456](bugs/BUG-1456-manga-source-preview-loading.md) | ✅ | ✅ | 漫画源预览并发拉图、超时与重复操作 |
| [BUG-1455](bugs/BUG-1455-lookup-popup-reactivates-main-window.md) | ✅ | ✅ | 拖动或缩放查词弹窗会把主窗口抬到前台 |
| [BUG-1454](bugs/BUG-1454-kana-compound-popup-selection.md) | ✅ | ✅ | 查词结果正文含假名词被 ruby 占位文本截断 |
| [BUG-1453](bugs/BUG-1453-video-gamepad-synthetic-right-click.md) | ✅ | ✅ | 手柄按键同时触发视频动作与右键菜单 |
| [BUG-1452](bugs/BUG-1452-gal-unselected-thread-implies-audio.md) | ✅ | ✅ | 未选择台词线程时仍显示正在监听与句级音频 |
| [BUG-1451](bugs/BUG-1451-popup-copy-shortcut-and-context-menu.md) | ✅ | ✅ | 查词弹窗无法复制（Ctrl+C 与右键「复制」都无效） |
| [BUG-1450](bugs/BUG-1450-windows-ime-swallows-shortcuts.md) | ✅ | ✅ | 中文输入法激活时全表面快捷键失效（IME 吞键） |
| [BUG-1449](bugs/BUG-1449-gal-helper-bundled-as-plain-files.md) | ✅ | ✅ | helper 改为构建期解压随包，消灭需与本体同步的第二份副本 |
| [BUG-1448](bugs/BUG-1448-gal-helper-version-check-short-circuited.md) | ✅ | ✅ | injector 存在即跳过 ensureInjector，随包新组件永不换入 |
| [BUG-1447](bugs/BUG-1447-manga-remote-ocr-probe-ignores-models-ready.md) | ✅ | ✅ | 远端 OCR probe 只校验 supported 不校验 modelsReady，模型未下载的主机照样可选，白传一整卷才报错 |
| [BUG-1446](bugs/BUG-1446-gal-fallback-detail-dropped-in-session-card.md) | ✅ | ✅ | galgame 降级状态卡丢弃 injectorDetail，版本对照证据永远看不到 |
| [BUG-1445](bugs/BUG-1445-ffmpeg-min-macos-arch-and-dead-dlls.md) | ✅ | ✅ | ffmpeg-min：macOS 二进制 arm64-only 无守卫钉住，Windows 两个 MinGW 运行时 DLL 是死重 |
| [BUG-1444](bugs/BUG-1444-v68-media-images-fk-parent-missing.md) | ✅ | ✅ | v68 迁移 INSERT media_images 在外键开启时因 FK 父表缺席抛 no such table，整条 onUpgrade 中断 |
| [BUG-1443](bugs/BUG-1443-macos-vendored-ffmpeg-homebrew-dylib.md) | ✅ | ✅ | macOS 随包 ffmpeg 动态依赖 Homebrew dylib，干净机器上 dyld 崩溃 |
| [BUG-1442](bugs/BUG-1442-spread-key-bridge-single-scope.md) | ✅ | ✅ | 双页 spread 键桥只能解析 reader scope，跨 scope 动作在 spread 里恒解析不到 |
| [BUG-1441](bugs/BUG-1441-manga-extension-filter-and-lag.md) | ✅ | ✅ | 漫画扩展列表筛选不生效 + 语言下拉卡顿 |
| [BUG-1440](bugs/BUG-1440-video-subtitle-frz-origin-not-anchor.md) | ✅ | ✅ | \frz 绕盒中心而非 \an 锚点旋转，竖排整列左移出框 |
| [BUG-1439](bugs/BUG-1439-video-subtitle-list-karaoke-chain-merge.md) | ✅ | ✅ | 字幕列表把整首 OP 歌词链式合并成一条逐字交错的乱码 |
| [BUG-1438](bugs/BUG-1438-context-menu-ui-scale.md) | ✅ | ✅ | 右键/上下文菜单不吃界面大小：漫画菜单错位 + 阅读器菜单双重缩放 |
| [BUG-1437](bugs/BUG-1437-renumber-selfcheck-blind.md) | ✅ | ✅ | renumber 自校验与替换共用同一扫描器，漏改文件被谎报零残留 |
| [BUG-1436](bugs/BUG-1436-collection-combine-uses-selection-order.md) | ✅ | ✅ | 批量组合成合集：成员按点选顺序落 sortIndex，选集列表乱序 |
| [BUG-1435](bugs/BUG-1435-video-folder-import-episode-title-in-series.md) | ✅ | ✅ | 按文件夹导入：SxxExx 后的分集标题并进系列名，同一部番分不到一组 |
| [BUG-1434](bugs/BUG-1434-mokuro-book-ocr-no-images.md) | ✅ | ✅ | 已导入的 mokuro 漫画在 OCR 向导被误判为没有找到图片 |
| [BUG-1433](bugs/BUG-1433-mokuro-download-no-retry.md) | ✅ | ✅ | mokuro.moe 卷下载失败后既无自动重试也无手动重试入口 |
| [BUG-1432](bugs/BUG-1432-ime-physical-key-ledger.md) | ✅ | ✅ | TODO-2652「三处快捷键台账仍记裸 logicalKey」经查证伪：`LogicalKeyboardKey.process` 在 5 个出包平台上根本不可达 |
| [BUG-1431](bugs/BUG-1431-mokuro-source-belongs-with-extensions.md) | ✅ | ✅ | mokuro.moe 挂在本地扫描根下，应与漫画扩展同级 |
| [BUG-1430](bugs/BUG-1430-subtitle-obscure-switch-lag.md) | ✅ | ✅ | 切换字幕遮罩模式卡顿：两次事务落盘 + UI 等落盘 + 全局广播重建全 app |
| [BUG-1429](bugs/BUG-1429-bug-tool-number-pool-misses-uncommitted-worktrees.md) | ✅ | ✅ | bug.dart 取号扫不到并发工作区未提交的 bug 文件，一天连撞六次 |
| [BUG-1428](bugs/BUG-1428-zero-context-patch-drift-silent.md) | ✅ | ✅ | 零上下文补丁漂移无声：git apply --unidiff-zero 对上游漂移 exit 0 后盲插 |
| [BUG-1427](bugs/BUG-1427-mobile-mining-ffmpeg-stuck-6-0.md) | 🚧 | 🚧 | 移动端制卡链 FFmpeg 停在 6.0，上游已迁到 ffmpeg-kit-next (FFmpeg 8.1.2) |
| [BUG-1426](bugs/BUG-1426-spread-input-bridges.md) | ✅ | ✅ | 双页 spread 页滚轮与左右翻页失效 |
| [BUG-1425](bugs/BUG-1425-md3-guard-allowlist-drift.md) | ✅ | ✅ | MD3 守卫豁免与实际命中脱节：四处裸 Material chrome 静默放行 + fontSizeFactor 绕过判据 + 过期豁免 |
| [BUG-1424](bugs/BUG-1424-manga-escape-dead-key.md) | ✅ | ✅ | 漫画阅读器里 Esc 是死键：无词典弹窗时退不出漫画 |
| [BUG-1423](bugs/BUG-1423-reader-floating-chrome-shortcut.md) | ✅ | ✅ | 阅读器悬浮控制栏快捷键未驱动临时显隐状态 |
| [BUG-1422](bugs/BUG-1422-shortcut-capture-ime-physical.md) | ✅ | ✅ | 快捷键录入在 IME 下把物理 Z 存成 Process |
| [BUG-1421](bugs/BUG-1421-macos-release-no-bundled-ffmpeg.md) | ✅ | ✅ | macOS 发布产物从不捆绑 ffmpeg，桌面制卡全链在未装 ffmpeg 的 Mac 上失效 |
| [BUG-1420](bugs/BUG-1420-desktop-ffprobe-never-bundled.md) | ✅ | ✅ | 桌面 ffprobe 从未被构建或捆绑，内封字幕字体与音频元数据在干净机器上静默失效 |
| [BUG-1419](bugs/BUG-1419-webview2-sticky-mouse-buttons-block-lookup.md) | ✅ | ✅ | Windows 阅读器右键后左键点击只出蓝色选区、查词失效（WebView2 鼠标键状态粘滞） |
| [BUG-1418](bugs/BUG-1418-manga-reader-ocr-paired-host-missing.md) | ✅ | ✅ | 阅读器整卷 OCR 看不到「配对主机」选项：openBookOcr 漏传 remoteRunner |
| [BUG-1417](bugs/BUG-1417-anime-download-added-activity.md) | ✅ | ✅ | 番剧下载自动入库不记 added 活动事件 |
| [BUG-1416](bugs/BUG-1416-netflix-still-frame-at-mine-time.md) | ✅ | ✅ | Netflix 沉浸捕获选静态帧时取的是片段首帧，不是制卡那一刻的帧 |
| [BUG-1415](bugs/BUG-1415-ci-mextension-upstream-404.md) | ✅ | ✅ | CI macos/windows/publish 全红：Mihon 桌面 runtime 构建 git clone 已 404 的 M-Extension-Server |
| [BUG-1414](bugs/BUG-1414-md3-manga-fontsize-guard.md) | ✅ | ✅ | manga.json 回写触发 MD3 fontSize 守卫，develop CI 单测门变红 |
| [BUG-1413](bugs/BUG-1413-local-audio-busy-swallowed-as-miss.md) | ✅ | ✅ | 本地音频库 SQLITE_BUSY 被吞成与「真没这词」同形的 null |
| [BUG-1412](bugs/BUG-1412-activity-identity-gates.md) | ✅ | ✅ | 游戏活动身份回退过宽：同名条目取第一个 / 脏 key 误绑封面 |
| [BUG-1406](bugs/BUG-1406-libmpv-ffmpeg-version-guard-first-match.md) | ✅ | ✅ | libmpv FFmpeg 版本守卫只校验第一个匹配，单 ABI 静默降级不报红 |
| [BUG-1400](bugs/BUG-1400-appaths-prefs-channel-fakeasync-deadlock.md) | ✅ | ✅ | AppPaths 解析穿真实 prefs 通道，fake async 相位一次调用钉死整个 isolate（互联下载登记测试 flaky） |
| [BUG-1394](bugs/BUG-1394-cover-write-guard-cross-file.md) | ✅ | ✅ | 封面写盘守卫的跨文件派生覆盖洞：番剧下载封面绕过 BUG-1118 收口 |
| [BUG-1393](bugs/BUG-1393-collection-member-poster.md) | ✅ | ✅ | 合集子篇被自动刮成作品级竖版海报，且作品海报被整个丢弃 |
| [BUG-1392](bugs/BUG-1392-md3-chrome-guard-collection-prs.md) | ✅ | ✅ | 合集三 PR 绕过 MD3 页面 chrome 守卫：CheckboxListTile / 手抄封面角标 / 硬编码 fontSize 直接把 develop 打红 |
| [BUG-1386](bugs/BUG-1386-webview-renderer-gone-kills-app.md) | ✅ | ✅ | Android renderer 被回收时未接管 onRenderProcessGone，整个 app 被系统杀掉 |
| [BUG-1381](bugs/BUG-1381-lyrics-bottom-reserve-guard.md) | ✅ | ✅ | 歌词底栏预留守卫锚在实现写法上，PR#670 合并 Padding 后 develop 单测红 |
| [BUG-1380](bugs/BUG-1380-wheel-gate-token-consumed-before-paginate.md) | ✅ | ✅ | 分页滚轮闸门在换章加载期消费手势 token，整段横向惯性被吞 |
| [BUG-1373](bugs/BUG-1373-ios-pod-install-license-file-type.md) | ✅ | ✅ | iOS pod install 断在 license 校验：LICENSE.GPLv3 扩展名不被 CocoaPods 接受 |
| [BUG-1372](bugs/BUG-1372-android-appsmoke-prewarm-webview-renderer-kills-app.md) | ✅ | ✅ | Android appSmoke：预热 headless WebView 永不销毁，renderer 被 OOM kill 后连坐杀整个 app 进程 |
| [BUG-1365](bugs/BUG-1365-local-audio-query-races-binding-index-build.md) | ✅ | ✅ | 桌面本地音频查询与绑定期建索引竞态：撞锁被吞成 null＝「暂无发音」（CI flaky） |
| [BUG-1364](bugs/BUG-1364-search-placeholder-covers-dialog.md) | ✅ | ✅ | 搜索中占位层未接对话框隐藏计数，可能盖住对话框 |
| [BUG-1358](bugs/BUG-1358-schema-guard-handwritten-comment-strip.md) | ✅ | ✅ | PR#679 新守卫手写 startsWith('//') 剥注释，违反 source_guard 纪律，develop 单测门红 |
| [BUG-1353](bugs/BUG-1353-ci-macos-bsd-sed-inplace.md) | ✅ | ✅ | CI macos/ios 作业固定红：TMDB key 注入用了 GNU-only 的裸 sed -i |
| [BUG-1352](bugs/BUG-1352-ci-package-tests-schema-literal.md) | ✅ | ✅ | CI Run package tests 红：packages 侧 schemaVersion 等值断言漏跟 v66 |
| [BUG-1351](bugs/BUG-1351-scan-playlist-import-no-added-activity.md) | ✅ | ✅ | 扫描导入新播放列表合集不落 added 活动事件 |
| [BUG-1350](bugs/BUG-1350-dashboard-activity-cross-series-merge.md) | ✅ | ✅ | 首页活动时间轴同日同集号跨作品被合并吞掉观看记录 |
| [BUG-1349](bugs/BUG-1349-collection-detail-escape-dead.md) | ✅ | ✅ | 合集详情页按Esc不退出（焦点导航开启时全局Esc解析不到路由被吞） |
| [BUG-1348](bugs/BUG-1348-gdrive-signin-token-exchange-direct-connect.md) | ✅ | ✅ | 谷歌云盘桌面登录：token 交换裸直连不走代理，浏览器已授权但 app 超时 |
| [BUG-1347](bugs/BUG-1347-dismiss-dict-mouse-popup-surface.md) | ✅ | ✅ | 关词典的鼠标键/快捷键在查词弹窗表面无效（Windows 指针与焦点所有权） |
| [BUG-1346](bugs/BUG-1346-gal-text-lane-v13-squeeze.md) | ✅ | ✅ | galgame 文本捕获：256 槽全局 FIFO 挤压导致放开非胜出线程必然复现 BUG-1159（IPC v13 按线程分道根治） |
| [BUG-1345](bugs/BUG-1345-gal-ipc-contract-host-copy-drift.md) | ✅ | ✅ | galgame 捕获报「捕获组件版本与 Hibiki 不一致」：IPC 契约在 host 侧有手抄副本，且处置指向已不存在的动作 |
| [BUG-1344](bugs/BUG-1344-macos-reader-selection-stale.md) | ✅ | ✅ | macOS查词关闭后原文选区高亮残留 |
| [BUG-1343](bugs/BUG-1343-macos-reader-window-drag.md) | ✅ | ✅ | macOS窗口化阅读器缺少可拖拽区域 |
| [BUG-1342](bugs/BUG-1342-macos-trackpad-paged-wheel.md) | ✅ | ✅ | macOS触控板一次滑动连续翻三到四页 |
| [BUG-1341](bugs/BUG-1341-mihon-detail-layout.md) | ✅ | ✅ | Mihon 漫画详情页路由触发布局断言 |
| [BUG-1340](bugs/BUG-1340-mihon-extension-catalog-restart.md) | ✅ | ✅ | 漫画扩展重启后可下载目录消失且无法安装新扩展 |
| [BUG-1339](bugs/BUG-1339-clip-export-mobile-h264-encoder.md) | ✅ | ✅ | 移动端片段导出缺 H.264 编码器导致静默产出不可播文件 |
| [BUG-1338](bugs/BUG-1338-delete-everywhere-srt-and-no-backend.md) | ✅ | ✅ | 「从所有设备删除」两个死角：纯字幕书无效、无同步后端时静默无效 |
| [BUG-1337](bugs/BUG-1337-video-subtitle-list-per-char-karaoke.md) | ✅ | ✅ | 字幕列表把 OP 逐字卡拉OK 列成整屏单字 |
| [BUG-1336](bugs/BUG-1336-mihon-online-ocr-niratan-parity.md) | ✅ | ✅ | Mihon 在线漫画 OCR 横竖排错位且加载缓存调度未对齐 Niratan |
| [BUG-1335](bugs/BUG-1335-video-subtitle-first-frame-font-scale-jump.md) | ✅ | ✅ | 字幕出现后位置动一下才正常（高分屏，特定句子） |
| [BUG-1334](bugs/BUG-1334-manga-card-wrong-spread-page.md) | ✅ | ✅ | 漫画双页模式制卡图片取错成跨页首页 |
| [BUG-1333](bugs/BUG-1333-manga-sentence-fragmented-blocks.md) | ✅ | ✅ | 漫画 Lens 同一气泡被拆成多列导致制卡句子残缺 |
| [BUG-1332](bugs/BUG-1332-video-pos-subtitle-no-controls-dodge.md) | ✅ | ✅ | 带 \pos 的字幕不避让控制条、盖住暂停键 |
| [BUG-1331](bugs/BUG-1331-video-ass-vertical-font-not-supported.md) | ✅ | ✅ | \fn@ 竖排字体未支持导致整行躺倒出屏 |
| [BUG-1330](bugs/BUG-1330-remote-mining-animated-format.md) | ✅ | ✅ | 浏览器扩展远端制卡（YouTube/Netflix）不吃制卡图片格式偏好，恒出 GIF |
| [BUG-1329](bugs/BUG-1329-video-subtitle-menu-not-refreshed-after-download.md) | ✅ | ✅ | 下载/导入字幕后字幕轨列表不刷新，且重新枚举时长时间挂加载条 |
| [BUG-1328](bugs/BUG-1328-ui-font-chain-collapsed-to-single-family.md) | ✅ | ✅ | 界面字体回退链被压成单值：中文默认字形难看、日文缺字逐字乱回退、用户第2条字体永不生效 |
| [BUG-1327](bugs/BUG-1327-video-context-dialog-barrier.md) | ✅ | ✅ | 视频页制卡上下文对话框被查词浮层 barrier 吃掉点击 |
| [BUG-1326](bugs/BUG-1326-popup-ctx-modal-args-stringified.md) | ✅ | ✅ | 调整上下文回点制卡永远点第一个词条 |
| [BUG-1325](bugs/BUG-1325-scrape-all-overwrites-user-chosen-cover.md) | ✅ | ✅ | 「全部刮削」会把用户手动纠正过的封面一并覆盖 |
| [BUG-1324](bugs/BUG-1324-sync-report-auth-failure-untyped.md) | ✅ | ✅ | 同步报告把鉴权失败压成一行字符串：UI 只剩「N 项失败」 |
| [BUG-1323](bugs/BUG-1323-sync-401-403-flattened.md) | ✅ | ✅ | webdav_ops 把 401/403 压成同一个 SyncAuthError：403 被谎报成登录过期还触发登出 |
| [BUG-1322](bugs/BUG-1322-clip-export-mobile-mjpeg-unplayable.md) | ✅ | ✅ | 移动端导出片段MJPEG-MOV体积巨大且普遍无法播放 |
| [BUG-1321](bugs/BUG-1321-clip-export-mismatch-window-collapse.md) | ✅ | ✅ | 选区与字幕文本不一致时长选区导出退化为单句音频 |
| [BUG-1320](bugs/BUG-1320-clip-export-toolong-crosschapter-toast.md) | ✅ | ✅ | 片段导出超时长上限被误报为跨章且上限过紧 |
| [BUG-1319](bugs/BUG-1319-collection-delete-cover-leak.md) | ✅ | ✅ | 删合集只有 1/6 入口回收自有封面：其余五条只删 DB 行，路径随行永久丢失、GC 又扫不到该子目录 = 确定性空间泄漏 |
| [BUG-1318](bugs/BUG-1318-tracking-mapping-stale-after-format-change.md) | 🚧 | 🚧 | 转化后 Bangumi 映射不复核：epub→manga 后进度静默永久停报 |
| [BUG-1317](bugs/BUG-1317-override-title-key-source-asymmetry.md) | ✅ | ✅ | 漫画/PDF 书改名后首页与统计仍显示旧名：override 键读写不同源 |
| [BUG-1316](bugs/BUG-1316-reader-route-ignores-live-format.md) | ✅ | ✅ | 跳回原文按写死的 EPUB 源打开：漫画/PDF 书用错阅读器 |
| [BUG-1315](bugs/BUG-1315-texthooker-threadless-lines-never-published.md) | ✅ | ✅ | 未选线程门控把无线程身份的行（WebSocket/Textractor 端点）永久丢弃 |
| [BUG-1311](bugs/BUG-1311-interconnect-service-config-403-on-plaintext.md) | ✅ | ✅ | 互联同步每轮都报「认证失败」：明文 host 上无条件请求 service-config |
| [BUG-1310](bugs/BUG-1310-collection-scrape-metadata.md) | ✅ | ✅ | 合集刮削只落封面：作品资料无宿主、合集名不回写 |
| [BUG-1309](bugs/BUG-1309-anime-download-confirm-subs-squeezed.md) | ✅ | ✅ | 下载弹窗确认阶段：Jimaku 选择器挤掉字幕列表，RenderFlex 溢出 10px 且只剩不到一条可见 |
| [BUG-1308](bugs/BUG-1308-popup-dict-style-node-per-section.md) | 🚧 | 🚧 | 查词弹窗每条目×每词典新建一个 style 节点，触发 10 次全文档样式重算 |
| [BUG-1307](bugs/BUG-1307-dict-engine-max-results-overshoot.md) | ✅ | ✅ | 查词冷路径白解压 20 倍：引擎结果上限硬编码 200 而 Dart 侧只用 maximumTerms |
| [BUG-1305](bugs/BUG-1305-delete-confirm-disclosure.md) | ✅ | ✅ | 删除确认文案与真实删除范围对不上（书架递归删解压目录+有声书；合集正文说反话） |
| [BUG-1304](bugs/BUG-1304-engine-freq-pitch-enrich-before-truncate.md) | ✅ | ✅ | 词典引擎 freq/pitch 在截断前富化：中间结果被重复富化约 3 倍（实测微优化，非秒级根因） |
| [BUG-1303](bugs/BUG-1303-hoshidicts-hash-probe-unbounded.md) | ✅ | ✅ | 词典 hash 探测无界循环 + load() 零边界校验：损坏词典可致查词永久挂死/越界读 |
| [BUG-1302](bugs/BUG-1302-lookup-blocking-network-timeouts.md) | ✅ | ✅ | 查词弹窗被网络超时阻塞数秒（远端查词 remote-first + 逐词条 AnkiConnect 查重） |
| [BUG-1301](bugs/BUG-1301-video-hidden-chrome-steals-focus-ring.md) | ✅ | ✅ | 视频页隐形chrome可聚焦致空焦点框 |
| [BUG-1300](bugs/BUG-1300-focus-ring-stale-rect-on-layout-shift.md) | ✅ | ✅ | 焦点环矩形不随布局位移过期悬空 |
| [BUG-1299](bugs/BUG-1299-continue-cover-portrait-crop.md) | ✅ | ✅ | 竖版海报封面在继续/继续观看/合集详情被裁切或留灰带 |
| [BUG-1298](bugs/BUG-1298-collection-hero-portrait-cover.md) | ✅ | ✅ | 合集详情页 hero 用竖版刮削海报时被 BoxFit.cover 裁成中间一条 |
| [BUG-1297](bugs/BUG-1297-danmaku-scroll-exit.md) | ✅ | ✅ | 滚动弹幕退场突兀：没滑出屏幕就被整条抹掉 |
| [BUG-1296](bugs/BUG-1296-anime-download-task-row-progress-lost.md) | ✅ | ✅ | 下载任务行百分比/确定进度环依赖 downloadStats，「立即导入」一跑就整列消失 |
| [BUG-1295](bugs/BUG-1295-qb-test-connection-undiagnosable.md) | ✅ | ✅ | qB测试连接失败无法自查且本机免密被登录门卡死 |
| [BUG-1294](bugs/BUG-1294-download-tasks-no-speed-traffic.md) | ✅ | ✅ | 下载任务行无速度与流量显示 |
| [BUG-1293](bugs/BUG-1293-embedded-upload-mode-kills-download.md) | ✅ | ✅ | 内置引擎默认关上传误用upload_mode掐死下载 |
| [BUG-1292](bugs/BUG-1292-magpie-bundled-only.md) | ✅ | ✅ | Magpie 内置后仍显示并保留下载路径 |
| [BUG-1291](bugs/BUG-1291-destructive-confirm-checkbox-truncated.md) | ✅ | ✅ | 销毁确认弹窗勾选行文案被单行省略号截断 |
| [BUG-1290](bugs/BUG-1290-bangumi-dashboard-history.md) | ✅ | ✅ | Bangumi 首页卡把映射误当观看历史且不列待手动关联条目 |
| [BUG-1289](bugs/BUG-1289-youtube-caption-track-labels-ambiguous.md) | ✅ | ✅ | YouTube 字幕轨标签退化成语言码且人工/ASR 重名，无法分辨选哪条 |
| [BUG-1288](bugs/BUG-1288-android-video-resume-seek-overwritten.md) | ✅ | ✅ | 安卓视频进入后被踢回开头：恢复 seek 被 loadfile 覆盖 |
| [BUG-1287](bugs/BUG-1287-gal-loopback-flush-no-settle.md) | ✅ | ✅ | galgame 查词/制卡时语音只到句子前半段：loopback 提前收束后不再补全 |
| [BUG-1286](bugs/BUG-1286-gal-lookup-hook-revoked.md) | ✅ | ✅ | galgame 查词浮窗点击失效：低级鼠标钩子被系统吊销后不再重装 |
| [BUG-1285](bugs/BUG-1285-subtitle-plain-mode-inline-color.md) | ✅ | ✅ | 纯字幕模式下行内 \c 主色穿透导致 OP 字幕变黑 |
| [BUG-1284](bugs/BUG-1284-activity-game-cover.md) | ✅ | ✅ | 游戏活动身份不统一导致封面缺失 |
| [BUG-1283](bugs/BUG-1283-nested-popup-custom-font-flash.md) | ✅ | ✅ | 嵌套查词显示前闪过系统字体 |
| [BUG-1282](bugs/BUG-1282-dictionary-redirect-only-entries.md) | ✅ | ✅ | redirect-only 词典条目混入真实释义结果 |
| [BUG-1281](bugs/BUG-1281-dict-auto-update-last-check.md) | ✅ | ✅ | 词典自动更新检查成功但无新版时永远显示从未并重复检查 |
| [BUG-1280](bugs/BUG-1280-spread-chrome-unreachable.md) | ✅ | ✅ | 双页 spread 页唤不出底栏、退不出书 |
| [BUG-1279](bugs/BUG-1279-ext-nested-lookup-inplace.md) | ✅ | ✅ | 浏览器扩展嵌套查词会关掉旧弹窗、跳位并重画原文高亮 |
| [BUG-1278](bugs/BUG-1278-download-settings-content-left.md) | ✅ | ✅ | 下载设置宽屏内容整体贴左且开关被推到远端 |
| [BUG-1277](bugs/BUG-1277-reader-navigation-after-dispose.md) | ✅ | ✅ | 有声书跨章等待后触发已销毁 State 重绘 |
| [BUG-1276](bugs/BUG-1276-dashboard-heatmap-dark-contrast.md) | ✅ | ✅ | 黑色主题下学习活动热力图空周融进背景 |
| [BUG-1275](bugs/BUG-1275-anti-leech-blacklist-range-ban.md) | ✅ | ✅ | 反吸血身份黑名单命中升级整段连坐封禁 |
| [BUG-1274](bugs/BUG-1274-anti-leech-blacklist-download-phase.md) | ✅ | ✅ | 反吸血身份黑名单下载期无差别封禁 |
| [BUG-1273](bugs/BUG-1273-reader-back-swallowed-while-audiobook-playing.md) | ✅ | ✅ | 有声书播放中侧滑返回无效（退出链 await 停播放器） |
| [BUG-1272](bugs/BUG-1272-bangumi-scrape-no-retry.md) | 🚧 | 🚧 | Bangumi 刮削单次请求无重试，链路丢连接直接失败 |
| [BUG-1271](bugs/BUG-1271-popup-autoexpand-rows-unit-mismatch.md) | ✅ | ✅ | 自动展开默认值按本数写进行数槽位，出厂默认从3本变9本 |
| [BUG-1270](bugs/BUG-1270-youtube-live-subtitle-seek-duplicate.md) | ✅ | ✅ | YouTube 实时字幕回跳后重复且累积成长段 |
| [BUG-1269](bugs/BUG-1269-dismiss-dict-popup-surface-input.md) | ✅ | ✅ | 关闭词典的快捷键/鼠标键在弹窗表面仍然无效 |
| [BUG-1268](bugs/BUG-1268-youtube-quality-entry-self-locked.md) | ✅ | ✅ | YouTube 画质入口自锁：设置面板画质行永不显示 |
| [BUG-1267](bugs/BUG-1267-gal-attach-missing-luna-pchooks.md) | ✅ | ✅ | 捕获窗口(attach)模式硬编码不装 LunaHook PC hooks，Unity 游戏中途对接抓不到文本 |
| [BUG-1266](bugs/BUG-1266-gamepad-b-hijacked-by-back.md) | ✅ | ✅ | 手柄 B 被 Android 系统返回兜底抢占，改键无效；视频页首帧就绪前手柄键全失灵 |
| [BUG-1265](bugs/BUG-1265-anki-gaiji-cache-miss-aborts-mine.md) | ✅ | ✅ | AnkiConnect 制卡：词典外字缓存缺失导致整张卡建不出来 |
| [BUG-1264](bugs/BUG-1264-popup-perdict-collapse-outranked.md) | ✅ | ✅ | 每本词典的折叠开关对前 N 本无效（被自动展开覆盖） |
| [BUG-1263](bugs/BUG-1263-anki-dedup-progress-cancel.md) | ✅ | ✅ | Anki媒体去重真删与扫描为分钟级长任务却无进度不可取消且期间Anki无响应 |
| [BUG-1262](bugs/BUG-1262-anki-dedup-vanished-file-aborts.md) | ✅ | ✅ | 媒体文件在扫描快照后消失导致整轮去重PathNotFoundException中止 |
| [BUG-1261](bugs/BUG-1261-oald-mdd-parts-sound-play.md) | ✅ | ✅ | MDX 分卷 MDD 未挂载 + 词典内 sound:// 发音点击无反应（OALD） |
| [BUG-1260](bugs/BUG-1260-sync-progress-blank-and-silent-noop.md) | ✅ | ✅ | 同步进度条只有线没有字 + 零通道空转静默收尾 |
| [BUG-1252](bugs/BUG-1252-scrape-cover-preview-size.md) | ✅ | ✅ | 刮削候选封面预览过小 |
| [BUG-1251](bugs/BUG-1251-manual-search-confidence.md) | ✅ | ✅ | 手动搜索封面仍按原路径标题评分 |
| [BUG-1250](bugs/BUG-1250-stream-import-hides-progress.md) | ✅ | ✅ | 边下边播提前入库把下载任务直接标成已完成并丢失进度 |
| [BUG-1249](bugs/BUG-1249-download-empty-result-reason.md) | ✅ | ✅ | 下载发现把空响应或损坏 RSS 伪装成无结果且不说明筛选原因 |
| [BUG-1248](bugs/BUG-1248-bangumi-cover-original-timeout.md) | ✅ | ✅ | Bangumi封面退化图落盘且原图下载30秒超时 |
| [BUG-1247](bugs/BUG-1247-gal-unity-text-source-isolation.md) | ✅ | ✅ | Unity TextMesh 停顿拆句且绕过文本线程选择 |
| [BUG-1246](bugs/BUG-1246-galgame-helper-version-drift.md) | ✅ | ✅ | 随包 helper 已更新但完整旧安装被直接放行，native 修复永远不生效 |
| [BUG-1245](bugs/BUG-1245-vn-reveal-chrome-also-advances.md) | ✅ | ✅ | VN唤出悬浮底栏时误同时推进 |
| [BUG-1244](bugs/BUG-1244-vn-media-screen-skipped.md) | ✅ | ✅ | VN独立图片屏被逐句跳转永久略过 |
| [BUG-1243](bugs/BUG-1243-audiobook-clip-multicue-export.md) | ✅ | ✅ | 有声书片段导出多句退化并附带多余音频文件 |
| [BUG-1242](bugs/BUG-1242-dictionary-popup-scroll-gesture-stall.md) | ✅ | ✅ | 查词弹窗横滑手势阻塞正文滚动 |
| [BUG-1241](bugs/BUG-1241-reader-terminal-not-completed.md) | ✅ | ✅ | 阅读器末页停在99%不自动标记读完 |
| [BUG-1240](bugs/BUG-1240-audiobook-stop-overwrites-position.md) | ✅ | ✅ | 有声书退出停止后位置被零覆盖 |
| [BUG-1239](bugs/BUG-1239-video-ime-fullwidth-space.md) | ✅ | ✅ | 全角空格在视频页仍无法播放暂停 |
| [BUG-1238](bugs/BUG-1238-clipboard-lookup-audio.md) | ✅ | ✅ | 剪贴板变更查词不应自动播放音频 |
| [BUG-1237](bugs/BUG-1237-popup-touch-copy-actionmode-finished.md) | ✅ | ✅ | 查词弹窗触屏复制经已结束 ActionMode 失效 |
| [BUG-1236](bugs/BUG-1236-reader-selection-menu-modal-blocks-handles.md) | ✅ | ✅ | 移动端阅读器选区菜单阻断手柄拖动 |
| [BUG-1235](bugs/BUG-1235-jimaku-batch-availability.md) | ✅ | ✅ | 合集字幕匹配无法区分来源与逐集可用性 |
| [BUG-1234](bugs/BUG-1234-cover-match-source-state.md) | ✅ | ✅ | 封面匹配切换来源会自动重搜并保留旧来源结果 |
| [BUG-1233](bugs/BUG-1233-book-import-repeated-archive-probe.md) | ✅ | ✅ | 书籍导入重复整包判定 EPUB 载体 |
| [BUG-1232](bugs/BUG-1232-mihon-sidecar-exit-leak.md) | ✅ | ✅ | 桌面关闭后 Mihon Java sidecar 残留 |
| [BUG-1231](bugs/BUG-1231-cross-chapter-search-locate-race.md) | ✅ | ✅ | 跨章节书内搜索只跳到章首且不高亮 |
| [BUG-1230](bugs/BUG-1230-manga-popup-ocr-direction.md) | ✅ | ✅ | 漫画查词弹窗未按 OCR 文字方向避让 |
| [BUG-1229](bugs/BUG-1229-dictionary-css-draft.md) | ✅ | ✅ | 自定义 CSS 遮罩退出丢失草稿且关闭即保存 |
| [BUG-1228](bugs/BUG-1228-video-mining-queue.md) | ✅ | ✅ | 连续视频制卡未串行且换集可能污染在途任务 |
| [BUG-1227](bugs/BUG-1227-anki-media-upload-orphan.md) | ✅ | ✅ | 大 GIF 上传超时被吞后仍创建无图卡并留下孤儿媒体 |
| [BUG-1226](bugs/BUG-1226-anki-mining-ui-thread-stall.md) | ✅ | ✅ | 制卡前查重导致 Anki 未响应 |
| [BUG-1225](bugs/BUG-1225-shm-reader-write-access-must-stay.md) | ✅ | ✅ | 读端共享内存写权限不可收紧：SelectTextThread 的原子写落在只读页上会崩 |
| [BUG-1224](bugs/BUG-1224-video-desktop-seekbar-click-stolen-by-subtitle.md) | ✅ | ✅ | 桌面视频点进度条被字幕吸走成查词 |
| [BUG-1221](bugs/BUG-1221-manga-path-case-folded.md) | ✅ | ✅ | 漫画页图解析把路径折成小写，制卡封面名被小写化且大小写敏感平台缺页 |
| [BUG-1220](bugs/BUG-1220-bangumi-sync-invisible.md) | ✅ | ✅ | Bangumi 同步链路全静默：看完了没反应且无处查看 |
| [BUG-1219](bugs/BUG-1219-scrape-failure-detail.md) | ✅ | ✅ | 封面刮削失败只给一句笼统提示，完整报错被吞到错误日志 |
| [BUG-1218](bugs/BUG-1218-epub-path-case-folded-android.md) | ✅ | ✅ | EPUB 解析把路径折成小写，大小写敏感平台上整本章节静默失踪 |
| [BUG-1217](bugs/BUG-1217-magpie-bundle-slim-offline.md) | ✅ | ✅ | 随主包发行精简版 Magpie，超分首次使用不再下载 |
| [BUG-1216](bugs/BUG-1216-gal-shm-open-unclassified.md) | ✅ | ✅ | 共享内存打不开被压成一句「请重启 Hibiki」，真实原因（拒绝访问/版本不符/映射不存在）在 native 返回值处丢弃 |
| [BUG-1215](bugs/BUG-1215-jimaku-entry-wrong-season-auto-select.md) | ✅ | ✅ | Jimaku 条目自动选中不校验季号，S1 条目被配给 S2 包 |
| [BUG-1214](bugs/BUG-1214-waveform-align-wheel-hscroll.md) | ✅ | ✅ | 波形对轴放大视图鼠标滚轮不能左右平移时间轴 |
| [BUG-1213](bugs/BUG-1213-android-legacy-storage-permission-query.md) | ✅ | ✅ | Android 7~10 上查询侧恒判未授权，用户根本加不了本地扫描根 |
| [BUG-1212](bugs/BUG-1212-manga-stats-guard-stale.md) | ✅ | ✅ | 漫画统计守卫仍钉旧口径 charsRead: 0，PR#504 后 develop 变红 |
| [BUG-1211](bugs/BUG-1211-collection-cover-writes-members.md) | ✅ | ✅ | 合集「在线匹配封面」把封面写进全部成员而不是改合集自己的封面 |
| [BUG-1210](bugs/BUG-1210-clipboard-panel-no-auto-read.md) | ✅ | ✅ | 剪贴板面板查词不自动朗读而浮窗会开关却是全局的 |
| [BUG-1209](bugs/BUG-1209-folder-picker-requests-camera-permission.md) | ✅ | ✅ | 安卓选文件夹时顺带弹相机权限申请 |
| [BUG-1208](bugs/BUG-1208-ps51-getrelativepath-build-dist.md) | ✅ | ✅ | helper 打包脚本用 .NET Core-only 的 GetRelativePath，CI 的 PowerShell 5.1 直接崩 |
| [BUG-1207](bugs/BUG-1207-android-embedded-torrent-dead-setting.md) | ✅ | ✅ | 安卓下载设置能选「内置引擎」并改下载目录，实际静默回退外接 qBittorrent |
| [BUG-1206](bugs/BUG-1206-jimaku-season-pack-wrong-season-match.md) | ✅ | ✅ | 整季包字幕按标题猜集号导致错季配对且条数无上界 |
| [BUG-1205](bugs/BUG-1205-video-mining-cover-audio-serial.md) | ✅ | ✅ | 视频制卡封面与句子音频串行且失败来源靠调用顺序区分 |
| [BUG-1204](bugs/BUG-1204-lookup-audio-play-failure-reason-swallowed.md) | ✅ | ✅ | 浮窗单词发音首播失败且失败原因被吞无法定位 |
| [BUG-1203](bugs/BUG-1203-epub-opf-mediatype-html-classification.md) | ✅ | ✅ | EPUB 内容文档按扩展名分类导致怪扩展名章节整本渲染空白 |
| [BUG-1202](bugs/BUG-1202-remote-library-cache-source-crosstalk.md) | ✅ | ✅ | 互联与云盘共用远端清单缓存槽，换来源后看到上一个来源的条目 |
| [BUG-1201](bugs/BUG-1201-sasasa-unity-resource-pcm-not-published.md) | ✅ | ✅ | Sasasa Unity 资源音频已解码但未写入音频环 |
| [BUG-1200](bugs/BUG-1200-sasasa-unity-textmesh-glyphs.md) | ✅ | ✅ | Sasasa Unity TextMesh 对白被拆成单字 |
| [BUG-1199](bugs/BUG-1199-epub-htm-mime-blank.md) | ✅ | ✅ | EPUB 章节用 .htm 扩展名时整本渲染空白（MIME 表缺 htm/xht） |
| [BUG-1196](bugs/BUG-1196-galgame-helper-drop-network-download.md) | ✅ | ✅ | 删除 helper 网络下载与后台自更新，只保留随主包归档 |
| [BUG-1195](bugs/BUG-1195-vn-blank-tap-blocks-chrome.md) | ✅ | ✅ | 视觉小说模式点空白只翻页，控制栏（菜单）永远唤不出 |
| [BUG-1194](bugs/BUG-1194-collection-reorder-nonvideo-order.md) | ✅ | ✅ | 视频合集详情页拖拽排序打乱非 video 成员的跨种类顺序 |
| [BUG-1193](bugs/BUG-1193-galgame-luna-nonwinner-threads-dropped.md) | ✅ | ✅ | primed 后非赢家 hook 线程被 native 丢弃，无法像 LunaTranslator 那样切换 |
| [BUG-1192](bugs/BUG-1192-galgame-steam-drm-load-error.md) | 🚧 | 🚧 | Steam 游戏直接启动撞 DRM 报 Application load error 3 |
| [BUG-1191](bugs/BUG-1191-galgame-upscaling-per-game.md) | ✅ | ✅ | 窗口超分改为每游戏一档，入口挪进游戏卡右键菜单 |
| [BUG-1190](bugs/BUG-1190-jimaku-title-dropdown-no-research.md) | ✅ | ✅ | 换番剧名后字幕来源不刷新 |
| [BUG-1189](bugs/BUG-1189-season-pack-jimaku-subs-empty.md) | ✅ | ✅ | 整季包种子拿不到任何 Jimaku 字幕 |
| [BUG-1188](bugs/BUG-1188-dataroot-pick-layout-split.md) | ✅ | ✅ | 选目录迁移产出第三种布局，到不了新装形态（DB 被拖进文档目录） |
| [BUG-1187](bugs/BUG-1187-gal-unvoiced-line-gets-bgm.md) | ✅ | ✅ | galgame 无配音句被整机混音兜底成 BGM |
| [BUG-1186](bugs/BUG-1186-appbar-actions-collapse-uses-window-width.md) | ✅ | ✅ | AppBar 动作折叠判据读整窗宽，分栏/受限宽容器里永不折叠 |
| [BUG-1185](bugs/BUG-1185-remote-mining-duplicate-auth-swallowed.md) | ✅ | ✅ | 远端制卡查重吞掉认证失败，静默答「不重复」 |
| [BUG-1184](bugs/BUG-1184-narrow-screen-segmented-clipped.md) | ✅ | ✅ | 窄屏/小窗口下多处内容显示不全（说明文字、分段控件、书名、对话框标题） |
| [BUG-1183](bugs/BUG-1183-restore-auth-invalidates-session.md) | ✅ | ✅ | restoreAuth 无条件作废已解析地址，每次切页面重跑全候选探测 |
| [BUG-1182](bugs/BUG-1182-show-remote-entries-gate-too-late.md) | ✅ | ✅ | 关闭「显示远端条目」仍全额拉取远端列表后丢弃 |
| [BUG-1181](bugs/BUG-1181-manga-shelf-fetches-remote-books.md) | ✅ | ✅ | 漫画书架实例误拉远端书，切到书架触发双倍网络 |
| [BUG-1180](bugs/BUG-1180-interconnect-remote-list-no-cache.md) | ✅ | ✅ | 互联远端库列表零缓存，每次切页面全额重拉 |
| [BUG-1179](bugs/BUG-1179-updater-diagnostics-before-validation.md) | ✅ | ✅ | Windows 更新器在校验安装包前就全机枚举进程，坏包也要等十几秒 |
| [BUG-1178](bugs/BUG-1178-manifest-race-test-cascade.md) | ✅ | ✅ | update-manifest 竞态测试超时会级联带红兄弟用例 |
| [BUG-1177](bugs/BUG-1177-ankimobile-end-task-timing.md) | ✅ | ✅ | AnkiMobile 制卡测试用 10ms 定时假设等真实 I/O，36% 概率红 |
| [BUG-1176](bugs/BUG-1176-cover-scrape-silent-catch.md) | ✅ | ✅ | 封面刮削/匹配失败被静默吞掉，用户只看到「无结果」 |
| [BUG-1175](bugs/BUG-1175-gal-embedkrkrz-ruby-repeat-text.md) | ✅ | ✅ | EmbedKrkrZ ruby 双写产生重复台词，折叠只认精确二倍全部漏过 |
| [BUG-1174](bugs/BUG-1174-docroot-migrator-path-gaps.md) | ✅ | ✅ | 数据根迁移漏改 6 处路径 + 非幂等 + 无事务 |
| [BUG-1173](bugs/BUG-1173-manga-ocr-cache-model-identity.md) | ✅ | ✅ | 漫画本地 OCR 缓存不含模型身份 |
| [BUG-1172](bugs/BUG-1172-manga-lens-rotated-hit-aspect.md) | ✅ | ✅ | 漫画 Lens 旋转命中区在非方形页上算错 |
| [BUG-1171](bugs/BUG-1171-manga-reader-progress-after-dispose.md) | ✅ | ✅ | 漫画阅读器销毁后仍写页码通知器并挂 10 秒 |
| [BUG-1170](bugs/BUG-1170-manga-window-ready-stale-generation.md) | ✅ | ✅ | 漫画窗口 ready 锁被迟到旧回调解除 |
| [BUG-1169](bugs/BUG-1169-gal-launch-failed-reason-release-assert.md) | ✅ | ✅ | release 剥离 assert 后 failed(none) 被判成启动成功 |
| [BUG-1168](bugs/BUG-1168-post-frame-focus-reclaim-never-fires-on-idle-tree.md) | ✅ | ✅ | 静止树上 addPostFrameCallback 焦点回收永不触发（进出全屏/关字幕遮罩后快捷键失灵） |
| [BUG-1167](bugs/BUG-1167-video-subtitle-align-dialog-focus-not-returned.md) | ✅ | ✅ | 视频字幕波形对轴弹窗关闭后不归还键盘焦点 |
| [BUG-1166](bugs/BUG-1166-gal-lookup-wheel-passthrough-to-game.md) | ✅ | ✅ | galgame 查词卡滚轮穿透到游戏 |
| [BUG-1165](bugs/BUG-1165-gal-track-panel-silent-predicate.md) | ✅ | ✅ | 音轨面板静音判据用错字段，空白轨从不置灰 |
| [BUG-1164](bugs/BUG-1164-manga-module-orphan-i18n-and-shelf-naming.md) | ✅ | ✅ | 漫画模块化重构遗留孤儿 i18n key 与 shelf 页面名违规 |
| [BUG-1163](bugs/BUG-1163-manga-ocr-silent-provider-fallback.md) | ✅ | ✅ | 漫画 OCR GPU 加速降级到 CPU 完全静默 |
| [BUG-1162](bugs/BUG-1162-torrent-pipeline-disk-flush-race.md) | ✅ | ✅ | hibiki_torrent 端到端测试在字节落盘前就比对，CI Windows 约 24% 概率红 |
| [BUG-1161](bugs/BUG-1161-subtitle-ruby-strip.md) | ✅ | ✅ | 字幕 <rt> 注音被拼进正文，污染查词/制卡 sentence/字数统计 |
| [BUG-1160](bugs/BUG-1160-gal-card-cover-gif-only.md) | ✅ | ✅ | galgame 制卡封面只能 GIF，不能选静态截图 |
| [BUG-1159](bugs/BUG-1159-gal-textthread-ctx-strict-match.md) | ✅ | ✅ | 文本线程记忆按 ctx 严格匹配掐断文本流，连带语音资源配对失败降级 |
| [BUG-1157](bugs/BUG-1157-test-runner-zero-test-false-green.md) | ✅ | ✅ | 全量测试入口把「零测试执行」当成通过（native asset 构建失败被伪装成绿） |
| [BUG-1156](bugs/BUG-1156-manga-spread-cropped-janky.md) | ✅ | ✅ | 漫画双页图片裁切且翻页卡顿 |
| [BUG-1155](bugs/BUG-1155-manga-popup-pagination-focus.md) | ✅ | ✅ | 漫画查词弹窗吞掉滚轮和左右翻页 |
| [BUG-1154](bugs/BUG-1154-manga-page-jump-controller-lifecycle.md) | ✅ | ✅ | 漫画页码跳转关闭弹窗后红屏 |
| [BUG-1153](bugs/BUG-1153-manga-window-generation-stale-page.md) | ✅ | ✅ | 漫画页码已翻但 WebView 仍显示旧页面 |
| [BUG-1152](bugs/BUG-1152-manga-lens-top-left-rotated-hit-regions.md) | ✅ | ✅ | 漫画 Lens OCR 坐标上下镜像且旋转文字点词错位 |
| [BUG-1151](bugs/BUG-1151-manga-incremental-ocr-cache-recovery.md) | ✅ | ✅ | 漫画增量 OCR 缓存重开后未恢复 |
| [BUG-1150](bugs/BUG-1150-manga-ocr-onnx-input-contract.md) | ✅ | ✅ | 漫画 OCR 按 ONNX 元数据适配单输入模型名称 |
| [BUG-1149](bugs/BUG-1149-windows-manga-ocr-falls-back-from-unsupported-directml-provider.md) | ✅ | ✅ | Windows 漫画本地 OCR 不支持 DirectML 时未回退 CPU |
| [BUG-1148](bugs/BUG-1148-manga-ocr-character-hit-zoom.md) | ✅ | ✅ | 漫画 OCR 横竖排字符在缩放后查词偏移 |
| [BUG-1147](bugs/BUG-1147-manga-ocr-coordinate-cache.md) | ✅ | ✅ | 漫画 OCR 查词坐标偏移且重启重复识别 |
| [BUG-1146](bugs/BUG-1146-manga-ocr-blocks-reader.md) | ✅ | ✅ | 漫画 OCR 模态阻塞阅读且完成页不能立即查词 |
| [BUG-1145](bugs/BUG-1145-clipboard-history-never-captured.md) | ✅ | ✅ | 桌面剪贴板复制历史永远为空（采集回调从未触发） |
| [BUG-1144](bugs/BUG-1144-manga-dense-ocr-black-screen.md) | ✅ | ✅ | 漫画全卷 OCR 后密集命中层导致阅读器黑屏 |
| [BUG-1143](bugs/BUG-1143-manga-high-frequency-turn-queue.md) | ✅ | ✅ | 漫画高频翻页跨窗口时丢失输入 |
| [BUG-1142](bugs/BUG-1142-gal-launch-failure-unclassified.md) | ✅ | ✅ | gal 启动失败只报无信息兜底文案，失败原因在 launchGame 的 bool 返回值处被丢弃 |
| [BUG-1141](bugs/BUG-1141-download-discovery-timeout-too-short.md) | ✅ | ✅ | 代理下「发现」搜索 20s 超时太短，请求本可成功却被掐断 |
| [BUG-1140](bugs/BUG-1140-cross-chapter-turn-latency.md) | ✅ | ✅ | 跨章翻页耗时实测与提速（遮罩口径） |
| [BUG-1139](bugs/BUG-1139-overlay-ctrl-wheel-zoom.md) | ✅ | ✅ | app 外查词浮窗 Ctrl+滚轮触发 WebView2 原生页面缩放，窗口/region 几何按 zoom=1 计算导致卡片被切、露出底下应用 |
| [BUG-1138](bugs/BUG-1138-gal-clipboard-overlay-ruby-markup.md) | ✅ | ✅ | gal 台词浮窗/剪切板文字窗把注音标记当正文显示，污染查词与字数 |
| [BUG-1137](bugs/BUG-1137-gal-mining-video-tag.md) | ✅ | ✅ | gal 制卡分类标签误标 video：来源枚举缺 game 且默认值静默兜底 |
| [BUG-1136](bugs/BUG-1136-ios-reader-scroll-lookup.md) | ✅ | ✅ | iPhone 阅读滑动被误判为点词查词 |
| [BUG-1135](bugs/BUG-1135-gal-clipnear-bypasses-track-exclusion.md) | ✅ | ✅ | gal 制卡兜底 grabClipNear 绕过选轨/排除集——排除的 BGM 轨会从兜底混回卡片 |
| [BUG-1134](bugs/BUG-1134-gal-line-track-preview-timestamp.md) | ✅ | ✅ | 逐句选轨试听与确认使用了不同台词时间戳 |
| [BUG-1133](bugs/BUG-1133-gal-capture-parallel-text-duplicate.md) | ✅ | ✅ | 全部文本线程把同一台词显示两遍 |
| [BUG-1132](bugs/BUG-1132-gal-capture-stale-text-thread.md) | ✅ | ✅ | 捕获工作台混入上次进程的 TextRender 文本线程 |
| [BUG-1131](bugs/BUG-1131-book-tracking-status-semantics.md) | ✅ | ✅ | Bangumi 小说/漫画阅读进度未按语义切换在读与读过 |
| [BUG-1130](bugs/BUG-1130-bangumi-watched-progress-stays-wish.md) | ✅ | ✅ | Bangumi 已有想看收藏在记录进度后未切换为在看 |
| [BUG-1129](bugs/BUG-1129-gal-textthread-list-luna-parity.md) | ✅ | ✅ | 文本线程列表对齐 Luna 选择文本：预览折叠/排序/重名消歧 + TextRender 0 行 |
| [BUG-1128](bugs/BUG-1128-gal-workbench-bgm-when-no-voice.md) | ✅ | ✅ | 无语音台词误配 BGM：捕获工作台补排除音轨入口 |
| [BUG-1127](bugs/BUG-1127-external-lookup-autoread-slow-swallowed.md) | ✅ | ✅ | app 外查词自动发音走 libmpv 慢路径且失败被静默吞掉 |
| [BUG-1126](bugs/BUG-1126-video-episode-panel-missing-covers.md) | ✅ | ✅ | 视频剧集侧栏只传标题导致本地与互联封面全部丢失 |
| [BUG-1125](bugs/BUG-1125-home-video-sanitize-missing-backslash.md) | ✅ | ✅ | home-video-sanitize-missing-backslash |
| [BUG-1124](bugs/BUG-1124-local-audio-cache-weak-hash.md) | ✅ | ✅ | local-audio-cache-weak-hash |
| [BUG-1123](bugs/BUG-1123-video-error-copy-says-bookshelf.md) | ✅ | ✅ | video-error-copy-says-bookshelf |
| [BUG-1122](bugs/BUG-1122-sync-webp-octet-stream.md) | ✅ | ✅ | sync-webp-octet-stream |
| [BUG-1121](bugs/BUG-1121-bmp-manga-ocr-skipped.md) | ✅ | ✅ | bmp-manga-ocr-skipped |
| [BUG-1120](bugs/BUG-1120-favorite-sentence-kind-downcast.md) | ✅ | ✅ | favorite-sentence-kind-downcast |
| [BUG-1119](bugs/BUG-1119-remote-continue-kind-downcast.md) | ✅ | ✅ | remote-continue-kind-downcast |
| [BUG-1118](bugs/BUG-1118-scrape-cover-cache-not-evicted.md) | ✅ | ✅ | scrape-cover-cache-not-evicted |
| [BUG-1117](bugs/BUG-1117-video-import-swallowed-errors.md) | ✅ | ✅ | 视频导入四方法 try/finally 无 catch：异常静默逃逸，用户只见 spinner 停住 |
| [BUG-1116](bugs/BUG-1116-reader-settings-prefcodec-one-way.md) | ✅ | ✅ | reader-settings-prefcodec-one-way |
| [BUG-1115](bugs/BUG-1115-default-documents-root-flat.md) | ✅ | ✅ | 默认数据根时 16 个 Hibiki 目录直接摊在用户文档根下 |
| [BUG-1114](bugs/BUG-1114-local-rig-rate-limit-flake.md) | 🚧 | 🚧 | 内置引擎本地 rig 测试：限速对 loopback peer 不生效导致 peer 观察窗口消失（flaky） |
| [BUG-1113](bugs/BUG-1113-galgame-no-tags.md) | ✅ | ✅ | 游戏没有标签：schema 缺 GalgameTagMappings 表 |
| [BUG-1112](bugs/BUG-1112-activity-timeline-game-no-cover.md) | ✅ | ✅ | 活动时间轴游戏条目只有图标没有封面 |
| [BUG-1111](bugs/BUG-1111-dashboard-continue-recent-missing-games.md) | ✅ | ✅ | 首页继续与最近添加装不下游戏：_ContinueEntry 用 isVideo 二元标志 |
| [BUG-1110](bugs/BUG-1110-narrow-screen-hides-degrade-reason.md) | ✅ | ✅ | 捕获工作台窄屏时藏掉降级原因，只留一个「已降级」徽章 |
| [BUG-1109](bugs/BUG-1109-gal-mining-audio-truncated-tail.md) | ✅ | ✅ | galgame 制卡音频尾部被截断：引擎 PCM 首取即冻结 + 资源 dump 写完前就转码 |
| [BUG-1108](bugs/BUG-1108-shelf-continue-hero-raw-title.md) | ✅ | ✅ | 改名后书架继续阅读条仍显示旧名 |
| [BUG-1107](bugs/BUG-1107-reading-stats-phantom-chars-lost-duration.md) | ✅ | ✅ | 阅读统计速度爆表：幻象字数+纯时长行被拒 |
| [BUG-1106](bugs/BUG-1106-desktop-settings-smoke-focus-gate-broken.md) | ✅ | ✅ | `desktop_settings_smoke_test.dart`（Windows 离屏 itest 默认门）在全新 profile 上必红 |
| [BUG-1105](bugs/BUG-1105-inapp-popup-webview2-status-bar-url.md) | ✅ | ✅ | app 内查词弹窗仍会冒 WebView2 链接地址预览（BUG-1097 只修了一半） |
| [BUG-1104](bugs/BUG-1104-lookup-overlay-webview2-dpi-inconsistent.md) | ✅ | ✅ | 查词浮窗两条 WebView2 创建路径的 DPI 处理不一致（且无 WM_DPICHANGED） |
| [BUG-1103](bugs/BUG-1103-helper-supply-chain.md) | ✅ | ✅ | galgame helper 安装器：sha256 侧车拉不到就不校验照装 + 侧车与产物同源第三方镜像（注入器/hook DLL 供应链后门） |
| [BUG-1102](bugs/BUG-1102-gal-audio-track-panel-dead-controls.md) | ✅ | ✅ | 兼容性诊断页「活跃音轨」面板全无效：选轨/排除点了没反应，空轨照样占位 |
| [BUG-1101](bugs/BUG-1101-gal-loopback-line-audio-off-by-one.md) | ✅ | ✅ | 降级到系统 Loopback 时逐行语音永远配到上一句 |
| [BUG-1100](bugs/BUG-1100-gal-degrade-unrecoverable-engine-pcm.md) | ✅ | ✅ | galgame 刚启动就误报「降级运行 · engine_pcm_unavailable」，且永远回不到引擎 PCM |
| [BUG-1099](bugs/BUG-1099-passive-clipboard-stream-clobbers-lookup.md) | ✅ | ✅ | 查完词后剪贴板一更新，浮窗释义就被清空「缩回去」 |
| [BUG-1098](bugs/BUG-1098-popup-headword-furigana-clipped.md) | ✅ | ✅ | 查词弹窗词头的假名（furigana）被垂直压扁 / 裁掉 |
| [BUG-1097](bugs/BUG-1097-lookup-overlay-webview2-status-bar-url.md) | ✅ | ✅ | 查词浮窗左下角冒出 `https://hibiki.popup/popup.html?query=…&wildcards=off` |
| [BUG-1096](bugs/BUG-1096-window-capture-two-mouse-cursors.md) | ✅ | ✅ | 画面捕获出现两个鼠标指针 |
| [BUG-1095](bugs/BUG-1095-gal-overlay-font-size-coupled-to-window-height.md) | ✅ | ✅ | galgame 台词浮窗拖动窗口时字号跟着变，「放不下」怎么拖都放不下 |
| [BUG-1094](bugs/BUG-1094-gal-manual-recapture-fixed-8s.md) | ✅ | ✅ | 手动录音 ⏺ 固定 8 秒自动关闭，且回取长度被同一个错误常量夹住 |
| [BUG-1093](bugs/BUG-1093-first-lookup-audio-missing.md) | ✅ | ✅ | 第一次查词音频容易没有：WebView autoplay 拦截+兜底失效 |
| [BUG-1092](bugs/BUG-1092-gal-locale-resume-skipped.md) | ✅ | ✅ | galgame 启动后留下永久挂起的僵尸进程：窗口永不出现，injector 却报 OK hooked |
| [BUG-1091](bugs/BUG-1091-gal-injector-diagnostics-mojibake.md) | ✅ | ✅ | injector 诊断按系统代码页解码：会话事件乱码且中文失败分类永久失配 |
| [BUG-1090](bugs/BUG-1090-audio-source-url-not-editable.md) | ✅ | ✅ | 管理音频来源弹窗里已有远端 URL 无法编辑，只能删了重加 |
| [BUG-1089](bugs/BUG-1089-gal-launch-silent-no-feedback.md) | ✅ | ✅ | 点启动游戏无任何提示：注入降级/窗口未出现都静默走成功路径 |
| [BUG-1088](bugs/BUG-1088-sync-host-hides-cloud-upload-and-interconnect-backend.md) | ✅ | ✅ | host 模式误藏云备份上传开关，互联从同步方式消失且无入口 |
| [BUG-1087](bugs/BUG-1087-jimaku-episode-label-truncated.md) | ✅ | ✅ | 番剧下载确认页集号输入框在界面缩放下 label 截断成「集…」 |
| [BUG-1086](bugs/BUG-1086-nyaa-search-error-swallowed.md) | ✅ | ✅ | Nyaa 搜索网络错误被吞成统一文案，真实报错不可见（生肉分类超时无从定位） |
| [BUG-1085](bugs/BUG-1085-gal-charcount-inflated.md) | ✅ | ✅ | galgame 字数统计虚高：标点全算/重复行重计/递增重发重计/外部通道双计 |
| [BUG-1084](bugs/BUG-1084-torrent-settings-field-full-width.md) | ✅ | ✅ | 下载设置输入框在宽屏详情面板被拉满整宽 |
| [BUG-1083](bugs/BUG-1083-manga-author-edit-missing.md) | ✅ | ✅ | 漫画编辑对话框缺作者字段(未覆盖supportsAuthorEdit) |
| [BUG-1082](bugs/BUG-1082-scrape-poster-lowres.md) | ✅ | ✅ | TMDB刮削海报w500缩略图发糊非满分辨率 |
| [BUG-1081](bugs/BUG-1081-poster-use-no-feedback.md) | ✅ | ✅ | 海报匹配弹窗点使用没反应无进度反馈 |
| [BUG-1080](bugs/BUG-1080-poster-match-cm-rank.md) | ✅ | ✅ | 视频海报离线匹配把联动CM排到正片前 |
| [BUG-1079](bugs/BUG-1079-extension-update-silent-stale.md) | ✅ | ✅ | 扩展自更新失败永久静默无重试且无任何更新提示 |
| [BUG-1078](bugs/BUG-1078-extension-passive-wheel-scroll-drag.md) | ✅ | ✅ | 扩展在所有网页常驻非passive wheel监听拖慢浏览器滚动 |
| [BUG-1077](bugs/BUG-1077-nested-lookup-mouse-hook-starvation.md) | ✅ | ✅ | 嵌套查词瞬间全局鼠标卡顿：钩子线程无优先级+嵌套路径卸装钩子churn |
| [BUG-1076](bugs/BUG-1076-galgame-helper-update-tied-to-launch.md) | ✅ | ✅ | galgame helper 自动更新绑死游戏启动时刻且 6s 硬超时弱网永远静默放弃 |
| [BUG-1075](bugs/BUG-1075-daily-goal-no-unit-no-hint.md) | ✅ | ✅ | 每日目标弹窗无单位无口径说明 |
| [BUG-1074](bugs/BUG-1074-cover-update-button-windows-noop.md) | ✅ | ✅ | 书籍编辑封面更新按钮Windows无反应 |
| [BUG-1073](bugs/BUG-1073-dashboard-layout-imbalance.md) | ✅ | ✅ | 首页dashboard排版失衡热力图大片空白 |
| [BUG-1072](bugs/BUG-1072-profile-snapshot-credential-leak.md) | ✅ | ✅ | 备份/Profile 分享泄漏凭据：判定散落三处且兜底锁死 sync_ 前缀，profile_settings 通道无判定 |
| [BUG-1071](bugs/BUG-1071-dismiss-dictionary-mouse-and-keyboard-fails.md) | ✅ | ✅ | 关闭词典鼠标键失效+键盘经常失效(弹窗无Flutter焦点) |
| [BUG-1070](bugs/BUG-1070-galgame-overlay-lyric-spills-into-control-band.md) | ✅ | ✅ | galgame浮窗台词溢出到顶部控制条按钮带遮住UI |
| [BUG-1069](bugs/BUG-1069-video-top-subtitle-covers-chrome.md) | ✅ | ✅ | 视频顶部字幕盖住标题栏和菜单UI |
| [BUG-1068](bugs/BUG-1068-subtitle-blur-reveal-latched-after-gap.md) | ✅ | ✅ | 字幕听力沉浸模糊在字幕间隙后锁死显形不再变模糊 |
| [BUG-1067](bugs/BUG-1067-favorite-video-jump-loses-track-memory.md) | ✅ | ✅ | 收藏句子跳视频丢失系列音轨/字幕调轴记忆 |
| [BUG-1066](bugs/BUG-1066-gal-hook-launch-degrade.md) | ✅ | ✅ | 已支持游戏总是启动失败或音频降级到整机混音 |
| [BUG-1065](bugs/BUG-1065-inapp-wheel-dpr-parity.md) | ✅ | ✅ | app 内查词弹窗滚轮比 app 外慢 1/dpr（native sendScroll 未还原 DPR） |
| [BUG-1064](bugs/BUG-1064-external-mined-card-action-dead.md) | ✅ | ✅ | app 外查词浮窗点已制卡 ✓ 无反应（重复卡操作面板被 native 降级成 null） |
| [BUG-1063](bugs/BUG-1063-gal-hook-line-display-latency.md) | ✅ | ✅ | galgame hook 台词显示慢：文本推进被逐行语音抓取阻塞 |
| [BUG-1062](bugs/BUG-1062-anki-glossary-image-size-vs-yomitan.md) | ✅ | ✅ | 制卡词典图片比 Yomitan 卡片小很多（导出把 em 折算成物理 px） |
| [BUG-1061](bugs/BUG-1061-anki-glossary-label-extra-index.md) | ✅ | ✅ | 制卡 {glossary} 词典名前多出自造序号「1」 |
| [BUG-1060](bugs/BUG-1060-gal-loopback-engine-pcm-cache.md) | ✅ | ✅ | Loopback 制卡误用引擎 PCM 碎片导致音频异常 |
| [BUG-1059](bugs/BUG-1059-galgame-x86-helper.md) | ✅ | ✅ | 残缺的 x86 galgame helper 被当成已安装，自动转区失效 |
| [BUG-1058](bugs/BUG-1058-ffmpeg-min-vendored-missing-movtext.md) | ✅ | ✅ | 入库精简 ffmpeg 缺 movtext 编码器，桌面片段导出永远封不进字幕 |
| [BUG-1057](bugs/BUG-1057-danmaku-comment-fetch-timeout-and-swallowed-status.md) | ✅ | ✅ | 手动匹配弹幕「弹幕加载失败」：拉弹幕与搜索共用 8s 超时，且非 2xx 被吞成空列表 |
| [BUG-1056](bugs/BUG-1056-jimaku-source-subscription.md) | ✅ | ✅ | 字幕来源不可选且连载订阅无法绑定合集字幕 |
| [BUG-1055](bugs/BUG-1055-anilist-segmented-title.md) | ✅ | ✅ | AniList 罗马字分词差异导致番剧误报无结果 |
| [BUG-1054](bugs/BUG-1054-download-discovery-proxy.md) | ✅ | ✅ | 下载发现未读取环境与系统代理导致搜索超时 |
| [BUG-1053](bugs/BUG-1053-embedded-torrent-dht-always-on.md) | ✅ | ✅ | 空闲也常驻 libtorrent/DHT（6881），整机网络周期性高延迟 |
| [BUG-1052](bugs/BUG-1052-reading-time-lost-session-clock-reanchor.md) | ✅ | ✅ | 阅读时长被会话时钟重锚吃掉，速度/统计爆表（今日 0 分钟 / 125666 字·时⁻¹） |
| [BUG-1051](bugs/BUG-1051-series-audio-subtitle-memory-lost.md) | ✅ | ✅ | 同系列音轨选择与字幕调轴记忆丢失（统一合集迁移回归） |
| [BUG-1050](bugs/BUG-1050-video-mine-word-audio-datauri-dropped.md) | ✅ | ✅ | 视频/沉浸制卡本地源单词发音被当 data: URI 丢弃 |
| [BUG-1049](bugs/BUG-1049-gal-hook-window-autobind-late.md) | ✅ | ✅ | 捕获目标没有自动选中 Hibiki 启动的游戏（窗口迟到即永久停在 window_not_found） |
| [BUG-1048](bugs/BUG-1048-galgame-lookup-mouse-hook-lag.md) | ✅ | ✅ | galgame 查词后鼠标移动全局卡顿（WH_MOUSE_LL 装在 Flutter 主线程） |
| [BUG-1047](bugs/BUG-1047-ext-reload-orphans-content-script.md) | ✅ | ✅ | 扩展自更新reload孤立已开页content script需手动刷新 |
| [BUG-1046](bugs/BUG-1046-hook-overlay-transparent-hittest.md) | ✅ | ✅ | 隐藏背景后Hook文本浮窗点不动文字 |
| [BUG-1045](bugs/BUG-1045-ext-connection-heartbeat.md) | ✅ | ✅ | 扩展未连接:app内存last-seen无心跳+MV3 SW空闲回收 |
| [BUG-1044](bugs/BUG-1044-popup-auto-expand-rows-vs-columns.md) | ✅ | ✅ | 折叠词典「自动展开词典数」与「词典列数」冲突：绝对本数不随列数对齐致顶部参差 |
| [BUG-1043](bugs/BUG-1043-ios-smoke-update-dialog-steals-focus.md) | ✅ | ✅ | iOS冒烟测试焦点断言被启动期更新弹窗与恒真判定掩盖 |
| [BUG-1042](bugs/BUG-1042-ios-generated-xcconfig-tracked.md) | ✅ | ✅ | iOS Flutter 生成文件误入库导致 Mac 上 pod install 失败 |
| [BUG-1041](bugs/BUG-1041-global-lookup-card-corner-asymmetry.md) | ✅ | ✅ | 查词浮窗卡片左侧圆角右侧直角 |
| [BUG-1040](bugs/BUG-1040-mined-card-dialog-centered-and-above-popup.md) | ✅ | ✅ | 「卡片已在 Anki 中」是底部 sheet 且层级低于查词弹窗（被盖住看不见） |
| [BUG-1039](bugs/BUG-1039-native-tier-gif-explodes-mining.md) | ✅ | ✅ | 制卡「原片档」把 GIF 按源分辨率+源帧率导出 → 制卡/覆盖巨慢、Anki 无响应 |
| [BUG-1038](bugs/BUG-1038-galgame-auto-locale.md) | ✅ | ✅ | Hibiki 启动日文非 Unicode 游戏时界面乱码 |
| [BUG-1037](bugs/BUG-1037-steam-launch-duplicate-instance.md) | ✅ | ✅ | Steam 游戏启动并捕获触发重复实例且晚附着漏音频 |
| [BUG-1036](bugs/BUG-1036-extension-connection-reopen-stale.md) | ✅ | ✅ | 浏览器扩展重开后连接检测误报 API 未开启 |
| [BUG-1035](bugs/BUG-1035-glossary-first-ignores-selected-dict.md) | ✅ | ✅ | 长按选中词典对制卡无效：{glossary-first} 恒取第一本，Lapis 默认无字段消费 {selected-glossary} |
| [BUG-1034](bugs/BUG-1034-subtitle-row-extent-clip.md) | ✅ | ✅ | 视频字幕列表当前行末行文字被裁掉一半 |
| [BUG-1033](bugs/BUG-1033-popup-zoom-tooltip-misfire.md) | ✅ | ✅ | 嵌套查词弹出时 A- 的「缩小查词字号」tooltip 自动弹出遮挡正文 |
| [BUG-1032](bugs/BUG-1032-qb-webui-no-request-timeout.md) | ✅ | ✅ | qB WebUI 请求缺少超时 |
| [BUG-1031](bugs/BUG-1031-download-default-config-no-completion-poll.md) | ✅ | ✅ | 默认下载配置未传给完成轮询 |
| [BUG-1030](bugs/BUG-1030-extension-subtitle-panel-overlay.md) | ✅ | ✅ | 浏览器扩展字幕列表覆盖页面而非挤压画面 |
| [BUG-1029](bugs/BUG-1029-extension-subtitle-live-cumulative.md) | ✅ | ✅ | 浏览器扩展 YouTube 字幕列表逐字累积为重复行 |
| [BUG-1028](bugs/BUG-1028-texthooker-popup-cold-webview.md) | ✅ | ✅ | 捕获工作台查词弹窗每次冷建WebView加载缓慢 |
| [BUG-1027](bugs/BUG-1027-gal-diagnostics-audio-tracks-stale.md) | ✅ | ✅ | 兼容性诊断音轨快照不自动拉取且资源音频模式误报尚无数据 |
| [BUG-1026](bugs/BUG-1026-popup-wheel-speed-config.md) | ✅ | ✅ | 查词弹窗滚轮滚动慢，缺可配置速度项 |
| [BUG-1025](bugs/BUG-1025-clipboard-recopy-same-word-dedup.md) | ✅ | ✅ | 浏览器查词复制同一个词无法重复查（内容去重挡住手动重复复制） |
| [BUG-1024](bugs/BUG-1024-ext-shift-hover-pending-deadlock.md) | ✅ | ✅ | 浏览器扩展 Shift 悬停查词在途闸永久死锁致弹窗不敏感 |
| [BUG-1023](bugs/BUG-1023-drive-transient-408-not-retried.md) | ✅ | ✅ | Google Drive 瞬时故障(408/429/5xx)被判非重试整本skip |
| [BUG-1022](bugs/BUG-1022-galgame-helper-dialog-latency-and-restack.md) | ✅ | ✅ | galgame 引擎组件下载确认弹窗点击不立即出现且多次点击叠出多个弹窗 |
| [BUG-1021](bugs/BUG-1021-galgame-cardimage-alias-false-warning.md) | ✅ | ✅ | galgame 场景制卡误报缺少 {card-image}（旧别名瞎眼） |
| [BUG-1020](bugs/BUG-1020-clipboard-watcher-pref-flip-desync.md) | ✅ | ✅ | Windows剪贴板监听页内翻转开关后永久失效 |
| [BUG-1019](bugs/BUG-1019-profile-swallows-audiobook-progress.md) | ✅ | ✅ | profile 切换吞听书进度/倍速：进度型 pref 被快照/prune/回灌 |
| [BUG-1018](bugs/BUG-1018-rename-not-applied-everywhere.md) | ✅ | ✅ | 改名/改作者不生效：override title 消费面缺口 + 作者保存不刷新 + SRT 空 bookKey 互踩 + profile 吞 override |
| [BUG-1017](bugs/BUG-1017-reader-fixed-layout-svg-blank.md) | 🚧 | ✅ | 固定版式SVG竖排EPUB打开白屏·cloak被init同步异常卡住 |
| [BUG-1016](bugs/BUG-1016-webdav-anonymous-empty-credentials.md) | ✅ | ✅ | WebDAV/FTP 匿名同步：空用户名密码被硬拦 |
| [BUG-1015](bugs/BUG-1015-desktop-lookup-autoread-first-silent.md) | ✅ | ✅ | 桌面首次查词自动发音无声·media_kit播放器冷启动 |
| [BUG-1014](bugs/BUG-1014-win-update-desktop-icon-move.md) | ✅ | ✅ | Windows 更新后桌面快捷方式移位 |
| [BUG-1013](bugs/BUG-1013-external-window-attach-ready-race.md) | ✅ | ✅ | 外部窗口挖矿在helper就绪前打开共享内存导致降级 |
| [BUG-1012](bugs/BUG-1012-ext-shadow-dom-lookup.md) | ✅ | ✅ | 浏览器扩展无法读取Shadow DOM内文字(B站评论区) |
| [BUG-1011](bugs/BUG-1011-interconnect-video-collection-playlist-autoplay.md) | ✅ | ✅ | 互联视频合集列表缺失+无自动连播·客户端合集播放 |
| [BUG-1010](bugs/BUG-1010-video-controls-autohide-focus-loss.md) | 🚧 | 🚧 | 视频控制条自动隐藏后键盘焦点疑似丢失 |
| [BUG-1009](bugs/BUG-1009-collection-detail-focus-id-clash.md) | ✅ | ✅ | 合集详情页返回后书架同名卡手柄焦点不可达 |
| [BUG-1008](bugs/BUG-1008-shelf-tag-filter-contradictory-empty.md) | ✅ | ✅ | 标签筛选下 SRT 命中仍显示无匹配空态且丢失下拉刷新 |
| [BUG-1007](bugs/BUG-1007-texthooker-anki-health-hardcoded.md) | ✅ | ✅ | 游戏工作台健康卡 Anki 行恒显未配置 |
| [BUG-1006](bugs/BUG-1006-anime-download-embedded-pop.md) | 🚧 | 🚧 | 下载页内嵌推送成功后误 pop 宿主路由 |
| [BUG-1005](bugs/BUG-1005-mining-word-audio-remote-source.md) | ✅ | ✅ | 制卡缺单词音频·扩展needsAudio门+制卡器忽略远程发音源 |
| [BUG-1004](bugs/BUG-1004-interconnect-mining-audio-host-clip.md) | ✅ | ✅ | 互联视频制卡句子音频改 host 端裁绕开 client ffmpeg 抓远端流 |
| [BUG-1003](bugs/BUG-1003-download-kb-inset.md) | ✅ | ✅ | 下载页输入apikey时软键盘顶掉贴底下载任务区 |
| [BUG-1002](bugs/BUG-1002-jimaku-download-anilist-only-no-query-fallback.md) | ✅ | ✅ | 下载页字幕搜索仅按AniList id无文本回退致误报无字幕 |
| [BUG-1001](bugs/BUG-1001-lookup-panel-pin-block-off-faint-light.md) | ✅ | ✅ | 桌面查词浮窗顶栏图钉/防截屏关闭态浅色下太淡 |
| [BUG-1000](bugs/BUG-1000-floating-lyric-tap-dropped-stale-reader-handler.md) | ✅ | ✅ | 桌面悬浮字幕点词后台听书时静默丢弃(reader卸载后channel残留!mounted handler) |
| [BUG-999](bugs/BUG-999-lookup-slide-class-leak-invisible-cards.md) | ✅ | ✅ | app外查词第二张卡永远不可见——滑出class泄漏在复用根壳上 |
| [BUG-998](bugs/BUG-998-backup-audiobooks-untick-not-stripped.md) | ✅ | ✅ | 覆盖导入取消勾选有声书仍恢复幽灵有声书 |
| [BUG-997](bugs/BUG-997-video-import-uninvited-unskippable.md) | ✅ | ✅ | 覆盖导入视频强行进且无法取消勾选 |
| [BUG-996](bugs/BUG-996-remote-video-resume-and-subtitle-delay-sync.md) | ✅ | ✅ | 互联远端视频不续播(从头)+ 字幕调轴(delay)不同步 |
| [BUG-995](bugs/BUG-995-video-overview-hero-excludes-remote.md) | ✅ | ✅ | 视频页「继续观看」+「媒体库概览」在只有远端视频时不显示且不计入远端 |
| [BUG-994](bugs/BUG-994-video-auto-refresh-remote-on-tab-return.md) | ✅ | ✅ | 切回视频 tab 不自动拉远端视频(远端视频要手动下拉刷新才出来) |
| [BUG-992](bugs/BUG-992-shelf-auto-refresh-remote-on-tab-return.md) | ✅ | ✅ | 切回书架 tab 不自动拉远端书(远端书+书库概览总数要手动下拉刷新才补齐) |
| [BUG-991](bugs/BUG-991-shelf-overview-total-excludes-remote.md) | ✅ | ✅ | 书架「书库概览」总数漏算远端书(只数本地卡,不数书架上可见的互联远端占位卡) |
| [BUG-990](bugs/BUG-990-interconnect-audiobook-download-loading-gap.md) | ✅ | ✅ | 互联下载有声书两阶段之间露出「无转圈的普通书」(空窗期本地卡缺加载指示) |
| [BUG-989](bugs/BUG-989-interconnect-book-collection-count-remote.md) | ✅ | ✅ | 互联书籍合集行计数未计入远端占位书 |
| [BUG-988](bugs/BUG-988-interconnect-upload-toggles.md) | ✅ | ✅ | 互联解耦后失去「独立控制上不上传到互联对端」的能力 |
| [BUG-987](bugs/BUG-987-interconnect-pair-dialog-latch.md) | ✅ | ✅ | 互联首次配对失败后刷新不再弹申请框、只提示失败 |
| [BUG-973](bugs/BUG-973-macos-traffic-light-video-overlap.md) | ✅ | ✅ | macOS 交通灯遮挡视频退出按钮/左上角OSD |
| [BUG-972](bugs/BUG-972-popup-css-ctx-adjust-unclosed-brace.md) | ✅ | ✅ | popup.css .ctx-adjust-button 缺闭合括号吞掉 .global-lookup-ext-hit 高亮规则 |
| [BUG-971](bugs/BUG-971-ankiconnect-host-scheme.md) | ✅ | ✅ | AnkiConnect 主机字段吞掉 http:// 变成 http: |
| [BUG-970](bugs/BUG-970-reading-goal-first-set-no-entry.md) | ✅ | ✅ | 统计页每日/每周目标从未设置时无任何设置入口 |
| [BUG-969](bugs/BUG-969-reader-settings-sheet-120fps.md) | ✅ | ✅ | 阅读设置抽屉滚动与拖动跑不满120fps |
| [BUG-968](bugs/BUG-968-audiobook-export-text-audio.md) | ✅ | ✅ | 有声书片段导出文字与选区不符且移动端缺少音频 |
| [BUG-967](bugs/BUG-967-reader-context-menu-stack.md) | ✅ | ✅ | Windows 查词弹窗后右键菜单位于底层且重复累加 |
| [BUG-966](bugs/BUG-966-subtitle-list-mining-audio.md) | ✅ | ✅ | 字幕列表点词查词制卡音频截错句(锚到播放位置而非被点cue) |
| [BUG-965](bugs/BUG-965-longpress-speed-drag-jank.md) | ✅ | ✅ | 长按倍速拖动卡顿：每步全页 setState 掉帧 |
| [BUG-964](bugs/BUG-964-interconnect-video-subtitle-not-synced.md) | ✅ | ✅ | 互联视频live push不带外挂字幕 |
| [BUG-963](bugs/BUG-963-shelf-filter-collection-cover.md) | ✅ | ✅ | 筛选时合集内有声书成员丢封面 |
| [BUG-962](bugs/BUG-962-space-textfield-swallowed.md) | ✅ | ✅ | 文本框物理键盘空格被全局 DoNothingIntent 吞掉 |
| [BUG-961](bugs/BUG-961-voice-hook-helper-release-missing.md) | ✅ | ✅ | galgame voice hook helper 引擎组件下载 404（release 从未产出） |
| [BUG-960](bugs/BUG-960-textrender-thread-catalog.md) | ✅ | ✅ | 9nine 的 Luna 线程列表缺少 TextRender |
| [BUG-959](bugs/BUG-959-local-media-shelf-perf.md) | ✅ | ✅ | 本地视频/书籍页首屏慢：封面全分辨率解码+合集N+1查询+首帧同步stat |
| [BUG-958](bugs/BUG-958-gal-hook-ready-signal-late.md) | ✅ | ✅ | Galgame helper 已注入但 ready 信号过晚导致 engine_attach_failed |
| [BUG-957](bugs/BUG-957-galgame-dead-session-controller-leftover.md) | ✅ | ✅ | 旧 GalgameSessionController 死代码残留致查词面板 galgame 制卡出口失效 |
| [BUG-956](bugs/BUG-956-gal-mining-serial-queue-poisoning.md) | ✅ | ✅ | galgame 制卡串行队列异常毒化后所有后续制卡永久挂起 |
| [BUG-955](bugs/BUG-955-gal-mining-historical-line-media-mismatch.md) | ✅ | ✅ | 历史行制卡错配当前语音与当前画面且无降级标记 |
| [BUG-954](bugs/BUG-954-texthooker-mine-sentence-empty-non-windows.md) | ✅ | ✅ | 非外部窗口模式制卡 sentence 字段恒空 |
| [BUG-953](bugs/BUG-953-texthooker-popup-overlay-cross-tab-residue.md) | ✅ | ✅ | games tab 保活时查词弹窗与 barrier 跨 tab 残留遮挡 |
| [BUG-952](bugs/BUG-952-texthooker-thread-dropdown-value-mismatch.md) | ✅ | ✅ | texthooker 线程下拉 value 与动态 items 失配触发 debug 断言红屏 |
| [BUG-951](bugs/BUG-951-gal-overlay-click-through-cross-process.md) | 🚧 | 🚧 | Hook 浮窗鼠标穿透 HTTRANSPARENT 跨进程不生效存疑须真机验证 |
| [BUG-950](bugs/BUG-950-gal-hook-session-stale-line-bleed.md) | ✅ | ✅ | galgame hook 会话重启后旧行串入新会话且新文本被当重复静默丢弃 |
| [BUG-949](bugs/BUG-949-unity-resource-audio-extractor-stall.md) | ✅ | ✅ | Unity 资源音频提取队列阻塞后持续降级 |
| [BUG-948](bugs/BUG-948-dual-game-capture-acceptance.md) | ✅ | ✅ | Galgame 捕获不能稳定将正确文本与游戏资源语音一一配对并制卡 |
| [BUG-947](bugs/BUG-947-manosaba-text-loopback-hybrid.md) | ✅ | ✅ | Manosaba 正确文本 Hook 与 Loopback 音频不能同时保留 |
| [BUG-946](bugs/BUG-946-database-schema-v48-compat.md) | ✅ | ✅ | 游戏分支无法打开 schema v48 用户数据库 |
| [BUG-945](bugs/BUG-945-texthooker-popup-ui-scale.md) | ✅ | ✅ | 捕获工作台非默认缩放下查词断言 |
| [BUG-944](bugs/BUG-944-gal-text-thread-selector.md) | ✅ | ✅ | Galgame 捕获文本缺少 Luna 风格线程选择 |
| [BUG-943](bugs/BUG-943-video-card-bottom-gap.md) | ✅ | ✅ | 视频卡底部常驻空白（续 BUG-926 16:9 封面修复） |
| [BUG-942](bugs/BUG-942-prev-cue-button-always-jump.md) | ✅ | ✅ | 上/下一句字幕按钮太远时退化成 3 秒 seek |
| [BUG-941](bugs/BUG-941-texthooker-popup-platform-view-reparent.md) | ✅ | ✅ | 捕获工作台查词 WebView 重建后空白卡死 |
| [BUG-940](bugs/BUG-940-tag-filter-collection-rescue.md) | ✅ | ✅ | 标签筛选:打了标签的合集筛不出来(成员级过滤先于折叠剥空合集组) |
| [BUG-939](bugs/BUG-939-subtitle-menu-reenumerate.md) | ✅ | ✅ | 字幕轨菜单每次打开都重跑ffprobe显加载条+已有字幕先消失 |
| [BUG-938](bugs/BUG-938-collections-sync-trigger-gap.md) | ✅ | ✅ | 合集经常没同步：合集维度只搭载低频全量 sweep，日常关书/切后台路径从不推送合集 |
| [BUG-937](bugs/BUG-937-interconnect-video-cover-n2.md) | ✅ | ✅ | 互联视频浏览极慢：封面端点每张封面重跑整份 listVideos 清单（O(N²)） |
| [BUG-936](bugs/BUG-936-video-ime-space-playpause.md) | 🚧 | 🚧 | 日文IME激活时视频页空格无法播放暂停（BUG-853 修复真机仍失效） |
| [BUG-935](bugs/BUG-935-stats-chars-wan-unit.md) | ✅ | ✅ | 阅读统计字符数汇总缺万单位 |
| [BUG-934](bugs/BUG-934-prev-sentence-dup.md) | ✅ | ✅ | 前加一句制卡把当前句重复采集两遍 |
| [BUG-933](bugs/BUG-933-mining-ui-jank-isolate.md) | ✅ | ✅ | 制卡媒体处理阻塞UI线程未响应 |
| [BUG-932](bugs/BUG-932-popup-mine-plus-size.md) | ✅ | ✅ | 查词弹窗制卡加号(+)比相邻图标小 |
| [BUG-931](bugs/BUG-931-video-favorite-osd-topleft.md) | ✅ | ✅ | 视频收藏快捷键唤起进度条+底部提示统一左上角OSD |
| [BUG-930](bugs/BUG-930-subtitle-list-resize-cursor.md) | ✅ | ✅ | 视频字幕列表左缘调宽把手 hover 不显 resizeLeftRight（左右箭头）光标 |
| [BUG-929](bugs/BUG-929-ass-mpv-windows-font-fallback.md) | ✅ | ✅ | ASS 缺失字体在 Windows 上与 mpv 回退不一致 |
| [BUG-928](bugs/BUG-928-video-card-16x9-gap.md) | ✅ | ✅ | 视频卡对标准 16:9 封面留空隙·封面比例随标题长短浮动 |
| [BUG-927](bugs/BUG-927-reader-native-selection-blocks-lookup-and-rightclick-crash.md) | ✅ | ✅ | 阅读器原生选区残留卡住查词 + 右键闪退 |
| [BUG-926](bugs/BUG-926-popup-touch-copy-disabled.md) | ✅ | ✅ | 词典弹窗触屏无法复制释义(撤回BUG-762全量禁选) |
| [BUG-925](bugs/BUG-925-settings-all-sections-collapsible.md) | ✅ | ✅ | 设置所有带标题分区都应可折叠，默认展开/收起互不影响 |
| [BUG-924](bugs/BUG-924-video-dict-dismiss-shortcut.md) | ✅ | ✅ | 视频词典浮层无法用快捷键关闭·浮层开着时快捷键穿透控制视频 |
| [BUG-923](bugs/BUG-923-immersive-cursor-lock-button-no-idle-rehide.md) | ✅ | ✅ | 沉浸模式鼠标光标与沉浸退出按钮静止时不隐藏（缺「空闲重隐」路径，除非把鼠标移到别处） |
| [BUG-922](bugs/BUG-922-scm-landscape-sentence-collapsed.md) | ✅ | ✅ | 制卡·选择句子上下文对话框横屏塌陷只剩选项看不见句子 |
| [BUG-921](bugs/BUG-921-mining-collection-tag.md) | ✅ | ✅ | 制卡缺少所属合集名标签 |
| [BUG-920](bugs/BUG-920-media-source-open-folder-forward-slash.md) | ✅ | ✅ | 管理来源打开文件夹按钮路径不对 |
| [BUG-919](bugs/BUG-919-anilist-macron-search.md) | ✅ | ✅ | 番剧下载AniList搜索:带macron长音的罗马字全无结果 |
| [BUG-918](bugs/BUG-918-subtitle-offset-input-no-live-update.md) | ✅ | ✅ | 字幕偏移输入框不按回车不更新·退格没反应 |
| [BUG-917](bugs/BUG-917-video-clip-mp4-muxer.md) | ✅ | ✅ | 视频片段导出 exit -22（捆绑 ffmpeg-min 无 matroska muxer，输出跟随源容器） |
| [BUG-916](bugs/BUG-916-subtitle-list-shift-hover-offset.md) | ✅ | ✅ | 视频字幕列表Shift悬停查词偏左一格 |
| [BUG-915](bugs/BUG-915-ass-user-scale-and-plain-off-mode.md) | ✅ | ✅ | 尊重字幕不能调字号；关闭尊重时 ASS 特效层叠印乱字 |
| [BUG-914](bugs/BUG-914-remove-release-diagnostic-noise.md) | ✅ | ✅ | 发布版残留诊断日志/性能打点（查词·弹窗·按句同步热路径） |
| [BUG-913](bugs/BUG-913-asymmetric-disposal-leak.md) | ✅ | ✅ | 常驻服务/Notifier/provider 未对称释放（泄漏） |
| [BUG-912](bugs/BUG-912-state-not-reset-on-exception-path.md) | ✅ | ✅ | 异常/取消路径状态不复位（Windows 弹窗资产永久闩 + 长按缺 onLongPressCancel） |
| [BUG-911](bugs/BUG-911-fail-open-swallow-add-logging.md) | ✅ | ✅ | fail-open 静默吞异常致线上不可诊断（补 ErrorLogService 日志） |
| [BUG-910](bugs/BUG-910-video-subtitle-dismiss-halo-reloop.md) | ✅ | ✅ | 视频字幕查词点空白想关闭却重复查同一个词 |
| [BUG-909](bugs/BUG-909-remove-vertical-forensic-probes.md) | ✅ | ✅ | 移除发布版残留的竖排取证探针（TODO-792/753 系列 + 753-DIAG） |
| [BUG-908](bugs/BUG-908-lan-sync-server-hardening.md) | ✅ | ✅ | LAN 局域网同步服务器健壮性欠账（token 膨胀 / PROPFIND 同步阻塞 / 写无互斥） |
| [BUG-907](bugs/BUG-907-danmaku-layout-binary-and-isolate-parse.md) | ✅ | ✅ | 弹幕两项性能缺陷：布局每帧 O(N) 全量扫描 + 20MB sidecar 主 isolate 同步解析 |
| [BUG-906](bugs/BUG-906-prefs-version-txn-and-indexes.md) | ✅ | ✅ | 偏好版本并发自增丢失 + 查询热路径缺索引 |
| [BUG-905](bugs/BUG-905-ffmpegkit-precise-cancel.md) | ✅ | ✅ | 移动端 ffmpeg 超时用 FFmpegKit.cancel() 误杀全部并发会话 |
| [BUG-904](bugs/BUG-904-anki-gaiji-cache-key-per-dict.md) | ✅ | ✅ | Anki 外字(gaiji)媒体缓存键漏词典名 → 跨词典串味 |
| [BUG-903](bugs/BUG-903-audiobook-manual-seek-explicit-flag.md) | ✅ | ✅ | 有声书暂停态手动 seek 后显式 seek 抑制旗不复位，cue/高亮卡住 |
| [BUG-902](bugs/BUG-902-anki-dict-media-path-normalize.md) | ✅ | ✅ | 制卡词典图片脏path未归一化导致坏图 |
| [BUG-901](bugs/BUG-901-subtitle-seekbar-tap-proximity.md) | ✅ | ✅ | 字幕点击与进度条点击命中区重叠误触 |
| [BUG-900](bugs/BUG-900-secondary-subtitle-same-list.md) | ✅ | ✅ | 副字幕无法添加外挂字幕·应与主字幕共用同一可用字幕列表 |
| [BUG-899](bugs/BUG-899-collection-tag-drop-target.md) | ✅ | ✅ | 标签拖到合集行头无接收（合集打标签仅详情页按钮入口） |
| [BUG-898](bugs/BUG-898-audio-follow-image-pause-mask-persist.md) | ✅ | ✅ | 音频跟随遇图片暂停失效且遮罩未揭，遮罩揭开状态应持久化并与图片库双向同步 |
| [BUG-897](bugs/BUG-897-ass-size-outline-mpv-parity.md) | ✅ | ✅ | ASS 字幕字号偏小、描边偏细：cell 校准含 lineGap + 居中描边只显一半，与 mpv/libass 不齐 |
| [BUG-896](bugs/BUG-896-ankidroid-open-note-view-uri.md) | ✅ | ✅ | AnkiDroid 中打开卡片失败：ACTION_VIEW note URI 无 activity 处理 |
| [BUG-895](bugs/BUG-895-video-cards-too-large-on-phone.md) | ✅ | ✅ | 手机端视频卡片过大（窄屏只出 1 列铺满整屏） |
| [BUG-894](bugs/BUG-894-remote-video-reload-on-return.md) | ✅ | ✅ | 互联远端视频看完返回即重拉列表 |
| [BUG-893](bugs/BUG-893-favorited-sentences-stat-zero.md) | ✅ | ✅ | 阅读统计「收藏语句」计数恒为 0 |
| [BUG-892](bugs/BUG-892-reading-time-suspend-inflation.md) | ✅ | ✅ | 阅读时长记账把后台/挂起/睡眠时长计为阅读（34h 的书 / 单小时 >1h / 凌晨幻影 / 纵轴 "2h 2h"） |
| [BUG-891](bugs/BUG-891-remote-mining-audio-tls.md) | ✅ | ✅ | 远端流媒体制卡句子音频 ffmpeg-kit 无 https/自签 Protocol not found |
| [BUG-890](bugs/BUG-890-paused-audio-follow-image-snap.md) | ✅ | ✅ | 暂停/图片等待时有声书跟随把阅读器拽回音频位置 |
| [BUG-889](bugs/BUG-889-book-completed-status.md) | ✅ | ✅ | 书/有声书无「已读完」状态·概览 Completed 恒 0·无手动标记入口 |
| [BUG-888](bugs/BUG-888-tag-count-multimedia.md) | ✅ | ✅ | 标签管理器对有声书/视频标签显示 0 本 |
| [BUG-887](bugs/BUG-887-top-progress-squeeze-frost.md) | ✅ | ✅ | 挤压模式顶部进度不应有毛玻璃且不应压住正文首行 |
| [BUG-886](bugs/BUG-886-collapse-header-center.md) | ✅ | ✅ | 折叠设置分组标题头文字与箭头未垂直居中 |
| [BUG-885](bugs/BUG-885-ext-shift-hover-miss.md) | 🚧 | 🚧 | 浏览器扩展 Shift 悬停查词约 80% 不弹（机器相关，本机未复现） |
| [BUG-884](bugs/BUG-884-extension-lookup-compact-result.md) | ✅ | ✅ | 浏览器扩展查词响应重复携带原始词条导致冷链路慢 |
| [BUG-883](bugs/BUG-883-extension-shadow-text-align.md) | ✅ | ✅ | 浏览器扩展弹窗继承宿主页居中对齐 |
| [BUG-882](bugs/BUG-882-lyrics-restore-position.md) | ✅ | ✅ | 歌词模式重开书高亮跳回开头 |
| [BUG-881](bugs/BUG-881-video-subtitle-list-lookup-barrier.md) | ✅ | ✅ | 查词浮层开着时列表下一个词被 dismiss barrier 吞掉 |
| [BUG-880](bugs/BUG-880-video-shift-lookup-static-cursor.md) | ✅ | ✅ | Shift 查词静止光标不触发（"按了不出"） |
| [BUG-879](bugs/BUG-879-video-subtitle-list-shift-hover.md) | ✅ | ✅ | 字幕列表单词无法 Shift 悬停查词 |
| [BUG-878](bugs/BUG-878-video-subtitle-list-font-persist.md) | ✅ | ✅ | 字幕列表字号每次重开重置且上限太小 |
| [BUG-877](bugs/BUG-877-video-subtitle-list-panel-resize.md) | ✅ | ✅ | 字幕列表面板大小不可自定义 |
| [BUG-876](bugs/BUG-876-favorite-jump-missing-offset-text-fallback.md) | ✅ | ✅ | 书内点收藏「有时」跳不到句子位置（normCharOffset 缺失时静默失败/落章首） |
| [BUG-875](bugs/BUG-875-reader-vertical-single-char-line-end-flip.md) | ✅ | ✅ | 竖排有声书读到「句首是行尾单字」的句子时凭空前翻一页、下一句又翻回 |
| [BUG-874](bugs/BUG-874-subtitle-list-lookup-barrier.md) | ✅ | ✅ | 查词浮层打开时点字幕列表下一个词被 dismiss barrier 吞掉，必须先关弹窗 |
| [BUG-873](bugs/BUG-873-macos-trafficlight-overlap.md) | ✅ | ✅ | macOS 交通灯按钮与顶部导航/返回按钮重叠 |
| [BUG-872](bugs/BUG-872-update-channel-pingpong.md) | ✅ | ✅ | 调试版与正式版来回更新 |
| [BUG-871](bugs/BUG-871-win-touch-popup-scroll-primary.md) | ✅ | ✅ | Windows 触屏手指滑不动查词弹窗：注入触点缺 POINTER_FLAG_PRIMARY |
| [BUG-870](bugs/BUG-870-popup-touchpad-scroll-native.md) | ✅ | ✅ | 查词弹窗触控板滚不动 / 很难滚：native sendScroll 无残差截断 + JS 0.24 过度降速 |
| [BUG-869](bugs/BUG-869-fscx-line-level-squash.md) | ✅ | ✅ | 静态 \fscx/\fscy 被按行级「最后值生效」建模，句尾/前缀压扁标签把整行压扁 |
| [BUG-868](bugs/BUG-868-reader-content-ready-timeout-pagination-wedge.md) | ✅ | ✅ | 开EPUB偶发卡住·内容就绪兜底超时漏复位导航态致翻页永久失效 |
| [BUG-867](bugs/BUG-867-ass-fontname-gdi-fullname.md) | ✅ | ✅ | 装了字幕指定字体 hibiki 仍用回退字体（ASS Fontname=GDI 全名解析缺失） |
| [BUG-866](bugs/BUG-866-reader-live-margin-theme-gate.md) | ✅ | ✅ | 阅读器余白/主题改完不实时生效须退出重进(样式重锚就绪门控静默丢CSS) |
| [BUG-865](bugs/BUG-865-anki-popup-engine-missing-channel.md) | ✅ | ✅ | 外部查词面制卡 MissingPluginException 副engine未注册anki channel |
| [BUG-864](bugs/BUG-864-gdrive-sync-transient-no-retry.md) | ✅ | ✅ | Google Drive 聚合同步瞬时网络超时不重试整轮放弃 |
| [BUG-863](bugs/BUG-863-embedded-sub-poison-track.md) | ✅ | ✅ | 内嵌字幕单遍抽取被一条毒轨整批击穿 |
| [BUG-861](bugs/BUG-861-video-shift-hover-switch.md) | ✅ | ✅ | 视频按住Shift无法连续切换查词 |
| [BUG-860](bugs/BUG-860-popup-link-overflow.md) | ✅ | ✅ | 查词弹窗长URL链接出框 |
| [BUG-859](bugs/BUG-859-global-lookup-nested-popup-position.md) | ✅ | ✅ | 全局查词嵌套弹窗弹出位置不对 |
| [BUG-858](bugs/BUG-858-anki-overwrite-sentence.md) | ✅ | ✅ | Anki 覆盖卡片只覆盖图片和语音，原文句子未覆盖 |
| [BUG-857](bugs/BUG-857-horizontal-swipe-direction-not-flipped.md) | ✅ | ✅ | 横排滑动翻页方向未随书写方向翻转（和竖排一样，应与日语相反） |
| [BUG-856](bugs/BUG-856-mobile-swipe-insensitive-lookup.md) | ✅ | ✅ | 手机滑动翻页迟钝且短滑误触查词 |
| [BUG-855](bugs/BUG-855-ass-fontsize-em-vs-cell.md) | ✅ | ✅ | ASS Fontsize 被当 em 用，字号比 mpv 整体大一截 |
| [BUG-854](bugs/BUG-854-selection-menu-favorite.md) | ✅ | ✅ | 移动端选区菜单缺少收藏项 |
| [BUG-853](bugs/BUG-853-video-ime-space-pause.md) | 🚧 | 🚧 | 日语输入法激活时视频页按空格无法暂停 |
| [BUG-852](bugs/BUG-852-lyrics-blur-exposes-context.md) | ✅ | ✅ | 歌词模式模糊只盖当前句，前后文暴露 |
| [BUG-851](bugs/BUG-851-dict-dark-usage-tag-washed.md) | ✅ | ✅ | ダークモードで辞書の使い方タグがライト背景のまま浮く |
| [BUG-850](bugs/BUG-850-dict-ruby-hspacing-overlap.md) | ✅ | ✅ | 辞書例文の逐字ルビが横方向に重なる |
| [BUG-849](bugs/BUG-849-reader-paginated-live-style.md) | ✅ | ✅ | 分页模式改字号/边距/主题不实时生效需重开书 |
| [BUG-848](bugs/BUG-848-continue-watching-nextup-hero.md) | ✅ | ✅ | 继续观看hero不前进下一集停在旧集/不认远端进度 |
| [BUG-847](bugs/BUG-847-remote-cover-disk-cache.md) | ✅ | ✅ | 远端封面无磁盘缓存每次冷启动重下 |
| [BUG-846](bugs/BUG-846-nested-update-channels.md) | ✅ | ✅ | 测试版/调试版通道应收到正式版更新（嵌套合集） |
| [BUG-845](bugs/BUG-845-webdav-folder-slash-spill.md) | ✅ | ✅ | WebDAV book folderId 缺尾斜杠致进度文件溢出根目录并删除对端 in-folder 副本 |
| [BUG-844](bugs/BUG-844-lyrics-shift-hover-lookup.md) | ✅ | ✅ | 歌词模式不支持Shift/悬停查词 |
| [BUG-843](bugs/BUG-843-top-progress-overlaps-first-line.md) | ✅ | ✅ | 顶部阅读进度毛玻璃pill压住正文首行 |
| [BUG-842](bugs/BUG-842-popup-native-title-tooltip-flies.md) | ✅ | ✅ | Windows查词弹窗调整上下文等按钮原生title提示飞到窗口角落 |
| [BUG-841](bugs/BUG-841-subtitle-list-effect-dup.md) | ✅ | ✅ | 字幕列表特效叠加ASS未去重 |
| [BUG-840](bugs/BUG-840-bilingual-bottom-overlap.md) | ✅ | ✅ | 双语底部对白跨层/边距重叠 |
| [BUG-839](bugs/BUG-839-fullscreen-autoplay-esc-stack.md) | ✅ | ✅ | 全屏连播换集漏栈致ESC逐层回退 |
| [BUG-838](bugs/BUG-838-video-subtitle-lookup-seek-steal.md) | ✅ | ✅ | 视频字幕点字查词被进度条隐形热区抢成seek跳走 |
| [BUG-837](bugs/BUG-837-video-fullscreen-desktop-lock.md) | ✅ | ✅ | 桌面视频全屏独占锁死桌面无法切到其他软件 |
| [BUG-836](bugs/BUG-836-video-ultra-anime4k-ul-windows-black.md) | ✅ | ✅ | 视频画质增强极高档(Anime4K UL)在 Windows ANGLE 后端黑屏 |
| [BUG-835](bugs/BUG-835-ffmpeg-failure-summary-tail.md) | ✅ | ✅ | 制卡句子音频失败toast只显示ffmpeg版本banner看不到真因 |
| [BUG-834](bugs/BUG-834-remote-card-timer-leak.md) | ✅ | ✅ | HomeVideoPage的videoBooks watch订阅dispose取消时遗留drift缓存保留Timer致isolate不退出+CI全量单测挂死60min |
| [BUG-833](bugs/BUG-833-ass-karaoke-layers-stacked.md) | ✅ | ✅ | OP 多层卡拉 OK 同句三层被竖排堆叠成「三个字幕」 |
| [BUG-832](bugs/BUG-832-backup-media-sources-dict-history-leak.md) | ✅ | ✅ | 备份导出泄漏 media_sources 本地路径与 dictionary_history 查词记录 |
| [BUG-831](bugs/BUG-831-develop-md3-guard-red.md) | ✅ | ✅ | develop md3_static 守卫红:jimaku ListTile + collection-delete CheckboxListTile 2处既存违规 |
| [BUG-830](bugs/BUG-830-playlist-collection-not-reconciled.md) | ✅ | ✅ | m3u8播放列表增删视频后合集成员不更新 |
| [BUG-829](bugs/BUG-829-ffprobe-missing-logged-as-error.md) | ✅ | ✅ | 内封字幕字体枚举缺 ffprobe 被当错误记日志 |
| [BUG-828](bugs/BUG-828-backup-orphan-tables-leak.md) | ✅ | ✅ | 备份导出泄漏合集/标签/书架/搜索历史/删除墓碑等未受类别控制的孤儿表 |
| [BUG-827](bugs/BUG-827-android-mine-cover-fileprovider.md) | ✅ | ✅ | 安卓阅读器制卡书籍封面缺失(FileProvider 未覆盖 app_flutter 解压目录) |
| [BUG-826](bugs/BUG-826-popup-topbar-overlap-narrow.md) | ✅ | ✅ | 查词弹窗顶栏按钮窄宽时重叠 |
| [BUG-825](bugs/BUG-825-subtitle-hit-seekbar.md) | ✅ | ✅ | 点视频进度条被误判成点字幕触发查词 |
| [BUG-824](bugs/BUG-824-ankidroid-mine-permission-prompt.md) | ✅ | ✅ | AnkiDroid 权限未授予制卡失败无明显提醒 |
| [BUG-823](bugs/BUG-823-episode-switch-dualplay.md) | ✅ | ✅ | 切换剧集时上一个视频仍在播放（过渡期双音轨） |
| [BUG-822](bugs/BUG-822-subtitle-group-order-padding-slide.md) | ✅ | ✅ | 换句时字幕组序翻转致避让 padding 动画重播（每句对白入场滑跳） |
| [BUG-821](bugs/BUG-821-debug-update-check-plain-version.md) | ✅ | ✅ | beta/debug通道装无后缀X.Y.Z包永判已是最新 |
| [BUG-820](bugs/BUG-820-ass-scale-letterbox-container.md) | ✅ | ✅ | ASS 字号/描边缩放基准误用播放器容器高（应为 fit:contain 视频内容矩形） |
| [BUG-819](bugs/BUG-819-ass-bold0-fake-bold.md) | ✅ | ✅ | ASS `Bold=0` 被用户统一字重假粗体化（字号/描边观感全毁） |
| [BUG-818](bugs/BUG-818-popup-surface-translucent-wallpaper.md) | ✅ | ✅ | 查词浮窗卡片背景半透明透出壁纸浅色下看不清 |
| [BUG-817](bugs/BUG-817-merge-text-image-spread-mispair.md) | ✅ | ✅ | 自动跨页把文本章与固定布局插画章错配成spread导致合并插图失效 |
| [BUG-816](bugs/BUG-816-backup-export-category-gating.md) | ✅ | ✅ | 导出未按功能类别剥离个人数据(收藏句/音频源路径/字体路径/sync开关/配对token泄漏) |
| [BUG-815](bugs/BUG-815-init-retry-race.md) | ✅ | ✅ | 启动数据根不可达/看门狗重试致「数据全空」观感(移动端竞态 + 桌面静默回退空默认库) |
| [BUG-814](bugs/BUG-814-interconnect-video-list-empty.md) | ✅ | ✅ | 互联开启后手机视频列表为空(host listVideos 每视频串行 ffmpeg 探测超过 client 15s 超时) |
| [BUG-813](bugs/BUG-813-interconnect-download-no-reading-progress.md) | ✅ | ✅ | 互联手动下载远端书不带回阅读记录(阅读进度/有声书断点) |
| [BUG-812](bugs/BUG-812-interconnect-audiobook-not-in-collection.md) | ✅ | ✅ | 互联开启后手机上有声书不进合集(host listBooks 只用 epub\|bookKey 查归属，漏 srt-backed 有声书的 srt\|uid 成员键) |
| [BUG-811](bugs/BUG-811-remote-video-list-timeout-toast.md) | ✅ | ✅ | 远端视频清单超时把异常原文泄漏进 toast |
| [BUG-810](bugs/BUG-810-backup-import-overlay-no-progress.md) | ✅ | ✅ | 备份导入复制阶段无进度条遮罩 |
| [BUG-809](bugs/BUG-809-audiobook-clip-mjpeg-mov-size.md) | ✅ | ✅ | 有声书导出片段桌面仍用mjpeg/.mov无帧间压缩导致30秒200MB且非通用格式 |
| [BUG-808](bugs/BUG-808-audiobook-clip-highlight-reflow.md) | ✅ | ✅ | 有声书导出片段竖排逐句高亮撑大盒子导致整段文字重新排版抖动 |
| [BUG-807](bugs/BUG-807-multiselect-combine-icon-tooltip.md) | ✅ | ✅ | 多选栏组合成系列图标与收藏夹雷同且无tooltip |
| [BUG-806](bugs/BUG-806-dict-columns-autofit.md) | ✅ | ✅ | 词典最多列数自动调整对方框布局不生效 |
| [BUG-805](bugs/BUG-805-video-missing-reimport-noop.md) | ✅ | ✅ | 视频缺失态重新导入空操作没反应 |
| [BUG-804](bugs/BUG-804-shelf-continue-excludes-audiobook.md) | ✅ | ✅ | 书架继续阅读hero排除有声书永不更新 |
| [BUG-803](bugs/BUG-803-inline-gaiji-width.md) | ✅ | ✅ | 词典行内外字图标撑开相邻链接 |
| [BUG-802](bugs/BUG-802-popup-copy-search-selection.md) | ✅ | ✅ | 查词弹窗选中后复制/搜索无效 |
| [BUG-801](bugs/BUG-801-android-native-subtitleview-duplicate.md) | ✅ | ✅ | 安卓视频原生SubtitleView与可点浮层字幕重复(控制条显示时上下两条) |
| [BUG-800](bugs/BUG-800-subtitle-group-element-reuse-flicker.md) | ✅ | ✅ | 双语字幕重叠进出场时在屏字幕元素被跨 cue 复用导致闪烁 |
| [BUG-799](bugs/BUG-799-ass-blur-border-only.md) | ✅ | ✅ | ASS `\blur` 有描边时整字被糊成一团（应只糊描边、留锐利字面） |
| [BUG-798](bugs/BUG-798-exotic-audio-layout-silence.md) | ✅ | ✅ | 特殊多声道音频布局(6.1 FLC)无声 |
| [BUG-797](bugs/BUG-797-sentence-context-dialog-behind-popup.md) | ✅ | ✅ | 制卡「选择句子上下文」原生对话框被查词弹窗盖住（层级不对） |
| [BUG-796](bugs/BUG-796-video-seek-gap-subtitle-linger.md) | ✅ | ✅ | 视频普通 seek（±秒键）跳到无字幕段后旧字幕不消失 |
| [BUG-795](bugs/BUG-795-subtitle-list-empty-hint.md) | ✅ | ✅ | 字幕列表收藏/已选档结果为空误显示未加载字幕 |
| [BUG-793](bugs/BUG-793-video-import-no-refresh.md) | ✅ | ✅ | 视频导入后库页不自动刷新(外部打开等路径) |
| [BUG-792](bugs/BUG-792-subtitle-list-hover-popover-close.md) | ✅ | ✅ | 悬停底栏音量/倍速图标误关 push-aside 字幕列表 |
| [BUG-791](bugs/BUG-791-popup-empty-reading-split.md) | ✅ | ✅ | 查词弹窗同词因空读音拆成两张卡 |
| [BUG-790](bugs/BUG-790-video-collection-count-remote.md) | ✅ | ✅ | 视频合集行计数只数本地成员导致全云端合集显示0集 |
| [BUG-789](bugs/BUG-789-reader-chrome-inset-stale-pagination-metrics.md) | ✅ | ✅ | 底栏 inset 后分页终点过期导致章尾不可读 |
| [BUG-788](bugs/BUG-788-fractional-page-boundary-premature-limit.md) | ✅ | ✅ | 亚像素页距在第31页误判边界提前停翻 |
| [BUG-787](bugs/BUG-787-vertical-pagination-drift-recurrence.md) | ✅ | ✅ | 竖排累计漂移探针取整假阳性（当前 develop 未复现） |
| [BUG-786](bugs/BUG-786-md3-macos-double-shell.md) | ✅ | ✅ | macOS 自动/MD3 仍套原生侧栏形成双壳 |
| [BUG-785](bugs/BUG-785-lyrics-mode-persist-reentry.md) | ✅ | ✅ | 重新进入书籍不再是歌词模式（歌词模式跨会话不恢复） |
| [BUG-784](bugs/BUG-784-lyrics-follow-scroll-window-noop.md) | ✅ | ✅ | 歌词模式音频跟随「高亮变但不滚动」（window.scrollBy 空转，Windows/桌面复现） |
| [BUG-783](bugs/BUG-783-youtube-timedtext-format3.md) | ✅ | ✅ | YouTube 字幕失效: androidVr 返回 timedtext format3 <p t d> 而解析器只认 srv1 <text> |
| [BUG-782](bugs/BUG-782-reader-sheet-exit-bypasses-popscope.md) | ✅ | ✅ | 快捷面板退出按钮直接pop绕过PopScope致hero不更新且不触发同步 |
| [BUG-781](bugs/BUG-781-collection-member-menu-ui-scale-offset.md) | ✅ | ✅ | 合集详情页成员右键菜单未按界面缩放换算坐标错位 |
| [BUG-780](bugs/BUG-780-backup-keep-settings-local-audio-wipe.md) | ✅ | ✅ | 覆盖整库保留设置冲掉本地音频注册 |
| [BUG-779](bugs/BUG-779-local-audio-import-invalid-file.md) | ✅ | ✅ | 本地音频源导入无效文件假成功 |
| [BUG-778](bugs/BUG-778-collection-detail-drag-ui-scale-offset.md) | ✅ | ✅ | 合集详情页拖拽排序不吃界面大小缩放拖动位置错位 |
| [BUG-777](bugs/BUG-777-shelf-continue-hero-imported-order.md) | ✅ | ✅ | 继续阅读hero与书架最近阅读按导入序选书而非最近阅读序 |
| [BUG-776](bugs/BUG-776-sentence-context-native-dialog.md) | ✅ | ✅ | 制卡「选择句子上下文」应为 app 原生顶层对话框（不是画在查词弹窗内） |
| [BUG-775](bugs/BUG-775-ext-expression-scroll-scrollbar.md) | ✅ | ✅ | 扩展弹窗词头旁多出迷你滚动条：标准scrollbar-color继承使::-webkit-scrollbar隐藏失效 |
| [BUG-774](bugs/BUG-774-mine-button-global-lookup.md) | ✅ | ✅ | 剪贴板/选中查词缺少制卡按钮 |
| [BUG-773](bugs/BUG-773-clipboard-sentence-hit-offset.md) | ✅ | ✅ | 剪贴板面板句子横幅整词高亮左移吞句首标点 |
| [BUG-772](bugs/BUG-772-video-startup-freeze.md) | ✅ | ✅ | 快速进出视频后 Windows 启动冻死在 loading |
| [BUG-771](bugs/BUG-771-lyrics-reload-flicker-first-cue.md) | ✅ | ✅ | 歌词模式进入后一直闪烁 + 高亮恒第一句（不是正在听的那句） |
| [BUG-770](bugs/BUG-770-ext-popup-covers-word.md) | ✅ | ✅ | 网页扩展 Shift 查词弹窗遮住被查词 |
| [BUG-769](bugs/BUG-769-nf-postmessage-file-origin.md) | ✅ | ✅ | Netflix字幕面板file://下postMessage因opaque origin报错致列表空 |
| [BUG-768](bugs/BUG-768-clipboard-panel-btn-invisible.md) | ✅ | ✅ | 剪贴板面板图钉/关闭按钮暗背景不可见 |
| [BUG-767](bugs/BUG-767-reader-mdx-crossref-link.md) | ✅ | ✅ | MDX词典类义语交叉引用链接点击后面板空白 |
| [BUG-766](bugs/BUG-766-video-batch-book-counter.md) | ✅ | ✅ | 视频页批量删除/打标签文案误用「本书」量詞 |
| [BUG-765](bugs/BUG-765-reader-selection-handles-cannot-drag.md) | ✅ | ✅ | 阅读器移动端自绘选区两端手柄拖不动 |
| [BUG-764](bugs/BUG-764-scm-cross-paragraph-no-next.md) | ✅ | ✅ | 制卡「后加一句/前退一句」跨段落无反应（不支持跨 `<p>`） |
| [BUG-763](bugs/BUG-763-scm-modal-clipped.md) | ✅ | ✅ | 制卡「选择句子上下文」模态显示不全（预览被按钮区遮挡） |
| [BUG-762](bugs/BUG-762-popup-native-selection-freeze.md) | ✅ | ✅ | 词典弹窗长按释义弹原生选择菜单后卡住 |
| [BUG-759](bugs/BUG-759-anime4k-shader-noop.md) | ✅ | ✅ | Anime4K 着色器开了跟没开一样（glsl-shaders-append 非法 property 空下发） |
| [BUG-758](bugs/BUG-758-local-video-card-right-click.md) | ✅ | ✅ | 本地视频卡不支持右键弹菜单 |
| [BUG-757](bugs/BUG-757-lyrics-audio-follow-snap.md) | ✅ | ✅ | 歌词模式音频跟随失效（followAudio 门控 + snap 回中不生效） |
| [BUG-756](bugs/BUG-756-lyrics-input-no-chrome-no-esc.md) | ✅ | ✅ | 歌词模式唤不出隐藏底栏 + esc 退不出 |
| [BUG-755](bugs/BUG-755-interconnect-token-label-clipped.md) | ✅ | ✅ | 互联对端访问令牌浮动标签上半截被折叠区裁剪 |
| [BUG-754](bugs/BUG-754-clipboard-transient-banner-dup.md) | ✅ | ✅ | 剪贴板面板释义子查词瞬态窗顶部重复贴剪贴板整句横幅 |
| [BUG-753](bugs/BUG-753-header-pill-crushes-title.md) | ✅ | ✅ | 页头标签药丸按本地宽降级失败·挤压书架标题重叠 |
| [BUG-752](bugs/BUG-752-ext-content-css-reset-specificity.md) | ✅ | ✅ | 扩展查词弹窗与app内完全不一样：content.css生成器把通用reset抬到ID特异性压死低特异性margin/padding |
| [BUG-751](bugs/BUG-751-panel-header-buttons-washed-out.md) | ✅ | ✅ | 剪贴板半透明面板顶部按钮(制卡/音频/收藏)几乎不可见 |
| [BUG-750](bugs/BUG-750-remote-tab-reload.md) | ✅ | ✅ | 远端视频/书切 tab 每次重新加载（顶层 tab 无保活） |
| [BUG-749](bugs/BUG-749-lookup-window-floor-region-eats-clicks.md) | ✅ | ✅ | app外查词覆盖窗铺满工作区吞掉下一次点击 |
| [BUG-748](bugs/BUG-748-vn-blank-tap-advance-vertical.md) | ✅ | ✅ | VN居中竖排布局下点击空白翻页永不触发(caret clamp到文字) |
| [BUG-747](bugs/BUG-747-desktop-restart-button-only-exits.md) | ✅ | ✅ | 桌面导入后点立即重启只退出不重启 |
| [BUG-746](bugs/BUG-746-overwrite-import-rename-access-denied.md) | ✅ | ✅ | 覆盖导入书籍树换名Windows拒绝访问导致整个导入失败 |
| [BUG-745](bugs/BUG-745-merge-import-deleted-book-empty-orphan.md) | ✅ | ✅ | 合并导入让已删书变空书籍(srt行不认书墓碑被复活) |
| [BUG-744](bugs/BUG-744-merge-import-audio-sources-lost.md) | ✅ | ✅ | 合并导入不恢复音频来源(音频源配置/本地音频库被当设备设置丢弃) |
| [BUG-743](bugs/BUG-743-dual-subtitle-bounce-and-large-display-overlap.md) | ✅ | ✅ | 双轨字幕来回弹跳 + 大屏底部双语塌陷重叠 |
| [BUG-742](bugs/BUG-742-subtitle-blur-weak.md) | ✅ | ✅ | 视频听力沉浸字幕模糊度不够(固定8px不随字号缩放) |
| [BUG-741](bugs/BUG-741-transient-lookup-window-owned-pulls-main-foreground.md) | ✅ | ✅ | 悬浮字幕点词瞬态查词窗owned·Z序连带把主窗拉前台 |
| [BUG-740](bugs/BUG-740-overlay-window-dead-handle-no-recreate.md) | ✅ | ✅ | 覆盖窗HWND被外部销毁后悬垂hwnd_不重建·第二个弹窗出不来 |
| [BUG-739](bugs/BUG-739-video-volume-device-switch.md) | ✅ | ✅ | 反复切换音频输出设备后视频音量逐步变小甚至静音 |
| [BUG-738](bugs/BUG-738-mine-icon-charset-mojibake.md) | ✅ | ✅ | 手机制卡后制卡按钮图标乱码 âœ (UTF-8 编码丢失/file:// opaque origin 外链脚本回退 1252) |
| [BUG-737](bugs/BUG-737-selfclosing-anchor-blocks-lookup.md) | ✅ | ✅ | 自闭合a锚点被HTML解析成未闭合a包裹正文导致点字查词被链接守卫拒绝 |
| [BUG-736](bugs/BUG-736-extension-popup-theme-vars.md) | ✅ | ✅ | 浏览器扩展查词弹窗主题与 app 不一致(漏发4个CSS变量) |
| [BUG-735](bugs/BUG-735-shelf-add-button-size.md) | ✅ | ✅ | 书架添加按钮尺寸位置与其它头部按钮不一致 |
| [BUG-734](bugs/BUG-734-stats-mobile-text-clip.md) | ✅ | ✅ | 手机统计页文字被省略号裁切显示不全 |
| [BUG-733](bugs/BUG-733-popup-glossary-ruby-element-base-overlap.md) | ✅ | ✅ | 词典弹窗释义正文元素基字 ruby 注音塌到基字上 |
| [BUG-732](bugs/BUG-732-ext-page-scroll.md) | ✅ | ✅ | 扩展影响普通网页滚动速度 |
| [BUG-731](bugs/BUG-731-backup-font-count-inflated.md) | ✅ | ✅ | 备份导出自定义字体计数虚高(2个显示7个) |
| [BUG-730](bugs/BUG-730-clipboard-mine-sentence.md) | ✅ | ✅ | 剪贴板/全局查词制卡句子字段恒空（未接剪贴板文本） |
| [BUG-729](bugs/BUG-729-simple-dict-inflected-lookup.md) | ✅ | ✅ | MDX/StarDict/DSL 等 simple 词典屈折形查词命中丢失 |
| [BUG-728](bugs/BUG-728-shelf-audiobook-progress.md) | ✅ | ✅ | 书架有声书进度条听书时不更新 |
| [BUG-727](bugs/BUG-727-mdx-encrypted-keyinfo.md) | ✅ | ✅ | MDX Encrypted=2 词典导入失败 empty key block info |
| [BUG-726](bugs/BUG-726-ext-unpacked-copy-never-refreshed.md) | ✅ | ✅ | 浏览器扩展已解压副本永不随app升级刷新导致弹窗停留旧版 |
| [BUG-725](bugs/BUG-725-interconnect-testconn-button-in-server-mode.md) | ✅ | ✅ | 互联服务端模式仍显示测试连接按钮 |
| [BUG-724](bugs/BUG-724-audiobook-image-contained-anchor.md) | ✅ | ✅ | 有声书正文中间插图:当前句cue锚点是含图容器时compareDocumentPosition只判PRECEDING位漏检导致不暂停不去遮罩 |
| [BUG-722](bugs/BUG-722-popup-multibase-ruby-furigana-overlap.md) | ✅ | ✅ | 词典弹窗多基字词逐字振假名完全重叠(勝負/将棋) |
| [BUG-721](bugs/BUG-721-clipboard-panel-close-drops-lookups.md) | ✅ | ✅ | 剪贴板面板关闭后被永久暂停：第二个词出不来 |
| [BUG-720](bugs/BUG-720-sasayaki-lookup-ruby-lane-misalign.md) | ✅ | ✅ | 有声书/查词注音高亮 narrow-lane 错位 |
| [BUG-719](bugs/BUG-719-fontcache-mtime-roundtrip.md) | ✅ | ✅ | 词典字体缓存测试在 Linux CI 挂：setLastModified 亚秒 round-trip 丢精度 |
| [BUG-718](bugs/BUG-718-vn-restore-charoffset-cloak.md) | ✅ | ✅ | VN模式按字符偏移恢复时FOUC遮罩未移除致整页空白 |
| [BUG-717](bugs/BUG-717-lookup-latency-half-second.md) | ✅ | ✅ | 查词全链路延迟半秒级 |
| [BUG-716](bugs/BUG-716-bilingual-bottom-marginv-overlap.md) | ✅ | ✅ | 双语底部对白 MarginV 塌陷重叠 |
| [BUG-715](bugs/BUG-715-nested-popup-searching-placeholder-zorder.md) | ✅ | ✅ | 嵌套查词子弹窗渲染前显示在父弹窗下方图层(视频/首页/悬浮歌词) |
| [BUG-714](bugs/BUG-714-interconnect-live-book-push-500.md) | ✅ | ✅ | 互联 live 书籍推送全部 HTTP 500(host 未接线 importBookFromFile) |
| [BUG-713](bugs/BUG-713-clip-highlight-fps-quantization-lag.md) | ✅ | ✅ | 有声书导出片段逐句高亮系统性滞后=12fps帧量化 |
| [BUG-712](bugs/BUG-712-popup-js-error-silent.md) | ✅ | ✅ | 查词弹窗 JS 渲染报错静默、错误日志为空 |
| [BUG-711](bugs/BUG-711-nav-jump-rtc-verified-not-reproducible.md) | ✅ | ✅ | 导航跳转落章首 TODO-1308 复诉在 develop 无法复现（已被 BUG-696 根治） |
| [BUG-710](bugs/BUG-710-font-relocate-pjoin-platform.md) | ✅ | ✅ | 字体路径自愈测试硬编码Windows分隔符在Linux CI挂(Release APK阻断) |
| [BUG-709](bugs/BUG-709-global-lookup-shadow-black-halo.md) | ✅ | ✅ | 全局查词覆盖窗圆角外黑边(非分层WebView2下box-shadow成黑晕) |
| [BUG-708](bugs/BUG-708-interconnect-repair-blocked-by-lingering-pin-dialog.md) | ✅ | ✅ | 公网PIN配对取消后重新配对被host常驻PIN弹窗挡成拒绝 |
| [BUG-707](bugs/BUG-707-selection-capture-clipboard-echo.md) | ✅ | ✅ | 全局查词抓选区的剪贴板回声泄漏进剪贴板查词管线 |
| [BUG-706](bugs/BUG-706-lookup-popup-blank.md) | ✅ | ✅ | 查词弹窗全空白: __hibikiRoot 函数名与 window.__hibikiRoot marker 冲突 |
| [BUG-705](bugs/BUG-705-font-catalog-stale-path.md) | ✅ | ✅ | 字体库字体丢失：数据根迁移/备份恢复后 font_catalog 路径失联 |
| [BUG-704](bugs/BUG-704-min-window-dialog-overflow.md) | ✅ | ✅ | 最小窗高(TODO-1377 480px)下弹窗底部 RenderFlex 溢出 |
| [BUG-703](bugs/BUG-703-mine-cover-case-insensitive.md) | ✅ | ✅ | 手机(Android)书籍阅读制卡缺封面(制卡与书架对封面路径大小写解析不对称) |
| [BUG-702](bugs/BUG-702-netflix-maturity-overlay.md) | ✅ | ✅ | 网飞制卡时剧集开头的年龄分级 overlay 被录进卡片截图/gif（TODO-1391） |
| [BUG-701](bugs/BUG-701-touchpad-wheel-subpixel.md) | ✅ | ✅ | 查词弹窗触控板滚轮亚像素步进丢帧（时好时坏） |
| [BUG-700](bugs/BUG-700-desktop-clipboard-breakpoint.md) | ✅ | ✅ | 桌面剪贴板自动查词跨窗口尺寸断点后失效 |
| [BUG-699](bugs/BUG-699-ghost-remote-book.md) | ✅ | ✅ | WebDAV-only 用户首屏闪现无内容的幽灵远端书 |
| [BUG-698](bugs/BUG-698-dual-subtitle-slot-snap.md) | ✅ | ✅ | 两条字幕同显时字幕盒随活动集增减跳动（组内堆叠槽位不稳定） |
| [BUG-697](bugs/BUG-697-fullscreen-gamepad-dead.md) | ✅ | ✅ | 视频全屏路由内手柄仅B返回可用（A/D-pad静默no-op） |
| [BUG-696](bugs/BUG-696-nav-jump-lands-chapter-start.md) | ✅ | ✅ | 导航跳转落章节开头而非目标文字 |
| [BUG-695](bugs/BUG-695-vertical-ruby-rtc-inline.md) | ✅ | ✅ | 竖排rtc形态振假名内联占字符格挤开基字 |
| [BUG-694](bugs/BUG-694-logpanel-context-menu-crash.md) | ✅ | ✅ | 日志面板选中文本弹右键菜单崩溃（选区端点空断言） |
| [BUG-693](bugs/BUG-693-overlay-webview-process-failed-selfheal.md) | ✅ | ✅ | 悬浮字幕点词覆盖窗死亡后永久没反应：overlay WebView2 无 ProcessFailed 自愈 |
| [BUG-692](bugs/BUG-692-popup-dictionary-hidden-warm-webview-blocks-touch.md) | ✅ | ✅ | 安卓app外查词弹窗上下滑不动点击无反应（隐藏热槽屏内截触摸） |
| [BUG-691](bugs/BUG-691-mine-icon-tofu-android.md) | ✅ | ✅ | 手机制完卡后制卡图标✓乱码/豆腐（Android WebView 缺符号字体） |
| [BUG-690](bugs/BUG-690-sasayaki-active-lineheight-shift.md) | ✅ | ✅ | 竖排跟随句高亮激活时整段列平移（active 态 line-height:1 改写盒模型） |
| [BUG-689](bugs/BUG-689-global-lookup-root-offwork-clip.md) | ✅ | ✅ | app外查词根卡靠屏右下生成在工作区外被裁 |
| [BUG-688](bugs/BUG-688-ext-popup-theme-mismatch.md) | ✅ | ✅ | 浏览器扩展查词弹窗主题分裂：data-theme跟宿主页/--md-*跟app且漏--text-color/--background-color |
| [BUG-687](bugs/BUG-687-longpress-arrow-sentence.md) | ✅ | ✅ | 长按左右键无法连续切句/连续翻页 |
| [BUG-686](bugs/BUG-686-interconnect-book-progress-shelf-stale.md) | ✅ | ✅ | 互联同步书籍进度后书架不刷新(收端显示旧进度·观感=书籍没同步·有声书resume现读故正常) |
| [BUG-685](bugs/BUG-685-netflix-seek-in-then-out-skip.md) | ✅ | ✅ | 网飞批量制卡 seek 过去马上跳走没录制（seek-in-then-out） |
| [BUG-684](bugs/BUG-684-multi-subtitle-full.md) | ✅ | ✅ | 视频多字幕降级:同锚点MarginV裹挟+副字幕硬拽顶部 |
| [BUG-683](bugs/BUG-683-first-card-taller.md) | ✅ | ✅ | 查词弹窗首个词典卡片比其他卡片高 |
| [BUG-682](bugs/BUG-682-audio-image-mask-not-revealed.md) | ✅ | ✅ | 有声书音频跨过图片不去掉防剧透遮罩(未持久·懒图漏揭) |
| [BUG-681](bugs/BUG-681-netflix-clip-audio-truncation.md) | ✅ | ✅ | Netflix 制卡句子音频尾段被截断（录制在字幕清空即停，无尾部余量） |
| [BUG-680](bugs/BUG-680-bookshelf-progress-old-build.md) | ✅ | ✅ | 书架书籍进度「还是没有」——复诉根因=旧包(debug.6783)，BUG-659 修复已在 develop(TODO-1346) |
| [BUG-679](bugs/BUG-679-column-image-squish.md) | ✅ | ✅ | 分页多列图片挤压/溢出盖住相邻列正文（TODO-1285 图片复诉） |
| [BUG-678](bugs/BUG-678-youtube-stream-replay-ua.md) | ✅ | ✅ | YouTube 分离流回放 UA 残缺致 googlevideo tarpit 超时打不开 |
| [BUG-677](bugs/BUG-677-subtitle-import-system-picker.md) | ✅ | ✅ | 导入选字幕文件的选择器变了 回退系统文件选择器 (board 1360) |
| [BUG-676](bugs/BUG-676-netflix-mine-missing-video-name.md) | ✅ | ✅ | 网飞制卡缺少视频名（documentTitle） |
| [BUG-675](bugs/BUG-675-netflix-batch-mine-silent-skip.md) | ✅ | ✅ | 网飞批量制卡有概率跳过某几张卡 |
| [BUG-674](bugs/BUG-674-netflix-next-episode-hide.md) | ✅ | ✅ | 网飞剧末下一集按钮无法隐藏 |
| [BUG-673](bugs/BUG-673-headword-ltr-rtl-flip.md) | ✅ | ✅ | 查词卡 headword 在 RTL UI 语言下被甩到最右 |
| [BUG-672](bugs/BUG-672-video-subtitle-track-live-secondary.md) | ✅ | ✅ | 视频字幕轨切换不即时+副字幕跳到另一个窗口 |
| [BUG-671](bugs/BUG-671-sparse-cover-prev-landing.md) | ✅ | ✅ | 文字少+图片封面章往前翻仍落章首（BUG-661 续） |
| [BUG-670](bugs/BUG-670-parent-shift-deep-cascade.md) | ✅ | ✅ | app 外查词深层级联父弹窗残留 1 帧位移 |
| [BUG-669](bugs/BUG-669-reorder-mode-group-frame-remove.md) | ✅ | ✅ | 编辑排序模式：合集分组框看不见、减号删除后书籍消失、减号遮挡类型徽章 |
| [BUG-668](bugs/BUG-668-reimport-book-title-not-refreshing.md) | ✅ | ✅ | 重导入书选文件后书名不刷新 |
| [BUG-667](bugs/BUG-667-delete-fail-diag.md) | ✅ | ✅ | 删除书籍失败无原因+磁盘清理异常翻转已提交删除 |
| [BUG-666](bugs/BUG-666-vertical-ruby-position-flip.md) | ✅ | ✅ | 竖排振假名翻到基字左侧+高亮带错位(阅读器未拥有 ruby-position) |
| [BUG-665](bugs/BUG-665-anki-mine-connect-timeout.md) | ✅ | ✅ | 远端制卡查重挂满 10s 超时（AnkiConnect 不可达/无响应，缺连接建立超时） |
| [BUG-664](bugs/BUG-664-pitch-number-float-niratan.md) | ✅ | ✅ | 查词卡音高数字浮动/读音位置不如 Niratan 整齐 |
| [BUG-663](bugs/BUG-663-peer-device-name-localhost.md) | ✅ | ✅ | 互联已配对设备名显示 localhost 而非真实设备名 |
| [BUG-662](bugs/BUG-662-clipboard-focus-steal.md) | ✅ | ✅ | 桌面剪贴板变化把 Hibiki 拉到前台/抢焦点打断用户 |
| [BUG-661](bugs/BUG-661-prev-chapter-landing.md) | ✅ | ✅ | 从目录往前翻落到封面而非封面章节最后部分（图片章章末落点塌缩） |
| [BUG-660](bugs/BUG-660-sentence-context-dup.md) | ✅ | ✅ | 视频制卡例句上下文疑似重复两遍(develop已单句·验旧包/残留队列) |
| [BUG-659](bugs/BUG-659-progress-lost.md) | ✅ | ✅ | 书架/视频进度「好像没了」——非数据丢失，显示短板已修（TODO-1346） |
| [BUG-658](bugs/BUG-658-book-import-notfound.md) | ✅ | ✅ | 特殊字符标题EPUB导入后打不开/删不掉(bookKey含%XX被标识符round-trip解码) |
| [BUG-657](bugs/BUG-657-settings-autoupdate-dict-overlap.md) | ✅ | ✅ | 词典管理页自动更新卡与词典列表粘连 |
| [BUG-656](bugs/BUG-656-merge-consecutive-images.md) | ✅ | ✅ | 图片合并两张连续图只有最后一张合并进章节 |
| [BUG-655](bugs/BUG-655-mine-icon-garble.md) | ✅ | ✅ | 制卡后查词弹窗制卡图标(✓↩)变乱码 |
| [BUG-654](bugs/BUG-654-reorder-frame-drag.md) | ✅ | ✅ | 编辑排序合集分组框看不见 + 手机缩放态拖动误滚(TODO-947) |
| [BUG-653](bugs/BUG-653-cloud-spill-multiple.md) | ✅ | ✅ | 云盘 per-book 文件溢出根目录并累积多份（TODO-1340，BUG-619 复报） |
| [BUG-652](bugs/BUG-652-page-edge-leak-v2.md) | ✅ | ✅ | 分页阅读器翻页看到上下页内容(相邻页泄露)复诉·真机WebView2实测已修 |
| [BUG-651](bugs/BUG-651-dual-subtitle-position.md) | ✅ | ✅ | 双字幕同显但两条挤在同一位置来回变+样式没按各自轨道 |
| [BUG-650](bugs/BUG-650-sync-incomplete-discard.md) | ✅ | ✅ | 同步未完成被中断仍误记冷却时间戳·压制下次启动重试（应丢弃中间态并按时机重试） |
| [BUG-649](bugs/BUG-649-ios-lyrics-mode-load-race.md) | ✅ | ✅ | iOS 歌词模式进入时旧页面 onLoadStop 误初始化 |
| [BUG-648](bugs/BUG-648-ios-lyrics-mode-huge-html.md) | ✅ | ✅ | iOS 歌词模式整本字幕 HTML 导致打不开 |
| [BUG-647](bugs/BUG-647-ios-profile-promotion-disabled.md) | ✅ | ✅ | iOS Profile/Release 未启用高刷新率 |
| [BUG-646](bugs/BUG-646-ios-lyrics-mode-reopen-timeout.md) | ✅ | ✅ | iOS 重开书籍恢复歌词模式导致内容超时白屏 |
| [BUG-645](bugs/BUG-645-ios-ankimobile-media-url-404.md) | ✅ | ✅ | iOS AnkiMobile 制卡本地媒体 URL 404 |
| [BUG-644](bugs/BUG-644-ios-audiobook-card-sentence-audio-aac.md) | ✅ | ✅ | iOS 有声书制卡句音频仍以 .aac localhost URL 入卡 |
| [BUG-643](bugs/BUG-643-reader-ruby-highlight-wide.md) | ✅ | ✅ | 阅读器竖排 ruby 有声书高亮条包含振假名导致变宽 |
| [BUG-642](bugs/BUG-642-ios27-vsync-startup-crash.md) | ✅ | ✅ | iOS 27 真机启动在 Flutter VSyncClient 崩溃 |
| [BUG-641](bugs/BUG-641-ios-audiobook-silent.md) | ✅ | ✅ | iOS 有声书播放没声音 |
| [BUG-640](bugs/BUG-640-ankimobile-svg-cache-hash.md) | ✅ | ✅ | iOS/Anki 制卡外字 SVG 偶发读不到（词典媒体缓存名使用 String.hashCode） |
| [BUG-639](bugs/BUG-639-url-drag-import.md) | ✅ | ✅ | 拖动链接(URL)进桌面窗口直接添加为视频（TODO-1306，feature） |
| [BUG-638](bugs/BUG-638-popup-close-latch.md) | ✅ | ✅ | 查词弹窗首次查词后关不掉(warm复用_isClosing闭锁永不复位) |
| [BUG-637](bugs/BUG-637-interconnect-token-display.md) | ✅ | ✅ | 互联访问令牌两端显示不一致令用户困惑 |
| [BUG-636](bugs/BUG-636-popup-expand-icon.md) | ✅ | ✅ | 查词弹窗词典分组展开/收起图标渲染不出来 |
| [BUG-635](bugs/BUG-635-mining-marker-revert.md) | ✅ | ✅ | 查词弹窗制卡标记还原为 ✓✓↩ 文本标记 |
| [BUG-634](bugs/BUG-634-page-columns-noop.md) | ✅ | ✅ | 阅读器每页列数(pageColumns)不生效 |
| [BUG-633](bugs/BUG-633-floating-lyric-tap-slop.md) | ✅ | ✅ | 悬浮字幕点击文字没反应的更深根因：tap/drag 阈值低于平台 touch slop |
| [BUG-632](bugs/BUG-632-netflix-record-wait-buffer.md) | ✅ | ✅ | 网飞制卡录制时长不准（未等缓冲就绪即开录·录进 stall 冻结帧） |
| [BUG-631](bugs/BUG-631-extension-popup-word-audio-remote-source.md) | ✅ | ✅ | 扩展/远端查词弹窗无单词音频（server 只查本地库漏配置的远程源） |
| [BUG-630](bugs/BUG-630-netflix-mine-issue.md) | ✅ | ✅ | 网飞制卡有问题（未复现·待用户日志） |
| [BUG-629](bugs/BUG-629-youtube-subtitle-vanish.md) | ✅ | ✅ | YouTube 字幕快加载后整个消失（回归） |
| [BUG-628](bugs/BUG-628-ass-outline-width-scale.md) | ✅ | ✅ | 外挂ASS描边宽未随PlayResY缩放（尊重自带样式仍不够忠实） |
| [BUG-627](bugs/BUG-627-m3u8-playlist-dedup-identity.md) | ✅ | ✅ | m3u8 播放列表来源库重复扫描不去重、封面缺失（判重键错用首集易变路径） |
| [BUG-626](bugs/BUG-626-merge-image-toc-lost.md) | ✅ | ✅ | 图片合并后章节列表消失 |
| [BUG-625](bugs/BUG-625-theme-swatch-full-preview.md) | ✅ | ✅ | 未选中主题色卡空白·预览画布塌成0x0 |
| [BUG-624](bugs/BUG-624-longpress-text-selection.md) | ✅ | ✅ | 手机长按丢了文本区间选择(复制)·回归 |
| [BUG-623](bugs/BUG-623-subtitle-timing-entry.md) | ✅ | ✅ | 字幕调轴波形对轴入口在弱设备被隐藏（懒加载化后已改为常驻可见） |
| [BUG-622](bugs/BUG-622-card-image-compat.md) | ✅ | ✅ | 老 {book-cover} 模板视频制卡也产 GIF（向后兼容超集，无需手改） |
| [BUG-621](bugs/BUG-621-extension-popup-parity.md) | ✅ | ✅ | 浏览器扩展查词弹窗与 app 内不一致（丑/按钮位置不同） |
| [BUG-620](bugs/BUG-620-sync-autodownload-decouple.md) | ✅ | ✅ | 同步误把远端独有书自动灌书架(syncAudioBookFiles 触发 TODO-873 自动下书) |
| [BUG-619](bugs/BUG-619-cloud-folder-spill.md) | ✅ | ✅ | 云盘进度文件溢出到父目录 |
| [BUG-618](bugs/BUG-618-interconnect-token-mismatch-confusion.md) | 🚧 | 🚧 | 互联访问令牌与桌面端不一致（per-peer token·非 bug 待确认） |
| [BUG-617](bugs/BUG-617-interconnect-wan-pin-vanishes.md) | ✅ | ✅ | 公网配对 host 点允许即关窗抹掉 PIN·client 还没输就看不到 |
| [BUG-616](bugs/BUG-616-interconnect-test-connection-tls.md) | ✅ | ✅ | 互联测试连接对已配对 https host 恒失败（漏传钉扎指纹） |
| [BUG-615](bugs/BUG-615-nav-double-jump-first-chapter-only.md) | ✅ | ✅ | 导航跨章跳转首次只到章节需跳两次（TODO-1309 ②） |
| [BUG-614](bugs/BUG-614-multicue-overlap-secondary.md) | ✅ | ✅ | 重叠cue跳+副字幕并入overlay多层渲染重构（TODO-1312 方案A） |
| [BUG-613](bugs/BUG-613-data-migration-hang-folder-loss.md) | ✅ | ✅ | 改数据文件夹位置卡死+目标文件夹消失 |
| [BUG-612](bugs/BUG-612-cover-not-showing-6897.md) | ✅ | ✅ | 6897书籍封面检测到却不显示回归（TODO-1319） |
| [BUG-611](bugs/BUG-611-vertical-ruby-nav-misplace.md) | ✅ | ✅ | 竖排滚动导航后假名跑文字中间 |
| [BUG-610](bugs/BUG-610-settings-area-narrowed.md) | ✅ | ✅ | 设置部分区域宽度变窄回归 |
| [BUG-609](bugs/BUG-609-mobile-longpress-select.md) | ✅ | ✅ | 1279 coarse user-select:none禁了手机长按选中·补app选区手势 |
| [BUG-608](bugs/BUG-608-share-callback-error.md) | ✅ | ✅ | 分享图片PlatformException share-sheet未回调重入 |
| [BUG-607](bugs/BUG-607-pitch-reading-mined.md) | ✅ | ✅ | 词典音高片假名reading被拖选烤进制卡卡片 |
| [BUG-606](bugs/BUG-606-yt-slow-first-frame.md) | ✅ | ✅ | 油管首帧被字幕+title串行阻塞~28s |
| [BUG-605](bugs/BUG-605-selectgraphic-loadtoken-uaf.md) | ✅ | ✅ | 1295 minTrackCount await破BUG-344 loadToken守卫 |
| [BUG-604](bugs/BUG-604-ass-font-weight-shadow.md) | ✅ | ✅ | 外挂ASS字号字重阴影不尊重 |
| [BUG-603](bugs/BUG-603-netflix-mine-false-success.md) | ✅ | ✅ | 网飞制卡失败报成功+诊断不回传 |
| [BUG-602](bugs/BUG-602-yt-subtitle-not-in-track.md) | ✅ | ✅ | 油管字幕绕过远端字幕轨模型选不到 |
| [BUG-601](bugs/BUG-601-large-window-gpu-flicker.md) | ✅ | ✅ | 大窗集显呼出UI仍GPU100%闪烁 |
| [BUG-600](bugs/BUG-600-yt-inapp-mining-no-audio.md) | ✅ | ✅ | 油管应用内制卡音频源指向audio-only DASH致stall无音频gif连坐 |
| [BUG-599](bugs/BUG-599-video-stuck-loading.md) | ✅ | ✅ | 视频buffered已满仍卡加载态 |
| [BUG-598](bugs/BUG-598-floating-sub-tap-no-lookup.md) | ✅ | ✅ | 悬浮字幕点击文字不出查词窗(Android) |
| [BUG-597](bugs/BUG-597-android-video-black-texture.md) | ✅ | ✅ | 安卓视频解码正常但纹理合成黑屏 |
| [BUG-596](bugs/BUG-596-yt-stream-dedup-cover.md) | ✅ | ✅ | 油管流去重无videoId规范化+非YouTube流无封面 |
| [BUG-595](bugs/BUG-595-mobile-mining-no-cover.md) | ✅ | ✅ | 手机制卡回退路径漏coverHref致无书籍封面 |
| [BUG-594](bugs/BUG-594-chapter-jump-illustration-skip.md) | ✅ | ✅ | 章节翻页初始正确后异步跳过章首插图（TODO-1229 第 5–6 次复诉） |
| [BUG-593](bugs/BUG-593-netflix-card-subtitle-dup.md) | ✅ | ✅ | 网飞制卡卡片字幕重复两次+截取混入UI+少开头 |
| [BUG-592](bugs/BUG-592-interconnect-connect-fail.md) | ✅ | ✅ | 互联LAN token成功仍连失败+公网无pin |
| [BUG-591](bugs/BUG-591-external-sub-style.md) | ✅ | ✅ | 外挂ASS字幕自带颜色描边不生效 |
| [BUG-590](bugs/BUG-590-secondary-subtitle-race.md) | ✅ | ✅ | 副字幕轨就绪竞态致有时不显示 |
| [BUG-589](bugs/BUG-589-waveform-density.md) | ✅ | ✅ | 字幕对轴波形显示密度不利于辨句 |
| [BUG-588](bugs/BUG-588-stats-mobile-numbers.md) | ✅ | ✅ | 手机阅读统计页数字不可见 |
| [BUG-587](bugs/BUG-587-reader-restore-stale-charoffset.md) | ✅ | ✅ | 退出图1重进回图2·恢复位置错误 |
| [BUG-586](bugs/BUG-586-netflix-mine-queue-dup-sentence.md) | ✅ | ✅ | 网飞扩展制卡队列句子一模一样重复 |
| [BUG-585](bugs/BUG-585-ffmpeg-audio-138.md) | ✅ | ✅ | 制卡句子音频 ffmpeg exit -138（googlevideo connect 阶段网络超时） |
| [BUG-584](bugs/BUG-584-image-spoiler-reveal-persist.md) | ✅ | ✅ | 图片防剧透遮罩点击揭开后又恢复 |
| [BUG-583](bugs/BUG-583-global-lookup-flicker-residual.md) | ✅ | ✅ | app 外查词第一个弹窗出现/嵌套子弹窗打开或消失时父卡残留闪烁 + 子弹窗出现被裁一帧再跳进来 |
| [BUG-582](bugs/BUG-582-interconnect-audiobook-shown-as-plain-no-audio-sync.md) | ✅ | ✅ | 互联有声书显示成普通书且音频不同步 |
| [BUG-581](bugs/BUG-581-nonvideo-mine-no-cue.md) | ✅ | ✅ | 普通网页制卡误报没找到当前字幕 |
| [BUG-580](bugs/BUG-580-interconnect-audiobook-rename.md) | ✅ | ✅ | 互联下载有声书 EPUB 落盘 rename 失败中止导入 |
| [BUG-579](bugs/BUG-579-youtube-external-audio-silent-until-seek.md) | ✅ | ✅ | YouTube 分离流初始无声，跳转后才有声（audio-only 音轨在 play 之后才外挂） |
| [BUG-578](bugs/BUG-578-desktop-floating-lyric-global-lookup-blank.md) | ✅ | ✅ | 桌面悬浮字幕点词全局查词覆盖窗空白/不出现 |
| [BUG-577](bugs/BUG-577-ext-highlight-vanish.md) | ✅ | ✅ | 浏览器扩展查词高亮非常容易消失 |
| [BUG-576](bugs/BUG-576-lan-pair-pin-prompt.md) | ✅ | ✅ | LAN配对总弹PIN框但对方无PIN |
| [BUG-575](bugs/BUG-575-remote-audio-404-cooldown.md) | ✅ | ✅ | 可达远端发音源对缺词返回404被误冷却导致app外查词整段无音频 |
| [BUG-574](bugs/BUG-574-ext-shift-hover-lookup.md) | ✅ | ✅ | 浏览器扩展 Shift 悬停查词失效复诉 |
| [BUG-573](bugs/BUG-573-css-editor-row-width.md) | ✅ | ✅ | 阅读器布局子页「编辑书籍 CSS」入口条比上方配置项组宽·左右不对齐 |
| [BUG-572](bugs/BUG-572-app-init-infinite-loading-dataroot-hang.md) | ✅ | ✅ | App 偶发无限加载：自定义数据根掉线盘早期同步 IO 永不返回 |
| [BUG-571](bugs/BUG-571-respect-ass-style-reload.md) | ✅ | ✅ | 尊重字幕自带样式开关重开视频后失效 |
| [BUG-570](bugs/BUG-570-windows-msvcp140-crash-stale-redist.md) | ✅ | ✅ | Windows app crashes at launch (MSVCP140.dll c0000005) on machines with stale VC++ Redistributable |
| [BUG-569](bugs/BUG-569-tls-cover-not-pinned.md) | ✅ | ✅ | TLS 默认开后对端封面空白（Image.network 无法钉扎自签证书） |
| [BUG-568](bugs/BUG-568-chapter-jump-skips-first-page.md) | ✅ | ✅ | 竖排跳章落点错误(章界输入穿透+图片late-load冻结) |
| [BUG-567](bugs/BUG-567-nested-lookup-parent-flicker.md) | ✅ | ✅ | Windows app 外查词嵌套时父弹窗闪烁 |
| [BUG-566](bugs/BUG-566-mobile-seekbar-use-after-dispose.md) | ✅ | ✅ | 移动版进度条 onPointerMove/onPointerUp 拖动中控件销毁后崩溃 |
| [BUG-565](bugs/BUG-565-remote-book-download-rename-notempty.md) | ✅ | ✅ | 远端书下载改名到已存在书目录 ENOTEMPTY 失败 |
| [BUG-564](bugs/BUG-564-dataroot-migrate-moves-whole-documents.md) | ✅ | ✅ | Windows 数据根迁移整树搬移并删除用户整个 Documents（默认根） |
| [BUG-563](bugs/BUG-563-gameinput-dll-missing-startup-crash.md) | ✅ | ✅ | 无GameInput.dll的Windows机器启动即崩 |
| [BUG-562](bugs/BUG-562-ankimobile-background-media-download.md) | ✅ | ✅ | iOS AnkiMobile 视频句音频导入后仍保留 localhost URL |
| [BUG-561](bugs/BUG-561-ankimobile-media-url-plus-payload.md) | ✅ | ✅ | iOS AnkiMobile 制卡音频不播放且词典/详情字段出现加号和本地路径 |
| [BUG-560](bugs/BUG-560-xcode27-ios-deployment-target.md) | ✅ | ✅ | Xcode 27 真机编译失败：iOS deployment target 低于 15.0 |
| [BUG-559](bugs/BUG-559-ankimobile-local-media-fields.md) | ✅ | ✅ | iOS AnkiMobile 制卡本地音频图片未嵌入 |
| [BUG-558](bugs/BUG-558-ankimobile-query-plus-encoding.md) | ✅ | ✅ | iOS AnkiMobile 制卡字段空格显示成加号 |
| [BUG-557](bugs/BUG-557-interconnect-manual-url-scheme.md) | ✅ | ✅ | Hibiki互联手动地址提示HTTPS导致默认HTTP主机无法连接 |
| [BUG-556](bugs/BUG-556-ios-video-topbar-transient-inset.md) | ✅ | ✅ | iOS 视频顶部功能栏偶发位置不准 |
| [BUG-555](bugs/BUG-555-ios-video-controls-tap-anywhere.md) | ✅ | ✅ | iOS 视频画面中部点击无法唤出控制栏 |
| [BUG-554](bugs/BUG-554-ios-hoshidicts-release-export.md) | ✅ | ✅ | iOS release startup fails: hoshidicts_import symbol not found |
| [BUG-553](bugs/BUG-553-subtitle-tap-swallow-controls.md) | ✅ | ✅ | 字幕盒吞掉唤出视频控制条的点击 |
| [BUG-552](bugs/BUG-552-android-clip-export-anr-oom.md) | ✅ | ✅ | 安卓导出片段视频ANR/OOM崩溃 |
| [BUG-551](bugs/BUG-551-dict-result-webview-lower-half-blank.md) | ✅ | ✅ | in-app 查词结果区 WebView 下半屏空白(Windows WebView2/WGC 渲染完 idle 无 damage) |
| [BUG-550](bugs/BUG-550-ffmpeg-715-crash.md) | ✅ | ✅ | ffmpeg 7.1.5 本地构建二进制崩溃破坏视频制卡 |
| [BUG-549](bugs/BUG-549-glookup-overlay-env-conflict.md) | ✅ | ✅ | Windows app-external lookup shows no popup (overlay WebView2 env fails silently) |
| [BUG-548](bugs/BUG-548-update-staging-dir-leak.md) | ✅ | ✅ | Windows 更新 .staging 暂存根目录泄漏堆积 |
| [BUG-547](bugs/BUG-547-progress-frosted.md) | ✅ | ✅ | 悬浮阅读进度无背景看不清 |
| [BUG-546](bugs/BUG-546-theme-card-width.md) | ✅ | ✅ | 设置主题卡与下方配置项不等宽 |
| [BUG-545](bugs/BUG-545-windows-video-black-flash.md) | ✅ | ✅ | Windows 高显卡占用时视频黑屏闪烁 |
| [BUG-544](bugs/BUG-544-clip-context-menu-order.md) | ✅ | ✅ | 移动端导出片段右键菜单项垫底应前置 |
| [BUG-543](bugs/BUG-543-clip-png-decoder.md) | ✅ | ✅ | 有声书片段导出移动端合成失败 ffmpeg-kit min 变体缺 png decoder |
| [BUG-542](bugs/BUG-542-apple-prune-mapfile-bash32.md) | ✅ | ✅ | apple debug release prune 用 mapfile 在 macOS bash3.2 崩(command not found) |
| [BUG-541](bugs/BUG-541-pageheader-narrow-window-icon-clip.md) | ✅ | ✅ | 页头窄窗动作图标被裁切 |
| [BUG-540](bugs/BUG-540-update-404-rolling-prune-race.md) | ✅ | ✅ | 更新下载 404: rolling tag prune 竞态 |
| [BUG-539](bugs/BUG-539-sync-latin1-body.md) | ✅ | ✅ | live sync 日文书名上报 latin1 编码崩 |
| [BUG-538](bugs/BUG-538-mpv-sigmoid-upscaling-default-off.md) | ✅ | ✅ | mpv sigmoid upscaling default on (perf cost) |
| [BUG-537](bugs/BUG-537-windows-video-picture-flicker.md) | 🚧 | 🚧 | Windows video picture layer flickers (subtitle overlay stable) |
| [BUG-536](bugs/BUG-536-popup-longpress-select-too-slow.md) | ✅ | ✅ | 查词弹窗长按选中文字等待时间过长(500ms) |
| [BUG-535](bugs/BUG-535-android-video-noframe.md) | ✅ | ✅ | Android 视频无画面(vo=null/texture not-created) |
| [BUG-534](bugs/BUG-534-updater-stuck-connecting.md) | ✅ | ✅ | Update download stuck on connecting while traffic runs |
| [BUG-533](bugs/BUG-533-updater-installer-not-cleaned.md) | ✅ | ✅ | Windows update installer not deleted after successful install |
| [BUG-532](bugs/BUG-532-pref-null-roundtrip.md) | ✅ | ✅ | PrefCodec 清空 override round-trip 成字面 null |
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
| [BUG-430](bugs/BUG-430-win-ime-shortcut-fallback.md) | 🚧 | 🚧 | Windows IME 激活时全表面快捷键失效 |
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

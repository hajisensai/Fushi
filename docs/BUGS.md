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

> 共 140 条。点号进各自文件。

| BUG | 修复 | 测试 | 标题 |
|---|:--:|:--:|---|
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

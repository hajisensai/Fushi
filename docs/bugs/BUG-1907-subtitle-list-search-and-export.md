## BUG-1907 · 字幕列表缺少搜索（Ctrl+F）与导出收藏语句
- **报告**：2026-08-28（用户：「字幕列表增加搜索（ctrl+F可快捷触发）和导出（导出收藏语句）」）
- **真实性**：✅ 功能缺失（不是坏了，是没有）。

### 现状与两个非显然的坑

`fushi/lib/src/media/video/video_subtitle_jump_panel.dart` 全文没有任何输入框，
全仓视频侧栏都没有搜索。做这个功能有两处不做对就会悄悄失效：

**① 搜索不能用裸 `contains`。** 仓库对「用户可见搜索」有强制口径
（`fushi/lib/src/media/media_search_text.dart` 的 `matchesMediaSearch`，
CLAUDE.md 术语表列为硬性要求）：统一做全角→半角、大写→小写、**片假名→平假名**、
去标点的归一化。对日语字幕这不是锦上添花——用户打「なれーしょん」要能命中
「ナレーション」，裸 `contains` 做不到。

**② Ctrl+F 面板必须自己接一份。** 视频页那张整表快捷键装在 media_kit controls 的
`CallbackShortcuts` 上，**只包住 controls 子树**；而字幕列表是它的**兄弟节点**
（`_videoWithSubtitlePanel` 把 `Row[Expanded(video), 面板列]` 包在 `Video` 外面，
见 `layout.part.dart` 的覆盖面注释）。焦点一旦进了面板（`PanelFocusScope` 挂载即领焦点），
那张表收不到任何按键。只在注册表里加一条绑定是不够的。

另外 video scope 里 Ctrl+F **完全空闲**：同键的 `readerOpenNavigation` /
`homeFocusSearch` 属不同 co-active 组，绝不同时激活（`shortcut_defaults.dart:90` 已有
这条论证）。

### 实现

- **[x] ① 已实现**：
  - 面板加搜索开关（头部第一行，与字号/自动滚动/关闭同族）+ 展开式输入框
    （收起时**完全不占高度**——面板最窄 240px，常驻输入框会实打实吃掉列表可视区）。
    过滤走 `matchesMediaSearch`，与 tab 过滤是「与」的关系。
    搜索词与收藏档同理**绕开可见行缓存**：缓存键是 `(cues 身份, 长度, filter)`，
    边打字边过滤时这三者都不变，命中缓存就等于搜索不生效。
    搜不到时提示「没有匹配的台词」而不是照搬空档文案（后者会让用户以为收藏没了）；
    收起搜索会清空搜索词，否则列表会停在一个用户已看不见输入框的过滤态上。
  - **Ctrl+F 两条路都通**：新增 `ShortcutAction.videoSearchSubtitleList`（默认 Ctrl+F，
    用户可改绑，进设置页快捷键列表）。焦点在播放器上时由整表快捷键接住 → 页面先开列表、
    再经 `_subtitleSearchRequests` 计数器让面板展开搜索框并抢焦点；焦点已在面板内时，
    面板自带的 `CallbackShortcuts` 直接生效。activator **由页面从注册表取出传入**，
    注册表是唯一真相源，用户改绑后两处不会分叉。
  - **导出收藏语句**：收藏档头部（「收藏 N 句」旁）出现导出按钮，无收藏时禁用。
    面板不碰文件 IO——它连 `AppModel` 都没有，落盘/分享要平台分流；只把句子交出去，
    页面层用既有的 `buildSentenceExport` + `saveOrShareExport` 落地（与 `onCopyCue` /
    `onFavoriteCue` 同一条纪律）。导出口径是「收藏档实际渲染的那批」，**与当前搜索词
    无关**——搜索着导出只导搜索结果会是个陷阱。
    顺带把 `collections_page` 的私有 `_sanitizeFileName` 提成导出器里的
    `sanitizeExportFileName`，两处共用一份而不是复制。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_list_search_export_test.dart`
  8 个用例：展开即过滤、片假名/大小写归一化命中、搜不到的专用空态、收起清词、
  面板自带 Ctrl+F、页面层请求通道、导出交出的是收藏句（不受搜索词影响）、无收藏时禁用。
  **变异实测**（2026-08-28）：把 `matchesMediaSearch` 换成裸
  `toLowerCase().contains` → 归一化那条转红。还原后本文件 8 项 +
  video/shortcuts/i18n/导出器共 **3445 项**全绿。

### 备注

- 导出格式固定 Markdown：这是个一键动作，不值得为它再弹一层格式选择框；要挑格式
  （四种）的用户走收藏夹页的导出面板。
- 未做真机复测（Ctrl+F 的实际焦点竞争、以及移动端分享面板需要真设备）。
  widget 层已覆盖两条 Ctrl+F 路径与导出取数口径。

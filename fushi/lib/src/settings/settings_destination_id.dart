enum SettingsDestinationId {
  // 「通用」一级分类：不属于任何一个模块的全局规则——界面与内容语言、键盘与手柄、
  // 学习计时口径、小内存模式与上手引导（settings_schema_general.dart）。
  general,
  appearance,
  // 「导航与首页」一级分类：功能模块开关与底栏顺序、启动页、底栏外形、首页面板、
  // 跳转记录（settings_schema_navigation.dart）。与「外观」分开：这些决定的是
  // 「有哪些页面、怎么到达」，不是长什么样。
  navigation,
  // 「悬浮球」一级分类：应用内 / 应用外开关与各场景按钮的唯一入口
  // （settings_schema_floating_ball.dart）。此前散在查词页与阅读页两处。
  floatingBall,
  profiles,
  reading,
  // 「听书」一级分类：有声书播放、转录与悬浮字幕（settings_schema_listening.dart）。
  // 跟随 listening 模块开关。
  listening,
  // 「漫画」一级分类：漫画阅读器的观看偏好（方向/缩放/翻页）+ 漫画 OCR。原先
  // OCR 组寄生在 reading 末尾、观看偏好则完全不在设置里；漫画与 EPUB 阅读没有
  // 任何共享设置项，故拆成独立大类（见 settings_schema_manga.dart）。
  manga,
  lookup,
  cardCreation,
  // 「本机模型」一级分类：OCR / 语音识别 / 语音合成的本机模型与引擎。漫画与视频
  // 图形字幕共用同一份 OCR 配置，所以它不寄生在任何一个内容分类下。LLM（AI 提供商
  // 与 AI 功能）是独立的一级分类 `ai`。
  models,
  video,
  // 「音乐」一级分类（音乐模块，docs/specs/2026-10-23-music-module-design.md §11.1）：
  // 播放 / 输出 / 识别 / 服务器 / 歌词；来源管理只在曲库页「来源」。与 music 顶层 tab 同门控。
  music,
  mediaTracking,
  // 「下载」一级分类：torrent / qBittorrent 后端配置从下载页齿轮抬进设置主页
  // （可达 + 可搜）。位置紧随视频/听，在同步备份之前。
  downloads,
  // 「在线服务」一级分类：第三方 API / 索引器 / 媒体服务器的凭据与端点
  // （Jimaku、OpenSubtitles、Torznab、内置索引器、发现来源、Jellyfin/Emby、AniDB、
  // TMDB、Dandanplay 服务器）唯一的家。此前按「服务于哪个媒介」散在视频/下载两
  // 页，同一组件甚至双挂载；用户配完一处不知道另一处还有（BUG-1712 的真根因）。
  // 本机后端（qBittorrent）、云盘备份后端、Anki/Yomitan 是各自域的核心，不归此。
  services,
  // 「本机服务」一级分类：Fushi 对外开放的本机 HTTP 服务（Fushi API / yomitan-api /
  // AnkiConnect 兼容端点）的开关、允许谁连、端口与密钥（settings_schema_local_services）。
  // 此前寄生在「查词 › 外部集成」，监听范围与端口没有任何入口。
  localServices,
  // 「游戏」一级分类（审计 K/Phase 3.12）：游戏库 / 捕获工作台 / 兼容性诊断此前
  // 完全没有 settings destination，页面与其中配置项不可搜。与 games 顶层 tab
  // 同门控（仅 Windows，galgame hook 平台边界）。
  game,
  // 「AI」一级分类：提供商与「哪个功能用哪家」的映射、AI 助手、MCP 外部访问与各
  // AI 功能的单独配置。跟随 ai 模块开关，见 module_registry.dart。
  ai,
  // 「浏览器」一级分类：内置浏览器、广告拦截与网页查词 / 字幕
  // （settings_schema_web_browser.dart）。
  webBrowser,
  // 「主屏幕小组件」一级分类（仅 Android，settings_schema_widgets.dart）：小组件读的每日
  // 目标、默认隐私与添加方法。
  widgets,
  syncBackup,
  // 「存储」一级分类：磁盘占用总览（书/词典单条删除）+ 可选模块（OCR 模型 /
  // Anime4K 着色器删除恢复）+ 随包组件展示（构建函数在 settings_schema_storage.dart）。
  storage,
  system,
  // Fushi P2P 互联（设备直连 + 本机作为服务器）；从 syncBackup 拆出的
  // 独立一级分类（构建函数在 sync_settings_schema.dart 同库，共享私有状态）。
  interconnect,
  // Synthetic destination for the reader quick-settings dialog; its own id so
  // it never collides with the real reading destination (HBK-AUDIT-131).
  readerQuickSettings,
  // Synthetic destination for the pushed app-icon sub-page
  // (MiscellaneousSettingsPage)；own id so the shell no longer borrows
  // `appearance` for content that isn't the appearance destination.
  appIcon,
  // Synthetic destination for the in-video quick-settings sheet; its own id so
  // it never collides with the real video destination（与 readerQuickSettings
  // 同款约定）。
  videoQuickSettings,
  // Synthetic destination for the pushed shortcut-settings page
  // (ShortcutSettingsPage)；own id so the shell no longer borrows `system` for
  // content that isn't the system destination（与 appIcon 同款约定）。
  shortcuts,
}

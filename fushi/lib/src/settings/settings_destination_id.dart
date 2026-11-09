enum SettingsDestinationId {
  appearance,
  // 「悬浮球」一级分类：应用内 / 应用外开关与各场景按钮的唯一入口
  // （settings_schema_floating_ball.dart）。此前散在查词页与阅读页两处。
  floatingBall,
  profiles,
  reading,
  // 「漫画」一级分类：漫画阅读器的观看偏好（方向/缩放/翻页）+ 漫画 OCR。原先
  // OCR 组寄生在 reading 末尾、观看偏好则完全不在设置里；漫画与 EPUB 阅读没有
  // 任何共享设置项，故拆成独立大类（见 settings_schema_manga.dart）。
  manga,
  lookup,
  cardCreation,
  // 「模型」一级分类（2026-10-13 用户拍板）：LLM / OCR / 语音转录 / 语音合成 / 模型
  // 文件的唯一的家。此前 OCR 寄生在漫画、模型文件在存储、LLM（原「AI」）在连接组，
  // 视频图形字幕却和漫画共用同一份 OCR 配置，用户找不到。原 `ai` 分类降为本页的
  // 「LLM」子页，枚举值保留（模块门控与入口可见性判据仍按它问）。
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
  // 「AI」一级分类：用户自配的大模型提供商（端点/凭据/模型/协议）与「哪个功能用
  // 哪家」的映射。归在 services 模块下（同 Jimaku / OpenSubtitles / Torznab 一类
  // 第三方在线服务），见 module_registry.dart。
  ai,
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

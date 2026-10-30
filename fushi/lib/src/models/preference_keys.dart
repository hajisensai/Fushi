/// Preferences 表键注册表（数据层重构 2026-08 P2，见
/// docs/design/data-layer-refactor-2026-08.md）。
///
/// `preferences` 是一张 `(key TEXT PK, value TEXT)` 万能表，键此前以 ~140 个
/// 裸字符串字面量散落全代码库——无集中定义、无类型注解、拼错键名静默读到默认值。
/// 本文件是**唯一的新增键入口**：守卫测试
/// （test/models/preference_keys_guard_test.dart）扫描 `getPref*/setPref*`
/// 调用点的字面量键，不在 [kKnownPreferenceKeys] 里的直接红。
///
/// 纪律：
///  - **新增键必须先登记**：加进 [kKnownPreferenceKeys]（按字母序插入），并在
///    调用点旁注释类型与用途。存量键冻结（改名 = 数据迁移，别随手动）。
///  - **动态键（前缀 + 运行时后缀）**不在守卫扫描面内（字面量含 `$` 即跳过），
///    但前缀必须登记进 [kKnownPreferenceKeyPrefixes] 供人查阅。
///  - 🔴 凭据键（[kCredentialPreferenceKeys] 与 `media_source_secret_` 前缀）：
///    值是 base64 的敏感凭据，**绝不写日志、绝不进明文导出**（红线与
///    MediaSources.configJson / FushiPairedPeers.token 同源）。
library;

/// 「绑定切换前」用户自己选的 Profile id（int，缺失 = 无）。与
/// `active_profile_id` 同族，不进 Profile 快照；值是**本库**自增 id，换库即失效，
/// 所以合并导入接管源库偏好时不带它（见 `BackupMergeEngine`）。
const String kProfileFallbackIdPrefKey = 'profile_fallback_id';

/// Anki 制卡设置（整份 `AnkiSettings` JSON，String）。原先存在 SharedPreferences
/// `fushi_anki_settings`，迁进 Drift 是为了让 `:popup` 进程 / 悬浮词典与主 app
/// 读到同一份（见 `anki_settings_drift_store.dart`）。含 AnkiConnect apiKey 明文 →
/// 凭据 + 设备本地：不进备份 / 同步 / Profile 快照（牌组、映射等字段由
/// `ProfileKeys.ankiSettingsToMap` 按字段随 Profile 走，与迁移前一致）。
const String kAnkiSettingsPrefKey = 'anki_settings';

/// 库页顶部页签的用户自定义顺序（反馈 ndQ5eXLcqp），后缀 = 页签栏的 orderKey
/// （`video` / `book-library-view` / …），值是逗号分隔的页签 id（见
/// `section_tab_order.dart`）。入口布局，与底栏模块顺序同族：设备本地，不进
/// Profile 快照（ProfileKeys._excludedPrefPrefixes）。
const String kSectionTabOrderPrefKeyPrefix = 'section_tab_order::';

/// 库页「手动」排序的顺序（排序模式里拖出来的），后缀 = 库（`book` / `manga` /
/// `video` / `game`），值是换行分隔的单元 tieKey（`encodeShelfManualOrder`）。
/// 与页签顺序同族：设备本地，不进 Profile 快照（ProfileKeys._excludedPrefPrefixes）。
const String kLibraryManualOrderPrefKeyPrefix = 'library_manual_order::';

/// 查词弹窗「我库里的例句」开关（bool，默认 true：全在本机、不上传，所有者 D-L2）。
const String kLibrarySentencesEnabledPrefKey = 'lookup_library_sentences';

/// 已知的静态偏好键全集（守卫强制）。按字母序。
const Set<String> kKnownPreferenceKeys = <String>{
  'active_profile_id',
  // bool（默认 false）：本机当互联 host 时，是否允许已配对设备经 `/api/assistant`
  // 远程使用 AI 助手（会用本机的 AI 指派、调本机操作目录）。与服务端
  // `ai.agent_for_peers` 同一判据：默认关、用户在设置里亲手打开（设备本地）。
  'ai_agent_for_peers',
  // 「哪个功能用哪家 AI」的映射。不含凭据，但跟着 ai_providers 一起设备本地：
  // providers 不跨设备，映射跨过去只会指向一个不存在的 id。
  'ai_feature_providers',
  // String（JSON map）：AI 多 key 轮换的冷却记录 `{指纹: {until, failures,
  // reason}}`。指纹是 sha256(providerId + key) 的前 16 位，不含 key 本身，非凭据；
  // 但描述的是本机配的 key 的健康，跟着 ai_providers 设备本地（deviceLocalPrefKeys）。
  'ai_key_health',
  // 用户自配的 AI 提供商清单，每条里带 base64 的 apiKeyB64 →
  // 同时登记在 kCredentialPreferenceKeys、PrefRedactionPolicy.sensitiveKeys
  // 与 deviceLocalPrefKeys。
  'ai_providers',
  // String：「AI 下视频」的码率偏好（只排序）。`''` 不限 / `high` 高码率优先 /
  // `low` 小体积优先。非凭据、跨设备。
  'ai_video_download_bitrate',
  // String：「AI 下视频」的默认画质。`''` 未设置（首次使用时问并按勾选写回）/
  // `ask` 每次询问 / `best` 最高可用 / `2160p` `1440p` `1080p` `720p` `480p` /
  // `any` 固定档。非凭据、跨设备。
  'ai_video_download_quality',
  // String：「AI 下视频」的片源偏好（只排序）。`''` 不限 / `best` 最佳 /
  // `bluray` 蓝光优先 / `web` 网络源优先。非凭据、跨设备。
  'ai_video_download_source',
  // String：「AI 下视频」的字幕语言。`''` 未设置 / `ask` 每次询问 / `original`
  // 跟随作品语言 / `ja` 等语言码 / `none` 不配字幕。非凭据、跨设备。
  'ai_video_download_subtitle_language',
  // String（JSON 数组）：AI 联网资料里用户自加的 MediaWiki 站点
  // `[{id: 'custom:…', label, endpoint: 'https://…/api.php'}]`。只是公开网址，
  // 非凭据、跨设备。
  'ai_web_knowledge_custom_sites',
  // String：AI 联网资料**关掉**的站点 id，逗号分隔（内置 `moegirl` 等 + 自定义
  // `custom:…`）。从未写过 = 全开（或按旧键迁移）；新增的内置站默认开。非凭据、跨设备。
  'ai_web_knowledge_disabled_sites',
  // String：旧版（只有三个维基时）启用的站点 id。只读迁移用，新版不再写。
  'ai_web_knowledge_sources',
  // String（AnkiSettings JSON）：见 [kAnkiSettingsPrefKey]。凭据 + 设备本地。
  kAnkiSettingsPrefKey,
  'app_locale',
  'app_ui_scale',
  'asr_transcribe_language',
  'audio_source_configs',
  'audio_sources',
  // bool：只有音频（没有字幕）的有声书下载完成后，自动用设备端语音模型转录
  // 并入库（有正文对齐、没有成独立字幕书）。默认开；关掉 = 改前行为（任务
  // 停在「缺字幕」，用户手动配对）。见 media/audiobook/audiobook_auto_transcribe.dart。
  'audiobook_auto_transcribe',
  'audiobook_background_play',
  // bool：有声书导入时音频「引用原文件」而不是复制进应用目录（两个导入对话框
  // 共用）。默认 false。见 PreferencesRepository.audiobookImportReferenceOriginal。
  'audiobook_import_reference_original',
  // int 秒（15..1800，默认 120）：有声书「返回原位置」跳转距离——显式音频 seek 挪动
  // 至少这么远才进跳转回退历史（反馈 0AwuVqrNFn）。普通偏好，随 Profile / 备份走。
  'audiobook_jump_threshold_sec',
  // String（JSON 数组）：有声书素材库目录（绝对路径）。库里放按作品身份命名的
  // 字幕/正文文件，下载完成后据此自动配齐「正文 + 字幕 + 音频」。见
  // media/audiobook/audiobook_material_library.dart。
  'audiobook_material_dirs',
  // bool（默认 false）：是否把 Audiobookshelf 收听中条目混排进首页「继续」（显式
  // opt-in，与 jellyfin_show_in_library 同原则，同样是普通偏好）。
  'audiobookshelf_show_in_home',
  'auto_add_book_name_to_tags',
  // bool：小说阅读器制卡时给卡片追加「制卡所在字符数」标签（`chars_12345`，
  // countStudyChars 口径的全书绝对位置）。默认开。
  'auto_add_char_position_to_tags',
  'auto_search',
  'auto_search_debounce_delay',
  'auto_update_dictionaries',
  // bool：「下载」改名「浏览」的一次性搬迁提示已处理（弹过，或判定本安装不需要
  // 弹）。描述本安装的状态，与 first_time_setup 同族、不随 Profile 走。
  'browse_moved_notice_handled',
  'clipboard_panel_block_capture',
  'collapse_dictionaries',
  'collapsed_collection_ids',
  'compress_mining_media',
  'current_home_tab_index',
  'custom_dict_css',
  'deduplicate_pitch_accents',
  // String（BCP-47，如 'ja' / 'zh-Hant'；空串 = 未设置）：全局默认内容语言。
  // 内容字体链优先级的第三档，兜在「资源手动指定 > 内容自带元数据」之后。
  'default_content_language',
  'design_system',
  'dictionary_entry_font_size',
  'dictionary_update_interval',
  // 用户自配的 AList / OpenList 站点清单（JSON 数组：id/name/url/kinds/
  // username/passwordB64/enabled/allowInsecureHttp）。String，读写见
  // PreferencesRepository。与 discovery_opds_servers 同形、同隔离纪律。
  'discovery_alist_sites',
  // 用户自配的 Audiobookshelf 服务器清单（JSON 数组：id/name/url/username/
  // accessTokenB64/refreshTokenB64/enabled/allowInsecureHttp）。String，读写见
  // PreferencesRepository。不存密码，只存令牌；refresh token 轮换后由
  // AppModel.persistAudiobookshelfTokens 写回。与 discovery_opds_servers 同隔离纪律。
  'discovery_audiobookshelf_servers',
  // 发现页「全部源」聚合排除的内置源 id（逗号分隔，默认空）。String，读写见
  // PreferencesRepository。用户 BT 站展开的发现源各自带 enabled，不进这里。
  'discovery_disabled_sources',
  // bool（默认 true）：发现页隐藏疑似漫画（`DiscoveryContentHint.manga`）的
  // 条目；undecided 保留。读写见 PreferencesRepository。
  'discovery_hide_suspected_manga',
  // bool（默认 true）：发现页隐藏 0 做种的种子条目。读写见 PreferencesRepository。
  'discovery_hide_zero_seeders',
  // int（0 全部 / 1 排除 remake / 2 仅 trusted，默认 0）：发现页 Nyaa 过滤三态，
  // 透传为 nyaa `f`。读写见 PreferencesRepository。
  'discovery_nyaa_quality_filter',
  // 用户自配的 OPDS 书目服务器清单（JSON 数组：id/name/url/username/
  // passwordB64/enabled/allowInsecureHttp）。String，读写见
  // PreferencesRepository。与 discovery_disabled_sources 的分界同 Torznab：
  // 自配服务器各自带 enabled 字段，不进那份停用清单。
  // 含凭据 → 同时登记在 kCredentialPreferenceKeys 与 deviceLocalPrefKeys。
  'discovery_opds_servers',
  'download_save_root',
  'download_save_root_history',
  'experimental_focus_navigation_enabled',
  'extension_popup_independent_size',
  'extension_popup_max_height',
  'extension_popup_max_width',
  // bool，默认 true：「反馈有新回复时通知我」。开 = 移动端排后台检查（WorkManager /
  // BGTaskScheduler）、桌面运行中定时检查，新回复发系统通知；关 = 撤掉后台任务、
  // 不发系统通知（应用内提示照常）。见 feedback_reply_alerts.dart。
  'feedback_reply_notifications',
  'first_time_setup',
  // 悬浮球（docs/specs/2026-09-28-floating-ball.md）。`.actions` / `.mode` 是
  // 旧版单份全局按钮 / 三态模式，只作迁移读取；新值是 `.in_app` / `.system`
  // 两个 bool 开关、每场景一份的 `.buttons.<场景>`（逗号分隔按钮 id）与关闭后
  // 自动恢复的三态 `.auto_restore`。
  'floating_ball.actions',
  'floating_ball.auto_restore',
  'floating_ball.buttons.general',
  'floating_ball.buttons.manga',
  'floating_ball.buttons.reader',
  'floating_ball.buttons.system',
  'floating_ball.buttons.video',
  'floating_ball.dock',
  'floating_ball.in_app',
  'floating_ball.mode',
  // bool：展开按钮旁显示文字，默认 true；保留 tooltip / 无障碍名称。
  'floating_ball.show_labels',
  'floating_ball.system',
  // 桌面应用外悬浮球的停靠边（String）与纵向比例（double），与应用内球的
  // `.dock` / `.y` 分开存：两颗球可以同时在。
  'floating_ball.system_dock',
  // bool：应用外悬浮球菜单里有没有「打开 Fushi」，默认 true。
  'floating_ball.system_open_app',
  'floating_ball.system_y',
  // String：Android 应用外悬浮球收起态点一下做什么（FloatingBallTapAction：
  // '' 展开 / clipboard / screen_ocr），非展开时长按才展开。没写过时沿用下面的旧键。
  'floating_ball.tap_action',
  // bool（旧，只读作迁移）：收起态点球 = 查剪贴板，已由 tap_action 取代。
  'floating_ball.tap_clipboard',
  'floating_ball.y',
  'floating_lyric_bg_opacity',
  // bool：悬浮字幕粗体（默认 true）。
  'floating_lyric_bold',
  'floating_lyric_button_bg_opacity',
  'floating_lyric_click_lookup',
  // int ARGB，0 = 跟随主题：底 / 非当前句字 / 当前句字 / 描边。
  'floating_lyric_color_background',
  'floating_lyric_color_current',
  'floating_lyric_color_outline',
  'floating_lyric_color_text',
  // 旧「上下文行数 N」，只作 floating_lyric_visible_lines 未写时的迁移来源。
  'floating_lyric_context_lines',
  // int 0..100：多行时非当前句不透明度。
  'floating_lyric_context_opacity',
  'floating_lyric_corner_radius',
  'floating_lyric_font_size',
  // double：字距 / 行高 / 描边宽。
  'floating_lyric_letter_spacing',
  'floating_lyric_line_height',
  'floating_lyric_outline_width',
  // int：水平对齐（0 居中 / 1 左）、文字内边距。
  'floating_lyric_text_alignment',
  'floating_lyric_text_opacity',
  'floating_lyric_text_padding',
  // bool：竖排（Windows 原生窗）。
  'floating_lyric_vertical',
  // int 0..15：同时显示句数（0 = 按窗口高度自动）。
  'floating_lyric_visible_lines',
  'floating_lyric_width',
  // String JSON：Windows 悬浮字幕窗口矩形（物理 px）。
  'floating_lyric_window_rect',
  // String：Fushi API「允许谁连」（FushiApiAccessMode.wireName），缺省 `lan`。
  'fushi_api_access_mode',
  // String：「指定网段」模式的白名单原文（每行一个 IP / CIDR），非凭据。
  'fushi_api_allowed_networks',
  'gal_card_lookup_independent_size',
  'gal_card_lookup_max_height',
  'gal_card_lookup_max_width',
  'gal_hook_click_lookup',
  'gal_hook_fold_progressive_lines',
  'gal_hook_ingame_lookup_enabled',
  'gal_hook_lookup_trigger',
  'gal_hook_passthrough_blocks_mouse',
  'gal_hook_text_alignment',
  'gal_hook_text_background_color',
  'gal_hook_text_bold',
  'gal_hook_text_color',
  'gal_hook_text_corner_radius',
  'gal_hook_text_font_size',
  'gal_hook_text_letter_spacing',
  'gal_hook_text_line_height',
  'gal_hook_text_outline_color',
  'gal_hook_text_outline_width',
  'gal_hook_text_padding',
  'gal_hook_text_vertical_alignment',
  'gal_hook_text_window_bg_opacity',
  'gal_hook_toolbar_auto_hide',
  'gal_hook_toolbar_labels',
  'gal_mining_animated_format',
  'gal_mining_clip_format',
  'gal_mining_image_mode',
  'gal_mining_still_format',
  'galgame_library',
  'galgame_library_view',
  // bool：第三方游戏资源站下载前的风险说明勾了「不再提示」（download_notice.dart）。
  'game_resource_notice_dismissed',
  'games_collapsed_collection_ids',
  // String（默认 'grid'）：游戏库主体布局，'grid' 海报网格 / 'list' 分段卡列表。
  // 页头切换钮写入，跨会话记住。
  'games_library_layout',
  'global_dict_css',
  'harmonic_frequency',
  // String（JSON 数组，默认空）：书架上「仅从本机移除」的远端书（反馈 nvlhtczbro），
  // 元素是 `HiddenRemoteBook` 的 JSON（来源身份 / 互联对端身份 / 远端身份键 / 书名）。设备本地（见
  // SyncRepository 的设备本地清单）：别的设备恢复备份不该把这台的隐藏带过去。
  'hidden_remote_books',
  // String（JSON map，默认空）：首页 dashboard 各面板的显示档 `{面板 id: auto /
  // shown / hidden}`，缺省 = auto（按面板自己的默认判据）。见
  // models/home_dashboard_panel.dart 的 [HomeDashboardPanel]。随 Profile 走。
  'home_dashboard_panels',
  // bool（默认 true，BUG-1891）：进视频页时是否自动向 Jellyfin/Emby 服务器枚举
  // 条目。几十万条目的公共 Emby 服上自动枚举会被当成爬虫，关掉后改由下拉刷新手动触发。
  'jellyfin_auto_list_videos',
  // bool（默认 false）：是否把媒体服务器条目混排进首页 / 系列 / 全部视频。默认只在
  // 「媒体服务器」分区按服务器自己的树浏览；混排是显式 opt-in，因为它意味着整库
  // 拍平枚举（BUG-1891 的根源），`jellyfin_auto_list_videos` 只在它开着时才有意义。
  'jellyfin_show_in_library',
  'jimaku_api_key',
  'jimaku_default_language',
  // bool（默认 true）：Jimaku 是否参与字幕搜索。与 jimaku_api_key 组成
  // `enabled && key` 双门控（对齐 OpenSubtitles）。默认 true 是兼容存量：
  // 本键出现之前「填了 key」即启用，默认 false 会让存量用户升级后失效。
  'jimaku_enabled',
  'jimaku_pref_langs',
  // Kavita 漫画每章「上次成功同步」时刻（JSON 对象 `"<bookUid>|<chapterKey>" →
  // epoch 毫秒`）。String，读写见 kavita_manga_sync.dart；设备本地，不含凭据。
  'kavita_manga_sync_state',
  // 用户自配的 Kavita 服务器清单（JSON 数组：id/name/url/apiKeyB64/enabled/
  // allowInsecureHttp）。String，读写见 PreferencesRepository。apiKey 是长期凭据，
  // 与 discovery_opds_servers 同隔离纪律。
  'kavita_servers',
  'last_dictionary_update_at',
  'last_selected_deck',
  'last_selected_dictionary_format',
  'last_selected_model',
  // String（JSON 字符串数组）：AI 整理库里本机「允许再次建议」的被拒分组键。拒绝本身
  // 跨端同步（删除哨兵），放行只对点它的设备成立——放行后再建出的同键合集会让这个
  // 分组在每台设备上自然解除拒绝（设备本地）。
  'library_organize_allowed_keys',
  // bool（默认 false）：AI 整理库「导入后自动整理」（设备本地：按量计费的同意只对
  // 点它的那台设备成立；只在一台设备上开就够，结果靠同步传播）。
  'library_organize_auto',
  // int（毫秒，0 = 没开过）：最近一次打开自动整理的时刻。自动整理只看此后新入库的
  // 条目，打开开关不会把整个库发给 AI（设备本地）。
  'library_organize_auto_since',
  // bool（默认 false）：用户点过 AI 整理的「会发送什么」说明并同意（设备本地）。
  'library_organize_consented',
  'local_audio_db_display_name',
  'local_audio_db_path',
  'local_audio_dbs',
  'lookup.global_context_capture',
  'lookup.ime_language',
  // bool（默认 false）：已删除的「查词时让 AI 按句意挑词条」开关（2026-10-09
  // 所有者拍板移除）。存量键冻结、不再读写；留在这里只为键名不被别的功能复用。
  'lookup_ai_context_auto',
  // bool（默认 true，D-L2）：查词弹窗「我库里的例句」区块（作品图谱 L4）。关掉时弹窗不渲染、
  // 也不再往语料库喂入（索引留在本机，再开时增量补齐）。常量 [kLibrarySentencesEnabledPrefKey]。
  'lookup_library_sentences',
  // bool（默认 true = 原行为）：进入查词页（导航点「查词」）以及清空查询后自动
  // 聚焦搜索框、弹出软键盘（反馈 cczhbM7ZOI）。关掉后只有用户点搜索框才弹。
  'lookup_page_auto_show_keyboard',
  // bool（默认 false，桌面端）：查词页按「返回上一级」直接最小化主窗（一键收窗
  // 回到之前的程序），不走关弹窗 → 清查询的阶梯。
  'lookup_page_escape_minimizes_window',
  // bool（默认 true = 原行为）：查词结果滚到顶后继续下拉 = 清空查询、回到搜索
  // 历史（反馈 3D-JH966Kr）。关掉后下拉不再清空。
  'lookup_page_pull_to_clear',
  'low_memory_mode',
  // String（`MangaBackground.key`，默认 `black`）：页图周围留白的底色。
  'manga_background',
  // bool（默认 true）：漫画章节列表新→旧（源顺序）；false = 第 1 话在前。作品页与
  // 阅读器章节抽屉共用。
  'manga_chapter_list_newest_first',
  // bool（默认 true）：漫画阅读器顶栏悬浮（不占布局、点页面中央/顶边悬停唤出）
  // 还是常驻钉在页图上方。
  'manga_chrome_floating',
  // 漫画阅读器工具栏按钮布局 JSON（MangaControlLayout，v1 槽位表；空 = 出厂布局）。
  'manga_control_layout',
  // 窄窗（手机竖屏）漫画按钮布局 JSON（同形；空 = 沿用宽窗那份）。
  'manga_control_layout_compact',
  // int（天，BUG-2450）：在线漫画封面磁盘缓存的保留天数（Mihon 封面缓存
  // MihonCoverCache.maxAge）。默认 180，范围 30..360。
  'manga_cover_cache_max_age_days',
  // bool（默认 false）：作品页「完成后自动识别」chip——章节下载任务入队时写进
  // `manga_download_jobs.auto_ocr`，下载完成钩子据此起整卷 OCR（设计稿 2026-09-12 §5）。
  'manga_download_auto_ocr',
  'manga_external_mokuro_path',
  // bool（默认 false）：一键制卡的卡图默认裁到查词那句话所在的分镜（需分镜模型，
  // 非条漫；否则整页）。与「分镜导航」开关无关。
  'manga_mining_crop_to_panel',
  'manga_ocr_ai_mode',
  'manga_ocr_engine_preference',
  'manga_ocr_lens_language',
  'manga_ocr_local_model',
  'manga_ocr_paired_host_model',
  'manga_ocr_parallel_tasks',
  'manga_online_catalog_base_url',
  'manga_online_catalog_enabled',
  'manga_page_animation',
  // String（`PageTurnAnimationSpeed.key`，默认 `normal`）：漫画翻页动画速度。
  'manga_page_animation_speed',
  // bool（默认 true）：单 / 双页模式滑动翻页逐帧跟手。
  'manga_page_turn_follow_drag',
  // bool（默认 false）：启用本地 AI 分镜检测与逐分镜导航。
  'manga_panel_navigation',
  // String（JSON）：漫画阅读器的全局默认偏好（布局/缩放/裁边/点击区等，
  // MangaReaderPreferences 序列化）。每作品覆盖落 manga_reader_overrides 表。
  'manga_reader_preferences',
  'manga_reading_direction',
  // String（`MangaResumeTarget.key`，默认 `furthest`）：在线漫画重新打开时回到
  // 进度（读完过的章跳过）还是最后停下的那一页（`last`）。
  'manga_resume_target',
  // int（默认 1）：跨页配对的整体偏移，用来把「封面独占一页」这类错位掰回来。
  'manga_spread_offset',
  'manga_spread_preference',
  // String（`MangaTapZoneLayout.key`，默认 `left_right`）：点击翻页热区布局。
  'manga_tap_zone_layout',
  'manga_tap_zone_paging',
  'manga_volume_key_paging',
  // bool（默认 true）：宽页（w/h >= 1）在双页模式下独占一屏，不塞进半个槽位。
  'manga_wide_page_solo',
  'manga_zoom_percent',
  'manga_zoom_sensitivity',
  'maximum_terms',
  // bool（默认 false）：启动时在后台把签名未变的 Mihon 漫画 / 视频扩展更新到
  // 仓库新版（`kMihonExtensionAutoUpdatePref`，update_probes.dart）。
  'mihon_extension_auto_update',
  // bool（默认 true）：制卡提示——查重拦下（「重复卡片，未导出」）时弹 toast
  // （反馈 aK5wv0CnWf）。失败与「成功但缺音频」不受开关影响。
  'mine_notice_duplicate',
  // bool（默认 true）：制卡提示——成功 / 制卡中 / 已存入待发卡片的 toast
  // （反馈 zNuGKLIhmT：阅读时挡住正文）。
  'mine_notice_success',
  'mine_to_server',
  // bool（默认 false = 循环）：制卡动图（视频 cue / galgame 窗口，GIF·WebP·AVIF）只播放
  // 一次（反馈 ZxyIMK-C5V）。经 `miningAnimatedPlayOnceReader` 交给 ffmpeg 的 `-loop`。
  'mining_animated_play_once',
  // 有声书倍速制卡：句子音频跟随播放倍速（默认开）。
  'mining_audio_follow_playback_speed',
  // #1447：制卡句子音频头/尾 padding（asbplayer 式），两条链共用。
  'mining_audio_head_pad_ms',
  'mining_audio_quality',
  'mining_audio_tail_pad_ms',
  // 封面模式迁到片段默认的一次性标记（历史键名），见
  // PreferencesRepository.settleMiningImageModeInstallDefault。
  'mining_image_mode_install_default',
  'mining_image_quality',
  // String（MiningTtsFallbackVoice.wire：'system' 默认 / 'none' / 'preset:<id>'）：
  // 制卡单词音频的 TTS 兜底声音。值可能指向本机声音预设，与 tts_active_preset_id
  // 同族：设备本地（deviceLocalPrefKeys），不进 Profile 快照 / 备份 / 同步。
  'mining_tts_fallback_voice',
  'module_books_enabled',
  'module_browser_extension_enabled',
  'module_dictionaries_enabled',
  'module_downloads_enabled',
  'module_games_enabled',
  // bool（默认 true）：「功能模块」里的首页 dashboard 开关（2026-10-09 起可关）。
  'module_home_enabled',
  'module_manga_enabled',
  'module_music_enabled',
  'module_video_enabled',
  // String（默认 ''）：用户自填的 AcoustID 应用 API key（音乐刮削 §8.1；空 = 用内置 key
  // `kBuiltinAcoustidApiKey`，两者都空 = AcoustID 不可用）。凭据：同时登记在
  // kCredentialPreferenceKeys 与 PrefRedactionPolicy.sensitiveKeys。
  'music_acoustid_api_key',
  // String（默认 'auto'）：音乐输出设备（mpv audio-device 名；设备本地）。
  'music_audio_device',
  // int（默认 0 = 关）：交叉淡入时长毫秒（设计 §7.2）。
  // bool（默认 false）：专辑连续曲目 / CUE 拆轨也交叉淡入（设计 §7.2）。
  'music_crossfade_continuous',
  'music_crossfade_ms',
  // bool（默认 false）：桌面歌词（Android 悬浮窗 / Windows 置顶穿透窗，设计 §6.2）。
  'music_desktop_lyrics',
  // int（默认 176400）：DSD → PCM 目标采样率 Hz（设计 §7.1）。
  'music_dsd_pcm_rate',
  // bool（默认 false）：图示均衡器开关（P5，可选；开且不平直即非 bit-perfect）。
  'music_eq_enabled',
  // String（逗号分隔 10 段 dB，默认 '' = 平直）：图示均衡器各段增益（31 Hz … 16 kHz）。
  'music_eq_gains',
  // bool（默认 false）：独占 / bit-perfect 输出（设计 §7.4；设备本地）。
  'music_exclusive_output',
  'music_gapless',
  // String（默认 'auto'）：卡拉 OK 字幕页 ASS 歌词默认显示 auto / original / structured
  // （音乐 P3，设计 §6.3；MusicAssRenderPreference.prefValue）。
  'music_karaoke_ass_render',
  // bool（默认 false）：听歌计入学习时长（决策 D4；关着时只在歌词页学习动作后计）。
  'music_listening_counts_as_study',
  // bool（默认 true）：缺 ReplayGain 标签时后台 EBU R128 测响度写曲库（设计 §7.3）。
  'music_loudness_scan',
  // bool（默认 true）：歌词页流体背景动态流动；false = 静态（只渲染一次，更省电）。
  // 设备本地观感偏好（MusicLyricsBackdrop）。
  'music_lyrics_backdrop_animate',
  // double（默认 1.0，0.5–2.0）：歌词页流体背景饱和度倍数。
  'music_lyrics_backdrop_saturation',
  // String（默认 'mesh'）：歌词页流体背景算法 pixi / mesh / classic
  // （MusicLyricsBackdropStyle.prefValue）。
  'music_lyrics_backdrop_style',
  // String（默认 'split'）：歌词页布局 split（左封面右歌词）/ stage（歌词居中 +
  // 底部停靠条）/ disc（唱片 + 一行歌词）。设备本地观感偏好。
  'music_lyrics_layout',
  // bool（默认 true）：查歌词时自动暂停（音乐 P1 歌词页）。
  'music_lyrics_lookup_pause',
  // bool（默认 true）：锁屏 / 媒体通知副标题显示当前歌词行（设计 §6.2）。
  'music_lyrics_media_session',
  // bool（默认 true）：本地没有歌词时去 LRCLIB 精确匹配（设计 §5.4 / D3）。
  'music_lyrics_online',
  'music_replaygain',
  // double（默认 0）：ReplayGain 预放大 dB（设计 §7.3）。
  'music_replaygain_preamp_db',
  // String（JSON 数组，serverId）：混排进本地曲库的服务器（服务器曲库 P5，显式 opt-in）。
  // 服务器配置本身设备本地，这份也设备本地（deviceLocalPrefKeys）。
  'music_server_library_mix',
  // int（kbps，默认 0 = 原样直出）：服务器曲库的码率上限，非 0 时请服务器转码。跨设备。
  'music_server_max_bitrate',
  // double（默认 1.0）：音乐播放速度（变速不变调）。
  'music_speed',
  // String（JSON 数组）：用户自配的 OpenSubsonic 服务器（服务器曲库 P5），每条里带
  // base64 的密码 / API key → 同时登记在 kCredentialPreferenceKeys、
  // PrefRedactionPolicy.sensitiveKeys 与 deviceLocalPrefKeys。
  'music_subsonic_servers',
  // bool（默认 false）：VGMdb 补充（社区镜像 vgmdb.info，无官方 API，频率保守、可关）。
  'music_vgmdb_enabled',
  // double（默认 100）：音乐软件音量（100 = 不改样本）。
  'music_volume',
  // bool（默认 true）：MD3 悬浮底栏图标下是否显示标签。
  'nav_bar_labels_visible',
  // String（默认 '' = AdaptiveNavBarStyle.defaultStyle，2026-10-23 起 mode_strip）：
  // 手机底栏形态 flat / pager / dial / shelf / drum / fan / mode_strip
  // （AdaptiveNavBarStyle.prefValue）。
  'nav_bar_style',
  // String：宽屏主导航 rail 手动展开 / 收起（'' 跟随窗口尺寸 / expanded /
  // collapsed）。描述本机窗口布局，不进 Profile 快照。
  'nav_rail_expanded',
  // String：全局公网出口模式 auto / direct / manual（BUG-1980）。
  'network_proxy_mode',
  // bool：P2P（torrent）传输是否也走全局代理（旧键，冻结；三态 mode 键未写过
  // 时作迁移来源，setP2pProxyMode 会写穿它保降级一致）。
  'network_proxy_p2p_enabled',
  // String：P2P（torrent）传输代理档位 direct / proxy / mixed，默认 direct。
  'network_proxy_p2p_mode',
  'network_proxy_password',
  'network_proxy_username',
  'onboarding_completed',
  // bool：新手引导是否**走完**（点了最后一步的「开始使用」；跳过 / 返回不算）。
  // 缺省 true（老安装不受影响），全新安装首帧写 false。与 onboarding_completed
  // 同族、不随 Profile 走。首页「新手引导」卡据此判定（见 homeOnboardingCardVisible）。
  'onboarding_finished',
  // bool：首页「新手引导」卡被用户点了「不再显示」。同族、不随 Profile 走。
  'onboarding_home_card_dismissed',
  'overlay_lookup_independent_size',
  'overlay_lookup_max_height',
  'overlay_lookup_max_width',
  // bool：BT / 磁力下载前的 P2P 说明勾了「不再提示」（p2p_download_notice.dart）。
  'p2p_download_notice_dismissed',
  'player_hardware_acceleration',
  'popup_auto_expand_dictionaries',
  'popup_bottom_docked',
  // bool（默认 true）：底部停靠按模块细分，总开关 popup_bottom_docked 之下生效。
  'popup_bottom_docked_books',
  'popup_bottom_docked_games',
  'popup_bottom_docked_manga',
  'popup_bottom_docked_video',
  // bool：查词弹窗释义紧凑排版（对齐 Hoshi Reader Android
  // "Compact Glossaries"）。默认 false。
  'popup_compact_glossaries',
  'popup_dictionary_columns',
  // bool：词典样式统一（导入词典颜色按语义映射到当前 ColorScheme）。默认 true。
  'popup_dictionary_unified_style',
  'popup_instant_scroll',
  // double：瞬时滚动步长（占被滚表面视口高度的比例，0.1–1.0）。触摸 = 手指滑满
  // 这么多才跳一步，默认 0.25；滚轮 = 一格跳这么多（再乘滚轮速度），默认 0.5。
  'popup_instant_scroll_touch_step',
  'popup_instant_scroll_wheel_step',
  'popup_max_height',
  'popup_max_width',
  'popup_wheel_speed',
  // int：绑定临时切换前用户自己选的 Profile id（缺失 = 无）。非 Profile 键。
  'profile_fallback_id',
  'qb_connection_config',
  // 阅读器顶栏 / 底栏按钮布局 JSON（ReaderControlLayout，v1 槽位表）。
  'reader_control_layout',
  // 窄窗（手机竖屏）按钮布局 JSON（同 reader_control_layout 形；空 = 沿用宽窗那份）。
  'reader_control_layout_compact',
  // String 'left' | 'right'：小说 / 漫画阅读设置侧边弹窗停靠在哪一侧（与翻页方向无关）。
  'reader_settings_panel_side',
  // String 'floating' | 'docked'：阅读器工具栏样式（M3E 悬浮工具栏 / 贴边实体条）。
  'reader_toolbar_style',
  // bool：「工具栏样式强制悬浮」一次性迁移已跑（2026-10-06，非 Profile 键）。
  'reader_toolbar_style_floating_migrated',
  'reading_goal_daily_chars',
  // int：每周字数目标（2026-10-10 用户拍板删除——#2029 删了统计中心目标卡后它
  // 只能设、不显示进度）。存量键冻结、不再读写；留在这里只为键名不被别的功能复用。
  'reading_goal_weekly_chars',
  'remote_lookup_enabled',
  // 用户自己添加的 BT 站清单（JSON 数组：id/name/url/enabled/domains/format/
  // nyaaCategories/allowInsecureHttp，编码在引擎 bt_site_config.dart）。String，
  // 读写见 PreferencesRepository.btSites。地址可能带站点 passkey → 与
  // video_resource_torznab_config 同样归类：PrefRedactionPolicy.sensitiveKeys +
  // deviceLocalPrefKeys + 互联服务配置同步。
  'resource_bt_sites',
  // 旧内置 BT 站 → 用户 BT 站一次性升级迁移的已跑标记（'migrated' / 'fresh'，见引擎
  // bt_site_legacy_migration.dart）。描述本安装，设备本地（deviceLocalPrefKeys）：
  // 不进 Profile 快照 / 备份，恢复备份也不重判——新装用户恢复后不会被塞进旧内置站。
  'resource_bt_sites_legacy_migrated',
  'reverse_navigation_bar',
  'reverse_reader_bottom_bar',
  // BUG-2100 沙箱重定位台账：上次启动时的两个数据根。根变了（iOS 每次更新都会换
  // app 容器 UUID）就据此把全库绝对路径重基过去，见 storage/sandbox_relocation.dart。
  'sandbox_last_documents_root',
  'sandbox_last_support_root',
  'saved_tags',
  'scan_non_japanese_text',
  // bool：截屏识字 / 拍照查词制卡带所点文本块的截图（默认 true）。
  'screen_ocr.card_image',
  // bool：Android 截屏识字保持录屏会话、之后不再弹确认框（默认 false）。
  'screen_ocr.keep_capture_session',
  // string（JSON 数组，最近的在前）：最近打开的设置一级分类（SettingsDestinationId.name），
  // 首页侧栏「设置」速览卡读它（settings_recent_destinations.dart，设备本地）。
  'settings_recent_destinations',
  // String：已废弃（2026-10-13 起合集一律是网格里的单个格子，「整行展开」rows
  // 模式已移除；旧值 rows / cards 都无人读取）。key 冻结保留，备份 / 旧数据兼容。
  'shelf_collection_layout',
  // String：书架「阅读状态」筛选（ShelfReadStatus.name，'' = 全部）。
  'shelf_read_status_filter',
  'shelf_sort_mode',
  'show_expression_tags',
  'show_floating_lyric',
  'show_media_notification',
  'show_remote_entries',
  // String（JSON，SrsAnkiImportOptions.toJson）：上次「导入 Anki 包」选的五个选项，
  // 下次作对话框初值；缺省 = Anki 默认值。非凭据、跨设备（随 Profile / 备份）。
  // String（JSON，SrsCardAppearance.toJson）：复习卡面（Fushi 卡片模板）的外观：
  // 字体 / 字号 / 行距 / 配色 / 区块显隐 / 统一词典样式 / 密度。缺省 = 模板默认外观。
  // 非凭据、跨设备（随 Profile / 备份；字体文件路径在别的设备上不存在时回落默认字体）。
  'srs_card_appearance',
  'srs_import_anki_options',
  // bool（默认 true）：复习页顶部旧 Lapis 迁移横幅，「不再提醒」写 false。设备本地：
  // 不进 Profile 快照（ProfileKeys._excludedPrefKeys），否则切 Profile 会把它删掉。
  'srs_lapis_migration_reminder',
  // String（SRS 牌组 id，'' = 默认牌组）：挖词目标 = Fushi 复习时卡落进的牌组。
  // 被删时制卡回落默认牌组。非凭据、跨设备（id 自带 profileUid）。
  'srs_mining_deck_id',
  // String（JSON `{noteTypeId: {fieldId: 模板}}`）：非 Lapis 笔记类型的制卡字段
  // 映射，模板与 Anki 字段映射同一套 handlebar。非凭据、跨设备。
  'srs_mining_field_mappings',
  // String（SRS 笔记类型 id，'' = 从没选过 = 内置 Fushi 卡片）：挖词目标 = Fushi
  // 复习时用的笔记类型。被删时回落 Lapis。非凭据、跨设备。
  'srs_mining_note_type_id',
  // String（SrsMiningTarget.wire）：复习模块开着时制卡发往 Anki 还是 Fushi 复习（二选一；
  // 存量 'both' 读成 'anki'）。没设过取下面的安装默认。模块关着时不读。非凭据、跨设备。
  'srs_mining_target',
  // bool：旧开关「启动时打开查词」，已由 startup_module 取代；只读不写，
  // startup_module 从未写过时据此迁移（PreferencesRepository.startupModule）。
  // String 'anki' | 'srs'：本安装「挖词目标」的出厂默认，兼一次性判定标记（2026-10-16：
  // 新装 srs、老用户 anki）。设备本地（SyncRepository.installScopedPrefKeys）：不进
  // Profile 快照 / 分享、不随备份 / 推荐包出境；导入设置的恢复会清掉它，下次启动重判。
  'srs_mining_target_install_default',
  // bool（默认 true）：复习页顶栏悬浮——不占布局、默认收起，点卡面空白 / 右键唤出、
  // 再点收起（与小说、漫画阅读器的悬浮顶栏同一口径）；false = 固定页头常驻。非凭据、跨设备。
  'srs_review_chrome_floating',
  // bool（默认 false）：复习页底部评分栏只留「重来 / 良好」两个按钮（对齐 AnkiDroid
  // 的 hideHardAndEasy）；键盘 2/4 仍可评「困难 / 简单」。非凭据、跨设备。
  'srs_review_hide_hard_easy',
  // String（SrsReviewImageSize.wire：'original' | 'fit_width' | 'large'，默认
  // 'original'）：复习卡面图片大小（牌组 CSS 限得太小 / 原图像素小时放大）。非凭据、跨设备。
  'srs_review_image_size',
  // String（SrsReviewReplayButton.wire：'off' | 'start' | 'end'，默认 'off'）：复习页
  // 底部操作行一端放一颗重播音频键（手机刷卡时拇指在屏幕下方，够不到顶栏）。非凭据、跨设备。
  'srs_review_replay_button',
  // bool（默认 true）：复习页页头显示剩余卡数（新 / 学习 / 复习，对齐 Anki「显示剩余卡片
  // 数量」）。非凭据、跨设备。
  'srs_review_show_counts',
  // bool（默认 true）：评分按钮显示下次间隔（小号副标签，误按 / 排程异常一眼可见）。
  // 非凭据、跨设备。
  'srs_review_show_intervals',
  // double（默认 1.0，0–1）：复习卡面音频音量，点播与自动连播共用。非凭据、跨设备。
  'srs_review_volume',
  // double（默认 1.0，0.6–2.0）：复习页卡面缩放（Ctrl / ⌘ + 滚轮、Ctrl + 加减号 / 0）。
  'srs_review_zoom',
  // String（JSON 数组，SrsFolderLocation）：复习同步 v2 用户加的文件夹存储位置与用途（同步 / 媒体 / 归档）。
  // 设备本地（SyncRepository._deviceLocalFixedKeys）：路径只在这台设备上有意义。
  'srs_sync2_folder_locations',
  // String（JSON：位置身份 → SrsLocationKey）：复习同步 v2 各存储位置的端到端加密密钥。凭据 + 设备本地
  // （同时登记在 kCredentialPreferenceKeys、PrefRedactionPolicy.sensitiveKeys 与 deviceLocalPrefKeys）。
  'srs_sync2_location_keys',
  // bool（默认 false）：升级到同步 v2 后已确认首次同步（并入、不覆盖）。设备本地，同上。
  'srs_sync2_merge_confirmed',
  'startup_default_dictionary_tab',
  // String：启动页模块（ModuleId.prefKey，'' = 底栏第一个页面）。设备本地，
  // 与 module_nav_order 同族（ModuleId.devicePrefKeys）。
  'startup_module',
  // int（profiles.id）：v105 统计按 Profile 隔离——legacy 统计家族（v92 前的四张
  // 投影表 + activity_events 学习行）归属哪个 Profile。由 v105 迁移一次性写下
  // （升级那一刻激活的 Profile），fushi_core 侧常量 `kStatLegacyProfileIdPrefKey`。
  // 设备本地键：值是本库自增 id，不进 Profile 快照、不随备份 / 分享出境。
  'stats_legacy_profile_id',
  // bool，默认 true：自动下载的外挂字幕按视频内嵌字幕轨对时间轴
  // （embedded_reference_subtitle_sync.dart）。
  'subtitle_reference_sync_enabled',
  'sync_backend_type',
  'texthooker_enabled',
  'texthooker_urls',
  'torrent_upload_intro_shown',
  // String：当前朗读声音预设 id（TtsPresetStore）。指向本机预设，设备本地。
  'tts_active_preset_id',
  // JSON：本机一键部署的 GPT-SoVITS（GptSovitsLocalEngine）：整合包目录 / 端口 /
  // 下载源 / 是否 app 所装。路径与端口只对这台电脑成立，设备本地。
  'tts_gpt_sovits_local',
  // JSON：本机一键部署的官方 Irodori-TTS-Server（IrodoriLocalEngine）：专属目录 / 端口 /
  // 下载源 / 后端 / 模型 / 是否 app 所装。只对这台电脑成立，设备本地。
  'tts_irodori_local',
  // JSON：TTS 发音词典（写法 → 读法，TtsPronunciationStore），只改合成文本。
  'tts_pronunciation_rules',
  // double：TTS 朗读倍速（播放器本地倍速，服务端恒 1.0）。
  'tts_read_aloud_speed',
  // JSON：朗读声音预设清单，每条的凭据参数以 base64 存在 secretsB64；同时登记在
  // kCredentialPreferenceKeys、PrefRedactionPolicy.sensitiveKeys 与
  // deviceLocalPrefKeys（地址多是本机 / 局域网的 GPT-SoVITS 服务）。
  'tts_voice_presets',
  'update_auto_install',
  'update_beta_channel',
  'update_custom_proxy',
  'update_debug_channel',
  'update_download_source',
  'update_never_remind',
  // bool ×6（v101 统一更新提醒）：各域一个「要不要提醒」开关 + 系统通知总
  // 开关。默认全 true（装了订阅功能就是想被告知）。域开关关掉 = 该域整批不投递
  // （不进更新页、不出红点、不发通知）；总开关只掐系统通知，红点照常。
  // 调用点走 `UpdateFeedKind.enabledPrefKey` / [kUpdateSystemNotificationsPref]
  // 常量，不是裸字面量——守卫扫不到，但纪律要求登记。
  'updates_notify_anime_extension',
  'updates_notify_app_release',
  'updates_notify_manga_chapter',
  'updates_notify_manga_extension',
  'updates_notify_video_episode',
  'updates_system_notifications',
  // 安装统计（updates/usage_heartbeat.dart），全是设备本地：开关（bool，默认 true）、
  // 回退随机种子（UUID v4；机器标识取不到时才用，见 updates/install_attestation.dart）、
  // 安装证明的工作量证明缓存（String `<installId>:<nonce>`）、上次心跳成功时刻（int 毫秒）。
  'usage_stats_enabled',
  'usage_stats_install_id',
  'usage_stats_install_pow',
  'usage_stats_last_ping_at',
  // String（`VideoSeriesFilter.name`，默认 `standalone`）：「全部视频」系列归属
  // 筛选的上次选择（BUG-2835，用户拍板默认只看散片、并记住选择）。
  'video_all_series_filter',
  'video_anime4k_prompt_shown',
  'video_asbplayer_config',
  'video_auto_play_next',
  'video_auto_scrape',
  'video_black_flicker_notice_suppressed',
  'video_control_customization',
  'video_custom_action_bindings',
  'video_danmaku_block_rules',
  'video_danmaku_config',
  'video_danmaku_enabled',
  'video_danmaku_max_active',
  'video_danmaku_online_enabled',
  'video_danmaku_style',
  // bool（默认 false）：系列详情页宽屏版式——true = 海报横幅（与竖屏同形），
  // false = 两栏。详情页右上角切换，跨作品记住。
  'video_detail_poster_layout',
  // bool（三项默认都 true）：原盘会话。auto_fullscreen = 桌面端进原盘会话自动全屏、
  // 退出恢复进入前窗口状态；launch_animation = 封面放大铺满再淡入盘菜单的启动动画；
  // open_menu_by_default = 原盘作品详情页主按钮打开原盘菜单（关 = 直接播正片）。
  'video_disc_auto_fullscreen',
  'video_disc_launch_animation',
  'video_disc_open_menu_by_default',
  // bool（默认 false）：远端原盘流式播放反复缓冲时的「建议下载到本机」提示，用户
  // 点了「不再提示」后为 true（拍板决策：只提示、绝不强制切换）。
  'video_disc_remote_buffering_notice_suppressed',
  'video_download_backend_path_mappings',
  'video_download_embedded_installation_id',
  // bool：下载进受管视频来源时跳过特典（PV / CM / NCOP / NCED / 菜单…）——管线
  // 拿到种子文件表后把特典文件设为不下载；AI 下视频选版本时也丢掉只有特典的发布。
  // 默认 false（旧行为：整颗种子全下）。非凭据、跨设备。
  'video_download_skip_extras',
  'video_download_target_source_id',
  'video_fit_mode',
  // String（VideoImmersiveControlLayout JSON，空串 = 没改过、按普通布局派生）：
  // 沉浸锁定后屏幕左右侧栏的按钮排列。
  'video_immersive_control_layout',
  'video_immersive_mode',
  // bool（默认 true）：沉浸锁定 + 字幕遮蔽中点画面任意处显示当前句。
  'video_immersive_tap_reveal',
  // int（默认 -1 = 自动）：互联远端视频画质档在 kInterconnectQualityPresets 里的
  // 下标。自动 = 局域网原画直传、走公网压到中档（interconnect_video_quality.dart）。
  'video_interconnect_quality_preset',
  // int 秒（默认 10，0 = 不自动隐藏）：「返回跳转前位置」胶囊自上次跳转起多久后
  // 不再随控制条出现，见 videoJumpPillLiveVisible。
  'video_jump_pill_auto_hide_seconds',
  'video_library_auto_backfill_scrape',
  // bool（默认 true）：后台为媒体库里的在线视频作品（在线视频源 / 媒体服务器的剧）
  // 补新集（video_library_update_probe.dart）；与「番剧新集提醒」开关分开。
  'video_library_auto_update',
  'video_lock_window_aspect_ratio',
  // int（默认 -1 = 自动）：媒体服务器（Jellyfin/Emby）串流画质档在
  // JellyfinVideoClient.kQualityPresets 里的下标；选档 = 向服务器声明码率 / 宽度上限，
  // 超限由服务器转码。
  'video_media_server_quality_preset',
  // String（JSON 对象）：媒体服务器多版本条目「选哪个版本」的记忆
  // （`MediaServerVersionMemory`）。键 `<serverId>|item|<itemId>` → MediaSource id、
  // `<serverId>|series|<seriesId>` → 规格签名 + 版本名；按写入先后保留最近
  // 500 条。非凭据、跨设备（服务器条目 id 在哪台设备上都一样）。
  'video_media_server_version_choices',
  'video_mining_animated_format',
  'video_mining_clip_format',
  'video_mining_image_mode',
  'video_mining_still_format',
  'video_mpv_config',
  // String（[MpvLuaCapability] 的 name）：随包 libmpv 有没有编入 Lua 解释器，
  // 视频页建 Player 后读 `mpv-configuration` 探到并缓存。全局设置页没有播放器，
  // 靠这份缓存如实说明脚本开关在本平台是否可用。默认 unknown = 从未播过视频。
  // 见 media/video/video_lua_capability.dart（BUG-2032）。
  'video_mpv_lua_capability',
  'video_mpv_shader_dir',
  // String（[VideoOnlineMiningMode] 的 wireName）：在线视频点制卡后弹窗等不等——
  // `background` 后台（默认）/ `deferred` 看完再制卡 / `wait` 等整张卡落地。
  'video_online_mining_mode',
  // bool（默认 true）：暂停 OCR 在没有字幕轨的画面（硬字幕）上点字查词制卡时，给句子
  // 音频一个「暂停位置前后各几秒」的默认窗口（见 media/video/player_decoded_subtitle_cues.dart
  // 的 buildFrameOcrFallbackCue）。关掉 = 这类查词制卡不带句子音频（`0..0` 哨兵）。
  'video_pause_ocr_audio_fallback',
  // int（毫秒，默认 2000，夹到 500..10000）：上面那个默认窗口在暂停位置前后**各**取多长。
  'video_pause_ocr_audio_fallback_ms',
  // String（[VideoPauseOcrScope] 的 wireName）：暂停时识别画面文字（OCR 点字查词）
  // 的范围——`all` 所有视频（默认）/ `graphic_subtitles` 只在图形字幕时 / `off`。
  'video_pause_ocr_scope',
  // 手机字幕遥控器控制卡按钮布局 JSON（VideoRemoteControlLayout，v1 槽位表）。
  'video_remote_control_layout',
  'video_remote_subtitle',
  // 旧「内置视频资源索引器」停用清单（逗号分隔）。内置 BT 站已整体移除（用户
  // 自己添加 BT 站，见 resource_bt_sites），存量键冻结、不再写；只有一次性升级迁移
  // （引擎 bt_site_legacy_migration.dart）读它决定迁出站点的启停。留在这里也为键名
  // 不被别的功能复用。
  'video_resource_disabled_sources',
  'video_resource_torznab_config',
  'video_respect_ass_style',
  'video_secondary_subtitle_blur',
  'video_secondary_subtitle_obscure_hide',
  // bool（未写过时继承 video_subtitle_obscure_reveal）：副字幕遮蔽态是否允许
  // 暂停 / 查词 / 悬停 / 点击临时显形，与主字幕分开配置。
  'video_secondary_subtitle_obscure_reveal',
  'video_shaders_enabled',
  // bool（默认 false）：控制条淡出后，在视频最下方留一条主题色细进度条
  // （B 站 / YouTube 同款）。默认关——控制条淡出就是要把画面让干净。小窗档不受
  // 它管——那里完整进度条已被收起，细线是唯一的进度指示，见
  // videoSlimProgressBarVisible。
  'video_slim_progress_bar',
  'video_sort_mode',
  // bool（默认 true）：AJATT 日语字幕库（kitsunekko 镜像）是否参与字幕搜索。
  // 零配置源，没有 key 门控；默认开是因为它是没填 Jimaku/OpenSubtitles key 的
  // 用户唯一能用的源。
  // bool（默认 false）：用户是否已看过「AI 校对会发送什么」说明；设备本地。
  'video_subtitle_ai_consented',
  // bool（默认 false）：生成日语字幕时是否 AI 校对；设备本地（计费同意）。
  'video_subtitle_ai_proofread',
  'video_subtitle_ajatt_enabled',
  // bool（默认 true）：远端（互联 host）视频上导入 / 重定时得到的字幕，是否自动上传到
  // host 并设为该集默认字幕（所有 peer 都会看到）。关掉则字幕只在本机生效。
  // 见 PreferencesRepository.videoSubtitleAutoUploadToHost。
  'video_subtitle_auto_upload_to_host',
  'video_subtitle_backfill_after_scrape',
  'video_subtitle_blur',
  'video_subtitle_list_auto_scroll',
  // string（默认 all）：字幕列表上次打开的页签（VideoSubtitleListFilter.name，
  // all / favorites），下次打开恢复（反馈 xlzGuK5YmD）。
  'video_subtitle_list_filter',
  'video_subtitle_list_font_scale_index',
  // bool（默认 true）：字幕列表里点字幕文字是否查词；关掉后点哪里都只跳到该句
  // （手机上列表旁的查词弹窗太扁，多数人只拿列表跳转，群反馈 GbN9MoKDCQ）。
  'video_subtitle_list_tap_lookup',
  'video_subtitle_list_width',
  // string（默认 auto）：生成日语字幕的 MOSS 后端 auto/cuda/vulkan/cpu；设备本地。
  'video_subtitle_moss_backend',
  'video_subtitle_obscure_hide',
  // bool（默认 true）：遮蔽（模糊 / 隐藏）态是否允许悬停 / 点击临时显形。关掉后
  // 遮蔽在整句期间恒定生效，不被误触破功。
  'video_subtitle_obscure_reveal',
  'video_subtitle_opensubtitles_config',
  // string（默认 auto）：生成日语字幕的分段方式 auto/moss/window；设备本地。
  'video_subtitle_segmenter',
  'video_subtitle_style',
  // string：SubDL（subdl.com）API key（用户在站点 panel 免费生成）。搜索必须带 key。
  'video_subtitle_subdl_api_key',
  // bool（默认 true）：SubDL 是否参与字幕搜索。与 api key 组成 `enabled && key`
  // 双门控（形状对齐 Jimaku）；key 为空即不装配，所以默认开不会产生任何请求。
  'video_subtitle_subdl_enabled',
  // bool（默认 false）：播放器底栏时间显示「剩余时长」而不是「已播时长」。
  // 点按底栏时间切换（MD3 Expressive chrome），跨设备。
  // bool（默认 false）：作品图谱 L2，进入识别出的片头 / 片尾时自动跳到段尾。
  // （曾有的 `video_theme_song_now_playing` 曲名角标开关随角标一起删了，BUG-3850；
  // 旧库残留行无人读。）
  'video_theme_song_auto_skip',
  'video_time_display_remaining',
  'video_youtube_quality_height',
  // bool（默认 true）：浏览器手机上滚动时收起工具栏（web_browser_prefs.dart，设备本地）。
  'web_browser_collapse_toolbar_on_scroll',
  // string（JSON 数组）：浏览器用户自定义搜索引擎（web_browser_sites.dart，设备本地）。
  'web_browser_custom_search_engines',
  // bool（默认 false）：浏览器新标签页默认桌面版网页（web_browser_prefs.dart，设备本地）。
  'web_browser_desktop_mode_default',
  // string（JSON 对象）：app 内浏览器运行扩展脚本时的 chrome.storage.local
  // （features/extension_host/web_browser_extension_storage.dart，设备本地）。
  'web_browser_extension_storage',
  // bool（默认 false）：浏览器网页深色模式（web_browser_prefs.dart，设备本地）。
  'web_browser_force_dark',
  // bool：已删除的浏览器「整页注音」开关（2026-10-27 用户要求移除）。存量键冻结、
  // 不再读写；留在这里只为键名不被别的功能复用。
  'web_browser_furigana',
  // bool：已删除的浏览器「生词高亮」开关（2026-10-27 用户要求移除）。存量键冻结、
  // 不再读写；留在这里只为键名不被别的功能复用。
  'web_browser_known_words',
  // bool（默认 true）：浏览器重启后恢复上次的标签页（web_browser_prefs.dart，设备本地）。
  'web_browser_restore_tabs',
  // string（内置引擎名 / custom:<id>，默认 google）：浏览器当前搜索引擎（设备本地）。
  'web_browser_search_engine',
  // bool（默认 true）：浏览器侧边栏模式下侧边栏是否展开（web_browser_prefs.dart，设备本地）。
  'web_browser_sidebar_open',
  // string（JSON）：浏览器按站点记住的权限决定（web_browser_site_settings.dart，设备本地）。
  'web_browser_site_permissions',
  // string（JSON 数组，空串 = 用预置站点）：app 内浏览器的站点书签（web_browser_sites.dart）。
  'web_browser_sites',
  // string（sidebar / topStrip，默认 sidebar）：浏览器宽窗口标签页样式（web_browser_prefs.dart，设备本地）。
  'web_browser_tab_style',
  // 已删除的「YouTube 页内可点字幕」开关（由扩展宿主取代）：不再读写，只为键名不被复用。
  'web_browser_youtube_subtitles',
  // bool（默认 true）：网页漫画章末二维码广告页剔除（判定在 native/fushi_web_core 的 comic_ad）。
  'web_comic_ad_filter',
  'yomitan_api_key',
  'yomitan_api_port',
  'yomitan_api_server_enabled',
};

/// 已知的动态键形态（前缀/模板 + 运行时段，守卫不扫，登记供人查阅）。
///
/// 有声书 per-book 播放态（后缀 = bookKey，常量在
/// fushi_audio/audiobook_repository.dart）、媒体源命名空间
/// （`src:<sourceId>:<key>`，见 media_source.dart 的 dbSourcePrefKey——含
/// reader 设置与字体目录）、媒体类型当前源（`current_source/<uniqueKey>`）、
/// 导入记忆（`<uniqueKey>/last_picked_file`）、gal 捕获记忆（后缀 = gameKey）、
/// 弹幕分集映射（后缀 = bookUid）、来源库凭据（后缀 = MediaSources.id，🔴 凭据）。
const List<String> kKnownPreferenceKeyPrefixes = <String>[
  'audiobook_delay_',
  // 调轴 LWW 时间戳孪生键（互联完整支持批次；与 audiobook_pos_at_ 同范式）。
  'audiobook_delay_at_',
  'audiobook_follow_',
  'audiobook_health_overlay_',
  'audiobook_image_pause_',
  'audiobook_pos_',
  'audiobook_pos_at_',
  'audiobook_speed_',
  'audiobook_volume_',
  'current_source/',
  'gal_capture_memory::',
  'gal_lookup_surface_v1::',
  'media_source_secret_',
  // 书 / 漫画来源的扫描索引（后缀 = MediaSources.id，JSON：源相对路径 → 书 uid，
  // 外加「不是本类媒体」的负向表 源相对路径 → 内容指纹）。无头服务端书 / 漫画根扫描
  // （BUG-2816）与 app 漫画来源扫描（BUG-3574）共用（引擎 book_library_prune.dart）；
  // 设备本地状态，不进 Profile 快照（ProfileKeys._excludedPrefPrefixes）。
  'media_source_scan_index_',
  kSectionTabOrderPrefKeyPrefix,
  kLibraryManualOrderPrefKeyPrefix,
  'src:',
  // int（毫秒，v101）：`updates_last_check_<UpdateFeedKind.dbValue>`——某个域上次
  // 后台检查完成的时刻。到期判据只读它，失败也照记（否则断网时每个 tick 都重试）。
  'updates_last_check_',
  // JSON：`tts_resume_<bookKey>` TTS 朗读断点（章 + 句首匹配偏移 + 句内毫秒 +
  // 音频缓存键，TtsResumePoint）。
  'tts_resume_',
  'video_danmaku_episode/',
  // 视频远端断点/播放偏好三件套族（PositionPrefKeys，fushi_library_host_service.dart）：
  // `<前缀><bookUid>` 值键 + `<前缀>at_<bookUid>` 时间戳键，逐字段 LWW 跨设备同步
  //（播放偏好同步泛化批：调轴/音轨/副字幕源/副字幕调轴；看完标记 = 手动标记已看 /
  // 未看的 LWW 镜像，值是 completedAt 毫秒、0 = 未看完）。
  'video_remote_audio_track_',
  'video_remote_audio_track_at_',
  'video_remote_completed_',
  'video_remote_completed_at_',
  'video_remote_delay_',
  'video_remote_delay_at_',
  'video_remote_position_',
  'video_remote_position_at_',
  'video_remote_secondary_delay_',
  'video_remote_secondary_delay_at_',
  'video_remote_secondary_subtitle_',
  'video_remote_secondary_subtitle_at_',
];

/// 🔴 凭据键：值为 base64 敏感凭据，不进日志 / 不进明文导出。
/// （`media_source_secret_<id>` 前缀族见 [kKnownPreferenceKeyPrefixes]。）
const Set<String> kCredentialPreferenceKeys = <String>{
  // 复习同步 v2 各存储位置的集合密钥（hex）。
  'srs_sync2_location_keys',
  // 每条 AI 提供商记录里带 base64 的 apiKeyB64。
  'ai_providers',
  // AnkiSettings JSON 里的 AnkiConnect apiKey（明文）。
  kAnkiSettingsPrefKey,
  // 每条 AList / OpenList 站点记录里带 base64 的 passwordB64。
  'discovery_alist_sites',
  // 每条 Audiobookshelf 服务器记录里带 base64 的 access / refresh token。
  'discovery_audiobookshelf_servers',
  // 每条 OPDS 服务器记录里带 base64 的 passwordB64。
  'discovery_opds_servers',
  'jimaku_api_key',
  'music_acoustid_api_key',
  // 每条 OpenSubsonic 服务器记录里带 base64 的 passwordB64 / apiKeyB64。
  'music_subsonic_servers',
  // 每条 Kavita 服务器记录里带 base64 的长期 API key。
  'kavita_servers',
  'network_proxy_password',
  'network_proxy_username',
  // 每份朗读声音预设里 base64 的 secretsB64（API key / Bearer）。
  'tts_voice_presets',
  'video_subtitle_subdl_api_key',
  'yomitan_api_key',
};

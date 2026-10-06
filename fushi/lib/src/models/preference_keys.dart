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

/// 已知的静态偏好键全集（守卫强制）。按字母序。
const Set<String> kKnownPreferenceKeys = <String>{
  'active_profile_id',
  // 「哪个功能用哪家 AI」的映射。不含凭据，但跟着 ai_providers 一起设备本地：
  // providers 不跨设备，映射跨过去只会指向一个不存在的 id。
  'ai_feature_providers',
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
  // String（JSON 数组）：有声书素材库目录（绝对路径）。库里放按作品身份命名的
  // 字幕/正文文件，下载完成后据此自动配齐「正文 + 字幕 + 音频」。见
  // media/audiobook/audiobook_material_library.dart。
  'audiobook_material_dirs',
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
  // 发现页「全部源」聚合默认排除的源 id（逗号分隔；默认 sukebei——18+ 源
  // 只在用户显式单选时使用）。String，读写见 PreferencesRepository。
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
  'floating_ball.system',
  // 桌面应用外悬浮球的停靠边（String）与纵向比例（double），与应用内球的
  // `.dock` / `.y` 分开存：两颗球可以同时在。
  'floating_ball.system_dock',
  'floating_ball.system_y',
  'floating_ball.y',
  'floating_lyric_bg_opacity',
  'floating_lyric_button_bg_opacity',
  'floating_lyric_click_lookup',
  'floating_lyric_context_lines',
  'floating_lyric_corner_radius',
  'floating_lyric_font_size',
  'floating_lyric_text_opacity',
  'floating_lyric_width',
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
  'games_collapsed_collection_ids',
  // String（默认 'grid'）：游戏库主体布局，'grid' 海报网格 / 'list' 分段卡列表。
  // 页头切换钮写入，跨会话记住。
  'games_library_layout',
  'global_dict_css',
  'harmonic_frequency',
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
  'last_dictionary_update_at',
  'last_selected_deck',
  'last_selected_dictionary_format',
  'last_selected_model',
  'local_audio_db_display_name',
  'local_audio_db_path',
  'local_audio_dbs',
  'lookup.global_context_capture',
  'lookup.ime_language',
  // bool（默认 false）：查词后自动让 AI 按句意把符合用法的词头挪到最前
  // （「设置 › AI」指派了查词用的提供商才生效；悬停查词与嵌套查词不触发）。
  'lookup_ai_context_auto',
  // bool（默认 false，桌面端）：查词页按「返回上一级」直接最小化主窗（一键收窗
  // 回到之前的程序），不走关弹窗 → 清查询的阶梯。
  'lookup_page_escape_minimizes_window',
  'low_memory_mode',
  // String（`MangaBackground.key`，默认 `black`）：页图周围留白的底色。
  'manga_background',
  // bool（默认 true）：漫画阅读器顶栏悬浮（不占布局、点页面中央/顶边悬停唤出）
  // 还是常驻钉在页图上方。
  'manga_chrome_floating',
  // int（天，BUG-2450）：在线漫画封面磁盘缓存的保留天数（Mihon 封面缓存
  // MihonCoverCache.maxAge）。默认 180，范围 30..360。
  'manga_cover_cache_max_age_days',
  // bool（默认 false）：作品页「完成后自动识别」chip——章节下载任务入队时写进
  // `manga_download_jobs.auto_ocr`，下载完成钩子据此起整卷 OCR（设计稿 2026-09-12 §5）。
  'manga_download_auto_ocr',
  'manga_external_mokuro_path',
  'manga_ocr_ai_mode',
  'manga_ocr_engine_preference',
  'manga_ocr_lens_language',
  'manga_ocr_local_model',
  'manga_ocr_paired_host_model',
  'manga_ocr_parallel_tasks',
  'manga_online_catalog_base_url',
  'manga_online_catalog_enabled',
  'manga_page_animation',
  // bool（默认 false）：启用本地 AI 分镜检测与逐分镜导航。
  'manga_panel_navigation',
  // String（JSON）：漫画阅读器的全局默认偏好（布局/缩放/裁边/点击区等，
  // MangaReaderPreferences 序列化）。每作品覆盖落 manga_reader_overrides 表。
  'manga_reader_preferences',
  'manga_reading_direction',
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
  'mine_to_server',
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
  'module_books_enabled',
  'module_browser_extension_enabled',
  'module_dictionaries_enabled',
  'module_downloads_enabled',
  'module_games_enabled',
  'module_manga_enabled',
  'module_video_enabled',
  // bool（默认 true）：MD3 悬浮底栏图标下是否显示标签。
  'nav_bar_labels_visible',
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
  'overlay_lookup_independent_size',
  'overlay_lookup_max_height',
  'overlay_lookup_max_width',
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
  'reading_goal_weekly_chars',
  'remote_lookup_enabled',
  'reverse_navigation_bar',
  'reverse_reader_bottom_bar',
  // BUG-2100 沙箱重定位台账：上次启动时的两个数据根。根变了（iOS 每次更新都会换
  // app 容器 UUID）就据此把全库绝对路径重基过去，见 storage/sandbox_relocation.dart。
  'sandbox_last_documents_root',
  'sandbox_last_support_root',
  'saved_tags',
  'scan_non_japanese_text',
  // String：书架合集呈现方式（ShelfCollectionLayout.name：rows 横排行 / cards
  // 单个格子），默认 rows。
  'shelf_collection_layout',
  // String：书架「阅读状态」筛选（ShelfReadStatus.name，'' = 全部）。
  'shelf_read_status_filter',
  'shelf_sort_mode',
  'show_expression_tags',
  'show_floating_lyric',
  'show_media_notification',
  'show_remote_entries',
  'startup_default_dictionary_tab',
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
  'update_auto_install',
  'update_beta_channel',
  'update_custom_proxy',
  'update_debug_channel',
  'update_download_source',
  'update_never_remind',
  // bool ×5（v101 统一更新提醒）：四个域各一个「要不要提醒」开关 + 系统通知总
  // 开关。默认全 true（装了订阅功能就是想被告知）。域开关关掉 = 该域整批不投递
  // （不进更新页、不出红点、不发通知）；总开关只掐系统通知，红点照常。
  // 调用点走 `UpdateFeedKind.enabledPrefKey` / [kUpdateSystemNotificationsPref]
  // 常量，不是裸字面量——守卫扫不到，但纪律要求登记。
  'updates_notify_app_release',
  'updates_notify_manga_chapter',
  'updates_notify_manga_extension',
  'updates_notify_video_episode',
  'updates_system_notifications',
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
  'video_download_backend_path_mappings',
  'video_download_embedded_installation_id',
  // bool：下载进受管视频来源时跳过特典（PV / CM / NCOP / NCED / 菜单…）——管线
  // 拿到种子文件表后把特典文件设为不下载；AI 下视频选版本时也丢掉只有特典的发布。
  // 默认 false（旧行为：整颗种子全下）。非凭据、跨设备。
  'video_download_skip_extras',
  'video_download_target_source_id',
  'video_fit_mode',
  'video_immersive_mode',
  // int（默认 -1 = 自动）：互联远端视频画质档在 kInterconnectQualityPresets 里的
  // 下标。自动 = 局域网原画直传、走公网压到中档（interconnect_video_quality.dart）。
  'video_interconnect_quality_preset',
  'video_library_auto_backfill_scrape',
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
  'video_mpv_lua_scripts_enabled',
  'video_mpv_shader_dir',
  // String（[VideoOnlineMiningMode] 的 wireName）：在线视频点制卡后弹窗等不等——
  // `background` 后台（默认）/ `deferred` 看完再制卡 / `wait` 等整张卡落地。
  'video_online_mining_mode',
  'video_remote_subtitle',
  // 用户停用的内置视频资源索引器 id（逗号分隔，默认空 = 全部启用）。
  // 与 discovery_disabled_sources 同形；自配 Torznab 各自带 enabled，不进这里。
  'video_resource_disabled_sources',
  'video_resource_torznab_config',
  'video_respect_ass_style',
  'video_secondary_subtitle_blur',
  'video_secondary_subtitle_obscure_hide',
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
  'video_subtitle_ajatt_enabled',
  // bool（默认 true）：远端（互联 host）视频上导入 / 重定时得到的字幕，是否自动上传到
  // host 并设为该集默认字幕（所有 peer 都会看到）。关掉则字幕只在本机生效。
  // 见 PreferencesRepository.videoSubtitleAutoUploadToHost。
  'video_subtitle_auto_upload_to_host',
  'video_subtitle_backfill_after_scrape',
  'video_subtitle_blur',
  'video_subtitle_list_auto_scroll',
  'video_subtitle_list_font_scale_index',
  'video_subtitle_list_width',
  'video_subtitle_obscure_hide',
  // bool（默认 true）：遮蔽（模糊 / 隐藏）态是否允许悬停 / 点击临时显形。关掉后
  // 遮蔽在整句期间恒定生效，不被误触破功。
  'video_subtitle_obscure_reveal',
  'video_subtitle_opensubtitles_config',
  'video_subtitle_style',
  // string：SubDL（subdl.com）API key（用户在站点 panel 免费生成）。搜索必须带 key。
  'video_subtitle_subdl_api_key',
  // bool（默认 true）：SubDL 是否参与字幕搜索。与 api key 组成 `enabled && key`
  // 双门控（形状对齐 Jimaku）；key 为空即不装配，所以默认开不会产生任何请求。
  'video_subtitle_subdl_enabled',
  // bool（默认 false）：播放器底栏时间显示「剩余时长」而不是「已播时长」。
  // 点按底栏时间切换（MD3 Expressive chrome），跨设备。
  'video_time_display_remaining',
  'video_youtube_quality_height',
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
  // 书 / 漫画来源的扫描索引（后缀 = MediaSources.id，JSON：源相对路径 → 书 uid）。
  // 目前只有无头服务端扫描写它（引擎 book_library_prune.dart，BUG-2816）。
  'media_source_scan_index_',
  'src:',
  // int（毫秒，v101）：`updates_last_check_<UpdateFeedKind.dbValue>`——某个域上次
  // 后台检查完成的时刻。到期判据只读它，失败也照记（否则断网时每个 tick 都重试）。
  'updates_last_check_',
  'video_danmaku_episode/',
  // 视频远端断点/播放偏好三件套族（PositionPrefKeys，fushi_library_host_service.dart）：
  // `<前缀><bookUid>` 值键 + `<前缀>at_<bookUid>` 时间戳键，逐字段 LWW 跨设备同步
  //（播放偏好同步泛化批：调轴/音轨/副字幕源/副字幕调轴）。
  'video_remote_audio_track_',
  'video_remote_audio_track_at_',
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
  // 每条 AI 提供商记录里带 base64 的 apiKeyB64。
  'ai_providers',
  // 每条 AList / OpenList 站点记录里带 base64 的 passwordB64。
  'discovery_alist_sites',
  // 每条 Audiobookshelf 服务器记录里带 base64 的 access / refresh token。
  'discovery_audiobookshelf_servers',
  // 每条 OPDS 服务器记录里带 base64 的 passwordB64。
  'discovery_opds_servers',
  'jimaku_api_key',
  'network_proxy_password',
  'network_proxy_username',
  'video_subtitle_subdl_api_key',
  'yomitan_api_key',
};

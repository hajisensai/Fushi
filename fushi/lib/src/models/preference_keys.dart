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
  'app_locale',
  'app_ui_scale',
  'audio_source_configs',
  'audio_sources',
  'audiobook_background_play',
  'auto_add_book_name_to_tags',
  'auto_search',
  'auto_search_debounce_delay',
  'auto_update_dictionaries',
  'builtInTagsSeeded',
  'clipboard_panel_block_capture',
  'clipboard_panel_opacity',
  'clipboard_panel_pinned',
  'clipboard_panel_rect',
  'clipboard_text_window_bg_opacity',
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
  'desktop_clipboard_always_on_top',
  'desktop_clipboard_auto_lookup',
  'desktop_clipboard_destination',
  'desktop_clipboard_enabled',
  'desktop_clipboard_window_mode',
  'dictionary_entry_font_size',
  'dictionary_update_interval',
  // 发现页「全部源」聚合默认排除的源 id（逗号分隔；默认 sukebei——18+ 源
  // 只在用户显式单选时使用）。String，读写见 PreferencesRepository。
  'discovery_disabled_sources',
  'download_custom_proxy',
  'download_network_proxy_mode',
  'download_save_root',
  'download_save_root_history',
  'experimental_focus_navigation_enabled',
  'extension_popup_independent_size',
  'extension_popup_max_height',
  'extension_popup_max_width',
  'first_time_setup',
  'floating_lyric_bg_opacity',
  'floating_lyric_button_bg_opacity',
  'floating_lyric_click_lookup',
  'floating_lyric_context_lines',
  'floating_lyric_corner_radius',
  'floating_lyric_font_size',
  'floating_lyric_text_opacity',
  'floating_lyric_width',
  'gal_hook_ingame_lookup_enabled',
  'gal_hook_text_font_size',
  'gal_mining_animated_format',
  'gal_mining_image_mode',
  'gal_mining_still_format',
  'galgame_library',
  'galgame_library_view',
  'games_collapsed_collection_ids',
  'global_dict_css',
  'harmonic_frequency',
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
  'low_memory_mode',
  'manga_external_mokuro_path',
  'manga_ocr_engine_preference',
  'manga_ocr_lens_language',
  'manga_online_catalog_base_url',
  'manga_online_catalog_enabled',
  'manga_page_animation',
  'manga_reading_direction',
  'manga_spread_preference',
  'manga_tap_zone_paging',
  'manga_volume_key_paging',
  'manga_zoom_percent',
  'manga_zoom_sensitivity',
  'maximum_terms',
  'mine_to_server',
  'mining_audio_quality',
  'mining_image_quality',
  'module_games_enabled',
  'module_manga_enabled',
  'module_video_enabled',
  'onboarding_completed',
  'overlay_lookup_independent_size',
  'overlay_lookup_max_height',
  'overlay_lookup_max_width',
  'player_hardware_acceleration',
  'popup_auto_expand_dictionaries',
  'popup_bottom_docked',
  'popup_dictionary_columns',
  'popup_instant_scroll',
  'popup_max_height',
  'popup_max_width',
  'popup_wheel_speed',
  'qb_connection_config',
  'reading_goal_daily_chars',
  'reading_goal_weekly_chars',
  'remote_lookup_enabled',
  'reverse_navigation_bar',
  'reverse_reader_bottom_bar',
  'saved_tags',
  'scan_non_japanese_text',
  'shelf_sort_mode',
  'show_expression_tags',
  'show_floating_lyric',
  'show_media_notification',
  'show_remote_entries',
  'startup_default_dictionary_tab',
  'sync_backend_type',
  'texthooker_enabled',
  'texthooker_urls',
  'torrent_upload_intro_shown',
  'update_auto_install',
  'update_beta_channel',
  'update_custom_proxy',
  'update_debug_channel',
  'update_never_remind',
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
  'video_download_target_source_id',
  'video_fit_mode',
  'video_immersive_mode',
  'video_lock_window_aspect_ratio',
  'video_mining_animated_format',
  'video_mining_image_mode',
  'video_mining_still_format',
  'video_mpv_config',
  'video_mpv_shader_dir',
  'video_remote_subtitle',
  // 用户停用的内置视频资源索引器 id（逗号分隔，默认空 = 全部启用）。
  // 与 discovery_disabled_sources 同形；自配 Torznab 各自带 enabled，不进这里。
  'video_resource_disabled_sources',
  'video_resource_torznab_config',
  'video_respect_ass_style',
  'video_secondary_subtitle_blur',
  'video_secondary_subtitle_obscure_hide',
  'video_shaders_enabled',
  'video_sort_mode',
  'video_subtitle_backfill_after_scrape',
  'video_subtitle_blur',
  'video_subtitle_list_auto_scroll',
  'video_subtitle_list_font_scale_index',
  'video_subtitle_list_width',
  'video_subtitle_obscure_hide',
  'video_subtitle_opensubtitles_config',
  'video_subtitle_style',
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
  'media_source_secret_',
  'src:',
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
  'jimaku_api_key',
  'yomitan_api_key',
};

/// app 侧偏好键登记（架构重构 F1）：不归某个模块自带登记的固定键与全部动态键族。
///
/// 设备本地 / 安装级的固定键由 `SyncRepository.prefKeyDefs` 登记，功能模块开关、内置
/// 浏览器、页面背景、备份内容注册表各在自己的文件里登记，全部经
/// `fushi_pref_registry.dart` 的 [kFushiPrefRegistry] 汇总。各通道（Profile 快照、
/// 备份、设置同步、ctl 打码）只从登记表派生，不再各写一份名单——新增一个键只改一处声明。
///
/// 没进登记表的键（`kKnownPreferenceKeys` 里那批只登记了名字的）按 [PrefPolicy.profile]
/// 处理，名字像凭据的照旧按凭据拦（[PrefKeyRegistry.policyOf] 的形状兜底）。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_pref_keys.dart'
    show kLyricsModeBookPrefDbPrefix;
import 'package:fushi_engine/media/override_title_key.dart';
import 'package:fushi_engine/media/source_library/book_library_prune.dart'
    show kBookSourceScanIndexPrefKeyPrefix;
import 'package:fushi_engine/media/tracking/media_tracking_service.dart'
    show kTrackingSeriesMergeDeclinedPrefSuffix;
import 'package:fushi_engine/profile/profile_document.dart'
    show kObsoleteGalgameUpscalingModePrefKey;
import 'package:fushi_engine/sync/online_library_sync.dart'
    show OnlineLibraryMailbox;
import 'package:fushi/src/media/video/video_online_services_preferences.dart';
import 'package:fushi/src/media/video/video_screenshot_destination.dart'
    show kVideoScreenshotDirectoryPref;
import 'package:fushi/src/models/preference_keys.dart'
    show
        kLibraryManualOrderPrefKeyPrefix,
        kMiningTtsFallbackVoiceProfilePrefKeyPrefix,
        kMusicScanParserRevisionPrefKeyPrefix,
        kSectionTabOrderPrefKeyPrefix,
        kSrsDayRolloverPendingPrefKeyPrefix,
        kSrsDayRolloverSeenPrefKeyPrefix,
        kSrsLapisMigrationReminderPrefKey,
        kVideoOrientationPrefKeyPrefix;
import 'package:fushi/src/models/preferences_repository.dart'
    show PreferencesRepository;

/// app 侧固定键与键族的登记（见文件头）。
final List<PrefKeyDef> kAppPrefKeyDefs = <PrefKeyDef>[
  // ── 固定键：不随 Profile 的本安装状态、凭据 ──────────────────────────────
  // qBittorrent WebUI 连接配置：{host, port, username, password} JSON，密码明文。
  PrefKey<String>(
    'qb_connection_config',
    defaultValue: '',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  // 手动 HTTP 代理登录名；密码由 `password` 形状兜底命中，两者都不得随备份出境。
  PrefKey<String>(
    'network_proxy_username',
    defaultValue: '',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  PrefKey.untyped(
    'video_anidb_username',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  PrefKey.untyped(
    'video_anidb_password',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  PrefKey.untyped(
    'video_anidb_udp_api_key',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  // 第三方服务 API key（都被 `api_key` 子串覆盖，显式列出以便审计时一眼看全）。
  PrefKey<String>(
    'yomitan_api_key',
    defaultValue: '',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  PrefKey<String>(
    'jimaku_api_key',
    defaultValue: '',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  PrefKey<String>(
    'video_subtitle_subdl_api_key',
    defaultValue: '',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  PrefKey.untyped(
    'manga_cloud_ocr_api_key',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  PrefKey.untyped(
    'video_scraper_tmdb_api_key',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  PrefKey<String>(
    'music_acoustid_api_key',
    defaultValue: '',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  PrefKey.untyped(
    'video_metadata_fanart_api_key',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  PrefKey.untyped(
    'video_metadata_bangumi_token',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  PrefKey.untyped(
    'video_metadata_douban_authorized_token',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  // Bangumi 追番同步 access token（media_tracking_service.dart）。此前只靠
  // `token` 子串兜底才被拦——形状兜底是防漏网的最后一道，真凭据必须点名
  //（apikey 同步设定重设计 2026-08-17：名单对称性审计）。
  PrefKey.untyped(
    'media_tracking_bangumi_access_token',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  // 授权端点可能是私有服务 URL，也可能携带 query credential；它的名字没有
  // token/api_key 形状，必须显式点名，避免备份/Profile 分享时旁路出境。
  PrefKey.untyped(
    'video_metadata_douban_authorized_endpoint',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  PrefKey.untyped(
    'active_profile_id',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  // 绑定临时切换前用户自己选的配置 id：与 active_profile_id 同族。
  PrefKey.untyped(
    'profile_fallback_id',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  PrefKey<bool>(
    'first_time_setup',
    defaultValue: true,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  // 新手引导完成标志与 first_time_setup 同族：描述本安装的状态，不随 Profile 切换。
  PrefKey<bool>(
    'onboarding_completed',
    defaultValue: true,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  PrefKey<bool>(
    'onboarding_finished',
    defaultValue: true,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  PrefKey<bool>(
    'onboarding_home_card_dismissed',
    defaultValue: false,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  // 「下载 → 浏览」一次性搬迁提示的已处理标记：同族。进快照的话，切到一个
  // 标记落地前建的老 Profile 会把它删掉，关着浏览的用户又被提示一遍。
  PrefKey<bool>(
    'browse_moved_notice_handled',
    defaultValue: false,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  // 已删除的「库页现在默认封面网格」一次性提示的已处理标记（BUG-5060，不再读写）：
  // 存量库里还留着这一行，仍按同族排除，免得把描述本安装的死键带进 Profile 快照。
  PrefKey.untyped(
    'library_layout_default_notice_handled',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  // BT / 磁力下载的 P2P 说明「不再提示」：同族（描述本安装看过说明，不随
  // Profile 切换重新弹出）。
  PrefKey<bool>(
    'p2p_download_notice_dismissed',
    defaultValue: false,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  // 「已收进托盘」一次性系统通知提示过了：同族（描述本安装见过提示，不随 Profile
  // 切换重新弹出）。
  PrefKey<bool>(
    'desktop_tray_hint_shown',
    defaultValue: false,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  // 「词典格式可以升级」提示的「以后再说」：描述本机词典目录的状态，同族。
  PrefKey<bool>(
    'dict_format_upgrade_prompt_dismissed',
    defaultValue: false,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  PrefKey<bool>(
    'game_resource_notice_dismissed',
    defaultValue: false,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  // 复习页旧 Lapis 迁移横幅的「不再提醒」：同族。进快照的话，切到这个键落地前建的
  // 老 Profile（含媒体绑定的临时切换）会把它删掉，横幅下次启动又弹出来。
  PrefKey<bool>(
    kSrsLapisMigrationReminderPrefKey,
    defaultValue: true,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  // 封面模式迁到片段默认的一次性标记：同族。进快照的话，切 Profile 会把旧值 gif
  // 带回来，下次启动迁移重跑，把用户此后自己选的 GIF 又改成片段。
  PrefKey.untyped(
    'mining_image_mode_install_default',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  // 「工具栏样式强制悬浮」一次性迁移标记：同族（迁移本身会改写各 Profile 快照
  // 里的 reader_toolbar_style，标记只描述本安装）。
  PrefKey<bool>(
    PreferencesRepository.readerToolbarStyleFloatingMigratedKey,
    defaultValue: false,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  PrefKey.untyped(
    kVideoOnlineServicesSetupDismissedPref,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  PrefKey<int>(
    'current_home_tab_index',
    defaultValue: 0,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  // 宽屏导航 rail 的展开 / 收起记的是本机窗口布局，与 current_home_tab_index
  // 同族；进快照的话切 Profile 会把侧栏忽宽忽窄地翻过去。
  PrefKey<String>(
    'nav_rail_expanded',
    defaultValue: '',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  PrefKey.untyped(
    'startup_default_dictionary_tab',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKey.untyped(
    'app_ui_scale',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKey.untyped(
    'app_ui_scale_mode',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKey.untyped(
    'app_locale',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  // E-ink mode describes the physical display the app is running on (same
  // family as app_ui_scale), never a per-profile reading preference —
  // snapshotting it would flip the whole app's colors on profile switch.
  PrefKey.untyped(
    'eink_mode',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  // 墨水屏「每 N 页全刷」的间隔 / 方式：同样描述这块屏幕（厂商通道可不可用是
  // 设备属性），与 eink_mode 同族。
  PrefKey.untyped(
    'eink_full_refresh_interval',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKey.untyped(
    'eink_full_refresh_method',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKey<String>(
    'last_selected_deck',
    defaultValue: 'Default',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  PrefKey.untyped(
    'last_selected_dictionary_format',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  PrefKey.untyped(
    'last_selected_model',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  PrefKey<bool>(
    'update_never_remind',
    defaultValue: false,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKey<bool>(
    'update_auto_install',
    defaultValue: false,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  // 扩展后台自动更新与 update_auto_install 同族：扩展装在本机、不分 Profile，
  // 切 Profile 把安装策略翻掉没有意义。
  PrefKey.untyped(
    'mihon_extension_auto_update',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKey<bool>(
    'update_beta_channel',
    defaultValue: false,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  // HBK-AUDIT-045: keep ALL update-channel/policy keys app-global so the
  // debug channel isn't asymmetrically profile-scoped vs the others.
  PrefKey<bool>(
    'update_debug_channel',
    defaultValue: false,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  // The app-wide network proxy (TODO-871; the only proxy setting since the
  // download-specific mode was folded into it) describes this device's
  // network, not a reading profile — never per-profile snapshot.
  PrefKey<String>(
    'update_custom_proxy',
    defaultValue: '',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKey<bool>(
    'network_proxy_p2p_enabled',
    defaultValue: false,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKey<String>(
    'network_proxy_p2p_mode',
    defaultValue: '',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  // BUG-1980 同族：出口模式（自动/直连/手动）描述的是这台设备的网络，地址已经是
  // 设备本地的，模式却跟着 Profile 走 = 切一次 Profile 就把全局网络出口翻掉，
  // 事后极难归因。
  PrefKey<String?>(
    'network_proxy_mode',
    defaultValue: null,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  // GitHub 加速镜像开关同族：描述的是这台设备所处的网络 / 安全软件环境，跟着
  // Profile 走会让切 Profile 悄悄改掉下载出口。
  PrefKey<bool>(
    'network_github_mirrors_enabled',
    defaultValue: true,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  // 更新下载源与 update_beta_channel / update_debug_channel / update_auto_install
  // 同族（HBK-AUDIT-045：所有更新通道/策略键保持 app-global）。
  PrefKey<String>(
    'update_download_source',
    defaultValue: 'auto',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  // 截图目录与 download_save_root 同族同理：它描述的是这台设备的磁盘，不是阅读
  // Profile。随 Profile 走会让切 Profile 后截图落到本机不存在的路径上。
  // 去向枚举（对话框/剪贴板/目录）是真偏好，照常随 Profile。
  PrefKey<String>(
    kVideoScreenshotDirectoryPref,
    defaultValue: '',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKey.untyped(
    kObsoleteGalgameUpscalingModePrefKey,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  // TODO-855: the monotonic prefs-version counter is the cross-process signal
  // the :popup process reads to decide whether to refresh its warm-reuse
  // pref cache. It must stay app-global and monotonic — snapshotting it
  // into a profile (and restoring/wiping it on profile switch) would make
  // the counter non-monotonic and break change detection.
  PrefKey.untyped(
    PreferencesRepository.prefsVersionKey,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  PrefKey<String>(
    'network_proxy_password',
    defaultValue: '',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.setting,
  ),
  // ── 动态键族 ───────────────────────────────────────────────────────────
  // BUG-1018 (A4) / BUG-1317 / BUG-1488：按条目的书名改名是**内容**不是阅读偏好，持久形态
  // `src:<sourceId>:override_title://<mediaIdentifier>`（旧形态
  // `src:<sourceId>:override_title://<sourceId>/<uniqueKey>` 在读时回退迁移前并存），所以按
  // [kOverrideTitleKeyMarker] 子串认：不进 Profile 快照（改名跨 Profile 可见），备份不归
  // 设置类别（不勾设置导出时改名不丢），互联 host 清单与合并导入也认作内容。
  PrefKeyFamily.untyped(
    marker: kOverrideTitleKeyMarker,
    policy: PrefPolicy.content,
    kind: PrefKind.setting,
  ),
  // 导入记忆 `<uniqueKey>/last_picked_file`：这台设备上次选的文件路径，不随 Profile。
  PrefKeyFamily.untyped(
    suffix: '/last_picked_file',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'current_source/',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  // BUG-1019: per-book audiobook playback STATE lives in prefs
  // (`audiobook_<kind>_<bookKey>`, see AudiobookRepository). These are
  // progress/content data — the same family backup_service already treats as
  // the `progress` category (`key NOT LIKE 'audiobook_pos_%'` in
  // settingsPrefPredicate) — NOT per-profile reading preferences. Snapshotting
  // them meant a profile switch pruned the position prefs (progress reset to
  // 0) while restoring a stale speed snapshot (playback suddenly fast/slow).
  // `audiobook_pos_` also covers `audiobook_pos_at_` (its LWW timestamp twin).
  PrefKeyFamily.untyped(
    prefix: 'audiobook_pos_',
    policy: PrefPolicy.progress,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'audiobook_follow_',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKeyFamily.untyped(
    prefix: 'audiobook_delay_',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKeyFamily.untyped(
    prefix: 'audiobook_speed_',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKeyFamily.untyped(
    prefix: 'audiobook_volume_',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKeyFamily.untyped(
    prefix: 'audiobook_image_pause_',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKeyFamily.untyped(
    prefix: 'audiobook_health_overlay_',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  // TODO-2487: airing calendar fetch cache is device-local network cache,
  // not a reading preference. Snapshotting it per profile would restore
  // stale schedules on profile switch for zero benefit.
  PrefKeyFamily.untyped(
    prefix: 'airing_calendar_',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  // 合集详情页每合集排序偏好：键里是本机合集自增 id（设备本地状态），换
  // Profile 不该剪掉或串到别的合集上。
  PrefKeyFamily.untyped(
    prefix: 'collection_detail_sort_',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  // 书 / 漫画来源的扫描索引（后缀 = 本机来源 id，JSON：源相对路径 → 书 uid +
  // 「不是本类媒体」负向表）。是扫描器的设备本地状态，不是阅读偏好：进快照的话
  // 切 Profile 会把它剪掉或换回旧值，下一次扫描就把已导入的卷当成新卷重判。
  // 书 / 漫画来源的扫描索引（后缀 = MediaSources.id，JSON：源相对路径 → 书 uid，
  // 外加「不是本类媒体」的负向表 源相对路径 → 内容指纹）。无头服务端书 / 漫画根扫描
  // （BUG-2816）与 app 漫画来源扫描（BUG-3574）共用（引擎 book_library_prune.dart）；
  // 设备本地状态，不进 Profile 快照（偏好键登记表 kFushiPrefRegistry）。
  PrefKeyFamily.untyped(
    prefix: kBookSourceScanIndexPrefKeyPrefix,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.state,
  ),
  // 每本书独立记忆的歌词模式与 audiobook_follow_ 同族：按书的阅读状态，不是
  // 阅读偏好。进快照的话切 Profile（进出歌词模式本身就会切到 lyrics 媒体类型
  // 的 Profile）会把这本书刚写下的模式剪掉或换回旧值。
  PrefKeyFamily.untyped(
    prefix: kLyricsModeBookPrefDbPrefix,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  // 库页顶部页签的用户顺序与底栏模块顺序同族：描述这台设备的入口布局。进快照
  // 的话切 Profile 会把刚排好的顺序剪掉或换回旧值。
  PrefKeyFamily.untyped(
    prefix: kSectionTabOrderPrefKeyPrefix,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKeyFamily.untyped(
    prefix: kLibraryManualOrderPrefKeyPrefix,
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKeyFamily.untyped(
    prefix: kMiningTtsFallbackVoiceProfilePrefKeyPrefix,
    policy: PrefPolicy.local,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: kMusicScanParserRevisionPrefKeyPrefix,
    policy: PrefPolicy.local,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: kSrsDayRolloverPendingPrefKeyPrefix,
    policy: PrefPolicy.local,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: kSrsDayRolloverSeenPrefKeyPrefix,
    policy: PrefPolicy.local,
    kind: PrefKind.state,
  ),
  // JSON：`sync_online_library_peer:<设备 id>`——互联 host 的在线源条目清单信箱
  // （`OnlineLibraryMailbox.keyPrefix`，fushi_engine `online_library_sync.dart`，拍板台
  // mY5VWg1nD-）。设备本地（偏好键登记表的设备本地键族）。
  PrefKeyFamily.untyped(
    prefix: OnlineLibraryMailbox.keyPrefix,
    policy: PrefPolicy.local,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'media_source_secret_',
    policy: PrefPolicy.credentialOnly,
    kind: PrefKind.state,
  ),
  // 调轴 LWW 时间戳孪生键（互联完整支持批次；与 audiobook_pos_at_ 同范式）。
  PrefKeyFamily.untyped(
    prefix: 'audiobook_delay_at_',
    policy: PrefPolicy.unscoped,
    kind: PrefKind.setting,
  ),
  PrefKeyFamily.untyped(
    prefix: 'audiobook_pos_at_',
    policy: PrefPolicy.progress,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'gal_capture_memory::',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'gal_lookup_surface_v1::',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  // JSON：单游戏 gal 制卡设置覆盖层（后缀 = galgames.id，GalGameMiningOverrides，
  // 反馈 3dRZdakRdJ）。没覆盖的项跟随全局 gal_mining_* 键。
  PrefKeyFamily.untyped(
    prefix: 'gal_mining_overrides::',
    policy: PrefPolicy.profile,
    kind: PrefKind.setting,
  ),
  // JSON：`music_lyric_coverage_<trackUid>`——这首歌已计过字数的歌词句的曲目时间窗并集
  // （IntervalCoverage，music_study_tracker.dart 的 kMusicLyricCoveragePrefPrefix，拍板台
  // qQTh1Q3G9U）。与视频 `video_watch_coverage_<uid>` 同一存放形态；跨设备同步缺口见 BUG-5289。
  PrefKeyFamily.untyped(
    prefix: 'music_lyric_coverage_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'src:',
    policy: PrefPolicy.profile,
    kind: PrefKind.setting,
  ),
  // int（毫秒，v101）：`updates_last_check_<UpdateFeedKind.dbValue>`——某个域上次
  // 后台检查完成的时刻。到期判据只读它，失败也照记（否则断网时每个 tick 都重试）。
  PrefKeyFamily.untyped(
    prefix: 'updates_last_check_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  // JSON：`tts_resume_<bookKey>` TTS 朗读断点（章 + 句首匹配偏移 + 句内毫秒 +
  // 音频缓存键，TtsResumePoint）。
  PrefKeyFamily.untyped(
    prefix: 'tts_resume_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'video_danmaku_episode/',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  // String：`video_orientation::<bookUid>`——「记住每部作品的方向」开着时，这部作品
  // 上次手动转到的方向（`landscape` / `portrait`，拍板台 P9AS-fvjJh）。
  PrefKeyFamily.untyped(
    prefix: kVideoOrientationPrefKeyPrefix,
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  // 视频远端断点/播放偏好三件套族（PositionPrefKeys，fushi_library_host_service.dart）：
  // `<前缀><bookUid>` 值键 + `<前缀>at_<bookUid>` 时间戳键，逐字段 LWW 跨设备同步
  //（播放偏好同步泛化批：调轴/音轨/副字幕源/副字幕调轴；看完标记 = 手动标记已看 /
  // 未看的 LWW 镜像，值是 completedAt 毫秒、0 = 未看完）。
  PrefKeyFamily.untyped(
    prefix: 'video_remote_audio_track_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'video_remote_audio_track_at_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'video_remote_completed_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'video_remote_completed_at_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'video_remote_delay_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'video_remote_delay_at_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'video_remote_position_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'video_remote_position_at_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'video_remote_secondary_delay_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'video_remote_secondary_delay_at_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'video_remote_secondary_subtitle_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    prefix: 'video_remote_secondary_subtitle_at_',
    policy: PrefPolicy.profile,
    kind: PrefKind.state,
  ),
  PrefKeyFamily.untyped(
    suffix: kTrackingSeriesMergeDeclinedPrefSuffix,
    policy: PrefPolicy.local,
    kind: PrefKind.state,
  ),
];

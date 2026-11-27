import 'dart:io';

import 'package:test/test.dart';

/// `flutter test` 把测试文件的整个 import 闭包编进内存。2026-11-05 量到
/// `fushi/lib` 2330 个文件里有 1329 个互相 import 成一个环，主要由
/// `lib/utils.dart` / `models.dart` / `pages.dart` / `media.dart` /
/// `creator.dart` 五个顶层 barrel 撑起来：只 import 了
/// `preferences_repository.dart` 的模型测试，也要编三千多个文件（frontend_server
/// 约 3 GB）。各文件已改成直接 import 用到的库；本守卫防环长回来：
///
/// 1. `lib/` / `test/` / `integration_test/` / `test_driver/` 里不许 import 顶层
///    barrel（barrel 文件暂留给并发分支过渡，合完后删）。合并别的分支后这条红了，
///    在仓库根跑 `tool/barrel_imports/bin/expand_barrel_imports.dart`（用法见文件头）
///    机械换掉；
/// 2. 最大强连通分量（互相可达的文件集合）不超过 [kMaxCycleFiles]，只许往下调；
/// 3. [kAppModelFreeDirs] 目录下**每个**文件（含传递依赖）的闭包里不许出现
///    `app_model.dart`。
///
/// 换掉 barrel 之后大环几乎没缩（2426 个文件里仍有 1355 个），根子是 AppModel 上帝
/// 对象：底层的 models / utils / storage 里有文件直接或间接 import 了它
/// （`preferences_repository → error_log_service → fushi_toast → … →
/// fushi_header_search → app_model` 之类），于是整个底层都被拖进环。2026-11-05
/// 把底层用到的符号挪到更底层的文件、读 AppModel 的件挪到上层或改成参数注入后，
/// 这三个目录（278 个文件）的闭包全部碰不到 app_model，最大环降到 2435 个文件里
/// 的 710 个。剩下的环由 AppModel 直接 import 页面 / 媒体源 / 制卡字段撑着，要再缩
/// 得拆 AppModel 本身。
///
/// 合入 develop（2026-11-05，#2873）时 develop 新增了 4 个本就读 AppModel 的 UI /
/// provider 文件（`music_apple_music_pages`、`game_stream_client_page`、
/// `srs_home_stats`、`extension_image_ocr_service`），上限按实测调到 713；同一次合并
/// 里 develop 把整条浏览器扩展 sync API 经图形字幕 OCR 接进环的那条边已拆掉
/// （值类型挪到 `graphic_subtitle_ocr_types.dart`），没靠上限放过。
///
/// 2026-11-10 develop 实测涨到 714（几个 PR 单独都 ≤713，合在一起超了）。根子是
/// AI 助手（`ai_agent_controller` / `ai_agent_assistant_host` / `ai_mcp_ui`）直接
/// import `ops/op_routes.dart`：路由表依赖全部 `ctl_<域>_routes.dart`，后者又读
/// AppModel，整个操作目录（约 78 个文件，含 20 多个 `ctl_settings_body_*`）都被拖进
/// 大环。改成 app 根组件经 `registerAppOpContext(buildInProcessInvoker:)` 注入组装
/// 函数、AI 助手只依赖 `app_op_context.dart` 的窄接口后，最大环降到 636，上限随之下调。
///
/// 2026-11-11 批量合并后实测 643。拆掉两条底层边：曲目入库层
/// （`music_remote_tracks`，AppModel 建音乐会话就 import）为一个纯函数
/// `musicServerPlayItem` 反向 import 读 AppModel 的 `music_servers`（挪到
/// `music_server_play_item.dart`），把音乐会话 / 历史 / 曲库数据四个文件拖进了环；
/// 有声书版本记录为取对端身份 import `hidden_remote_books`（它要连云盘远端书客户端，
/// 挪到 `remote_book_source_host.dart`）。剩下 +2 是音乐页簇新增的两个 UI 文件
/// （`music_playlist_actions` / `music_playlist_track_column`，本就读 AppModel、
/// 与其它音乐页互相 import），与 2026-11-05 那 4 个 UI 文件同理，上限按实测调到 638。
///
/// 同日再合 develop（343 个提交）后实测 643，新进环的 5 个文件都没有把底层接上 UI：
/// 4 个本就读 AppModel 的 UI 页 / 流程（`gal_line_tts_voice_overrides_page`、
/// `audiobook_subtitle_export_flow`、`manga_ocr_manager_page`、设置页动作
/// `database_check_action`），与上面同理；`sync/synced_book_import` 只 import
/// `pdf_importer`，它进环是因为 `pdf_importer → media_cover_service` 早已在环里
/// （`media_cover_service` 直接 import `app_model` 与 UI 的 `video_import_dialog`）。
/// 上限按实测调到 643；拆 `media_cover_service` 对 AppModel / 导入对话框的依赖是下一步。
///
/// 2026-11-15 合入设置重整（#3277）新增两个一级分类的 schema 文件（`settings_schema_general` /
/// `settings_schema_navigation`）。设置 schema 整族本就在环里（`settings_schema.dart`
/// 注册它们，它们读 AppModel），新分类没有别的落脚处，上限随之 +2 到 645——
/// 新增的是本就读 AppModel 的 UI 文件，没有把任何底层模块接进环。
///
/// 同日合入服务端词典（#3147）新增 `sync/dictionary_transfer_service`（词典管理页按 host
/// 推送 / 下载单本词典）：它的唯一同步入口 `runHostDictionaryTransfer` 在 `sync_auto_trigger`
/// 里（与其它同步路径共用忙闸 / 在飞登记），而 `sync_auto_trigger` 本就在环里，AppModel 又持有
/// 这个服务，于是 +1 到 646。新进环的是新文件本身，没有把任何既有底层模块接进环。
///
/// 2026-11-17 develop 实测 653（+11 −4）：新进环的多是本就读 AppModel 的 UI / 设置文件
/// （收听提醒、NSFW 封面、库页恢复 / 覆盖快照提示、来源共享勾选等）。没有按「新文件读 AppModel」
/// 上调，而是拆掉一条底层边：视频图形字幕 OCR（`graphic_subtitle_ocr`）只用直读 OCR 的值类型
/// （引擎由调用方注入），却 import 了 `manga_reader_stream_ocr`（它解析引擎要读 AppModel 的
/// OCR 设置），把 `video_player_controller` 等 13 个视频文件拖进了环。值类型挪到
/// `manga_stream_ocr_types.dart` 后最大环降到 640，上限随之下调。
///
/// 2026-11-18 合入首页 / 库页重设计（#3515）实测 650：新进环的是本就读 AppModel 的导入页、
/// 壳布局选择、游戏 / 音乐新组件。同样不调上限，拆掉两条底层边：在线漫画库服务与 PDF 导入
/// 只用 `MediaCoverService.applyCoverBytes`（引擎 `writeCoverBytesAtomically` 的薄委派），
/// 却因此 import 了整个封面服务（它读 AppModel），把漫画下载 / 互联 / 同步编排等 20 个文件
/// 拖进环。改为直接调引擎 writer（封面写盘守卫本就认它为收口）后最大环降到 630。
///
/// 2026-11-19 合入漫画有声 / 小说 TTS 制作台（#3681，含 #3717）实测 651：漫画有声、TTS
/// 制作台、声线包的服务层（演出稿 / 声线存储、渲染、匹配、标注任务等）直接 import
/// AppModel，只为取数据库 / 数据目录 / 偏好 / 有声书会话。不调上限，改成窄依赖：
/// 新增 `AudioProductionHost`（AppModel 实现、调用方注入），连同 develop 上本就因此在
/// 环里的 `tts_studio_service` / `tts_render_runner` / `tts_cast_annotator` 一并改收它；
/// 漫画有声书音源的书名改注入 `MangaBookTitleResolver`（不再 import `display_title`）；
/// `AudiobookSessionStartRequest` 拆到叶子文件，断开 `manga_audio_session` ↔
/// `audiobook_session_launcher` 互引；`real_path_directory_picker` 改收
/// `ExternalStorageAccess`；`AiSavedPromptButton` 的存取由调用方注入、不再读
/// `appProvider`。最大环降到 622（剩下进环的是本就读 AppModel 的制作台页面），上限随之下调。
///
/// 2026-11-20 学习目标记录（目标面板、「语言目标」格、设置「目标」子页）实测 627。拆掉
/// 四条边：统计层的 `study_goals` / `study_goal_language_scope` 只读偏好与库，改收
/// `PreferencesRepository` / `FushiDatabase`，不再 import AppModel；`study_goals` 为两个
/// 文案函数 import 的 `stat_shared`（读 AppModel 的 UI 件）换成挪到统计层的
/// `stats/stat_format.dart`（`stat_shared` 原样转出）；目标面板与共用视觉件改收窄接口
/// `StudyGoalHost`（AppModel 实现）。剩下进环的只有新分类 schema 文件
/// `settings_schema_study_goals`（设置 schema 整族本就在环里，同 2026-11-15 的理由），
/// 上限 +1 到 623。
///
/// 2026-11-20 复习换代（协议 4）第六波合流合入 develop 实测 625（+4 −1）：新进环的 4 个是换代新加、本就读
/// AppModel 的复习文件——迁移控制器 `srs_gen4_migration_controller`（主库开关 / 关库静默要读
/// AppModel）、保留副本 `srs_retained_copy`（库目录按 AppModel 取）、迁移页 `srs_generation_view` 与载入失败页
/// `srs_load_error`（后者被全部复习页 import、前者经它进环，二者都靠迁移控制器碰到 AppModel）；出环的 1 个是
/// 换代删掉的预演区块 `srs_gen4_rehearsal_section`。逐个核过：没有底层（models / utils / storage / 服务层）
/// 文件因此被接进环，与 2026-11-05 / 11-15 那几次「新增的是本就读 AppModel 的 UI 文件」同理，上限按实测调到 625。
///
/// 2026-11-21 develop 实测 627（+5 −3）。不调上限，拆掉三条把值类型 / 窄能力接进环的边：
/// 网页视频会话（`web_video_session`）只为暖机两步 import 读 AppModel 的 `WebAdblockService`，
/// 把会话与选轨 `web_video_track_selection` 拖进环——改收叶子接口 `WebAdblockWarmup`
/// （`web_adblock_wiring.dart`，服务实现它）；扫描临时目录清理 `source_scan_temp` 只用
/// 扫描占用表，却 import 了自动扫描调度器 `source_auto_scan`（它反向 import 扫描器）——占用表与
/// 进度挪到叶子 `source_scan_activity.dart`；互联下载的任务映射只用值类型 `BackgroundTask`，
/// 却 import 了后台任务入口 UI——值类型挪到叶子 `background_task.dart`。最大环降到 623，剩下
/// 新进环的 1 个是本就读 AppModel 的音乐 UI `music_listen_from_video`，上限随之下调到 623。
///
/// 2026-11-22 develop 实测 624：共用查词宿主 `shared_lookup_popup_host`（#4036）import 弹窗栈
/// controller，而 controller 为了手柄四个动作直接持 `GlobalKey<DictionaryPopupWebViewState>`、
/// import 读 AppModel 的 `dictionary_popup_webview`（逻辑对象反向依赖 UI）。反转依赖：窄接口
/// `DictionaryPopupRealmState` 放叶子 `dictionary_popup_realm.dart`，WebView State 实现它，
/// controller 只持接口；controller 与宿主一起出环，最大环 622，上限下调到 622。
///
/// 2026-11-22 学习目标记录（#3980）合入：相对 develop 只多 `settings_schema_study_goals`
/// 一个文件（「目标」设置子页 schema；设置 schema 整族本就经 AppModel 在环里，同族其它
/// schema 文件同样在环），上限 622 + 1 = 623。其余新目标文件都用窄接口
/// （`study_goal_host.dart` / `stat_format.dart`）留在环外。
/// 同次合流时 develop 实测已是 624（守卫红）：有声漫画起播统一取书目元数据（b424304574）让
/// `audiobook_session_book_meta` import `reader_fushi_source` 读书名 override，它与
/// `manga_audio_session` 经漫画阅读器页进环。改由调用方注入 `SessionTitleOverride`，两个
/// 文件出环，develop 回到 622。
///
/// 2026-11-22 批量合并后 develop 实测 636（+13）。不调上限，拆三处：作品隐私口径
/// `media_visibility`（几十个库页 import）为一个 StreamProvider 直接 import AppModel，
/// 隐私对话框 / 上锁对话框 / 追踪页 / 合集管理页随它进环——Riverpod 接线挪到
/// `media_visibility_providers.dart`（只有 app 根 import）；NSFW 封面件 `media_nsfw_cover`
/// 同理（AppModel 只为 `watchMediaNsfwSnapshot` import 它，音乐封面 / 队列 / 歌词背景等
/// 6 个音乐 UI 件经它进环），provider 挪到 `media_nsfw_providers.dart`；手柄查词的命中量长
/// `lookup_match_measure` import AppModel 与 `base_source_page`——改收窄接口
/// `LookupMatchSearchHost`（AppModel 实现），`lookupHighlightCharCount` 下沉到该文件。
/// 剩下新进环的只有新分类 schema 文件 `settings_schema_media_privacy`（设置 schema 整族
/// 本就在环里，同 2026-11-15 的理由），而 `media_nsfw_cover` 出环，回到 623。
///
/// 2026-11-24 develop 实测 627（+5 −1）。不调上限，拆两处：#4196 系列追踪的「打开系列卡」
/// 实现 `tracking_series_card_open` 直读 AppModel（取书目 / 模块开关），又被追踪对话框、
/// 追踪页当默认参数 import，于是两者连同系列卡追踪区一起进环——签名挪到叶子
/// `tracking_series_card_opener.dart`、对话框 / 追踪页改成必填参数由调用方传，实现改读窄接口
/// `TrackingSeriesCardHost`（AppModel 实现），四个文件全出环；#4250 的首页默认配置胶囊
/// `home_profile_chip` 为取库 / 打开配置管理 / 切换配置 import AppModel 与
/// `profile_view_model`——改由首页注入库与两个回调。最大环降到 622，上限随之下调。
///
/// 2026-11-26 批量合并后实测 627（develop 626 + 本轮 1）。新进环 5 个：查词弹窗排队覆盖回执、
/// 流媒体书选集、网页档字幕生成、gal 场景卡中止文案、字段 AI 共用入口。不调上限，拆五条底层边：
/// galgame 浮窗后台写卡登记 `overlay_queued_mines` 只为两个回执值类型 import
/// `dictionary_popup_webview`——值类型挪到叶子 `dictionary_popup_queued_overwrite.dart`
/// （webview 原样 re-export）；流媒体书选集 `stream_book_episodes` 为单集封面 import 读 AppModel
/// 的 `media_cover_source`——单集没有书目分支，改用 `media_cover_standalone_source`；gal 中止
/// 文案 `gal_hook_mining_failure_text` 为结果值类型 import 整个编排器——结果类型挪到叶子
/// `gal_hook_mining_result.dart`（编排器 re-export）；视频字幕服务本体
/// `app_video_subtitle_service` 只为一个装配函数 import AppModel——装配挪到
/// `app_video_subtitle_service_entry.dart`，服务连同只持服务的字幕生成面板 / 术语表页 / 网页档
/// 字幕生成一起出环；它要的硬字幕 OCR `burned_in_subtitle_ocr` 为建服务 import 读 AppModel 的
/// `manga_ocr_provider`——纯工厂挪到 `manga_ocr_service_factory.dart`（provider re-export）。
/// 剩下新进环的只有本就读 AppModel 的 SRS 字段 AI 入口 `srs_field_ai_action` 与新装配入口，
/// 最大环降到 620，上限随之下调。
///
/// 2026-11-27 develop 实测 626（+6）：新进环的是复习捐赠三件（`srs_donation_banner` / `_page` /
/// `_providers`，复习首页 import，本身读 AppModel 与复习库 provider——`srs_providers` 直读
/// AppModel，整个复习模块都在环里，捐赠没有更窄的落脚处）与整库补字幕三件（控制器 / 端口实现 /
/// 面板）。不调上限，拆五条底层边：整库补字幕的控制器只为取库与建编排器、端口实现只为取偏好与
/// 解析 OCR 引擎、面板只为取控制器单例 import AppModel——控制器改收注入的库与 `createFill`，端口
/// 实现改收 `PreferencesRepository` 与 OCR 准备回调，面板改由调用方传控制器，AppModel 装配与
/// OCR 引擎解析挪到 `library_subtitle_fill_entry.dart`，三件出环；视频规格服务
/// `video_specs_service` 只为一个 provider import AppModel，把规格角标 / 规格面板一起拖进环——
/// provider 挪到 `video_specs_providers.dart`（只有视频库页 import）；放送日历取数
/// `airing_calendar_loader` 只读库 / 订阅 / 偏好缓存 / 下载出口，改收窄接口 `AiringCalendarHost`
/// （AppModel 实现），发现详情页与作品 logo 随它出环；远端字幕服务的装配函数
/// `appRemoteVideoSubtitleService` 只用库，改收 `FushiDatabase`，服务与远端字幕面板出环。最大环
/// 降到 617，上限随之下调。
///
/// 红了：新加的 import 把底层模块接到了 UI / AppModel 上。把用到的东西挪到
/// 更底层的文件，或改用参数 / 回调注入，不要调大上限、不要把文件从目录里豁免。
const int kMaxCycleFiles = 617;

const String kAppModel = 'lib/src/models/app_model.dart';

/// 这些目录下的所有文件（除 [kAppModel] 本身）都不许经 import 链连到 AppModel。
const List<String> kAppModelFreeDirs = <String>[
  'lib/src/models/',
  'lib/src/utils/',
  'lib/src/storage/',
];

/// 代表性的底层入口（目录级断言之外再钉一遍存在性，路径改了要跟着改）。
const List<String> kLeafEntries = <String>[
  'lib/src/models/preferences_repository.dart',
  'lib/src/models/theme_notifier.dart',
  'lib/src/storage/app_paths.dart',
  'lib/src/utils/misc/error_log_service.dart',
  'lib/src/utils/misc/platform_utils.dart',
  'lib/src/utils/components/fushi_material_components.dart',
  'lib/src/utils/adaptive/adaptive_widgets.dart',
  // 查词弹窗栈 controller 是纯逻辑对象，只经叶子接口 DictionaryPopupRealmState 持
  // WebView 层；直接 import dictionary_popup_webview.dart（读 AppModel）会把它和
  // 共用查词宿主 shared_lookup_popup_host 一起拖回大环（2026-11-22 实测 624）。
  'lib/src/pages/implementations/dictionary_popup_controller.dart',
  'lib/src/pages/implementations/dictionary_popup_realm.dart',
  // 作品隐私的口径本体与 NSFW 封面件被几十个库页 / 卡片 import；Riverpod 接线（读
  // AppModel）在各自的 `*_providers.dart`。本体再 import AppModel 就把音乐封面等 UI 件
  // 一起拖回大环（2026-11-22 实测 636）。
  'lib/src/media/privacy/media_visibility.dart',
  'lib/src/media/nsfw/media_nsfw_cover.dart',
  // 查词命中量长只经窄接口 LookupMatchSearchHost（AppModel 实现）查词。
  'lib/src/lookup/lookup_match_measure.dart',
  // 追踪对话框 / 追踪页只持「打开系列卡」的签名，实现经窄接口 TrackingSeriesCardHost
  // 读库与模块开关；默认参数直连读 AppModel 的实现会把它们拖回大环（2026-11-24 实测 627）。
  'lib/src/media/tracking/tracking_series_card_open.dart',
  'lib/src/media/tracking/book_tracking_dialog.dart',
  'lib/src/media/tracking/page/tracking_page.dart',
  // 首页默认配置胶囊的库与动作由首页注入。
  'lib/src/pages/implementations/home_profile_chip.dart',
  // 2026-11-26 拆出大环的五个件（见 [kMaxCycleFiles] 文档）：回执 / 结果值类型、单集封面、
  // 字幕服务本体与它的硬字幕 OCR 都不经 AppModel。
  'lib/src/lookup/overlay_queued_mines.dart',
  'lib/src/media/video/stream_book_episodes.dart',
  'lib/src/mining/gal_hook_mining_failure_text.dart',
  'lib/src/media/video/subtitle/app_video_subtitle_service.dart',
  'lib/src/media/video/subtitle/burned_in_subtitle_ocr.dart',
  'lib/src/media/video/web_video_subtitle_generation.dart',
  // 2026-11-27 拆出大环的件（见 [kMaxCycleFiles] 文档）：整库补字幕的控制器 / 端口实现 / 面板只收
  // 注入的依赖（AppModel 装配在 library_subtitle_fill_entry.dart）；规格服务与角标不经 provider
  // 接线读 AppModel；放送日历取数只经 AiringCalendarHost；远端字幕服务只收库。
  'lib/src/media/video/subtitle/library_subtitle_fill_controller.dart',
  'lib/src/media/video/subtitle/library_subtitle_fill_host.dart',
  'lib/src/media/video/subtitle/library_subtitle_fill_sheet.dart',
  'lib/src/media/video/video_specs_service.dart',
  'lib/src/media/video/cover_ui/video_specs_panel.dart',
  'lib/src/media/video/airing_calendar_loader.dart',
  'lib/src/media/video/subtitle/remote_video_subtitle_service.dart',
  'lib/src/media/video/subtitle/remote_video_subtitle_sheet.dart',
];

const List<String> kBarrels = <String>[
  'utils.dart',
  'models.dart',
  'pages.dart',
  'media.dart',
  'creator.dart',
];

final RegExp _directive = RegExp(
  r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// `lib/` 下的 import 图：键与值都是 `lib/...` 相对路径（`/` 分隔）。
Map<String, List<String>> _libGraph() {
  final Map<String, List<String>> graph = <String, List<String>>{};
  final List<File> files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList();
  final Set<String> known = files
      .map((File f) => f.path.replaceAll(r'\', '/'))
      .toSet();
  for (final File f in files) {
    final String path = f.path.replaceAll(r'\', '/');
    final String dir = path.substring(0, path.lastIndexOf('/'));
    final List<String> out = <String>[];
    for (final RegExpMatch m in _directive.allMatches(f.readAsStringSync())) {
      final String uri = m.group(1)!;
      String? target;
      if (uri.startsWith('package:fushi/')) {
        target = 'lib/${uri.substring('package:fushi/'.length)}';
      } else if (!uri.contains(':')) {
        target = _normalize('$dir/$uri');
      }
      if (target != null && known.contains(target)) out.add(target);
    }
    graph[path] = out;
  }
  return graph;
}

String _normalize(String path) {
  final List<String> parts = <String>[];
  for (final String seg in path.split('/')) {
    if (seg == '..') {
      parts.removeLast();
    } else if (seg != '.' && seg.isNotEmpty) {
      parts.add(seg);
    }
  }
  return parts.join('/');
}

/// 最大强连通分量的文件数（迭代 Tarjan，避免深递归）。
int _largestScc(Map<String, List<String>> graph) {
  final Map<String, int> index = <String, int>{};
  final Map<String, int> low = <String, int>{};
  final Set<String> onStack = <String>{};
  final List<String> stack = <String>[];
  int counter = 0;
  int largest = 0;
  for (final String root in graph.keys) {
    if (index.containsKey(root)) continue;
    final List<(String, int)> work = <(String, int)>[(root, 0)];
    index[root] = low[root] = counter++;
    stack.add(root);
    onStack.add(root);
    while (work.isNotEmpty) {
      final (String v, int i) = work.last;
      final List<String> edges = graph[v]!;
      if (i < edges.length) {
        work[work.length - 1] = (v, i + 1);
        final String w = edges[i];
        if (!index.containsKey(w)) {
          index[w] = low[w] = counter++;
          stack.add(w);
          onStack.add(w);
          work.add((w, 0));
        } else if (onStack.contains(w)) {
          low[v] = low[v]! < index[w]! ? low[v]! : index[w]!;
        }
      } else {
        work.removeLast();
        if (work.isNotEmpty) {
          final String parent = work.last.$1;
          low[parent] = low[parent]! < low[v]! ? low[parent]! : low[v]!;
        }
        if (low[v] == index[v]) {
          int size = 0;
          String w;
          do {
            w = stack.removeLast();
            onStack.remove(w);
            size++;
          } while (w != v);
          if (size > largest) largest = size;
        }
      }
    }
  }
  return largest;
}

Set<String> _closure(Map<String, List<String>> graph, String entry) {
  final Set<String> seen = <String>{entry};
  final List<String> todo = <String>[entry];
  while (todo.isNotEmpty) {
    for (final String next in graph[todo.removeLast()] ?? const <String>[]) {
      if (seen.add(next)) todo.add(next);
    }
  }
  return seen;
}

/// [from] 到 [to] 的一条最短 import 链（BFS）；不可达返回 null。
List<String>? _shortestChain(
  Map<String, List<String>> graph,
  String from,
  String to,
) {
  final Map<String, String?> prev = <String, String?>{from: null};
  final List<String> queue = <String>[from];
  for (int i = 0; i < queue.length; i++) {
    final String v = queue[i];
    if (v == to) break;
    for (final String w in graph[v] ?? const <String>[]) {
      if (!prev.containsKey(w)) {
        prev[w] = v;
        queue.add(w);
      }
    }
  }
  if (!prev.containsKey(to)) return null;
  final List<String> chain = <String>[];
  for (String? v = to; v != null; v = prev[v]) {
    chain.add(v);
  }
  return chain.reversed.toList();
}

/// 能经 import 链到达 [target] 的全部文件（反向图上的闭包，含 [target]）。
Set<String> _reaching(Map<String, List<String>> graph, String target) {
  final Map<String, List<String>> reverse = <String, List<String>>{};
  for (final MapEntry<String, List<String>> e in graph.entries) {
    for (final String to in e.value) {
      (reverse[to] ??= <String>[]).add(e.key);
    }
  }
  return _closure(reverse, target);
}

void main() {
  final Map<String, List<String>> graph = _libGraph();

  test('不 import 顶层 barrel', () {
    final RegExp barrelImport = RegExp(
      r'''^\s*(?:import|export)\s+['"]package:fushi/(?:'''
      '${kBarrels.map(RegExp.escape).join('|')}'
      r''')['"]''',
      multiLine: true,
    );
    final List<String> offenders = <String>[];
    for (final String root in <String>[
      'lib',
      'test',
      'integration_test',
      'test_driver',
    ]) {
      final Directory dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final File f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        if (barrelImport.hasMatch(f.readAsStringSync())) {
          offenders.add(f.path.replaceAll(r'\', '/'));
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'barrel 会把几十个库捆成一个 import，用到它的文件拖进整个 app。'
          '在仓库根跑 tool/barrel_imports/bin/expand_barrel_imports.dart 换成直接 import',
    );
  });

  test('lib/ 最大 import 环不超过 $kMaxCycleFiles 个文件', () {
    final int largest = _largestScc(graph);
    expect(
      largest,
      lessThanOrEqualTo(kMaxCycleFiles),
      reason:
          '最大强连通分量 $largest 个文件，超过上限 $kMaxCycleFiles：'
          '新 import 把底层模块接回了 UI / AppModel',
    );
  });

  test('底层入口的闭包不碰 AppModel', () {
    for (final String entry in kLeafEntries) {
      expect(graph.containsKey(entry), isTrue, reason: '$entry 不存在');
      expect(
        _closure(graph, entry),
        isNot(contains(kAppModel)),
        reason: '$entry 经 import 链连到了 app_model.dart',
      );
    }
  });

  test('models / utils / storage 目录下所有文件的闭包都不碰 AppModel', () {
    expect(graph.containsKey(kAppModel), isTrue, reason: '$kAppModel 不存在');
    final Set<String> reaching = _reaching(graph, kAppModel);
    final List<String> offenders = <String>[
      for (final String file in graph.keys.toList()..sort())
        if (file != kAppModel &&
            kAppModelFreeDirs.any(file.startsWith) &&
            reaching.contains(file))
          '$file：${_shortestChain(graph, file, kAppModel)!.join(' -> ')}',
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          '底层文件经 import 链连到了 app_model.dart（每行给一条最短链）。'
          '把链上真正用到的符号挪到更底层，或改成参数 / 回调注入',
    );
  });
}

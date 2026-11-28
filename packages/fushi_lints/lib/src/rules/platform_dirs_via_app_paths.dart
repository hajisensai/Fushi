import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

import '../ratchet.dart';

/// 平台目录（`path_provider` 的 `get*Directory*`）只经 `AppPaths` 解析。
///
/// TODO-935 E0：应用数据根目录的唯一入口是 `fushi/lib/src/storage/app_paths.dart`
/// 的 `AppPaths`（桌面自定义数据根、`FUSHI_TEST_ROOT` 注入都只在那里生效）。别处
/// 直连 `path_provider` 拿到的是平台默认目录，跟不上自定义数据根。
///
/// 按引用解析出的**函数**判定：调用、tear-off（`resolver ??= getXxxDirectory`）、
/// 加前缀导入都算；`show` 组合子与文档注释里的 `[getXxx]` 不算。
///
/// 豁免表是 2026-11-28 迁移时 `fushi/lib` 的现存直连点，按「文件 × 具体函数」
/// 计数（棘轮：只减不增，迁完一处就把数字调小，归零删行）。按函数分开计，是为了
/// 保住旧守卫「收敛过的模块不再直连 documents / support 根」的那层约束：只登记了
/// getTemporaryDirectory 的文件新写一处 getApplicationDocumentsDirectory 照样红。
class PlatformDirsViaAppPaths extends RatchetedRule {
  PlatformDirsViaAppPaths()
    : super(name: ruleName, description: '平台目录只经 AppPaths 解析');

  static const String ruleName = 'fushi_platform_dirs_via_app_paths';

  static const String _legacy = '存量直连（2026-11-28 迁入 lint 时盘点），待改经 AppPaths';

  static const LintCode code = LintCode(
    ruleName,
    "Don't call path_provider's {0}() directly: {1}",
    correctionMessage:
        'Use AppPaths (fushi/lib/src/storage/app_paths.dart) so the custom '
        'data root and FUSHI_TEST_ROOT apply.',
    severity: DiagnosticSeverity.WARNING,
  );

  static const LintCode stale = LintCode(
    '${ruleName}_stale_allowance',
    'fushi_lints allows {1} direct {0}() reference(s) in this file but found {2}.',
    correctionMessage:
        'Lower or delete the Allowance in '
        'packages/fushi_lints/lib/src/rules/platform_dirs_via_app_paths.dart.',
    severity: DiagnosticSeverity.WARNING,
  );

  static const List<Allowance> exemptions = <Allowance>[
    // ALLOWANCES-BEGIN
    Allowance(
      'fushi/lib/src/anki/ankimobile_mined_ledger.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/anki/mined_expression_cache.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/creator/enhancements/audio_recorder_enhancement.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/creator/enhancements/camera_enhancement.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/creator/enhancements/crop_image_enhancement.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/creator/enhancements/local_audio_enhancement.dart',
      'getApplicationSupportDirectory',
      2,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/creator/enhancements/local_audio_enhancement.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/creator/enhancements/pick_audio_enhancement.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/creator/enhancements/pick_image_enhancement.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/diagnostics/storage_footprint_log.dart',
      'getApplicationDocumentsDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/diagnostics/storage_footprint_log.dart',
      'getApplicationSupportDirectory',
      2,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/lookup/browser_extension_installer.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/lookup/lookup_audio_playback.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/media/audiobook/audiobook_storage_platform.dart',
      'getApplicationDocumentsDirectory',
      1,
      'fushi_audio 包不能 import app 层 AppPaths：平台兜底以 ??= 装进包内单一解析点，不覆盖 AppPaths 注入',
    ),
    Allowance(
      'fushi/lib/src/media/audiobook/book_import_dialog.dart',
      'getTemporaryDirectory',
      2,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/media/favorites/favorite_batch_mining_runner.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/media/music/lyrics/visualizer/lyric_visualizer_assets.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/mining/galgame_hook_runtime_stage.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/models/app_model.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/anki_settings_page.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/collections_page.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/crop_image_dialog_page.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/kavita/kavita_book_series_page.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/media_sources_view.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/reader_history/remote.part.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/srs/srs_anki_migration_page.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/srs/srs_field_editors.dart',
      'getTemporaryDirectory',
      2,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/srs/srs_history_page.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/srs/srs_remote_review_page.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/video_fushi/advanced_mining.part.dart',
      'getTemporaryDirectory',
      2,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/video_fushi/clip_export.part.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart',
      'getTemporaryDirectory',
      8,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/video_fushi_page.dart',
      'getTemporaryDirectory',
      3,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/web_video_fushi_page.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/platform/desktop/desktop_directory_service.dart',
      'getApplicationDocumentsDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/platform/desktop/desktop_directory_service.dart',
      'getDownloadsDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/platform/widget_cover_cache.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/platform/widget_snapshot_source.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/srs/donation/srs_donation_flow.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/srs/srs_import_entry.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/srs/srs_starter_pack_controller.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/srs/srs_storage_host.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/startup/durable_shared_preferences.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/storage/app_paths.dart',
      'getApplicationCacheDirectory',
      1,
      '唯一入口本身',
    ),
    Allowance(
      'fushi/lib/src/storage/app_paths.dart',
      'getApplicationDocumentsDirectory',
      11,
      '唯一入口本身',
    ),
    Allowance(
      'fushi/lib/src/storage/app_paths.dart',
      'getApplicationSupportDirectory',
      3,
      '唯一入口本身',
    ),
    Allowance(
      'fushi/lib/src/storage/app_paths.dart',
      'getExternalStorageDirectory',
      3,
      '唯一入口本身',
    ),
    Allowance(
      'fushi/lib/src/storage/app_paths.dart',
      'getLibraryDirectory',
      2,
      '唯一入口本身',
    ),
    Allowance(
      'fushi/lib/src/storage/app_paths.dart',
      'getTemporaryDirectory',
      1,
      '唯一入口本身',
    ),
    Allowance(
      'fushi/lib/src/storage/installer_data_root_bootstrap.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/storage/legacy_support_dir_migration.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/sync/sync_settings_schema/backup.part.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/sync/sync_settings_schema/data_root.part.dart',
      'getApplicationDocumentsDirectory',
      2,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/sync/sync_settings_schema/data_root.part.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/utils/misc/app_icon_preferences.dart',
      'getApplicationSupportDirectory',
      2,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/utils/misc/clipboard_image.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/utils/misc/collection_exporter.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/utils/misc/desktop_audio_playback.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/utils/misc/fushi_share.dart',
      'getTemporaryDirectory',
      2,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/utils/misc/log_exporter.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/utils/misc/shortcut_icon_sync.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/utils/misc/tts_channel.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/utils/misc/update_checker_download.dart',
      'getApplicationSupportDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/web_browser/tab_view/web_browser_downloader.dart',
      'getApplicationDocumentsDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/web_browser/tab_view/web_browser_downloader.dart',
      'getDownloadsDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/web_browser/tab_view/web_browser_downloader.dart',
      'getExternalStorageDirectory',
      1,
      _legacy,
    ),
    Allowance(
      'fushi/lib/src/web_browser/tab_view/web_browser_downloader.dart',
      'getTemporaryDirectory',
      1,
      _legacy,
    ),
    // ALLOWANCES-END
  ];

  @override
  LintCode get violationCode => code;

  @override
  LintCode get staleCode => stale;

  @override
  List<Allowance> get allowances => exemptions;

  @override
  // 只管 app：四个无头服务端闭包包连 import path_provider 都不许
  // （fushi_pure_dart_package_imports）；fushi_platform / fushi_anki 这些 Flutter
  // 插件包没有挂 fushi_lints，自有平台目录解析点。
  bool appliesTo(String repoPath) => repoPath.startsWith('fushi/lib/');

  @override
  List<RuleSite> collect(CompilationUnit unit, RuleContext context) {
    final _Collector collector = _Collector();
    unit.accept(collector);
    return collector.sites;
  }
}

class _Collector extends RecursiveAstVisitor<void> {
  final List<RuleSite> sites = <RuleSite>[];

  @override
  void visitShowCombinator(ShowCombinator node) {}

  @override
  void visitHideCombinator(HideCombinator node) {}

  @override
  void visitComment(Comment node) {}

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final Element? element = node.element;
    if (element is TopLevelFunctionElement &&
        element.library.uri.isScheme('package') &&
        element.library.uri.path.startsWith('path_provider/')) {
      sites.add(
        RuleSite(
          node,
          element.name!,
          'it returns the platform default and ignores the custom data root.',
        ),
      );
    }
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/reader/reader_engine_config.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_script_compactor.dart';
import 'package:fushi/src/reader/reader_seamless_chapters_script.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/reader/reader_settings_ia.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/source_guard.dart';
import '../helpers/test_platform_services.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// 反馈 R7k887yaJI ③：连续（滚动）模式章节无缝衔接（设计
/// `docs/specs/2026-11-07-continuous-seamless-chapters-design.md`）。
///
/// 真渲染层的行为（挂载 / 晋升 / 卸载时视口不动、索引只覆盖活动章、进度闸、真触摸晋升、
/// 开关关闭无宿主）由 `tool/reader_pitch_headless/continuous_seamless_chapters_probe.mjs`
/// 在真 Chromium 上实测。本文件锁：开关默认关与落盘、config 下发、模块只进连续 shell
/// 且以 `C.seamlessChapters` 为唯一安装条件、页面接线。
ReaderEngineConfig _config({
  bool seamless = false,
  int index = -1,
  List<ReaderSeamlessChapterEntry> order = const <ReaderSeamlessChapterEntry>[],
}) => ReaderEngineConfig(
  navigationGeneration: 1,
  continuousMode: true,
  vnMode: false,
  vnClickAdvance: false,
  scanNonJapaneseText: false,
  hoverAutoLookup: false,
  hoverKey: 'shiftKey',
  hostHoverLookup: false,
  highlightOnTap: false,
  showChrome: false,
  debugLogging: false,
  swipeDistThreshold: 24,
  swipeFastDistThreshold: 12,
  swipeFastVelocity: 300,
  wheelGestureQuietMs: 300,
  continuousTurnPullPx: 20,
  continuousTurnPinMidGesture: false,
  furiganaMode: 'off',
  caretColor: '#000',
  caretInsetTop: 0,
  caretInsetBottom: 0,
  initialProgress: 0,
  initialCharOffset: -1,
  initialCharOffsetEnd: -1,
  initialFragment: null,
  chromeTopInset: 0,
  chromeBottomInset: 0,
  dartPageWidth: 400,
  dartPageHeight: 800,
  marginTop: 0,
  marginBottom: 0,
  marginLeft: 0,
  marginRight: 0,
  blurImages: false,
  revealedKeys: const <String>[],
  perfTraceEnabled: false,
  vnRevealSpeed: 0,
  vnScreenMode: 'sentence',
  vnSentencesPerScreen: 1,
  vnPreserveDialogue: false,
  vnMergeCrossScreenSentenceAudioCues: false,
  seamlessChapters: seamless,
  seamlessChapterIndex: index,
  seamlessChapterOrder: order,
);

void main() {
  group('启用判据与章序', () {
    test('只有「连续模式 + 开关开 + 非双页文档」才启用', () {
      for (final bool continuous in <bool>[false, true]) {
        for (final bool enabled in <bool>[false, true]) {
          for (final bool spread in <bool>[false, true]) {
            expect(
              readerSeamlessChaptersActive(
                continuousMode: continuous,
                settingEnabled: enabled,
                spreadDocument: spread,
              ),
              continuous && enabled && !spread,
              reason: 'continuous=$continuous enabled=$enabled spread=$spread',
            );
          }
        }
      }
    });

    test('章序去掉被图片合并吸收的单图章，URL 原样取自 loadUrl 那一份', () {
      final List<ReaderSeamlessChapterEntry> order = readerSeamlessChapterOrder(
        chapterCount: 5,
        urlOf: (int i) => 'https://fushi.local/epub/c$i.xhtml',
        isAbsorbed: (int i) => i == 1 || i == 2,
      );
      expect(order.map((ReaderSeamlessChapterEntry e) => e.index), <int>[
        0,
        3,
        4,
      ]);
      expect(order[1].url, 'https://fushi.local/epub/c3.xhtml');
      expect(
        readerSeamlessChapterOrder(
          chapterCount: 3,
          urlOf: (int i) => '$i',
        ).map((ReaderSeamlessChapterEntry e) => e.index),
        <int>[0, 1, 2],
      );
    });
  });

  group('引擎 config', () {
    test('默认关：seamlessChapters=false、无章序（JS 侧模块不装）', () {
      final Map<String, Object?> json = _config().toJson();
      expect(json['seamlessChapters'], isFalse);
      expect(json['seamlessChapterIndex'], -1);
      expect(json['seamlessChapterOrder'], isEmpty);
    });

    test('启用时下发活动章号与章序（index + url），JS 字面量可解析', () {
      final ReaderEngineConfig config = _config(
        seamless: true,
        index: 3,
        order: const <ReaderSeamlessChapterEntry>[
          ReaderSeamlessChapterEntry(index: 2, url: 'https://fushi.local/a'),
          ReaderSeamlessChapterEntry(index: 3, url: 'https://fushi.local/b'),
        ],
      );
      final Map<String, dynamic> decoded =
          jsonDecode(config.toJsLiteral()) as Map<String, dynamic>;
      expect(decoded['seamlessChapters'], isTrue);
      expect(decoded['seamlessChapterIndex'], 3);
      expect(decoded['seamlessChapterOrder'], <Map<String, Object>>[
        <String, Object>{'index': 2, 'url': 'https://fushi.local/a'},
        <String, Object>{'index': 3, 'url': 'https://fushi.local/b'},
      ]);
    });
  });

  group('模块只在连续 shell、只按 C.seamlessChapters 安装（关闭时行为不变）', () {
    final String continuous = ReaderPaginationScripts.continuousShellSource();
    final String paginated = ReaderPaginationScripts.paginatedShellSource();
    final String vn = ReaderPaginationScripts.engineShell(
      vnMode: true,
      continuousMode: false,
    );

    test('连续 shell 含模块；翻页 / VN shell 与引擎源码都不含', () {
      expect(continuous, contains(kSeamlessChaptersInstallJs));
      for (final String other in <String>[
        paginated,
        vn,
        readerFushiEngineSource(),
        readerFushiEngineSource(vnMode: true),
      ]) {
        expect(other, isNot(contains('__fushiSeamless')));
        expect(other, isNot(contains('onSeamlessChapterActivated')));
        expect(other, isNot(contains(kSeamlessChapterHostTag)));
      }
      expect(
        readerFushiEngineSource(continuousMode: true),
        contains('onSeamlessChapterActivated'),
      );
    });

    test('安装的第一道闸是 C.seamlessChapters !== true → return', () {
      final List<String> lines = kSeamlessChaptersInstallJs
          .split('\n')
          .map((String l) => l.trim())
          .where((String l) => l.isNotEmpty)
          .toList();
      expect(lines[0], '(function() {');
      expect(lines[1], 'if (C.seamlessChapters !== true) return;');
    });

    test('模块之外，连续 shell 没有任何一处引用 __fushiSeamless（关闭时零接入点）', () {
      final String withoutModule = continuous.replaceFirst(
        kSeamlessChaptersInstallJs,
        '',
      );
      expect(withoutModule, isNot(contains('__fushiSeamless')));
      expect(withoutModule, isNot(contains(kSeamlessChapterHostTag)));
    });

    test('模块在 boot 之前安装（装饰的 notifyRestoreComplete 要先于初次恢复就位）', () {
      final int module = continuous.indexOf(kSeamlessChaptersInstallJs);
      final int boot = continuous.lastIndexOf('function _fushiBootInitialize');
      expect(module, greaterThan(0));
      expect(boot, greaterThan(module));
    });

    test('压缩器能完整扫过含模块的真实注入引擎', () {
      final String source = readerFushiEngineSourceUncompacted(
        continuousMode: true,
      );
      expect(ReaderScriptCompactor.scansCleanly(source), isTrue);
      expect(
        ReaderScriptCompactor.compact(source),
        contains('onSeamlessChapterActivated'),
      );
    });

    test('晋升只认用户驱动的滚动、带迟滞带；进度在 ack 前返回 null', () {
      final String code = kSeamlessChaptersInstallJs;
      expect(
        containsCodeLine(
          code,
          "if (!S.started || busy() || S.lastViewportSource !== 'user') return false;",
        ),
        isTrue,
      );
      expect(code, contains('var HYSTERESIS = $kSeamlessPromoteHysteresisPx;'));
      expect(
        containsCodeLine(code, 'if (S.awaitingAck()) return null;'),
        isTrue,
      );
      // 晋升时先清掉挂在旧活动章节点上的章内状态，再搬节点。
      final int clear = code.indexOf(
        'clearChapterScopedState();\n    preserveViewport',
      );
      expect(clear, greaterThan(0));
    });
  });

  group('页面接线', () {
    final String page = maskCommentsAndScriptLines(readReaderPageSource());

    test('注册 onSeamlessChapterActivated，config 由 _seamlessEngineConfig 派生', () {
      expect(page, contains("handlerName: 'onSeamlessChapterActivated'"));
      expect(page, contains('seamlessChapters: seamless.active'));
      expect(page, contains('seamlessChapterIndex: seamless.index'));
      expect(page, contains('seamlessChapterOrder: seamless.order'));
      expect(page, contains('settingEnabled: s.continuousSeamlessChapters'));
      expect(page, contains('spreadDocument: _spreadDocumentLoaded'));
    });

    test('换章在第一个 await 之前完成：结算账本、递增代际、换章号', () {
      final int start = page.indexOf(
        'Future<void> _onSeamlessChapterActivated(',
      );
      expect(start, greaterThan(0));
      final String body = page.substring(start);
      final int firstAwaitAfterValid = body.indexOf(
        'await controller.evaluateJavascript',
      );
      final String syncPart = body.substring(0, firstAwaitAfterValid);
      for (final String needle in <String>[
        '_readLedger.leave();',
        '_restoreExpectedGeneration = ++_navigateGeneration;',
        '_currentChapter = to;',
        '_audiobookController?.noteManualReaderNavigation();',
      ]) {
        expect(syncPart, contains(needle), reason: needle);
      }
      expect(body, contains('window.__fushiSeamless.ack(\$seq, \$generation)'));
      expect(body, contains('_applyChapterHighlights()'));
      expect(body, contains('_injectAudiobookBridge()'));
      expect(body, contains('notifySectionRestoreCompleted('));
    });

    test('两边对不上时整章重载到 JS 的活动章（不在不一致状态上继续）', () {
      final int start = page.indexOf(
        'Future<void> _onSeamlessChapterActivated(',
      );
      final String body = page.substring(start);
      final int rejected = body.indexOf('if (!valid) {');
      expect(rejected, greaterThan(0));
      expect(
        body.substring(rejected, rejected + 1200),
        contains('_navigateToChapter(to, manual: true)'),
      );
    });

    test('探针文件存在（真 Chromium 行为的实测入口）', () {
      expect(
        File(
          '../tool/reader_pitch_headless/continuous_seamless_chapters_probe.mjs',
        ).existsSync(),
        isTrue,
      );
    });
  });

  group('设置项', () {
    late FushiDatabase db;
    late ReaderSettings readerSettings;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      MediaSource.setDatabase(db);
      readerSettings = ReaderSettings(db);
      await readerSettings.refreshFromDb();
      ReaderFushiSource.readerSettings = readerSettings;
    });

    tearDown(() async {
      ReaderFushiSource.readerSettings = null;
      await db.close();
    });

    test('默认关；写入后重启读回；旁路写入同一个 key', () async {
      expect(readerSettings.continuousSeamlessChapters, isFalse);
      await readerSettings.setContinuousSeamlessChapters(true);
      final ReaderSettings restored = ReaderSettings(db);
      await restored.refreshFromDb();
      expect(restored.continuousSeamlessChapters, isTrue);

      ReaderFushiSource.readerSettings = null;
      await ReaderFushiSource.instance.setContinuousSeamlessChapters(false);
      await restored.refreshFromDb();
      expect(restored.continuousSeamlessChapters, isFalse);
    });

    testWidgets('开关只在滚动模式出现，位于翻页与手势页，改值写穿', (WidgetTester tester) async {
      late SettingsContext settingsContext;
      late SettingsItem item;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) {
                settingsContext = SettingsContext(
                  context: context,
                  appModel: AppModel(testPlatformServices()),
                  ref: ref,
                  readerSource: ReaderFushiSource.instance,
                  refresh: () {},
                );
                item = buildSettingsSchema(settingsContext)
                    .expand((SettingsDestination d) => d.sections)
                    .expand((SettingsSection s) => s.items)
                    .singleWhere(
                      (SettingsItem i) =>
                          i.id ==
                          'reading_controls.continuous_seamless_chapters',
                    );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      final SettingsSwitchItem sw = item as SettingsSwitchItem;
      for (final String mode in <String>['paginated', 'vn']) {
        await readerSettings.setViewMode(mode);
        expect(sw.isVisible(settingsContext), isFalse, reason: mode);
      }
      await readerSettings.setViewMode('continuous');
      expect(sw.isVisible(settingsContext), isTrue);
      expect(sw.value(settingsContext), isFalse);
      expect(
        kReaderSettingsSections
            .where(
              (ReaderSettingsSectionSpec s) =>
                  s.tab == ReaderSettingsTab.gestures,
            )
            .expand((ReaderSettingsSectionSpec s) => s.itemIds),
        contains('reading_controls.continuous_seamless_chapters'),
      );
      await sw.onChanged(settingsContext, true);
      expect(readerSettings.continuousSeamlessChapters, isTrue);
    });
  });
}

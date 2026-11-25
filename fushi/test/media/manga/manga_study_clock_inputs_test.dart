import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/manga_fushi_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/stats/read_unit_ledger.dart';
import 'package:fushi/src/stats/reader_study_clock_start_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

import '../../helpers/source_guard.dart';

/// 漫画学习计时的输入侧：缩放 / 平移喂空闲门、开始方式、快捷键、空闲门随设置刷新。
///
/// MangaFushiPage 过重，无法在纯 widget test 拉起完整链路（同
/// `manga_stats_dwell_guard_test` 纪律）：纯函数 / 生成的 JS / 默认键表按行为测，
/// 页面接线按源码守卫钉。
void main() {
  final String src = maskComments(
    File(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n'),
  );

  group('缩放 / 平移算在读（所有者拍板）：页内手势喂空闲门', () {
    const MokuroImage page = MokuroImage(
      url: 'p001.jpg',
      size: MokuroSize(1000, 1400),
      blocks: <MokuroBlock>[],
    );

    for (final MangaReadingMode mode in <MangaReadingMode>[
      MangaReadingMode.spread,
      MangaReadingMode.webtoon,
    ]) {
      test('${mode.name}：注入的手势机在捕获阶段监听指针 / 滚轮并节流上报', () {
        final String doc = mangaWindowDocument(
          const <MokuroImage>[page, page],
          const <String>['a.jpg', 'b.jpg'],
          mode: mode,
          spreadDirection: 'rtl',
          inlineSelectionJs: '',
        );
        expect(doc, contains("b.callHandler('onMangaUserActivity')"));
        expect(
          doc,
          contains(
            "['pointerdown','pointermove','wheel'].forEach(function(type){\n"
            '    document.addEventListener(type, _reportReaderActivity, '
            '{passive:true, capture:true});',
          ),
          reason: '捏合 / 拖动平移 / 双击 / 滚轮缩放都是这三类事件，捕获阶段才不被手势机吞掉',
        );
        expect(
          doc,
          contains(
            'if (now - lastActivityReport < '
            '$kMangaActivityReportIntervalMs) return;',
          ),
          reason: '按手势事件节流，不逐帧过桥',
        );
        expect(
          doc,
          contains("if (e.type === 'pointermove' && !e.buttons) return;"),
          reason: '悬停的鼠标移动不算阅读输入',
        );
      });
    }

    test('节流间隔远小于空闲门下限（不会因节流误停表）', () {
      expect(kMangaActivityReportIntervalMs, greaterThan(0));
      expect(
        Duration(milliseconds: kMangaActivityReportIntervalMs * 4),
        lessThanOrEqualTo(
          const Duration(
            minutes: PreferencesRepository.readingIdleTimeoutMinutesMin,
          ),
        ),
      );
    });

    test('Dart 侧：onMangaUserActivity 与键盘平移都只 touch 空闲门', () {
      final String activity = methodBody(src, '  void _noteReaderActivity() {');
      expect(activity, contains('_studyClock?.touch();'));
      expect(
        activity,
        isNot(contains('_readLedger')),
        reason: '缩放 / 平移不改位置，不碰账本',
      );
      expect(
        src,
        contains(
          "handlerName: 'onMangaUserActivity',\n"
          '          callback: (List<dynamic> _) => _noteReaderActivity(),',
        ),
      );
      final String exec = methodBody(src, '  void _executeReaderInputAction(');
      final int pan = exec.indexOf('if (panStep != null) {');
      expect(pan, isNonNegative);
      expect(
        exec.indexOf('_noteReaderActivity();', pan),
        allOf(isNonNegative, lessThan(exec.indexOf('return;', pan))),
        reason: '键盘平移（Ctrl+方向键）同样是在读',
      );
    });
  });

  group('开始方式（与小说共用 stats_reading_clock_start_mode）', () {
    /// 漫画账本单元 = 页号半开区间（单页 `[p, p+1)`、双页 `[p, p+2)`），经同一个
    /// `arriveReadUnitThroughStartGate` 进账本。
    ({bool started, bool paused, List<(int, int)> credited}) drive(
      ReaderStudyClockStartMode mode,
      List<(int, int)?> arrivals,
    ) {
      final List<(int, int)> credited = <(int, int)>[];
      final ReadUnitLedger ledger = ReadUnitLedger(
        onCredit: credited.addAll,
        onRetract: (_) {},
      );
      final ReaderStudyClockStartGate gate = ReaderStudyClockStartGate(mode);
      bool started = false;
      for (final (int, int)? unit in arrivals) {
        if (unit == null) {
          // 换章（_settleLeavingChapter）：结算 + 清并集。
          ledger
            ..leave()
            ..reset();
          continue;
        }
        started =
            arriveReadUnitThroughStartGate(
              gate: gate,
              ledger: ledger,
              start: unit.$1,
              end: unit.$2,
              onAutoStart: () {},
            ) ||
            started;
      }
      return (started: started, paused: gate.manualPause, credited: credited);
    }

    test('打开即开始：不暂停', () {
      expect(
        drive(ReaderStudyClockStartMode.onOpen, <(int, int)?>[(0, 1)]).paused,
        isFalse,
      );
    });

    test('手动：打开暂停，翻页也不自动起表', () {
      final r = drive(ReaderStudyClockStartMode.manual, <(int, int)?>[
        (0, 1),
        (1, 2),
        (2, 3),
      ]);
      expect(r.paused, isTrue);
      expect(r.started, isFalse);
    });

    test('翻页后开始：打开暂停；单页 / 双页向前翻一页自动起表', () {
      expect(
        drive(ReaderStudyClockStartMode.onPageTurn, <(int, int)?>[
          (3, 4),
        ]).paused,
        isTrue,
        reason: '只打开不计',
      );
      final single = drive(ReaderStudyClockStartMode.onPageTurn, <(int, int)?>[
        (3, 4),
        (4, 5),
      ]);
      expect(single.started, isTrue);
      expect(single.paused, isFalse);
      final spread = drive(ReaderStudyClockStartMode.onPageTurn, <(int, int)?>[
        (2, 4),
        (4, 6),
      ]);
      expect(spread.started, isTrue);
    });

    test('翻页后开始：回翻、换章后的首个落定、同页换单元边界都不算', () {
      expect(
        drive(ReaderStudyClockStartMode.onPageTurn, <(int, int)?>[
          (5, 6),
          (4, 5),
        ]).paused,
        isTrue,
        reason: '回翻',
      );
      expect(
        drive(ReaderStudyClockStartMode.onPageTurn, <(int, int)?>[
          (5, 6),
          null,
          (0, 1),
        ]).paused,
        isTrue,
        reason: '跳章：换章先清了当前单元，新章首屏没有上一单元',
      );
      expect(
        drive(ReaderStudyClockStartMode.onPageTurn, <(int, int)?>[
          (4, 6),
          (4, 5),
        ]).paused,
        isTrue,
        reason: '双页→单页同一页（起点不变）',
      );
    });

    test('页面接线：开书按偏好建门，暂停旗推进运行门；落定先过门再 arrive', () {
      final String init = methodBody(src, '  void initState() {');
      expect(
        init,
        contains(
          '_studyClockStartGate = ReaderStudyClockStartGate(\n'
          '      appModelNoUpdate.readerStudyClockStartMode,\n'
          '    );',
        ),
      );
      expect(
        init,
        contains(
          '_studyClockGate.setManualPause(_studyClockStartGate.manualPause);',
        ),
      );
      final String note = methodBody(src, '  void _noteVisiblePages() {');
      expect(note, contains('gate: _studyClockStartGate,'));
      expect(
        note,
        contains('onAutoStart: () => _studyClockGate.setManualPause(false),'),
      );
      expect(
        '.setManualPause('.allMatches(src).length,
        3,
        reason: '运行门的暂停旗只从开始方式门推进（开书 / 自动起表 / 手动键）',
      );
    });
  });

  group('快捷键：统计侧栏 I / 停续计时 P（与小说同键）', () {
    const Map<ShortcutAction, LogicalKeyboardKey> expected =
        <ShortcutAction, LogicalKeyboardKey>{
          ShortcutAction.mangaOpenStatistics: LogicalKeyboardKey.keyI,
          ShortcutAction.mangaToggleStudyClock: LogicalKeyboardKey.keyP,
        };

    test('manga scope，键盘默认与小说同名动作同键，手柄留空', () {
      for (final TargetPlatform platform in const <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        final Map<ShortcutAction, ShortcutBindingSet> table =
            ShortcutDefaults.forPlatform(platform);
        for (final MapEntry<ShortcutAction, LogicalKeyboardKey> e
            in expected.entries) {
          expect(e.key.scope, ShortcutScope.manga);
          expect(
            table[e.key]!.keyboardBindings,
            contains(InputBinding(key: e.value)),
            reason: '$platform ${e.key.key}',
          );
          expect(table[e.key]!.gamepadBindings, isEmpty);
        }
        expect(
          table[ShortcutAction.mangaOpenStatistics]!.keyboardBindings,
          table[ShortcutAction.readerOpenStatistics]!.keyboardBindings,
        );
        expect(
          table[ShortcutAction.mangaToggleStudyClock]!.keyboardBindings,
          table[ShortcutAction.readerToggleStudyClock]!.keyboardBindings,
        );
      }
    });

    test('manga co-active 组内没有别的动作默认占 I / P，注册表解析到本动作', () {
      final Map<ShortcutAction, ShortcutBindingSet> defaults =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      for (final MapEntry<ShortcutAction, LogicalKeyboardKey> e
          in expected.entries) {
        final String token = InputBinding(key: e.value).serialize();
        for (final ShortcutScope scope in ShortcutScope.manga.coactiveScopes) {
          for (final ShortcutAction action in ShortcutAction.actionsForScope(
            scope,
          )) {
            if (action == e.key) continue;
            expect(
              defaults[action]!.keyboardBindings.map(
                (InputBinding b) => b.serialize(),
              ),
              isNot(contains(token)),
              reason: '${action.key} 也默认绑 $token，会遮蔽 ${e.key.key}',
            );
          }
        }
        expect(
          registry.resolveKeyboard(
            e.value,
            modifiers: const <ModifierKey>{},
            scope: ShortcutScope.manga,
          ),
          e.key,
        );
      }
    });

    test('解析层：不吃两道翻页门控（查词弹窗开着 / webtoon 下照样可用）', () {
      for (final bool dictionaryShown in <bool>[false, true]) {
        for (final MangaReadingMode mode in MangaReadingMode.values) {
          expect(
            MangaFushiPage.inputActionForShortcut(
              action: ShortcutAction.mangaOpenStatistics,
              crossPageStep: false,
              dictionaryShown: dictionaryShown,
              mode: mode,
            ),
            MangaReaderInputAction.openStatistics,
          );
          expect(
            MangaFushiPage.inputActionForShortcut(
              action: ShortcutAction.mangaToggleStudyClock,
              crossPageStep: false,
              dictionaryShown: dictionaryShown,
              mode: mode,
            ),
            MangaReaderInputAction.toggleStudyClock,
          );
        }
      }
    });

    test('执行体与控制条统计键 / 计时键同一入口', () {
      final String exec = methodBody(src, '  void _executeReaderInputAction(');
      final RegExpMatch? stats = RegExp(
        r'if \(action == MangaReaderInputAction\.openStatistics\) \{[\s\S]*?return;',
      ).firstMatch(exec);
      expect(stats?.group(0), contains('_openMangaStatistics()'));
      final RegExpMatch? timer = RegExp(
        r'if \(action == MangaReaderInputAction\.toggleStudyClock\) \{[\s\S]*?return;',
      ).firstMatch(exec);
      expect(timer?.group(0), contains('_toggleStudyClockManualPause();'));
      // 纯状态切换：不先关查词弹窗。
      expect(timer?.group(0), isNot(contains('clearDictionaryResult')));
    });
  });

  test('空闲门分钟数随设置刷新：建时钟时订阅偏好、dispose 摘掉（同小说 BUG-2213）', () {
    final String ensure = methodBody(
      src,
      '  void _ensureStudyClock(FushiDatabase db) {',
    );
    expect(
      ensure,
      contains(
        '_idleTimeoutPrefs ??= appModelNoUpdate.prefsRepo\n'
        '      ..addListener(_syncStudyClockIdleTimeout);',
      ),
    );
    final String sync = methodBody(
      src,
      '  void _syncStudyClockIdleTimeout() {',
    );
    expect(sync, contains('_studyClock?.idleTimeout = Duration('));
    expect(sync, contains('prefs.readingIdleTimeoutMinutes'));
    expect(
      methodBody(src, '  void dispose() {'),
      contains(
        '_idleTimeoutPrefs?.removeListener(_syncStudyClockIdleTimeout);',
      ),
    );
  });
}

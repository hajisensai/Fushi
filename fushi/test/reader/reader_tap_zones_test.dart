import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart'
    show ReaderNavigationDirection;
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/reader/reader_settings_ia.dart';
import 'package:fushi/src/reader/reader_tap_zones.dart';
import 'package:fushi_core/fushi_core.dart';

/// indZkg2A0I：小说阅读器「点击翻页区域」模板。
///
/// 分发逻辑是纯函数（几何 + 书写方向），三种 view mode 共用同一个 `_paginate`
/// 入口——翻页 = 上一页 / 下一页、滚动 = 滚一屏、VN = 上一屏 / 下一屏。宿主接线
/// （空白点击才分发、查词弹窗优先、VN 点击前进优先）用源码切片守住。
void main() {
  const ReaderNavigationDirection fwd = ReaderNavigationDirection.forward;
  const ReaderNavigationDirection back = ReaderNavigationDirection.backward;

  ReaderNavigationDirection? turn(
    ReaderTapZoneLayout layout,
    double x,
    double y, {
    bool rtl = false,
  }) => readerTapZoneTurn(layout, x: x, y: y, rtl: rtl);

  group('模板几何', () {
    test('关闭：任何位置都不翻页（落回工具栏旧行为）', () {
      for (final double x in <double>[0, 0.1, 0.5, 0.9, 1]) {
        expect(turn(ReaderTapZoneLayout.disabled, x, 0.5), isNull);
      }
    });

    test('左右：横排左上一页右下一页，竖排（右开本）互换；中间不翻页', () {
      expect(turn(ReaderTapZoneLayout.leftRight, 0.1, 0.5), back);
      expect(turn(ReaderTapZoneLayout.leftRight, 0.9, 0.5), fwd);
      expect(turn(ReaderTapZoneLayout.leftRight, 0.1, 0.5, rtl: true), fwd);
      expect(turn(ReaderTapZoneLayout.leftRight, 0.9, 0.5, rtl: true), back);
      expect(turn(ReaderTapZoneLayout.leftRight, 0.5, 0.5), isNull);
      expect(turn(ReaderTapZoneLayout.leftRight, 0.5, 0.5, rtl: true), isNull);
    });

    test('单手：左右两侧都下一页（不随书写方向翻转），中间不翻页', () {
      for (final bool rtl in <bool>[false, true]) {
        expect(turn(ReaderTapZoneLayout.allForward, 0.05, 0.2, rtl: rtl), fwd);
        expect(turn(ReaderTapZoneLayout.allForward, 0.95, 0.8, rtl: rtl), fwd);
        expect(
          turn(ReaderTapZoneLayout.allForward, 0.5, 0.5, rtl: rtl),
          isNull,
        );
      }
    });

    test('上下：上方上一页、下方下一页，中间一带不翻页', () {
      for (final bool rtl in <bool>[false, true]) {
        expect(turn(ReaderTapZoneLayout.topBottom, 0.5, 0.1, rtl: rtl), back);
        expect(turn(ReaderTapZoneLayout.topBottom, 0.5, 0.9, rtl: rtl), fwd);
        expect(turn(ReaderTapZoneLayout.topBottom, 0.1, 0.5, rtl: rtl), isNull);
      }
    });

    test('每个开启的模板都给工具栏留出中心点', () {
      for (final ReaderTapZoneLayout layout in ReaderTapZoneLayout.values) {
        expect(turn(layout, 0.5, 0.5), isNull, reason: '$layout 中心必须留给工具栏');
      }
    });

    test('三分之一边界：左区不含 1/3，右区含 2/3', () {
      expect(turn(ReaderTapZoneLayout.leftRight, 0.33, 0.5), back);
      expect(turn(ReaderTapZoneLayout.leftRight, 1 / 3, 0.5), isNull);
      expect(turn(ReaderTapZoneLayout.leftRight, 2 / 3, 0.5), fwd);
    });

    test('越界 / 非有限坐标视为未命中', () {
      for (final ReaderTapZoneLayout layout in ReaderTapZoneLayout.values) {
        expect(turn(layout, -0.1, 0.5), isNull);
        expect(turn(layout, 1.2, 0.5), isNull);
        expect(turn(layout, 0.1, double.nan), isNull);
        expect(turn(layout, double.infinity, 0.9), isNull);
      }
    });
  });

  group('坐标归一化', () {
    test('视口像素 → 0..1', () {
      final ({double x, double y})? p = normalizeReaderTapPoint(
        x: 50,
        y: 300,
        viewportWidth: 400,
        viewportHeight: 800,
      );
      expect(p, isNotNull);
      expect(p!.x, closeTo(0.125, 1e-9));
      expect(p.y, closeTo(0.375, 1e-9));
    });

    test('缺参数或视口为零 → null（落回工具栏行为）', () {
      expect(
        normalizeReaderTapPoint(
          x: 1,
          y: 1,
          viewportWidth: null,
          viewportHeight: 10,
        ),
        isNull,
      );
      expect(
        normalizeReaderTapPoint(
          x: 1,
          y: 1,
          viewportWidth: 0,
          viewportHeight: 10,
        ),
        isNull,
      );
    });
  });

  group('偏好', () {
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

    test('默认关闭；写入后重启读回；未知值回落关闭', () async {
      expect(readerSettings.tapZoneLayout, ReaderTapZoneLayout.disabled);
      expect(
        ReaderFushiSource.instance.tapZoneLayout,
        ReaderTapZoneLayout.disabled,
      );
      await ReaderFushiSource.instance.setTapZoneLayout(
        ReaderTapZoneLayout.allForward,
      );
      final ReaderSettings restored = ReaderSettings(db);
      await restored.refreshFromDb();
      expect(restored.tapZoneLayout, ReaderTapZoneLayout.allForward);

      await db.setPref('src:reader_fushi:tap_zone_layout', 'diagonal');
      await restored.refreshFromDb();
      expect(restored.tapZoneLayout, ReaderTapZoneLayout.disabled);
    });

    test('持久化 key 往返', () {
      for (final ReaderTapZoneLayout layout in ReaderTapZoneLayout.values) {
        expect(ReaderTapZoneLayout.fromKey(layout.key), layout);
      }
    });

    test('设置项进了阅读器设置面板的「翻页与手势」', () {
      final bool listed = kReaderSettingsSections.any(
        (ReaderSettingsSectionSpec s) =>
            s.itemIds.contains('reading_controls.tap_zone_layout'),
      );
      expect(listed, isTrue);
    });
  });

  group('宿主接线（源码切片）', () {
    final String webview = File(
      'lib/src/pages/implementations/reader_fushi/webview.part.dart',
    ).readAsStringSync();
    final String chrome = File(
      'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
    ).readAsStringSync();
    final String selection = File(
      'lib/src/reader/reader_selection_scripts.dart',
    ).readAsStringSync();

    String slice(String src, String start, String end) {
      final int a = src.indexOf(start);
      expect(a, greaterThanOrEqualTo(0), reason: '锚不到 `$start`');
      final int b = src.indexOf(end, a + start.length);
      expect(b, greaterThan(a), reason: '锚不到 `$end`');
      return src.substring(a, b);
    }

    test('选词脚本判空白时带回坐标与视口尺寸（点到文字走 onTextSelected，不进模板）', () {
      expect(
        selection,
        contains("'onTapEmpty', x, y, window.innerWidth, window.innerHeight);"),
      );
    });

    test('onTapEmpty：查词弹窗先关，再按模板翻页，未命中才落到工具栏', () {
      final String body = slice(
        webview,
        "handlerName: 'onTapEmpty',",
        "handlerName: 'onVnBlankTap',",
      );
      final int dict = body.indexOf('if (isDictionaryShown) {');
      final int zone = body.indexOf(
        '_turnPageByTapZone(args, 0, sizeIndex: 2)',
      );
      final int chromeBranch = body.indexOf('_handleFloatingChromeReveal()');
      expect(dict, greaterThanOrEqualTo(0));
      expect(zone, greaterThan(dict), reason: '弹窗在场时点空白是关弹窗，不是翻页');
      expect(chromeBranch, greaterThan(zone), reason: '模板未命中才走工具栏分支');
    });

    test('onTap：只在不查词的两条分支（栏收起 / 点按查词关闭）认领翻页区', () {
      final String body = slice(
        webview,
        "handlerName: 'onTap',",
        '_selectTextAt(x, y);',
      );
      final int zone = body.indexOf('_turnPageByTapZone(args, 0)');
      expect(zone, greaterThanOrEqualTo(0));
      final String guard = body.substring(0, zone);
      expect(guard, contains('!shiftKey'));
      expect(guard, contains('!_tapGateChrome'));
      expect(guard, contains('!ReaderFushiSource.instance.highlightOnTap'));
    });

    test('JS 的 VN「点击空白前进」先于选词脚本：VN 开了点击前进时模板不参与', () {
      final int vn = webview.indexOf("callHandler('onVnBlankTap')");
      final int select = webview.indexOf(
        'window.fushiSelection.selectText(x, y, tapGate.maxLen || 400, false);',
      );
      expect(vn, greaterThanOrEqualTo(0));
      expect(select, greaterThan(vn));
    });

    test('分发统一走 _paginate（三种 view mode 各自解释方向），歌词层不参与', () {
      final String body = slice(
        chrome,
        'bool _turnPageByTapZone(',
        'void _handleVnBlankTap() {',
      );
      expect(body, contains('if (_lyricsMode) return false;'));
      expect(body, contains('ReaderFushiSource.instance.tapZoneLayout'));
      expect(body, contains('rtl: _isRtlReading'));
      expect(body, contains('_paginate(direction)'));
      expect(body, contains('FocusReclaimCause.gesture'));
    });
  });
}

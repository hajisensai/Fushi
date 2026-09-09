import 'package:flutter_test/flutter_test.dart';

import 'reader_fushi_page_source_corpus.dart';

/// 守卫：移动端阅读器底栏（`_buildSettingsBar`，桌面 ッツ 形态不画）右端必须有一颗
/// 「阅读统计」直达键，且是底栏级规格的按钮，不是紧凑小图标。
///
/// 由来：移动端此前唯一的统计入口是「齿轮 → 快速设置 sheet → 阅读统计行」三步，
/// 手动计时开关只活在浮层里，正文界面上没有任何「在不在计时」的指示；桌面那条状态行
/// （左 14px 计时图标 / 右进度数字）只在 `isDesktopPlatform` 渲染，手机上不存在。
///
/// 静态守卫而非 widget 测试：这颗键长在 `_ReaderFushiPageState` 的私有 build 方法里，
/// 渲染它要整页起 WebView（真 InAppWebView 平台视图），测试环境跑不动；能落地的最强层
/// 就是对合并语料切 `_buildSettingsBar` 方法体做结构断言。
///
/// 提取方法体：从签名起，到下一个 2 空格缩进的成员声明为止。签名/邻接方法改名时窗口
/// 只会变大，断言更保守，不会漏。
String _settingsBarBody(String src) {
  const String signature = 'Widget _buildSettingsBar() {';
  final int start = src.indexOf(signature);
  expect(
    start,
    greaterThanOrEqualTo(0),
    reason: '找不到 `_buildSettingsBar`——移动端底栏被改名了？请更新守卫。',
  );
  final int bodyStart = start + signature.length;
  final RegExp nextMember = RegExp(
    r'\n  (Future<|void |bool |String |int |double |Widget )',
  );
  final Match? next = nextMember.firstMatch(src.substring(bodyStart));
  final int end = next == null ? src.length : bodyStart + next.start;
  return src.substring(start, end);
}

void main() {
  group('移动端阅读器底栏统计键守卫', () {
    test('底栏右端有阅读统计直达键，点击开统计浮层', () {
      final String body = _settingsBarBody(readReaderPageSource());

      expect(
        body,
        contains("ValueKey<String>('fushi_reader_statistics_button')"),
        reason: '移动端底栏必须有一颗统计直达键',
      );
      expect(
        body,
        contains("identifier: 'hibiki.reader.bottom.statistics'"),
        reason: '统计键要有稳定的 semantics identifier（集成测试按它找控件）',
      );
      expect(
        body,
        contains('onPressed: _openReadingStatistics'),
        reason: '统计键点击必须开阅读统计浮层',
      );
      expect(
        body,
        contains('tooltip: t.reading_statistics'),
        reason: '统计键沿用既有 i18n key，不新造',
      );
    });

    test('统计键在 Spacer 之后（右端）且排在设置齿轮之前', () {
      final String body = _settingsBarBody(readReaderPageSource());

      final int spacer = body.indexOf('const Spacer(),');
      final int stats = body.indexOf('fushi_reader_statistics_button');
      final int settings = body.indexOf('fushi_reader_settings_button');

      expect(spacer, greaterThanOrEqualTo(0), reason: '底栏左右分区的 Spacer 没了？');
      expect(
        stats,
        greaterThan(spacer),
        reason: '统计键必须落在 Spacer 之后，也就是底栏右端（用户要的右下角）',
      );
      expect(stats, lessThan(settings), reason: '设置齿轮仍是最右那颗（移动端唯一面板入口，肌肉记忆不动）');
    });

    test('统计键是底栏级规格：iconSize 22，不套紧凑 visualDensity', () {
      final String body = _settingsBarBody(readReaderPageSource());
      final int stats = body.indexOf('fushi_reader_statistics_button');
      final int settings = body.indexOf('fushi_reader_settings_button');
      final String statsButton = body.substring(stats, settings);

      // 旧的「统计开关太小」正是 18px + visualDensity.compact 的紧凑 IconButton
      // （触摸目标约 40dp，低于 48dp 下限）。这里钉住底栏级规格：iconSize 22 +
      // IconButton 默认 48dp 命中区（底栏基高 56 容得下）。
      expect(
        statsButton,
        contains('iconSize: 22'),
        reason: '统计键要和底栏其余键同规格（22），不能缩成小图标',
      );
      expect(
        statsButton,
        isNot(contains('visualDensity')),
        reason: '统计键不得套紧凑 visualDensity，那会把触摸目标压到 48dp 以下',
      );
    });

    test('统计键图标随手动停表状态切换，但点击语义不双关', () {
      final String body = _settingsBarBody(readReaderPageSource());
      final int stats = body.indexOf('fushi_reader_statistics_button');
      final int settings = body.indexOf('fushi_reader_settings_button');
      final String statsButton = body.substring(stats, settings);

      expect(
        statsButton,
        contains('_studyClockManualPause'),
        reason: '移动端要有「计时被手动暂停」的常驻指示',
      );
      expect(
        statsButton,
        contains('Icons.timer_off_outlined'),
        reason: '停表态用 timer_off 图标',
      );
      expect(
        statsButton,
        isNot(contains('_toggleStudyClockManualPause')),
        reason: '停表 / 继续留在浮层底部那颗整宽按钮上，底栏键不塞第二种动作',
      );
    });

    test('统计键活在 barItems 里，跟随底栏反转镜像', () {
      final String body = _settingsBarBody(readReaderPageSource());
      final int listStart = body.indexOf('final List<Widget> barItems');
      final int listEnd = body.indexOf('\n    ];', listStart);
      expect(listStart, greaterThanOrEqualTo(0));
      expect(listEnd, greaterThan(listStart));

      final String barItems = body.substring(listStart, listEnd);
      expect(
        barItems,
        contains('fushi_reader_statistics_button'),
        reason: '统计键必须是 barItems 的一员，否则 reverseReaderBottomBar 反转时它不跟着镜像',
      );
      expect(
        body,
        contains('reversed ? barItems.reversed.toList() : barItems'),
        reason: '底栏反转仍由 barItems 统一处理',
      );
    });

    test('歌词模式不画统计键（进度/阅读追踪都不适用）', () {
      final String body = _settingsBarBody(readReaderPageSource());
      final int stats = body.indexOf('fushi_reader_statistics_button');
      final String before = body.substring(0, stats);

      expect(
        before.contains('if (!_lyricsMode)'),
        isTrue,
        reason: '歌词模式是独立 HTML 文档，桌面状态行同样不画，底栏统计键也不该出现',
      );
    });
  });
}

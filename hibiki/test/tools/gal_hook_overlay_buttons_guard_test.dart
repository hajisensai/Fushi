import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Hook 台词浮窗工具栏的绘制与命中必须来自同一个槽数：Render() 画 N 个按钮，
/// ControlActionAt() 就得给出 N 个 action，否则点击会落到看不见的按钮上，或者
/// 整排按钮相对居中布局漂移（浮窗是独立 native 窗口，Dart 侧测不到这层）。
///
/// BUG-951 起工具栏是两个窗口（正文窗内嵌一份 + 穿透态的独立 HookToolbarWindow），
/// 槽表因此上移到 `hook_toolbar_window.h` 的 `kSlotActions`；两窗同表索引，本守卫
/// 也随之改成「槽数 / 槽表 / 字形 / 命中四者对齐」，而不是数已经不存在的
/// `hook_button(N,` 与 `case N:` 字面量。
void main() {
  final String runner = p.join('windows', 'runner');
  final File window = File(p.join(runner, 'floating_lyric_window.cpp'));
  final File toolbarHeader = File(p.join(runner, 'hook_toolbar_window.h'));
  final File toolbar = File(p.join(runner, 'hook_toolbar_window.cpp'));
  final File host = File(p.join(runner, 'flutter_window.cpp'));

  test('hook 工具栏槽数与绘制、命中映射三者一致', () {
    final String source = window.readAsStringSync();
    final String header = toolbarHeader.readAsStringSync();

    final Match? declared =
        RegExp(r'kSlotCount\s*=\s*(\d+)\s*;').firstMatch(header);
    expect(declared, isNotNull, reason: '找不到 hook_toolbar::kSlotCount 声明');
    final int slots = int.parse(declared!.group(1)!);

    // 正文窗不得再持有自己的槽数：必须从共享表推导。
    expect(
      source.contains('kHookTextControlSlotCount = hook_toolbar::kSlotCount'),
      isTrue,
      reason: '正文窗的槽数必须由 hook_toolbar::kSlotCount 推导，不得另开一份',
    );

    // 槽表必须正好有 N 个 action。
    final int tableStart = header.indexOf('kSlotActions');
    expect(tableStart, greaterThan(0));
    final String table =
        header.substring(tableStart, header.indexOf('};', tableStart));
    expect(
      RegExp('"([a-zA-Z]+)"').allMatches(table).length,
      slots,
      reason: 'kSlotActions 必须为每个槽位给出 action',
    );

    // 字形表必须覆盖 0..N-1（default 分支只是兜底，不算覆盖）。
    final String toolbarSource = toolbar.readAsStringSync();
    final int glyphStart = toolbarSource.indexOf('const wchar_t* SlotGlyph');
    final int glyphEnd = toolbarSource.indexOf('bool SlotActive', glyphStart);
    expect(glyphStart, greaterThan(0), reason: '找不到 SlotGlyph 定义');
    expect(glyphEnd, greaterThan(glyphStart));
    final String glyphBody = toolbarSource.substring(glyphStart, glyphEnd);
    final List<int> glyphCases = RegExp(r'case (\d+):')
        .allMatches(glyphBody)
        .map((Match m) => int.parse(m.group(1)!))
        .toList()
      ..sort();
    expect(
      glyphCases,
      List<int>.generate(slots, (int i) => i),
      reason: 'SlotGlyph 必须为 0..N-1 每个槽位给出字形',
    );

    // 两个窗口的绘制与命中都必须遍历同一个槽数并索引同一张表。
    expect(
      source.contains('for (int slot = 0; slot < kHookTextControlSlotCount;'),
      isTrue,
      reason: '正文窗 Render() 必须按槽数循环画出全部槽位',
    );
    expect(
      source.contains('hook_toolbar::kSlotActions[slot]'),
      isTrue,
      reason: 'ControlActionAt() 必须索引共享槽表，不得另抄一份映射',
    );
    expect(
      toolbarSource.contains('hook_toolbar::kSlotActions[slot]'),
      isTrue,
      reason: '独立工具条窗的命中同样必须索引共享槽表',
    );
  });

  test('语音控件 action 与 native 状态方法齐全', () {
    final String source = window.readAsStringSync();
    final String header = toolbarHeader.readAsStringSync();
    for (final String action in <String>['replayVoice', 'recaptureVoice']) {
      expect(
        header,
        contains('"$action"'),
        reason: '浮窗必须能把「$action」按钮点击回传给 Dart',
      );
    }
    expect(
      source,
      contains('void FloatingLyricWindow::SetVoiceState'),
      reason: '试听 / 补录状态没有回写入口，用户就看不到自己在录音',
    );
    expect(
      host.readAsStringSync(),
      contains('setVoiceState'),
      reason: 'gal_hook_text channel 必须暴露 setVoiceState',
    );
  });

  test('hook 台词字号与窗口高度解耦（字号只由用户 pref 决定）', () {
    // BUG-1095 起，hook 台词字号不再随窗口高度缩放：拖窗只改窗口几何，字号由
    // 设置项 gal_hook_text_font_size 单独控制（旧的按高度缩放让「拖高一点」变成
    // 「字也跟着变」，两个诉求被绑死）。守卫从「必须缩放」翻转为「必须不缩放」。
    final String source = window.readAsStringSync();
    expect(
      source.contains('kHookTextBaseHeightForFontDip'),
      isFalse,
      reason: '这个常量就是「拖高浮窗 = 放大台词」的耦合来源，不得回来',
    );
    final int scaleAt = source.indexOf('const float height_scale');
    expect(scaleAt, greaterThan(0), reason: '非 hook 的歌词条仍按高度缩放，该表达式应当还在');
    final String scaleExpr = source.substring(scaleAt, scaleAt + 400);
    expect(
      scaleExpr.contains('hook_text_mode_ ? 1.0f'),
      isTrue,
      reason: 'hook 分支的高度缩放必须恒为 1.0f（字号与窗高解耦）',
    );
    // 有声书歌词条的「拖高放大」不受影响：非 hook 分支仍拿实时高度算比例。
    expect(
      scaleExpr.contains('strip_height_dip_ / kBaseStripHeightForFontDip'),
      isTrue,
      reason: '非 hook 分支仍须按实时窗口高度缩放字号',
    );
  });

  test('点词查询回传该字的屏幕矩形（查词卡锚定到词而非鼠标）', () {
    final String source = window.readAsStringSync();
    expect(
      source,
      contains('int FloatingLyricWindow::CharIndexAt(float x, float y,'),
      reason: 'CharIndexAt 必须能输出命中字符的矩形',
    );
    expect(
      source.contains(
          'on_context_lookup_(context_id_, utf8, index, screen_rect)'),
      isTrue,
      reason: '查词事件必须带上屏幕逻辑 px 的词矩形',
    );
    for (final String key in <String>[
      'wordLeft',
      'wordTop',
      'wordWidth',
      'wordHeight',
    ]) {
      expect(
        host.readAsStringSync(),
        contains('"$key"'),
        reason: 'channel 载荷缺少 $key，Dart 侧拿不到锚点',
      );
    }
  });
}

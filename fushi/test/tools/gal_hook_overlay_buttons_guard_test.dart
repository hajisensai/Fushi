import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Hook 台词浮窗工具栏的绘制与命中必须来自同一个槽数：Render() 画 N 个按钮，
/// ControlActionAt() 就得给出 N 个 action，否则点击会落到看不见的按钮上，或者
/// 整排按钮相对居中布局漂移（浮窗是独立 native 窗口，Dart 侧测不到这层）。
///
/// BUG-951 起工具栏是两个窗口（正文窗内嵌一份 + 穿透态的独立 HookToolbarWindow），
/// 槽表因此上移到 `hook_toolbar_window.h`；两窗同表索引。
///
/// 此后同一个浮窗类又服务了第二种用途（有声书悬浮字幕：上一句 / 播放暂停 /
/// 下一句 …），槽表**按用途分表**（`kGalHookSlotActions` / `kAudiobookSlotActions`），
/// 分派一律「先取 action 字符串再分支」而不是按槽位下标 switch —— 两张表长度不同，
/// 同一个下标在两表里是两回事，按下标分支必然在加表那天集体错位。
///
/// 本守卫因此从「单表 0..N-1 对齐」升级为：
///  * 每张表的 action 条数 == 该表声明的槽数；
///  * **两张表的每个 action** 都必须有字形分支 *和* 矢量画法（缺一个就是按钮画不
///    出来 —— 打包字体是极小子集，新 action 十有八九没有字形，只能落矢量）；
///  * 两个窗口的命中与绘制都走 SlotAction()/SlotCount()，不得各抄一份映射。
void main() {
  final String runner = p.join('windows', 'runner');
  final File window = File(p.join(runner, 'floating_lyric_window.cpp'));
  final File toolbarHeader = File(p.join(runner, 'hook_toolbar_window.h'));
  final File toolbar = File(p.join(runner, 'hook_toolbar_window.cpp'));
  final File host = File(p.join(runner, 'flutter_window.cpp'));

  test('每张 profile 槽表的槽数、字形、矢量画法、命中四者一致', () {
    final String source = window.readAsStringSync();
    final String header = toolbarHeader.readAsStringSync();
    final String toolbarSource = toolbar.readAsStringSync();

    /// 读出一张槽表声明的槽数与它实际列出的 action。
    List<String> tableActions(String countName, String tableName) {
      final Match? declared =
          RegExp('$countName' r'\s*=\s*(\d+)\s*;').firstMatch(header);
      expect(declared, isNotNull, reason: '找不到 hook_toolbar::$countName 声明');
      final int slots = int.parse(declared!.group(1)!);

      final int tableStart = header.indexOf('$tableName[');
      expect(tableStart, greaterThan(0), reason: '找不到槽表 $tableName');
      final String table =
          header.substring(tableStart, header.indexOf('};', tableStart));
      final List<String> actions = RegExp('"([a-zA-Z]+)"')
          .allMatches(table)
          .map((Match m) => m.group(1)!)
          .toList();
      expect(actions.length, slots,
          reason: '$tableName 必须为每个槽位给出 action');
      return actions;
    }

    final List<String> galActions =
        tableActions('kGalHookSlotCount', 'kGalHookSlotActions');
    final List<String> audiobookActions =
        tableActions('kAudiobookSlotCount', 'kAudiobookSlotActions');
    final Set<String> allActions = <String>{...galActions, ...audiobookActions};

    /// 取一个函数体（从签名到第 0 列收尾大括号）。终点必须是本函数自己的收尾，
    /// 不能拿相邻函数当分隔符 —— 相邻函数一挪位置守卫就崩在切片上，而不是报出
    /// 真正的问题。
    String functionBody(String signature) {
      final int start = toolbarSource.indexOf(signature);
      expect(start, greaterThan(0), reason: '找不到 $signature 定义');
      final int end = toolbarSource.indexOf('\n}', start);
      expect(end, greaterThan(start), reason: '$signature 必须有第 0 列收尾大括号');
      return toolbarSource.substring(start, end);
    }

    final String glyphBody = functionBody('const wchar_t* SlotGlyph');
    final String iconBody = functionBody('void DrawSlotIcon');

    for (final String action in allActions) {
      // 字形分支：给得出字体字形的返回码位，给不出的必须显式落到空串（由调用方
      // 逐槽回退矢量）。两种都算「SlotGlyph 认识这个 action」。
      expect(
        glyphBody.contains('"$action"'),
        isTrue,
        reason: 'SlotGlyph 必须认识 action「$action」，否则该按钮画不出字形也不回退',
      );
      // 矢量画法是打包字体缺字形时的唯一出路，必须覆盖每个 action。
      expect(
        iconBody.contains('"$action"'),
        isTrue,
        reason: 'DrawSlotIcon 必须为 action「$action」给出矢量画法（字体是极小子集，'
            '缺字形时只剩这条路）',
      );
    }

    // 绘制与命中都必须按 profile 问槽数 / 槽表，不得另开一份。
    expect(
      source.contains('hook_toolbar::SlotCount(toolbar_profile_)'),
      isTrue,
      reason: '正文窗必须按 profile 问槽数，不得持有自己的槽数常量',
    );
    expect(
      source.contains('hook_toolbar::SlotAction(toolbar_profile_, slot)'),
      isTrue,
      reason: 'ControlActionAt() 必须索引 profile 槽表，不得另抄一份映射',
    );
    expect(
      toolbarSource.contains('hook_toolbar::SlotAction(profile_, slot)'),
      isTrue,
      reason: '独立工具条窗的命中同样必须索引 profile 槽表',
    );
    // 分派按 action 而不是槽位下标：两张表长度不同，按下标 switch 必然错位。
    for (final String body in <String>[glyphBody, iconBody]) {
      expect(
        RegExp(r'case \d+:').hasMatch(body),
        isFalse,
        reason: '槽位分派不得按下标 switch —— 两张 profile 表的同一下标是两回事',
      );
    }
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

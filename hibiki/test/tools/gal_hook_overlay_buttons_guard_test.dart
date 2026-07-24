import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Hook 台词浮窗工具栏的绘制与命中必须来自同一个槽数：Render() 画 N 个按钮，
/// ControlActionAt() 就得给出 N 个 action，否则点击会落到看不见的按钮上，或者
/// 整排按钮相对居中布局漂移（浮窗是独立 native 窗口，Dart 侧测不到这层）。
void main() {
  final String runner = p.join('windows', 'runner');
  final File window = File(p.join(runner, 'floating_lyric_window.cpp'));
  final File host = File(p.join(runner, 'flutter_window.cpp'));

  test('hook 工具栏槽数与绘制、命中映射三者一致', () {
    final String source = window.readAsStringSync();
    final RegExp slotCount =
        RegExp(r'kHookTextControlSlotCount\s*=\s*(\d+)\s*;');
    final Match? declared = slotCount.firstMatch(source);
    expect(declared, isNotNull, reason: '找不到 kHookTextControlSlotCount 声明');
    final int slots = int.parse(declared!.group(1)!);

    final List<int> drawn = RegExp(r'hook_button\((\d+),')
        .allMatches(source)
        .map((Match m) => int.parse(m.group(1)!))
        .toList()
      ..sort();
    expect(
      drawn,
      List<int>.generate(slots, (int i) => i),
      reason: 'Render() 必须正好画出 0..N-1 全部槽位',
    );

    final int hookHitStart = source.indexOf('if (hook_text_mode_) {',
        source.indexOf('std::string FloatingLyricWindow::ControlActionAt'));
    expect(hookHitStart, greaterThan(0));
    // 只截 hook 分支自身：后面还有 clipboard / 歌词条的槽位 switch，混进来会误判。
    final int hookHitEnd = source.indexOf('const float lock_x', hookHitStart);
    expect(hookHitEnd, greaterThan(hookHitStart));
    final String hookHit = source.substring(hookHitStart, hookHitEnd);
    final List<int> mapped = RegExp(r'case (\d+):')
        .allMatches(hookHit)
        .map((Match m) => int.parse(m.group(1)!))
        .toList()
      ..sort();
    expect(
      mapped,
      List<int>.generate(slots, (int i) => i),
      reason: 'ControlActionAt() 必须为每个绘制出来的槽位给出 action',
    );
  });

  test('语音控件 action 与 native 状态方法齐全', () {
    final String source = window.readAsStringSync();
    for (final String action in <String>['replayVoice', 'recaptureVoice']) {
      expect(
        source,
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
}

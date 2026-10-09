// 设置页分组跳转条跟随当前分组（反馈 anuYVUChGs：「设置 › 视频」往下滚到「音频」时，
// 顶部 HDR / 画面 / 色彩 / 字幕 / 字幕行为与来源 / 音频… 跳转条不跟着横向滚动，高亮
// 的「音频」停在屏幕外）。跳转条是所有 SettingsKitScaffold 设置页共用的组件，修在
// 组件层，这里直接钉组件行为。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/settings/settings_kit.dart';

const List<(String, String)> _sections = <(String, String)>[
  ('hdr', 'HDR'),
  ('picture', 'Picture'),
  ('color', 'Color'),
  ('subtitle', 'Subtitles'),
  ('subtitle_behavior', 'Subtitle behavior and sources'),
  ('audio', 'Audio'),
  ('advanced', 'Advanced'),
];

Rect _chipRect(WidgetTester tester, String id) =>
    tester.getRect(find.byKey(ValueKey<String>('settings-jump.$id')));

Rect _barRect(WidgetTester tester) => tester.getRect(
  find.byKey(const ValueKey<String>('settings-jump-bar-scroll')),
);

void main() {
  testWidgets('active section chip scrolls into the visible bar and back', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(384, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ValueNotifier<String> active = ValueNotifier<String>('hdr');
    addTearDown(active.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: active,
            builder: (BuildContext context, String id, Widget? _) =>
                SettingsSectionJumpBar(
                  sections: _sections,
                  activeId: id,
                  onSelected: (String next) => active.value = next,
                ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Rect bar = _barRect(tester);
    // 前提：七个分组在 384 宽下放不下，「音频」一开始在可见区外。
    expect(_chipRect(tester, 'audio').right, greaterThan(bar.right));

    // 正文滚到「音频」分组 → 跳转条自己横向滚动，把「音频」完整带进可见区。
    active.value = 'audio';
    await tester.pumpAndSettle();
    final Rect audio = _chipRect(tester, 'audio');
    expect(audio.left, greaterThanOrEqualTo(bar.left - 0.5));
    expect(audio.right, lessThanOrEqualTo(bar.right + 0.5));

    // 滚回顶部 → 「HDR」也被带回可见区。
    active.value = 'hdr';
    await tester.pumpAndSettle();
    final Rect hdr = _chipRect(tester, 'hdr');
    expect(hdr.left, greaterThanOrEqualTo(bar.left - 0.5));
    expect(hdr.right, lessThanOrEqualTo(bar.right + 0.5));
  });

  testWidgets('already-visible active chip does not move the bar', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(384, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ValueNotifier<String> active = ValueNotifier<String>('hdr');
    addTearDown(active.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: active,
            builder: (BuildContext context, String id, Widget? _) =>
                SettingsSectionJumpBar(
                  sections: _sections,
                  activeId: id,
                  onSelected: (String next) => active.value = next,
                ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final double before = _chipRect(tester, 'hdr').left;
    active.value = 'picture';
    await tester.pumpAndSettle();
    expect(_chipRect(tester, 'hdr').left, before);
  });
}

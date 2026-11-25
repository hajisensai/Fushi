import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// 视频库页头「⋯」（设计稿 #video V2）：低频动作（选择、布局切换、遥控、管理
/// 标签 / 合集、刷新…）：宽度够时平铺，否则在「⋯」菜单里。点 [entryKey] 那一项；调用方
/// 照旧在之后 `pumpAndSettle`。
Future<void> tapVideoHeaderMoreEntry(
  WidgetTester tester,
  String entryKey,
) async {
  // 宽度够时「⋯」的项由页头平铺成独立图标钮（同一个 key），直接点。
  final Finder entry = find.byKey(ValueKey<String>(entryKey));
  if (entry.evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey<String>('video-library-more')));
    await tester.pumpAndSettle();
  }
  await tester.tap(entry);
}

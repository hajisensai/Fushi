// 详情页分区头（「剧集 13」那一行）的 trailing 必须贴右缘。
//
// 用户反馈：在线视频源作品页进多选后，「剧集」标题行的 ✕ 落在行中偏右的半空里。
// 根因是 `Flexible(标题) … Spacer() … trailing`：两个 flex 子项平分剩余宽度，松约束
// 的短标题用不完自己那一半也不让出来，Spacer 只拿到另一半。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<void> pumpHeader(WidgetTester tester, String title) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              key: const ValueKey<String>('host'),
              width: 344,
              child: MediaDetailSectionHeader(
                title,
                count: 13,
                trailing: const SizedBox(
                  key: ValueKey<String>('trailing'),
                  width: 40,
                  height: 40,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('短标题 + 计数胶囊：trailing 贴分区头右缘', (WidgetTester tester) async {
    await pumpHeader(tester, '剧集');
    expect(
      tester.getTopRight(find.byKey(const ValueKey<String>('trailing'))).dx,
      tester.getTopRight(find.byKey(const ValueKey<String>('host'))).dx,
    );
  });

  testWidgets('长标题省略而不挤掉 trailing，trailing 仍贴右缘', (WidgetTester tester) async {
    await pumpHeader(tester, '很长很长的分区标题' * 6);
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopRight(find.byKey(const ValueKey<String>('trailing'))).dx,
      tester.getTopRight(find.byKey(const ValueKey<String>('host'))).dx,
    );
  });
}

// BUG-3705：复习卡片段「放大查看」走 showAppDialog，路由下面没有 Material。关闭键（InkWell）
// 缺 Material 祖先时构建失败、被错误盒替换，错误盒在 Positioned 里铺满整个画面盖住视频。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_video_clip.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('放大视图在对话框里正常构建：画面不被错误盒盖住，关闭键可用', (WidgetTester tester) async {
    late BuildContext pageContext;
    int toggles = 0;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                pageContext = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
    showAppDialog<void>(
      context: pageContext,
      builder: (BuildContext context) => SrsCardVideoExpandedView(
        aspect: 16 / 9,
        view: const ColoredBox(
          key: ValueKey<String>('fake-video'),
          color: Colors.green,
        ),
        onToggle: () => toggles++,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '关闭键不能因缺 Material 祖先构建失败');
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byKey(const ValueKey<String>('fake-video')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('srs-card-video-expanded')),
    );
    expect(toggles, 1);

    await tester.tap(
      find.byKey(const ValueKey<String>('srs-card-video-expanded-close')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SrsCardVideoExpandedView), findsNothing);
  });
}

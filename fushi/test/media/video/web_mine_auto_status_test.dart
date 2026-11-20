import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/web_mine_auto_status.dart';
import 'package:material_ui/material_ui.dart';

/// 网页视频制卡队列一轮结束的提示（BUG-5039）：出错中止不能说成「已制卡 0，失败 0」
/// 或「你回来了，已暂停」。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('出错中止：手动 / 自动、胶囊 / Toast 都是「出错中止」文案', () {
    for (final bool auto in <bool>[false, true]) {
      final WebMineAutoFinished s = WebMineAutoFinished(
        ok: 0,
        failed: 0,
        remaining: 3,
        auto: auto,
        errored: true,
      );
      final String expected = t.web_video_mine_queue_errored(ok: 0, failed: 0);
      expect(webMineFinishedText(s), expected);
      expect(webMineFinishedText(s, forToast: true), expected);
    }
  });

  test('正常结束的文案不变', () {
    expect(
      webMineFinishedText(
        const WebMineAutoFinished(ok: 2, failed: 1, remaining: 0, auto: false),
      ),
      t.web_video_mine_queue_finished(ok: 2, failed: 1),
    );
    const WebMineAutoFinished paused = WebMineAutoFinished(
      ok: 2,
      failed: 0,
      remaining: 4,
    );
    expect(
      webMineFinishedText(paused),
      t.web_video_mine_auto_paused(ok: 2, failed: 0, count: 4),
    );
    expect(
      webMineFinishedText(paused, forToast: true),
      t.web_video_mine_auto_finished(ok: 2, failed: 0),
    );
  });

  testWidgets('结果胶囊：出错中止显示出错文案', (WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: WebMineAutoStatusChip(
              status: const WebMineAutoFinished(
                ok: 0,
                failed: 0,
                remaining: 5,
                errored: true,
              ),
              onDismiss: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(t.web_video_mine_queue_errored(ok: 0, failed: 0)),
      findsOneWidget,
    );
    expect(
      find.text(t.web_video_mine_auto_paused(ok: 0, failed: 0, count: 5)),
      findsNothing,
      reason: '修复前：准备步骤抛出后胶囊说「你回来了，已暂停」',
    );
  });
}

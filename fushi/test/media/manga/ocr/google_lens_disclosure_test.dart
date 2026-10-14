// BUG-3342：Google Lens 上传同意框按调用场景给文案——视频调用方以前直接用漫画
// 那份（「将漫画页面发送到 Google Lens？」），用户在视频页看到的是漫画文案。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_disclosure.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Future<bool>> _open(
  WidgetTester tester, {
  GoogleLensDisclosureScene? scene,
}) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) {
          ctx = context;
          return const SizedBox.expand();
        },
      ),
    ),
  );
  final Future<bool> result = scene == null
      ? ensureGoogleLensDisclosure(ctx)
      : ensureGoogleLensDisclosure(ctx, scene: scene);
  await tester.pumpAndSettle();
  return result;
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('漫画（默认场景）保持原文案', (tester) async {
    final Future<bool> result = await _open(tester);
    expect(find.text(t.manga_google_lens_disclosure_title), findsOneWidget);
    expect(find.text(t.manga_google_lens_disclosure_body), findsOneWidget);
    expect(find.text(t.video_google_lens_disclosure_title), findsNothing);
    await tester.tap(find.text(t.manga_google_lens_disclosure_accept));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt(kGoogleLensDisclosurePreferenceKey),
      kGoogleLensDisclosureVersion,
    );
  });

  testWidgets('视频场景：标题与正文说视频画面，不出现「漫画」', (tester) async {
    final Future<bool> result = await _open(
      tester,
      scene: GoogleLensDisclosureScene.videoFrames,
    );
    expect(find.text(t.video_google_lens_disclosure_title), findsOneWidget);
    expect(find.text(t.video_google_lens_disclosure_body), findsOneWidget);
    expect(find.text(t.manga_google_lens_disclosure_title), findsNothing);
    expect(t.video_google_lens_disclosure_title, isNot(contains('漫画')));
    expect(t.video_google_lens_disclosure_body, isNot(contains('漫画')));
    await tester.tap(find.text(t.manga_google_lens_disclosure_decline));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('同意记录按场景分开：同意过漫画不代表同意上传视频画面', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kGoogleLensDisclosurePreferenceKey: kGoogleLensDisclosureVersion,
    });
    final Future<bool> manga = await _open(tester);
    expect(await manga, isTrue, reason: '漫画已同意：不再弹框');
    expect(find.text(t.manga_google_lens_disclosure_title), findsNothing);

    final Future<bool> video = await _open(
      tester,
      scene: GoogleLensDisclosureScene.videoFrames,
    );
    expect(find.text(t.video_google_lens_disclosure_title), findsOneWidget);
    await tester.tap(find.text(t.manga_google_lens_disclosure_accept));
    await tester.pumpAndSettle();
    expect(await video, isTrue);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt(kVideoGoogleLensDisclosurePreferenceKey),
      kGoogleLensDisclosureVersion,
    );
  });
}

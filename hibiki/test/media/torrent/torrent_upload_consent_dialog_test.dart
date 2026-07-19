import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/pages/implementations/torrent_upload_consent_dialog.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('seed fields hidden until upload enabled', (tester) async {
    QbConnectionConfig? applied;
    await tester.pumpWidget(buildApp(TorrentUploadConsentDialog(
      initialConfig: const QbConnectionConfig(),
      onApply: (QbConnectionConfig c) async => applied = c,
    )));

    expect(find.text(t.torrent_upload_intro_title), findsOneWidget);
    // 未开启上传：限速/做种字段隐藏。
    expect(find.text(t.video_setting_torrent_seed_time_limit), findsNothing);
    expect(find.text(t.video_setting_torrent_seed_ratio_limit), findsNothing);

    // 打开开关 → 三字段出现。
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text(t.video_setting_torrent_upload_limit), findsOneWidget);
    expect(find.text(t.video_setting_torrent_seed_time_limit), findsOneWidget);
    expect(find.text(t.video_setting_torrent_seed_ratio_limit), findsOneWidget);
    expect(applied, isNull); // 尚未确认
  });

  testWidgets('keep off applies uploadEnabled=false', (tester) async {
    QbConnectionConfig? applied;
    await tester.pumpWidget(buildApp(TorrentUploadConsentDialog(
      initialConfig: const QbConnectionConfig(uploadEnabled: true),
      onApply: (QbConnectionConfig c) async => applied = c,
    )));

    await tester.tap(find.text(t.torrent_upload_intro_keep_off));
    await tester.pumpAndSettle();
    expect(applied, isNotNull);
    expect(applied!.uploadEnabled, isFalse);
  });

  testWidgets('enable + configure applies parsed values', (tester) async {
    QbConnectionConfig? applied;
    await tester.pumpWidget(buildApp(TorrentUploadConsentDialog(
      initialConfig: const QbConnectionConfig(),
      onApply: (QbConnectionConfig c) async => applied = c,
    )));

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, t.video_setting_torrent_upload_limit),
        '256');
    await tester.enterText(
        find.widgetWithText(TextField, t.video_setting_torrent_seed_time_limit),
        '90');
    await tester.enterText(
        find.widgetWithText(
            TextField, t.video_setting_torrent_seed_ratio_limit),
        '1.5');
    await tester.tap(find.text(t.torrent_upload_intro_confirm));
    await tester.pumpAndSettle();

    expect(applied, isNotNull);
    expect(applied!.uploadEnabled, isTrue);
    expect(applied!.uploadLimitKbps, 256);
    expect(applied!.seedTimeLimitMinutes, 90);
    expect(applied!.seedRatioLimit, 1.5);
  });
}

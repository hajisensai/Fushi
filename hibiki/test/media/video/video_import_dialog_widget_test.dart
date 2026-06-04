import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  testWidgets('renders with import disabled until a video is picked',
      (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);

    await tester.pumpWidget(buildApp(VideoImportDialog(repo: repo)));

    expect(tester.takeException(), isNull);
    // 字幕可选提示可见。
    expect(find.text(t.video_import_subtitle_optional), findsOneWidget);

    // 初始（未选视频）导入按钮禁用。
    final FilledButton importButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, t.video_import_confirm),
    );
    expect(importButton.onPressed, isNull);
  });
}

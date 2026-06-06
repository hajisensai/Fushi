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

  testWidgets('VideoImportDialog prefills dragged video path into UI',
      (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);

    await tester.pumpWidget(
      buildApp(
        VideoImportDialog(
          repo: repo,
          initialVideoPath: r'C:\movies\Spirited Away.mkv',
        ),
      ),
    );
    await tester.pump();

    // 拖入的视频文件名应渲染进对话框（已选视频展示其 basename）。
    expect(find.textContaining('Spirited Away'), findsWidgets);
  });
}

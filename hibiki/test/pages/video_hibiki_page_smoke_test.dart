import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  testWidgets('shows loader when book missing', (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      home:
          VideoHibikiPage(bookUid: 'video/none', repo: VideoBookRepository(db)),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}

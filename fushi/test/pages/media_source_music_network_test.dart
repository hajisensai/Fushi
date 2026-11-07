// 反馈 QAondMh4M5：音乐来源能按 SFTP / WebDAV / AList 添加（此前音乐域没有网络传输，
// 「添加来源」直接弹本地文件夹选择）。FTP 读不了区间，远程标签扫描与起播都做不了，不给。
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('music: add source offers Network with SFTP / WebDAV / AList, '
      'no FTP', (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    final GlobalKey<MediaSourcesViewState> viewKey =
        GlobalKey<MediaSourcesViewState>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
        child: MaterialApp(
          home: Scaffold(
            body: MediaSourcesView(key: viewKey, mediaKind: 'music'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    viewKey.currentState!.addSource();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Network'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    for (final String label in <String>['SFTP', 'WebDAV', 'AList']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('FTP'), findsNothing);
  });
}

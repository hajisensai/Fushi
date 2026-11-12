import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_sync_settings.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart' show SrsProfileConflict;
import 'package:fushi_engine/srs/srs_profile_link.dart' show SrsRemoteProfile;
import 'package:material_ui/material_ui.dart';

/// 复习页上自动弹出的「profile 冲突」对话框：内容里的候选行不能让对话框排版失败。
/// AlertDialog 用 IntrinsicWidth 量内容，候选行里一旦有 LayoutBuilder（跑马灯标题）就抛
/// 「LayoutBuilder does not support returning intrinsic dimensions」，对话框没有尺寸，
/// 桌面上鼠标命中测试随即每帧报错、整个 app 不再响应。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('桌面尺寸弹出冲突对话框：排版无异常、候选可见、可悬停', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1165, 677);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              host = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

    const SrsProfileConflict conflict = SrsProfileConflict(
      directoryKey: 'dir',
      localUid: 'local-uid',
      localHasNotes: true,
      localNoteCount: 42,
      candidates: <SrsRemoteProfile>[
        SrsRemoteProfile(
          uid: '01a13df1-aaaa-bbbb',
          writers: <String>['a#1'],
          names: <String>{'Default'},
          devices: <String>['Windows PC'],
          noteCount: 1234,
        ),
        SrsRemoteProfile(
          uid: '9f00aa11-cccc-dddd',
          writers: <String>['b#1'],
          names: <String>{'Default'},
        ),
      ],
    );
    showSrsProfileConflictDialog(host, conflict);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final Finder tile = find.byKey(
      const ValueKey<String>('srs-profile-conflict-01a13df1-aaaa-bbbb'),
    );
    expect(tile, findsOneWidget);
    expect(tester.getSize(tile).width, greaterThan(0));

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(tile));
    await mouse.moveTo(tester.getCenter(tile) + const Offset(4, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

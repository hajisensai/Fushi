import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/apple_sidebar_library_host.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-5533：Apple 宽窗侧栏外壳里切 tab 时，新库页登记分区行、旧库页撤回，
/// 宿主帧末通知一次。旧实现把宿主本身当 [AppleSidebarLibraryScope] 的
/// notifier，这一次通知让所有依赖 scope 的库页（访问过的保活页，包括藏起来
/// 的）各自整页重建。依赖者只该随侧栏形态（[AppleSidebarLibraryHost.sidebarMode]）
/// 重建；分区行只有侧栏外壳（直接监听宿主）要画。
void main() {
  late AppleSidebarLibraryHost host;
  late int builds;
  late int hostNotifications;

  Future<void> mount(WidgetTester tester) async {
    builds = 0;
    hostNotifications = 0;
    host.addListener(() => hostNotifications++);
    await tester.pumpWidget(
      AppleSidebarLibraryScope(
        host: host,
        child: Builder(
          builder: (BuildContext context) {
            builds++;
            final AppleSidebarLibraryHost? seen =
                AppleSidebarLibraryScope.maybeOf(context);
            return Text(
              '${seen?.sidebarMode}',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ),
    );
    expect(builds, 1);
  }

  AppleSidebarLibraryRow row(String id) =>
      AppleSidebarLibraryRow(id: id, label: id, selected: false, onTap: () {});

  setUp(() {
    host = AppleSidebarLibraryHost();
    host.reportSidebarMode(true);
  });
  tearDown(() => host.dispose());

  testWidgets('tab switch publish/retract does not rebuild scope dependents', (
    WidgetTester tester,
  ) async {
    await mount(tester);
    final Object books = Object();
    final Object manga = Object();
    host.publish(books, <AppleSidebarLibraryRow>[row('shelf')]);
    await tester.pump();
    await tester.pump();
    final int notificationsBefore = hostNotifications;

    // 切 tab：漫画页登记、书架页撤回，另加一节标签。
    host.publish(manga, <AppleSidebarLibraryRow>[row('manga')]);
    host.publish(books, null);
    host.publishTags(manga, <AppleSidebarLibraryRow>[row('tag')]);
    await tester.pump();
    await tester.pump();

    expect(hostNotifications, greaterThan(notificationsBefore));
    expect(host.rows.map((AppleSidebarLibraryRow r) => r.id).toList(), <String>[
      'manga',
      'tag',
    ]);
    expect(builds, 1, reason: 'row registration must not notify dependents');
  });

  testWidgets('sidebar mode change rebuilds scope dependents', (
    WidgetTester tester,
  ) async {
    await mount(tester);
    expect(find.text('true'), findsOneWidget);

    host.reportSidebarMode(false);
    await tester.pump();
    await tester.pump();

    expect(builds, 2);
    expect(find.text('false'), findsOneWidget);
  });
}

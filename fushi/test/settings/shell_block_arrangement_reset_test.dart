// BUG-4703：外观页「色块摆放」的「已改过 / 恢复默认」必须对照**真实生效的默认**——
// 没选过时摆放跟着库页布局走（`ShellBlockArrangement.defaultFor`），而不是写死成
// 拼贴下的「散落」。PR #3454 把默认布局改成封面网格后，全新安装就被标成已改过，
// 恢复默认反而把网格下色块分区的摆放写成散落。本文件用真实外观 schema +
// 真实 ThemeNotifier 走 settingsResetSpecFor 咬住。
//
// #3515 起：新安装出厂布局回到拼贴（`ShellContentLayout.defaultLayout`），没选过的
// 摆放一律规整（C1，`ShellBlockArrangement.defaultFor` 不再按布局区分）。不变式不
// 变——「已改过」只对照真实生效的默认，切布局不会把没碰过的摆放标成已改过。
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

const String _rowId = 'appearance.shell_block_arrangement';

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());
}

SettingsItem _arrangementRow() => buildAppearanceDestination().sections
    .expand((SettingsSection s) => s.items)
    .firstWhere((SettingsItem i) => i.id == _rowId);

void main() {
  late FushiDatabase database;
  late ThemeNotifier notifier;
  late AppModel appModel;

  setUp(() {
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    notifier = ThemeNotifier(database, () => const TextTheme())
      ..loadFromPrefsSnapshot(<String, String>{
        'design_system': PrefCodec.encode('material'),
        'brightness_mode': PrefCodec.encode('light'),
      });
    appModel = _TestAppModel()..themeNotifier = notifier;
  });

  tearDown(() async {
    notifier.dispose();
    await database.close();
  });

  Future<SettingsContext> pumpContext(WidgetTester tester) async {
    late SettingsContext ctx;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? _) {
              ctx = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return ctx;
  }

  testWidgets('全新安装（默认拼贴 + 规整）：色块摆放不算已改过', (WidgetTester tester) async {
    final SettingsContext ctx = await pumpContext(tester);
    expect(appModel.shellContentLayout, ShellContentLayout.collage);
    expect(appModel.shellBlockArrangement, ShellBlockArrangement.aligned);
    final SettingsResetSpec? spec = settingsResetSpecFor(
      _arrangementRow(),
      ctx,
    );
    expect(spec, isNotNull);
    expect(spec!.modified, isFalse);
  });

  testWidgets('只切布局、没碰摆放：摆放仍是默认规整，不算已改过', (WidgetTester tester) async {
    final SettingsContext ctx = await pumpContext(tester);
    await tester.runAsync(
      () => notifier.setShellContentLayout(ShellContentLayout.grid),
    );
    expect(appModel.shellBlockArrangement, ShellBlockArrangement.aligned);
    expect(settingsResetSpecFor(_arrangementRow(), ctx)!.modified, isFalse);
    await tester.runAsync(
      () => notifier.setShellContentLayout(ShellContentLayout.collage),
    );
    expect(appModel.shellBlockArrangement, ShellBlockArrangement.aligned);
    expect(settingsResetSpecFor(_arrangementRow(), ctx)!.modified, isFalse);
  });

  testWidgets('选过交错再恢复默认：回到未选（规整），'
      '之后切布局仍是规整', (WidgetTester tester) async {
    final SettingsContext ctx = await pumpContext(tester);
    await tester.runAsync(
      () => notifier.setShellBlockArrangement(ShellBlockArrangement.staggered),
    );
    final SettingsResetSpec modified = settingsResetSpecFor(
      _arrangementRow(),
      ctx,
    )!;
    expect(modified.modified, isTrue);

    await tester.runAsync(modified.reset);
    expect(appModel.shellBlockArrangement, ShellBlockArrangement.aligned);
    expect(notifier.shellTheme.blockArrangement, isNull);
    expect(settingsResetSpecFor(_arrangementRow(), ctx)!.modified, isFalse);

    await tester.runAsync(
      () => notifier.setShellContentLayout(ShellContentLayout.grid),
    );
    expect(appModel.shellBlockArrangement, ShellBlockArrangement.aligned);
    expect(settingsResetSpecFor(_arrangementRow(), ctx)!.modified, isFalse);
  });
}

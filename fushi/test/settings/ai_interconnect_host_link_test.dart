import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/torrent_settings_section.dart'
    show kDownloadExecutionHostSettingsItemId;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_ai.dart';
import 'package:fushi/src/settings/settings_schema_downloads.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 反馈 sOLqsIv6R9：「交给互联电脑办」（= 下载执行设备偏好）的控件只在下载页渲染
/// 一份，AI 设置页只留一条链接——点了跳到下载页并定位那一行。
class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext settingsContext;

  SettingsItem aiItem() => buildAiDestination().sections
      .singleWhere((SettingsSection s) => s.id == 'ai.video_download')
      .items
      .singleWhere((SettingsItem i) => i.id == 'ai.interconnect_host');

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'fushi_ai_interconnect_link_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db);
  });

  tearDown(() async {
    SettingsSearchReveal.pendingItemId = null;
    await db.close();
  });

  Future<_RecordingObserver> pumpContext(WidgetTester tester) async {
    final _RecordingObserver observer = _RecordingObserver();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorObservers: <NavigatorObserver>[observer],
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              settingsContext = SettingsContext(
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
    return observer;
  }

  test('the AI row is a link, not a second copy of the control', () {
    final SettingsItem item = aiItem();
    expect(item, isA<SettingsNavigationItem>());
    final SettingsNavigationItem link = item as SettingsNavigationItem;
    expect(link.title, t.ai_interconnect_host_title);
    expect(link.subtitle, t.ai_interconnect_host_link_hint);
    expect(link.onTap, isNotNull);
    expect(link.child, isNull, reason: '不在 AI 页另起一份子页');
    expect(link.builder, isNull);
  });

  test('the link target is the downloads page execution-host row', () {
    expect(
      buildDownloadsDestination().bodySearchEntries.map(
        (SettingsBodySearchEntry e) => e.id,
      ),
      contains(kDownloadExecutionHostSettingsItemId),
      reason: '链接落点必须是下载页登记过的搜索落点',
    );
  });

  testWidgets('tapping the link arms the reveal and pushes a page', (
    WidgetTester tester,
  ) async {
    final _RecordingObserver observer = await pumpContext(tester);
    final SettingsNavigationItem link = aiItem() as SettingsNavigationItem;
    expect(link.isVisible(settingsContext), isTrue);
    final int before = observer.pushed.length;
    unawaited(Future<void>.value(link.onTap!(settingsContext)));
    expect(
      SettingsSearchReveal.pendingItemId,
      kDownloadExecutionHostSettingsItemId,
    );
    expect(observer.pushed.length, before + 1);
  });
}

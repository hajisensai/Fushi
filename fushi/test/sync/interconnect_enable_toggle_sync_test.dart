import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/source_guard.dart';
import '../helpers/test_platform_services.dart';
import 'sync_settings_schema_source_corpus.dart';

/// BUG-1560：互联总开关有**两个**写入口——同步设置页的「启用互联」开关，和库页来源
/// 视图里的互联虚拟来源行——而两边各自缓存着一份内存态：
/// - 设置页的 `_SyncSettingsState` 按 AppModel 缓存（模块级 `_activeSyncState`），
///   `load()` 一辈子只跑一次；
/// - 来源视图在 `initState` 读一次 `isInterconnectEnabled()`。
///
/// 谁写完都不通知对方 → 另一边的开关、以及互联那几个 section 的显隐，一直显示旧值
/// 直到重启 app。修法是把「已变更」广播放进**唯一的写方法**
/// [SyncRepository.setInterconnectEnabled]，消费方收到广播后回 preferences 重读真值
/// （不信广播载荷，所以没有第二份真相）。
///
/// 本文件三头钉：
///  (1) 写方法一定 bump 广播（真 DB 行为）；
///  (2) 来源视图订阅广播、别处一改就跟上（真 widget 行为）；
///  (3) 设置页状态订阅同一条广播、换 owner 时摘钩（源码守卫）；
///  (4) 顺带钉住互联上传区页脚文案不再自称与「启用互联」互不影响（该 section 本就
///      被这个开关门控，旧文案与行为矛盾）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  FushiDatabase makeDb() {
    final FushiDatabase db =
        FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    addTearDown(db.close);
    return db;
  }

  test('setInterconnectEnabled 每次写入都 bump 广播（写入口再多也漏不掉）', () async {
    final FushiDatabase db = makeDb();
    final SyncRepository repo = SyncRepository(db);
    final int before = SyncRepository.interconnectEnabledRevision.value;
    int bumps = 0;
    void onBump() => bumps++;
    SyncRepository.interconnectEnabledRevision.addListener(onBump);
    addTearDown(
      () => SyncRepository.interconnectEnabledRevision.removeListener(onBump),
    );

    await repo.setInterconnectEnabled(true);
    expect(await repo.isInterconnectEnabled(), isTrue);
    expect(bumps, 1, reason: '写了却不广播 = 另一个入口永远看不到这次改动');

    await repo.setInterconnectEnabled(false);
    expect(await repo.isInterconnectEnabled(), isFalse);
    expect(bumps, 2);
    expect(
      SyncRepository.interconnectEnabledRevision.value,
      before + 2,
      reason: 'revision 必须单调递增，消费方靠它区分「又变了一次」',
    );
  });

  testWidgets('来源页互联开关跟随别处（设置页）的写入实时更新，不再等重启', (WidgetTester tester) async {
    final FushiDatabase db = makeDb();
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tempDir =
        Directory.systemTemp.createTempSync('hibiki_interconnect_toggle_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db);

    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaSourcesView(mediaKind: 'book'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    Switch interconnectSwitch() =>
        tester.widgetList<Switch>(find.byType(Switch)).first;
    expect(interconnectSwitch().value, isFalse,
        reason: '初始未启用互联（preferences 默认 false）');

    // 模拟「用户在同步设置页把互联打开」——同一条真值，另一个写入口。
    await SyncRepository(db).setInterconnectEnabled(true);
    await tester.pumpAndSettle();
    expect(interconnectSwitch().value, isTrue,
        reason: '来源页没订阅广播 → 停在旧值，用户要重启 app 才看得到真状态');

    await SyncRepository(db).setInterconnectEnabled(false);
    await tester.pumpAndSettle();
    expect(interconnectSwitch().value, isFalse, reason: '关回去同样要跟上');
  });

  test('设置页同步状态订阅同一条广播，且换 owner 时摘钩（不留永久监听者）', () {
    final String corpus = readSyncSettingsSchemaSource();

    final String state = methodBody(
      corpus,
      '  _SyncSettingsState(this._settingsContext)',
    );
    expect(
      containsCodeLine(state, 'SyncRepository.interconnectEnabledRevision'),
      isTrue,
      reason: '_SyncSettingsState 构造时不订阅广播，它那份 interconnectEnabled '
          '就永远停在 load() 那一刻的值（load 只跑一次）。',
    );

    final String reload =
        methodBody(corpus, '  Future<void> _reloadInterconnectEnabled()');
    expect(
      containsCodeLine(reload, '_repo.isInterconnectEnabled()'),
      isTrue,
      reason: '收到广播必须回 preferences 重读真值——广播只说「变了」，'
          '若改成信载荷就又多出一份真相。',
    );

    final String syncSettings = methodBody(
        corpus, '_SyncSettingsState _syncSettings(SettingsContext ctx)');
    expect(
      containsCodeLine(syncSettings, '_activeSyncState?.dispose()'),
      isTrue,
      reason: '换 AppModel owner 时不拆旧状态的全局监听 = 每换一次多一个永久监听者。',
    );
  });

  test('互联上传区页脚文案与真实门控一致（不再自称与「启用互联」互不影响）', () {
    final Map<String, dynamic> en = jsonDecode(
      File('lib/i18n/strings.i18n.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final String footer = en['interconnect_upload_section_footer'] as String;
    // 该 section 的 visible 谓词是 interconnectActive(ctx) && !_isHostingInterconnect(ctx)，
    // 通道枚举（enabledSyncChannelBackends）也只在互联启用时才追加互联通道——
    // 「与启用互联互不影响」在两处都不成立。
    expect(
      RegExp('[Ii]ndependent from[^.]*Enable interconnect').hasMatch(footer),
      isFalse,
      reason: '旧文案声称与「启用互联」开关互不影响，但整个 section 都被它门控。',
    );
    expect(
      footer.contains('only apply while Enable interconnect is on'),
      isTrue,
      reason: '页脚必须如实说明这些开关依赖「启用互联」。',
    );

    // 17 个语言文件都得有这个 key（Slang 缺 key 直接编译报错）。
    for (final FileSystemEntity f in Directory('lib/i18n').listSync()) {
      if (f is! File || !f.path.endsWith('.i18n.json')) continue;
      final Map<String, dynamic> map =
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      expect(map.containsKey('interconnect_upload_section_footer'), isTrue,
          reason: '${f.path} 缺 interconnect_upload_section_footer');
    }
  });
}

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2645：互联页没开「上传词典」，点立即同步时「词典 · 传输」那一行却在转圈、
/// 还显示全量同步的阶段进度，用户以为词典在同步、开关没生效。
///
/// 根因：`_AssetTransferMenuRow` 只看全局 `syncInProgress`，任何同步在飞都转圈。
/// 数据层本来就按 `isInterconnectSyncDictionaryEnabled` 跳过了词典阶段——错的是
/// 这一行把别人的进度当成自己的。这里渲染 schema 里**真的那几行**，钉住：
/// 只有本行这类资产、这类通道的手动传输在飞时才显示进度。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  tearDown(() {
    syncInProgress.value = false;
    syncProgress.value = null;
    syncActivity.value = null;
    activeAssetTransfer.value = null;
    debugSyncChannelsOverride = null;
  });

  SettingsCustomItem customItem(SettingsDestination dest, String id) {
    return dest.sections
        .expand((SettingsSection s) => s.items)
        .whereType<SettingsCustomItem>()
        .firstWhere((SettingsCustomItem i) => i.id == id);
  }

  Future<void> pumpRow(WidgetTester tester, SettingsCustomItem item) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) =>
                item.builder(_StubSettingsContext()),
          ),
        ),
      ),
    );
  }

  const SyncProgress sweepProgress = SyncProgress(
    phase: SyncPhase.books,
    itemIndex: 1,
    itemTotal: 3,
  );

  void simulateFullSweep() {
    syncInProgress.value = true;
    syncActivity.value = const SyncActivity(SyncActivityKind.fullSweep);
    syncProgress.value = sweepProgress;
  }

  group('互联页「词典 · 传输」行', () {
    late SettingsCustomItem row;
    setUp(() => row = customItem(
        buildInterconnectDestination(), 'interconnect.dictionary_transfer'));

    testWidgets('全量同步在飞时不转圈、不显示别人的进度', (WidgetTester tester) async {
      simulateFullSweep();
      await pumpRow(tester, row);

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text(t.sync_asset_transfer_hint), findsOneWidget);
      expect(find.text(t.sync_asset_transfer_menu), findsOneWidget,
          reason: '别的同步在飞时菜单照常可见，点了由 busy guard 提示');
    });

    testWidgets('云备份通道的词典传输在飞时也不转圈（通道不同）', (WidgetTester tester) async {
      simulateFullSweep();
      activeAssetTransfer.value = const SyncAssetTransferTarget(
          SyncAssetKind.dictionary, SyncAssetChannelScope.cloud);
      await pumpRow(tester, row);

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('本行自己的传输在飞时转圈并显示进度', (WidgetTester tester) async {
      syncInProgress.value = true;
      syncActivity.value = const SyncActivity(SyncActivityKind.assetTransfer);
      syncProgress.value = const SyncProgress(
          phase: SyncPhase.dictionaries, itemIndex: 1, itemTotal: 2);
      activeAssetTransfer.value = const SyncAssetTransferTarget(
          SyncAssetKind.dictionary, SyncAssetChannelScope.interconnect);
      await pumpRow(tester, row);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text(t.sync_asset_transfer_hint), findsNothing);
    });
  });

  group('云备份页两行', () {
    testWidgets('本地音频传输在飞时「词典」行不转圈', (WidgetTester tester) async {
      final SettingsDestination dest = buildSyncBackupDestination();
      syncInProgress.value = true;
      syncActivity.value = const SyncActivity(SyncActivityKind.assetTransfer);
      activeAssetTransfer.value = const SyncAssetTransferTarget(
          SyncAssetKind.localAudio, SyncAssetChannelScope.cloud);

      await pumpRow(tester, customItem(dest, 'sync.dictionary_transfer'));
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await pumpRow(tester, customItem(dest, 'sync.local_audio_transfer'));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  test('runManualAssetTransfer 在飞时公布自己的目标，结束后清空', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final Directory tmp = Directory.systemTemp.createTempSync('bug2645_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    SyncAssetTransferTarget? seenInFlight;
    debugSyncChannelsOverride = (SyncRepository repo) async {
      seenInFlight = activeAssetTransfer.value;
      return <SyncChannel>[];
    };

    final ManualSyncResult result = await runManualAssetTransfer(
      db: db,
      kind: SyncAssetKind.dictionary,
      direction: SyncAssetDirection.upload,
      scope: SyncAssetChannelScope.interconnect,
      dictionaryResourceRoot: tmp,
      audioDatabaseRoot: tmp,
      tempDir: tmp,
      localAudioEntries: const [],
      onLocalAudioImported: (_) async {},
    );

    expect(result.outcome, ManualSyncOutcome.notConfigured);
    expect(
      seenInFlight,
      const SyncAssetTransferTarget(
          SyncAssetKind.dictionary, SyncAssetChannelScope.interconnect),
    );
    expect(activeAssetTransfer.value, isNull);
  });
}

class _StubSettingsContext implements SettingsContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// 设置主页分块守卫（2026-08-24）。
//
// 主页原先把全部一级分类平铺进一张卡片，四块分层只活在 `_buildDestinations()` 的
// 注释里；现在每个 destination 声明 SettingsDestinationGroup，渲染器据此切成带组
// 标题的多张卡（groupSettingsDestinations）。两条不变式一旦破，症状都不是崩溃而是
// 「主页顺序悄悄变了 / 某分类掉进别的块」，肉眼很难发现：
//
// ① 每个真实一级分类都声明了 group——漏填会静默落进无标题首批（外观那块），
//    新增分类时最容易踩；
// ② 同一块的分类在 schema 里连续——批次顺序按「组首次出现」定，交错声明会把后半段
//    并回前面那批，UI 顺序与 schema 顺序脱节。
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  // 与 settings_schema_cache_test 同款轻量宿主：schema 树本身是纯的（分类构建函数
  // 零参），但 buildSettingsSchema 收 SettingsContext，故仍给它一个真的。
  Future<SettingsContext> makeContext(WidgetTester tester) async {
    final FushiDatabase db =
        FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tempDir =
        Directory.systemTemp.createTempSync('hibiki_dest_group_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefsRepo,
        databaseDirectory: tempDir,
      )
      ..wireDatabaseForTesting(db);

    late SettingsContext sctx;
    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: MaterialApp(
        home: Consumer(
          builder: (BuildContext ctx, WidgetRef ref, Widget? _) {
            sctx = SettingsContext(
              context: ctx,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderFushiSource.instance,
              refresh: () {},
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    ));
    return sctx;
  }

  testWidgets('每个一级分类都声明了主页分块 group', (WidgetTester tester) async {
    final SettingsContext sctx = await makeContext(tester);
    final List<String> missing = buildSettingsSchema(sctx)
        .where((SettingsDestination d) => d.group == null)
        .map((SettingsDestination d) => d.id.name)
        .toList(growable: false);
    expect(
      missing,
      isEmpty,
      reason: '这些一级分类没声明 SettingsDestinationGroup，会掉进主页的无标题首批：$missing',
    );
  });

  testWidgets('同一分块的分类在 schema 里连续（批次顺序 = schema 顺序）',
      (WidgetTester tester) async {
    final SettingsContext sctx = await makeContext(tester);
    final List<SettingsDestinationGroup?> sequence = buildSettingsSchema(sctx)
        .map((SettingsDestination d) => d.group)
        .toList(growable: false);
    final Set<SettingsDestinationGroup?> seen = <SettingsDestinationGroup?>{};
    SettingsDestinationGroup? previous;
    bool first = true;
    for (final SettingsDestinationGroup? group in sequence) {
      if (!first && group == previous) continue;
      first = false;
      expect(
        seen.contains(group),
        isFalse,
        reason: '分块 ${group?.name} 在 schema 里被切成了不相邻的两段：'
            '${sequence.map((SettingsDestinationGroup? g) => g?.name).toList()}',
      );
      seen.add(group);
      previous = group;
    }
  });

  testWidgets('分块批次覆盖全部分类且不重排组内顺序', (WidgetTester tester) async {
    final SettingsContext sctx = await makeContext(tester);
    final List<SettingsDestination> destinations = buildSettingsSchema(sctx);
    final List<SettingsDestinationBatch> batches =
        groupSettingsDestinations(destinations);
    expect(
      batches.expand((SettingsDestinationBatch b) => b.destinations).toList(),
      destinations,
      reason: '分批只应切段，不应增删或重排任何分类',
    );
    // 外观独占一块且不渲染标题；其余各块都必须有标题，否则主页会出现两张无题卡
    // 而用户看不出块界。
    expect(batches.first.title, isNull);
    expect(
      batches.skip(1).map((SettingsDestinationBatch b) => b.title).toList(),
      everyElement(isNotNull),
    );
    expect(batches.length, greaterThan(1), reason: '分块没生效就退化成了一张大卡');
  });

  testWidgets('听书并入阅读：不再是一级分类，两个分区落在阅读里',
      (WidgetTester tester) async {
    final SettingsContext sctx = await makeContext(tester);
    final List<SettingsDestination> destinations = buildSettingsSchema(sctx);
    final SettingsDestination reading = destinations.firstWhere(
      (SettingsDestination d) => d.id == SettingsDestinationId.reading,
    );
    final List<String> ids = reading.sections
        .expand((SettingsSection s) => s.items)
        .map((SettingsItem i) => i.id)
        .toList(growable: false);
    // 有声书 + 悬浮歌词两组的代表项，都必须能在「阅读」里找到。
    expect(ids, contains('listening.audiobook_background_play'));
    expect(ids, contains('listening.floating_lyric'));
    // 反向：不能有第二个 destination 也装着这些项（合并而非复制）。
    final int owners = destinations
        .where((SettingsDestination d) => d.sections
            .expand((SettingsSection s) => s.items)
            .any((SettingsItem i) => i.id == 'listening.floating_lyric'))
        .length;
    expect(owners, 1, reason: '听书分区只应挂在「阅读」一处');
  });

  testWidgets('搜「听书」仍落到阅读分类（合并后它只活在 summary 里）',
      (WidgetTester tester) async {
    final SettingsContext sctx = await makeContext(tester);
    final List<SettingsSearchEntry> hits = filterSettingsEntries(
      flattenVisibleSettings(buildSettingsSchema(sctx), sctx),
      // 默认 locale 是 en，对应 settings_destination_listening 的英文值。
      'listening',
    );
    expect(hits, isNotEmpty, reason: '听书并入阅读后，这个词必须仍能搜到');
    expect(
      hits.map((SettingsSearchEntry e) => e.destination.id).toSet(),
      contains(SettingsDestinationId.reading),
    );
    // 命中面确实来自分类 summary，而不是碰巧撞上了某条 item 标题。
    final SettingsSearchEntry viaSummary = hits.firstWhere(
      (SettingsSearchEntry e) =>
          e.destination.id == SettingsDestinationId.reading,
    );
    expect(viaSummary.title.toLowerCase(), isNot(contains('listening')));
    expect(viaSummary.destination.summary?.toLowerCase(),
        contains('listening'));
  });
}

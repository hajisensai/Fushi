// 把已启动的真 app 配置成经 [FakeAnkiConnect] 制卡——走的是设置页「获取」按钮
// 那条生产路径，不手拼 AnkiSettings。
//
// 生产入口对照：
//   * 主机 / 端口：`AnkiViewModel.updateAnkiConnectHost` / `updateAnkiConnectPort`
//     （fushi/lib/src/anki/anki_view_model.dart），即设置页两个文本框失焦后调的东西；
//   * 「获取」：设置页 `_buildFetchTile` → `_refreshAndCheckMining` →
//     `vm.fetchConfiguration()`（anki_settings_page.dart），仓库层是
//     `AnkiConnectRepository.fetchConfiguration()`（version → deckNames → modelNames →
//     每个 model 一次 modelFieldNames → `updateSettings` 选卡组 / 笔记类型 / 字段映射）。
//     `selectNoteTypeAfterFetch` 按 `LapisPreset.matches` 选中假服务的 Lapis 模型，
//     `fieldMappingsAfterFetch` 套上 `LapisNoteType.defaultFieldMappings`，于是
//     `AnkiSettings.isConfigured` 与 `canMineCards` 都为真，`mineEntry` 不再回
//     `MineOutcome.notConfigured()`（= toast「Anki 尚未配置。请打开 Anki 设置并点击获取」）。
//
// Windows 桌面端 `PlatformServices.createAnkiRepository` 就是 `AnkiConnectRepository.new`
// （platform_services.dart），不用碰 `useAnkiConnectOnMobile`。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_anki/fushi_anki.dart';

import '../helpers/library_fixture.dart';
import 'fake_ankiconnect.dart';

/// 把当前跑着的 app 指到 [server] 并执行一次「获取」，断言配置门已过。
///
/// 前置：app 已经 `launchFushiTestApp()` + `waitForHome` 起来（本函数内部用
/// [readyAppModel] 等 `AppModel.isInitialised`）。
Future<void> configureFakeAnkiConnect(
  WidgetTester tester,
  FakeAnkiConnect server,
) async {
  await readyAppModel(tester);
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
  final AnkiViewModel vm = container.read(ankiViewModelProvider.notifier);

  // 设置页两个文本框的 setter：host 会经 normalizeAnkiConnectHostInput 规范化，
  // port 经范围校验；两者都 `updateSettings` 落 SharedPreferences。
  await vm.updateAnkiConnectHost(server.uri.host);
  await vm.updateAnkiConnectPort('${server.port}');

  // 「获取」。
  await vm.fetchConfiguration();
  await tester.pump();

  final AnkiUiState ui = container.read(ankiViewModelProvider);
  expect(
    ui.errorMessage,
    isNull,
    reason: '「获取」不该失败（假 AnkiConnect ${server.uri}）：${ui.errorMessage}',
  );
  expect(
    server.requestsFor('version'),
    isNotEmpty,
    reason: '「获取」应真的 POST 到假服务（checkConnection → version）',
  );
  expect(
    server.requestsFor('modelFieldNames'),
    isNotEmpty,
    reason: '「获取」应拉取笔记类型字段',
  );

  // 制卡链路读的是仓库 loadSettings（SharedPreferences），不是 VM 内存态——
  // 两边都断一遍。
  final BaseAnkiRepository repo = container.read(ankiRepositoryProvider);
  final AnkiSettings settings = await repo.loadSettings();
  expect(settings.ankiConnectHost, server.uri.host);
  expect(settings.ankiConnectPort, server.port);
  expect(
    settings.isConfigured,
    isTrue,
    reason: 'fetchConfiguration 应选中卡组与笔记类型',
  );
  expect(settings.selectedDeckName, server.deckName);
  expect(settings.selectedNoteTypeName, server.modelName);
  expect(
    settings.canMineCards,
    isTrue,
    reason: 'Lapis 首字段 Expression 应已映射到 {expression}',
  );
  expect(ui.settings.isConfigured, isTrue);
}

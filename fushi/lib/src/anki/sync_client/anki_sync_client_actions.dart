/// 「Anki 同步（无需安装 Anki）」设置节背后的动作：切后端、登录、退出。
///
/// 设置节（[AnkiSyncClientSection]）与控制通道（`fushi_cli anki sync-*`）共用：
/// 两边只差「凭据 / 确认从哪来」（输入框 + 确认框 vs 参数 + stdin）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';

import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';

/// 本机内置的同步会话；本机没有 `fushi-anki-sync` 时为 null（整节不渲染）。
AnkiSyncSession? ankiSyncClientSessionOf(WidgetRef ref) =>
    ref.read(platformServicesProvider).ankiSyncSession;

/// 切后端的唯一落地路径：持久化 → 运行时选择 → 重建仓库 provider（与移动端
/// 「改用 AnkiConnect」同一顺序，三步缺一步就是存储与运行时不一致）。
Future<void> setAnkiSyncClientEnabled(WidgetRef ref, bool value) async {
  final AnkiViewModel vm = ref.read(ankiViewModelProvider.notifier);
  final PlatformServices platform = ref.read(platformServicesProvider);
  await vm.updateUseAnkiSyncClient(value);
  platform.setUseAnkiSyncClient(value);
  ref.invalidate(ankiRepositoryProvider);
}

/// 登录同步服务器（[endpoint] 为 null = AnkiWeb）。成功后顺手刷新牌组 / 笔记类型：
/// 库在本地了，设置页的选择器立刻可用。换账号而本机还有未同步卡时抛
/// [AnkiSyncHasUnsyncedNotes]（由调用方提示）。
Future<void> signInAnkiSyncClient(
  WidgetRef ref,
  AnkiSyncSession session, {
  required String? endpoint,
  required String username,
  required String password,
}) async {
  await session.signIn(
    endpoint: endpoint,
    username: username,
    password: password,
  );
  unawaited(ref.read(ankiViewModelProvider.notifier).fetchConfiguration());
}

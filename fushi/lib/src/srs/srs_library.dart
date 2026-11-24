/// 复习页 / 制卡用哪份复习库（拍板台 design-srs-shared-library 方案 a，组合阶段 4）。
///
/// * [SrsLibraries.activeUid]：激活配置（不叠作品会话）解析出的库——默认组合与没拆 `srs.library`
///   的组合都是共享库，拆成独立库的组合是它自己那份。制卡（非作品会话）、制卡落点的选项读它。
/// * [SrsLibraries.viewedUid]：复习页此刻看的库 = `srsStoreProvider` 打开的那份。默认跟着
///   [SrsLibraries.activeUid]；存在独立库时复习页顶部可切换（[srsLibraryChoiceProvider]），切到的
///   库消失（拆分撤销 / 组合删掉）时自动回到 [SrsLibraries.activeUid]。
///
/// 解析规则只在引擎 `ComboSrsLibraries` 写一次（`srs_library_resolver.dart` 读表喂进去）。
library;

import 'dart:async';

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdateQuery;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/srs_library_resolver.dart';
import 'package:fushi/src/profile/profile_view_model.dart';

/// 一份可在复习页切到的复习库。
class SrsLibraryEntry {
  const SrsLibraryEntry({
    required this.uid,
    required this.shared,
    this.ownerName,
  });

  /// 集合身份（`profiles.uid`）。
  final String uid;

  /// 共享库（界面写「共享复习库」）；否则是 [ownerName] 那个组合拆出的独立库。
  final bool shared;

  /// 拆出这份独立库的组合名；共享库为 null。
  final String? ownerName;

  @override
  bool operator ==(Object other) =>
      other is SrsLibraryEntry &&
      other.uid == uid &&
      other.shared == shared &&
      other.ownerName == ownerName;

  @override
  int get hashCode => Object.hash(uid, shared, ownerName);
}

/// 复习库解析结果（见库文档）。
class SrsLibraries {
  const SrsLibraries({
    required this.activeUid,
    required this.viewedUid,
    required this.entries,
  });

  /// 激活配置解析出的库；库里一个配置都没有时空串。
  final String activeUid;

  /// 复习页此刻看的库。
  final String viewedUid;

  /// 可切换的库（共享库在前）；少于两份时复习页不出库切换。
  final List<SrsLibraryEntry> entries;

  /// 复习页要不要出库切换。
  bool get switchable => entries.length > 1;

  @override
  bool operator ==(Object other) =>
      other is SrsLibraries &&
      other.activeUid == activeUid &&
      other.viewedUid == viewedUid &&
      _sameEntries(other.entries, entries);

  @override
  int get hashCode => Object.hash(activeUid, viewedUid, Object.hashAll(entries));

  static bool _sameEntries(List<SrsLibraryEntry> a, List<SrsLibraryEntry> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 由 [ComboSrsLibraries] 与配置名算出 [SrsLibraries]（纯函数，测试直接调）。
SrsLibraries srsLibrariesOf({
  required ComboSrsLibraries libraries,
  required int activeProfileId,
  required Map<int, String> profileNames,
  String? choice,
}) {
  final String active =
      libraries.resolve(baseProfileId: activeProfileId)?.uid ?? '';
  final List<SrsLibraryEntry> entries = <SrsLibraryEntry>[
    for (final ComboSrsLibrary l in libraries.libraries)
      SrsLibraryEntry(
        uid: l.uid,
        shared: l.shared,
        ownerName: l.shared ? null : profileNames[l.ownerProfileId],
      ),
  ];
  final bool choiceValid =
      choice != null && entries.any((SrsLibraryEntry e) => e.uid == choice);
  return SrsLibraries(
    activeUid: active,
    viewedUid: choiceValid ? choice : active,
    entries: entries,
  );
}

/// 复习页上用户切到的库（uid）；null = 跟着激活配置。只在本次运行内记着：下次打开 App 回到
/// 默认（设计 §4.1「默认显示共享库」）。
final StateProvider<String?> srsLibraryChoiceProvider = StateProvider<String?>(
  (Ref ref) => null,
);

/// 复习库解析结果。`profiles` / `profile_settings` 有写入（建 / 删组合、拆 `srs.library`、迁移定
/// 下共享库）时现算一遍，**结果不变就不通知**——下游用 `selectAsync` 只在 uid 真变了时重建。
final AsyncNotifierProvider<SrsLibrariesNotifier, SrsLibraries>
srsLibrariesProvider = AsyncNotifierProvider<SrsLibrariesNotifier, SrsLibraries>(
  SrsLibrariesNotifier.new,
);

class SrsLibrariesNotifier extends AsyncNotifier<SrsLibraries> {
  @override
  Future<SrsLibraries> build() async {
    // 配置装载完再读激活 id（装载期间是初值 -1，见 `ProfileViewModel.loaded`）。
    await ref.watch(profileViewModelProvider.notifier).loaded;
    final int activeId = ref.watch(
      profileViewModelProvider.select((ProfileUiState s) => s.activeProfileId),
    );
    final String? choice = ref.watch(srsLibraryChoiceProvider);
    final FushiDatabase db = ref.read(appProvider).database;
    final StreamSubscription<void> changes = db
        .tableUpdates(
          TableUpdateQuery.onAllTables(<ResultSetImplementation<dynamic, dynamic>>[
            db.profiles,
            db.profileSettings,
          ]),
        )
        .listen((_) => unawaited(_refresh(db, activeId, choice)));
    ref.onDispose(changes.cancel);
    return _compute(db, activeId, choice);
  }

  Future<void> _refresh(FushiDatabase db, int activeId, String? choice) async {
    final SrsLibraries next;
    try {
      next = await _compute(db, activeId, choice);
    } on Object {
      // 读表失败（库正在关）：保持现状，下一次写入再算。
      return;
    }
    if (state.valueOrNull == next) return;
    state = AsyncData<SrsLibraries>(next);
  }

  static Future<SrsLibraries> _compute(
    FushiDatabase db,
    int activeProfileId,
    String? choice,
  ) async {
    final List<ProfileRow> profiles = await db.getAllProfiles();
    // 激活 id 已不在库里（刚删掉、视图模型还没跟上）：与 `resolveActiveProfileId` 同口径取一份。
    final int active =
        profiles.any((ProfileRow p) => p.id == activeProfileId)
        ? activeProfileId
        : await db.resolveActiveProfileId();
    return srsLibrariesOf(
      libraries: await loadComboSrsLibraries(db),
      activeProfileId: active,
      profileNames: <int, String>{
        for (final ProfileRow p in profiles) p.id: p.name,
      },
      choice: choice,
    );
  }
}

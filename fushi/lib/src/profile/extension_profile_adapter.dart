import 'dart:async';

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdateQuery;
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_settings_view.dart';
import 'package:fushi/src/sync/extension_profile_api.dart';

/// 反馈 biLEesNqWb：[ExtensionProfileApi] 的 app 实现。
///
/// 解析一次扩展请求按哪份配置处理：扩展所选（请求头）> 「浏览器」媒体类型绑定 > 跟随 App
/// 的激活配置。解析结果不是激活配置时，用 [ProfileRepository.loadSettingsView] 建该配置的
/// 只读设置视图，再由 [_servicesForView]（`AppModel.extensionRequestServicesForView`）
/// 建按视图读设置的服务组。全程不切换 App 的激活配置、不写任何表。
///
/// 视图按配置 id 缓存：每次 hover 查词都现读整份快照太重。`profile_settings` /
/// `preferences`（含 Anki 设置）/ `dictionary_metadata` / `profiles` 任一表有写入即整份
/// 作废（drift 表级变更流，与写入方是谁无关），下一次请求重建。
class AppExtensionProfileApi implements ExtensionProfileApi {
  AppExtensionProfileApi({
    required ProfileRepository Function() repository,
    required FushiDatabase Function() database,
    required ExtensionRequestServices Function(ProfileSettingsView view)
    servicesForView,
  }) : _repository = repository,
       _database = database,
       _servicesForView = servicesForView;

  final ProfileRepository Function() _repository;
  final FushiDatabase Function() _database;
  final ExtensionRequestServices Function(ProfileSettingsView view)
  _servicesForView;

  final Map<int, Future<ExtensionRequestServices?>> _cache =
      <int, Future<ExtensionRequestServices?>>{};

  /// 每次作废 +1：建到一半的视图若跨过了一次作废，就不进缓存（它可能读到了旧数据）。
  int _generation = 0;
  FushiDatabase? _watchedDatabase;
  StreamSubscription<void>? _invalidation;

  @override
  Future<ExtensionProfileList> listProfiles() async {
    final ProfileRepository repo = _repository();
    final List<ProfileRow> profiles = await repo.getAllProfiles();
    return ExtensionProfileList(
      profiles: <ExtensionProfileSummary>[
        for (final ProfileRow p in profiles)
          ExtensionProfileSummary(id: p.id, name: p.name),
      ],
      activeProfileId: await repo.getActiveProfileId(),
    );
  }

  @override
  Future<ExtensionProfileScope> resolveScope(int? requestedProfileId) async {
    final ProfileRepository repo = _repository();
    final int activeId = await repo.getActiveProfileId();
    int? missing;
    int? target;
    if (requestedProfileId != null) {
      if (await repo.getProfileById(requestedProfileId) != null) {
        target = requestedProfileId;
      } else {
        missing = requestedProfileId;
      }
    }
    target ??= await repo.resolveBoundProfileId(
      bookUid: null,
      mediaType: ProfileMediaKind.browser,
    );
    if (target == null || target == activeId) {
      // 激活配置：直接用 App 当前生效的设置（它的快照只在切走时刷新，比 live 旧）。
      return ExtensionProfileScope(
        effectiveProfileId: activeId,
        missingRequestedProfileId: missing,
      );
    }
    final ExtensionRequestServices? services = await _servicesFor(target);
    if (services == null) {
      // 解析与建视图之间配置被删了：与「所选配置不存在」同一回退。
      return ExtensionProfileScope(
        effectiveProfileId: activeId,
        missingRequestedProfileId: missing ?? requestedProfileId,
      );
    }
    return ExtensionProfileScope(
      effectiveProfileId: target,
      missingRequestedProfileId: missing,
      services: services,
    );
  }

  Future<ExtensionRequestServices?> _servicesFor(int profileId) {
    _watchInvalidation();
    final Future<ExtensionRequestServices?>? cached = _cache[profileId];
    if (cached != null) return cached;
    final int generation = _generation;
    final Future<ExtensionRequestServices?> building = _build(profileId);
    _cache[profileId] = building;
    // 建的过程中作废过（或建失败）就别把结果留在缓存里。
    building.then(
      (ExtensionRequestServices? services) {
        if (services == null || generation != _generation) {
          if (identical(_cache[profileId], building)) _cache.remove(profileId);
        }
      },
      onError: (Object _) {
        if (identical(_cache[profileId], building)) _cache.remove(profileId);
      },
    );
    return building;
  }

  Future<ExtensionRequestServices?> _build(int profileId) async {
    final ProfileSettingsView? view = await _repository().loadSettingsView(
      profileId,
    );
    return view == null ? null : _servicesForView(view);
  }

  /// 订阅（或在库被替换后重新订阅）会影响视图的四张表的变更流。
  void _watchInvalidation() {
    final FushiDatabase db = _database();
    if (identical(db, _watchedDatabase)) return;
    unawaited(_invalidation?.cancel());
    _watchedDatabase = db;
    _invalidate();
    _invalidation = db
        .tableUpdates(
          TableUpdateQuery.onAllTables(
            <ResultSetImplementation<dynamic, dynamic>>[
              db.profileSettings,
              db.preferences,
              db.dictionaryMetadata,
              db.profiles,
            ],
          ),
        )
        .listen((_) => _invalidate());
  }

  void _invalidate() {
    _generation++;
    _cache.clear();
  }

  /// 停止监听（测试收尾用；app 里与进程同寿）。
  Future<void> dispose() async {
    await _invalidation?.cancel();
    _invalidation = null;
    _watchedDatabase = null;
    _cache.clear();
  }
}

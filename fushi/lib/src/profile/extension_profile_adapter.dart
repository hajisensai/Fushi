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
/// `dictionary_metadata` / `profiles` 任一表有写入即整份作废（drift 表级变更流，与写入方是谁
/// 无关），下一次请求重建。`preferences` 表写得很频繁（App 激活配置的每次设置改动、有声书进度等
/// 状态键、每次写入都跳的 `prefs_version`），而视图只从它读设备本地键
/// （[ProfileRepository.settingsViewReadsLivePref]，含 Anki 设置）：它有写入时只把缓存标脏，下一次
/// 请求读一遍这些键，和建视图时那份比，真变了才作废。
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
  StreamSubscription<void>? _prefsInvalidation;
  StreamSubscription<void>? _scopeInvalidation;

  /// 缓存的解析依据（见 [_scopeBasisNow]）；null = 要重读。
  Future<_ScopeBasis>? _scopeBasis;

  /// `preferences` 表在上次核对之后有过写入（核对见 [_recheckLivePrefs]）。
  bool _prefsDirty = true;

  /// 正在进行的核对（并发的请求等同一次）。
  Future<void>? _prefsRecheck;

  /// 上次核对时视图会读的 live 偏好（[_livePrefsOf]）；null = 还没核对过。
  Map<String, String>? _livePrefsBasis;

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
    final _ScopeBasis basis = await _scopeBasisNow();
    final int activeId = basis.activeProfileId;
    int? missing;
    int? target;
    if (requestedProfileId != null) {
      if (basis.profileIds.contains(requestedProfileId)) {
        target = requestedProfileId;
      } else {
        missing = requestedProfileId;
      }
    }
    target ??= basis.browserBoundProfileId;
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

  /// 解析依据（激活配置 / 「浏览器」绑定 / 现存配置）：缓存着，相关表有写入时作废
  /// （[_watchInvalidation]）。每个按配置处理的 POST（hover 查词每次都是）都要解析一次，
  /// 稳态下不该每次都查库。
  Future<_ScopeBasis> _scopeBasisNow() {
    _watchInvalidation();
    final Future<_ScopeBasis>? cached = _scopeBasis;
    if (cached != null) return cached;
    final Future<_ScopeBasis> loading = _readScopeBasis();
    _scopeBasis = loading;
    // 读失败不留在缓存里：下一次请求重读（错误照常交给本次请求）。
    loading.then(
      (_ScopeBasis _) {},
      onError: (Object _) {
        if (identical(_scopeBasis, loading)) _scopeBasis = null;
      },
    );
    return loading;
  }

  Future<_ScopeBasis> _readScopeBasis() async {
    final ProfileRepository repo = _repository();
    final int activeId = await repo.getActiveProfileId();
    final int? bound = await repo.resolveBoundProfileId(
      bookUid: null,
      mediaType: ProfileMediaKind.browser,
    );
    final List<ProfileRow> profiles = await repo.getAllProfiles();
    return _ScopeBasis(
      activeProfileId: activeId,
      browserBoundProfileId: bound,
      profileIds: <int>{for (final ProfileRow p in profiles) p.id},
    );
  }

  Future<ExtensionRequestServices?> _servicesFor(int profileId) async {
    _watchInvalidation();
    while (_prefsDirty || _prefsRecheck != null) {
      await (_prefsRecheck ??= _recheckLivePrefs());
    }
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

  /// 核对 `preferences` 的写入是否碰到视图会读的键：读一遍那些键，和上次核对的那份比，变了就作废
  /// 缓存。核对期间又有写入会再次标脏，下一轮接着核对。
  Future<void> _recheckLivePrefs() async {
    try {
      _prefsDirty = false;
      final Map<String, String> now = _livePrefsOf(
        await _database().getAllPrefs(),
      );
      final Map<String, String>? basis = _livePrefsBasis;
      if (basis != null && !_sameEntries(basis, now)) _invalidate();
      _livePrefsBasis = now;
    } on Object {
      // 读不到就无从判断：按「变了」处理（作废缓存、下次再核对），错误照常交给本次请求。
      _prefsDirty = true;
      _invalidate();
      rethrow;
    } finally {
      _prefsRecheck = null;
    }
  }

  /// 视图从 live `preferences` 读的键与值（不含 `prefs_version`：它只是每次写入都跳的变更计数，
  /// 不是视图用的值）。
  static Map<String, String> _livePrefsOf(Map<String, String> all) =>
      <String, String>{
        for (final MapEntry<String, String> e in all.entries)
          if (e.key != FushiDatabase.prefsVersionKey &&
              ProfileRepository.settingsViewReadsLivePref(e.key))
            e.key: e.value,
      };

  static bool _sameEntries(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, String> e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
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
    unawaited(_prefsInvalidation?.cancel());
    unawaited(_scopeInvalidation?.cancel());
    _watchedDatabase = db;
    _invalidate();
    _scopeBasis = null;
    _livePrefsBasis = null;
    _prefsDirty = true;
    _invalidation = db
        .tableUpdates(
          TableUpdateQuery.onAllTables(
            <ResultSetImplementation<dynamic, dynamic>>[
              db.profileSettings,
              db.dictionaryMetadata,
              db.profiles,
            ],
          ),
        )
        .listen((_) => _invalidate());
    // 激活配置 id 存在 preferences（`active_profile_id`）里：任何偏好写入都让解析依据重读
    // （只是三条小查询）；视图缓存则只标脏、核对后才作废。
    _prefsInvalidation = db
        .tableUpdates(TableUpdateQuery.onTable(db.preferences))
        .listen((_) {
          _prefsDirty = true;
          _scopeBasis = null;
        });
    _scopeInvalidation = db
        .tableUpdates(
          TableUpdateQuery.onAllTables(
            <ResultSetImplementation<dynamic, dynamic>>[
              db.profiles,
              db.mediaTypeProfiles,
            ],
          ),
        )
        .listen((_) => _scopeBasis = null);
  }

  void _invalidate() {
    _generation++;
    _cache.clear();
  }

  /// 停止监听（测试收尾用；app 里与进程同寿）。
  Future<void> dispose() async {
    await _invalidation?.cancel();
    _invalidation = null;
    await _prefsInvalidation?.cancel();
    _prefsInvalidation = null;
    await _scopeInvalidation?.cancel();
    _scopeInvalidation = null;
    _scopeBasis = null;
    _watchedDatabase = null;
    _cache.clear();
  }
}

/// 解析一次扩展请求按哪份配置处理所需的库内状态（见 [AppExtensionProfileApi.resolveScope]）。
class _ScopeBasis {
  const _ScopeBasis({
    required this.activeProfileId,
    required this.browserBoundProfileId,
    required this.profileIds,
  });

  /// App 的激活配置。
  final int activeProfileId;

  /// 「浏览器」媒体类型绑定的配置；null = 没绑。
  final int? browserBoundProfileId;

  /// 现存配置的 id（判断扩展所选配置是否还在）。
  final Set<int> profileIds;
}

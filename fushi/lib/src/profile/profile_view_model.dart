import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/profile/profile_deletion_cascade.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/work_profile_scope.dart';
import 'package:fushi/src/srs/srs_profile_cleanup.dart';

/// Serializes Profile application with temporary draft persistence.
///
/// A scope check on its own is racy: Profile application may start after Save
/// checks the scope, or Save may run against an intermediate AppModel while a
/// Profile is being applied. Both operations therefore use this same lock.
class ProfileDraftCoordinator {
  Object _draftScope = Object();
  Future<void> _tail = Future<void>.value();

  Object get draftScope => _draftScope;

  /// 正在切换去的目标配置（乐观标签）。它挂在这个跨重建存活的协调器上而不是视图
  /// 模型里：切换的应用回调会失效 `ankiRepositoryProvider`，整个视图模型随之重建，
  /// 新实例从零开始；目标放在这里，新旧实例都读得到、也都收得到清除通知。
  final ValueNotifier<ProfileRow?> pendingSwitchTarget =
      ValueNotifier<ProfileRow?>(null);

  void invalidateDrafts() {
    _draftScope = Object();
  }

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final Future<void> previous = _tail;
    final Completer<void> release = Completer<void>();
    _tail = release.future;

    return (() async {
      await previous;
      try {
        return await action();
      } finally {
        release.complete();
      }
    })();
  }

  Future<T> runProfileChange<T>(Future<T> Function() action) {
    return _runProfileMutation((_ProfileDraftMutation mutation) async {
      mutation.invalidateDrafts();
      return action();
    });
  }

  Future<T> _runProfileMutation<T>(
    Future<T> Function(_ProfileDraftMutation mutation) action,
  ) {
    return _exclusive(() async {
      final _ProfileDraftMutation mutation = _ProfileDraftMutation(this);
      try {
        return await action(mutation);
      } finally {
        mutation.finish();
      }
    });
  }

  Future<bool> saveDraftIfCurrent(
    Object expectedScope,
    Future<void> Function() save,
  ) {
    return _exclusive(() async {
      if (!identical(expectedScope, _draftScope)) return false;
      await save();
      return true;
    });
  }
}

class _ProfileDraftMutation {
  _ProfileDraftMutation(this._coordinator);

  final ProfileDraftCoordinator _coordinator;
  bool _invalidatesDrafts = false;

  void invalidateDrafts() {
    if (_invalidatesDrafts) return;
    _invalidatesDrafts = true;
    _coordinator.invalidateDrafts();
  }

  void finish() {
    if (!_invalidatesDrafts) return;
    // A dialog opened while settings were being applied observed an
    // intermediate AppModel and must not survive the completed change.
    _coordinator.invalidateDrafts();
  }
}

class ProfileUiState {
  const ProfileUiState({
    this.profiles = const [],
    this.activeProfileId = -1,
    this.mediaTypeBindings = const {},
    this.languageBindings = const {},
    this.isLoading = false,
    this.pendingProfile,
  });
  final List<ProfileRow> profiles;
  final int activeProfileId;
  final Map<String, int> mediaTypeBindings;

  /// 语言绑定：key = 归一化语言标签（`ja` / `zh-Hant`），value = profileId。
  /// 与 [mediaTypeBindings] 不同，它是**开放值域**——没有固定枚举可以铺死，UI 只
  /// 能列出已有绑定 + 一个添加入口。
  final Map<String, int> languageBindings;
  final bool isLoading;

  /// 切换已发起、尚未结束时的目标配置；展示用，不代表已落库的激活配置。
  final ProfileRow? pendingProfile;

  ProfileRow? get activeProfile {
    for (final p in profiles) {
      if (p.id == activeProfileId) return p;
    }
    return profiles.isNotEmpty ? profiles.first : null;
  }

  /// 悬浮球「切换配置」胶囊等要展示的配置：切换中是目标配置（切换要做快照、应用、
  /// 重载词典，是秒级的，期间不能还显示旧配置名），否则是激活配置；装载中为 null。
  ProfileRow? get displayProfile =>
      pendingProfile ?? (isLoading ? null : activeProfile);

  ProfileUiState withPendingProfile(ProfileRow? pending) => ProfileUiState(
    profiles: profiles,
    activeProfileId: activeProfileId,
    mediaTypeBindings: mediaTypeBindings,
    languageBindings: languageBindings,
    isLoading: isLoading,
    pendingProfile: pending,
  );

  ProfileUiState copyWith({
    List<ProfileRow>? profiles,
    int? activeProfileId,
    Map<String, int>? mediaTypeBindings,
    Map<String, int>? languageBindings,
    bool? isLoading,
  }) => ProfileUiState(
    profiles: profiles ?? this.profiles,
    activeProfileId: activeProfileId ?? this.activeProfileId,
    mediaTypeBindings: mediaTypeBindings ?? this.mediaTypeBindings,
    languageBindings: languageBindings ?? this.languageBindings,
    isLoading: isLoading ?? this.isLoading,
    pendingProfile: pendingProfile,
  );
}

class ProfileViewModel extends StateNotifier<ProfileUiState> {
  ProfileViewModel(
    this._repo,
    this._onProfileApplied,
    this._profileDraftCoordinator, {
    ProfileDeletionCascade? deletionCascade,
    Future<void> Function()? onWorkScopeSettled,
  }) : _deletionCascade = deletionCascade,
       _onWorkScopeSettled = onWorkScopeSettled ?? _noWorkScopeReload,
       super(
         ProfileUiState(
           pendingProfile: _profileDraftCoordinator.pendingSwitchTarget.value,
         ),
       ) {
    _profileDraftCoordinator.pendingSwitchTarget.addListener(
      _onPendingSwitchTargetChanged,
    );
    unawaited(_initialLoad());
    // BUG-3148：别处（互联下载 / 对端上传入站）写进 profiles 表的新配置，列表要跟着
    // 刷新，不必等重启。只重读列表本身——激活 id 与绑定的切换都经本类，不受影响。
    _profilesChanged = _repo.watchProfilesChanged().listen((_) {
      unawaited(_refreshProfileList());
    });
  }

  StreamSubscription<void>? _profilesChanged;

  void _onPendingSwitchTargetChanged() {
    if (!mounted) return;
    state = state.withPendingProfile(
      _profileDraftCoordinator.pendingSwitchTarget.value,
    );
  }

  Future<void> _refreshProfileList() async {
    final List<ProfileRow> profiles = await _repo.getAllProfiles();
    if (!mounted) return;
    state = state.copyWith(profiles: profiles);
  }

  @override
  void dispose() {
    _profilesChanged?.cancel();
    _profileDraftCoordinator.pendingSwitchTarget.removeListener(
      _onPendingSwitchTargetChanged,
    );
    _repo.snapshotCurrentSettings(state.activeProfileId).catchError((Object e) {
      debugPrint('[profile] snapshot on dispose failed: $e');
    });
    super.dispose();
  }

  final ProfileRepository _repo;
  final Future<void> Function() _onProfileApplied;
  final ProfileDraftCoordinator _profileDraftCoordinator;

  /// 作品级配置会话变化后，等 App 按新会话重读完内存缓存（`AppModel.workProfileScopeSettled`）。
  final Future<void> Function() _onWorkScopeSettled;

  static Future<void> _noWorkScopeReload() async {}

  /// 删 Profile 时连带清理的、主库外键级联管不到的数据（复习数据在 srs.db）；null = 不清（测试）。
  final ProfileDeletionCascade? _deletionCascade;

  Future<T> _whileInvalidatingProfileDrafts<T>(Future<T> Function() action) =>
      _profileDraftCoordinator.runProfileChange(action);

  Future<void> _load() async {
    state = state.copyWith(isLoading: true);
    await _repo.ensureDefaultProfile();
    final profiles = await _repo.getAllProfiles();
    final activeId = await _repo.getActiveProfileId();
    final bindings = await _repo.getAllMediaTypeBindings();
    final languageBindings = await _repo.getAllLanguageBindings();
    state = ProfileUiState(
      profiles: profiles,
      activeProfileId: activeId,
      mediaTypeBindings: bindings,
      languageBindings: languageBindings,
      pendingProfile: _profileDraftCoordinator.pendingSwitchTarget.value,
    );
  }

  Future<void> reload() => _load();

  /// 首次装载做完（成败都算）：此后 [ProfileUiState.activeProfileId] 是真实的激活配置，不再是初值 -1。
  ///
  /// 按激活配置打开东西的 provider（`srsStoreProvider`）先等它再读 id：否则装载期间读到 -1、自己解析一次打开，
  /// 装载完成 id 变成真实值时又整个重建一遍。
  Future<void> get loaded => _loaded.future;
  final Completer<void> _loaded = Completer<void>();

  /// 构造时的首次装载：失败照旧作为未处理错误报出（不吞），只保证 [loaded] 一定完成。
  Future<void> _initialLoad() async {
    try {
      await _load();
    } finally {
      _loaded.complete();
    }
    await _restoreLegacyBindingFallback();
  }

  /// 反馈 kEFPY4cuKZ：进入一部作品（阅读器 / 视频 / 漫画开页、gal hook 会话开始）。
  ///
  /// 解析绑定（book 级 > 语言级 > 媒体类型级，见 [ProfileRepository.resolveBoundProfileId]），
  /// 命中且不是激活配置时，把那份配置作为**会话作用域的覆盖层**装进 [WorkProfileScope]：
  /// 阅读样式与字体、有声书悬浮字幕样式、主题、视频字幕样式、Anki 牌组 / 复习制卡目标、查词
  /// 词典按它生效（清单见 [WorkProfileSession]），App 的激活配置与全局偏好一概不动。
  /// 没命中（或命中的就是激活配置）时撤掉 [owner] 之前的那层。离开作品调
  /// [leaveWorkSession]；没有页面生命周期的会话传 [endWhen]（每次 `listenable` 通知时问
  /// `ended`，为 true 即离开）。
  ///
  /// [languageTag]：该条目的**内容语言**原始串，由 repository 归一；拿不到就不传——绝不要
  /// 拿全局默认内容语言来填（理由见 [ProfileRepository.resolveProfileId] 的文档）。
  ///
  /// 非致命：失败只记日志（并按「无绑定」撤层），绝不打断调用方的加载链。返回时按新会话
  /// 重读的阅读器 / 偏好缓存已就绪（[_onWorkScopeSettled]）。
  Future<void> enterWorkSession({
    required Object owner,
    String? bookUid,
    String? languageTag,
    required ProfileMediaKind mediaType,
    ({Listenable listenable, bool Function() ended})? endWhen,
  }) async {
    final WorkProfileScope scope = WorkProfileScope.instance;
    final bool installed = await scope.enterProfile(
      owner: owner,
      repository: _repo,
      resolveProfileId: () => _repo.resolveBoundProfileId(
        bookUid: bookUid,
        languageTag: languageTag,
        mediaType: mediaType,
      ),
    );
    if (!installed) return;
    if (endWhen != null) {
      scope.leaveWhen(owner, endWhen.listenable, endWhen.ended);
    }
    await _onWorkScopeSettled();
  }

  /// 离开 [owner] 进入的作品：撤掉它的作品级配置覆盖层（全局配置本来就没动过）。
  void leaveWorkSession(Object owner) => WorkProfileScope.instance.leave(owner);

  /// 旧版「绑定直接切换激活配置」留下的回退点：升级前停在某部作品的绑定配置上的用户，
  /// 激活配置还是那部作品的配置。启动时一次性回到他们自己选的那份，并清掉回退点——此后
  /// 作品级配置只是会话覆盖层，不再产生回退点。
  Future<void> _restoreLegacyBindingFallback() async {
    final int? fallbackId = await _repo.getFallbackProfileId();
    if (fallbackId == null) return;
    await _profileDraftCoordinator._runProfileMutation((
      _ProfileDraftMutation mutation,
    ) async {
      final int? current = await _repo.getFallbackProfileId();
      if (current == null) return;
      await _repo.setFallbackProfileId(null);
      final List<ProfileRow> profiles = await _repo.getAllProfiles();
      final bool exists = profiles.any((ProfileRow p) => p.id == current);
      if (exists && current != await _repo.getActiveProfileId()) {
        await _switchLocked(mutation, current);
      }
    });
  }

  /// 用户手动切换：这是新的「自己选的配置」，作废绑定留下的回退点。清回退点与
  /// 切换在同一把锁里，不会被并发的绑定应用夹在中间。
  Future<void> switchProfile(int profileId) async {
    // 乐观标签：用户一点选就显示目标配置名，不等排队 / 快照 / 应用这些秒级步骤。
    ProfileRow? target;
    for (final ProfileRow p in state.profiles) {
      if (p.id == profileId) target = p;
    }
    final ValueNotifier<ProfileRow?> pending =
        _profileDraftCoordinator.pendingSwitchTarget;
    if (target != null) pending.value = target;
    try {
      await _profileDraftCoordinator._runProfileMutation((
        _ProfileDraftMutation mutation,
      ) async {
        await _repo.setFallbackProfileId(null);
        await _switchLocked(mutation, profileId);
      });
    } finally {
      // 成功：激活 id 已是目标；失败：已回滚——两种都回到读激活配置。
      if (identical(pending.value, target)) pending.value = null;
    }
  }

  /// 切换激活配置的本体；只能在配置变更锁里调用（[mutation] 就是那把锁的凭据）。
  Future<void> _switchLocked(
    _ProfileDraftMutation mutation,
    int profileId,
  ) async {
    mutation.invalidateDrafts();
    final int previousActiveId = state.activeProfileId;
    await _repo.snapshotCurrentSettings(previousActiveId);
    await _repo.setActiveProfileId(profileId);
    // state.activeProfileId 只代表「已生效」的配置：应用完成前编辑器草稿、删除判据等仍按
    // 旧配置走。切换期间要显示目标配置名的地方（悬浮球「切换配置」胶囊）读
    // [ProfileUiState.displayProfile]，由 [ProfileDraftCoordinator.pendingSwitchTarget] 驱动。
    try {
      await _repo.applyProfile(profileId);
    } catch (_) {
      // 应用失败：落库的激活 id 回到切换前，别停在没真正生效的配置上。
      await _repo.setActiveProfileId(previousActiveId);
      rethrow;
    }
    state = state.copyWith(activeProfileId: profileId);
    await _onProfileApplied();
  }

  /// 互联「下载配置」：把收到的配置作为**新**配置落地（不覆盖任何既有配置），再走
  /// 与配置选择器同一条 [switchProfile] 切过去（issue #1997，所有者 2026-10-09 拍板：
  /// 下载完直接生效，不再让用户自己去「配置管理」里切）。
  ///
  /// 切换前的规矩与手动切换完全一致：当前配置的实时设置先快照回它自己那一份，在飞的
  /// 设置草稿随配置代次一起作废，切换后 [_onProfileApplied] 刷新偏好缓存 / 词典 /
  /// 阅读器设置。返回新配置的 id。
  Future<int> importAndSwitchProfile(String json) async {
    final int id = await importProfile(json);
    await switchProfile(id);
    return id;
  }

  Future<void> createProfile(String name) =>
      _whileInvalidatingProfileDrafts(() async {
        await _repo.snapshotCurrentSettings(state.activeProfileId);
        final newId = await _repo.createProfile(name);
        await _repo.snapshotCurrentSettings(newId);
        await _repo.setActiveProfileId(newId);
        state = state.copyWith(
          profiles: await _repo.getAllProfiles(),
          activeProfileId: newId,
        );
      });

  Future<void> copyProfile(int sourceId, String newName) async {
    if (sourceId == state.activeProfileId) {
      await _repo.snapshotCurrentSettings(sourceId);
    }
    await _repo.copyProfile(sourceId, newName);
    state = state.copyWith(profiles: await _repo.getAllProfiles());
  }

  Future<void> renameProfile(int id, String name) async {
    await _repo.renameProfile(id, name);
    state = state.copyWith(profiles: await _repo.getAllProfiles());
  }

  /// 删掉 [id] 会连带删掉的数据规模（确认框用）。
  Future<ProfileDeletionImpact> deletionImpact(int id) async {
    final ProfileDeletionCascade? cascade = _deletionCascade;
    if (cascade == null) return const ProfileDeletionImpact.none();
    final ProfileRow? target = _profileById(await _repo.getAllProfiles(), id);
    if (target == null) return const ProfileDeletionImpact.none();
    return cascade.impactOf(target);
  }

  /// 删 Profile，连带它在 srs.db 里的复习数据与媒体目录（反馈 8TaOy2i-lL）：先备份（失败抛
  /// [ProfileDeletionBackupException]，什么都不删），再删 `profiles` 行（主库外键级联其余），最后清复习数据。
  /// 只剩一个 Profile 或 [id] 不存在时不删，返回 null。
  Future<ProfileDeletionOutcome?> deleteProfile(int id) =>
      _profileDraftCoordinator._runProfileMutation((
        _ProfileDraftMutation mutation,
      ) async {
        final List<ProfileRow> before = await _repo.getAllProfiles();
        final ProfileRow? target = _profileById(before, id);
        if (target == null || before.length <= 1) return null;
        final ProfileDeletionCleanup? cleanup = await _deletionCascade?.prepare(
          target,
        );

        // This repository read must happen after acquiring the same lock used
        // by switch/create/Save. State may still describe the previous Profile
        // while an earlier switch has already updated the repository.
        final int previousActiveId = await _repo.getActiveProfileId();
        final bool deletesActiveProfile = id == previousActiveId;
        if (deletesActiveProfile) {
          mutation.invalidateDrafts();
        }

        await _repo.deleteProfile(id);
        final profiles = await _repo.getAllProfiles();
        final activeId = await _repo.getActiveProfileId();
        state = state.copyWith(profiles: profiles, activeProfileId: activeId);
        if (deletesActiveProfile && activeId != previousActiveId) {
          await _onProfileApplied();
        }
        // 行删掉、当前 Profile 已切走之后再清：被删的若是当前 Profile，它的副本此刻才不再被界面使用。
        await cleanup?.run();
        return ProfileDeletionOutcome(
          impact: cleanup?.impact ?? const ProfileDeletionImpact.none(),
          backupPath: cleanup?.backupPath,
        );
      });

  /// 一次性存量扫描：清掉 srs.db 里不属于任何现存 Profile 的复习数据（先备份；扫完记标记，之后不再扫）。
  /// 进 Profile 管理时调用。失败时标记不写（下次进来再扫），错误照常抛给调用方。返回清掉的无主 uid 数。
  Future<int> sweepOrphanProfileData() async {
    final ProfileDeletionCascade? cascade = _deletionCascade;
    if (cascade == null) return 0;
    return _profileDraftCoordinator._runProfileMutation(
      (_ProfileDraftMutation _) async =>
          cascade.sweepOrphans(await _repo.getAllProfiles()),
    );
  }

  static ProfileRow? _profileById(List<ProfileRow> profiles, int id) {
    for (final ProfileRow p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> setMediaTypeBinding(
    ProfileMediaKind mediaType,
    int? profileId,
  ) async {
    if (profileId == null) {
      await _repo.removeMediaTypeBinding(mediaType);
    } else {
      await _repo.setMediaTypeBinding(mediaType, profileId);
    }
    state = state.copyWith(
      mediaTypeBindings: await _repo.getAllMediaTypeBindings(),
    );
  }

  /// 绑定 / 解绑一种内容语言（[profileId] 为 null 即解绑）。[languageTag] 传任意
  /// 形态的 BCP-47 串，归一在 repository 层做。
  Future<void> setLanguageBinding(String languageTag, int? profileId) async {
    if (profileId == null) {
      await _repo.removeLanguageBinding(languageTag);
    } else {
      await _repo.setLanguageBinding(languageTag, profileId);
    }
    state = state.copyWith(
      languageBindings: await _repo.getAllLanguageBindings(),
    );
  }

  Future<void> saveCurrentSettingsToActiveProfile() async {
    await _repo.snapshotCurrentSettings(state.activeProfileId);
  }

  /// 把指定 Profile 序列化成可分享的 JSON（凭据已剔除、字体绝对路径已剥离）。
  /// [fontsRootDirectory] 是本机 `custom_fonts/` 根，用于 A1 字体路径剥离。
  Future<String> exportProfile(int profileId, {String? fontsRootDirectory}) =>
      _repo.exportProfileToJson(
        profileId,
        fontsRootDirectory: fontsRootDirectory,
      );

  /// 从导出 JSON 导回一个 Profile。坏文件在写 DB 前抛 [ProfileImportException]。
  ///
  /// 默认新建 Profile（重名加后缀）；overwrite 模式覆盖 [targetProfileId]。
  /// 导入后刷新 Profile 列表；若覆盖的是当前激活 Profile，立即 [applyProfile]
  /// 并触发 [_onProfileApplied] 让设置生效。
  Future<int> importProfile(
    String json, {
    ProfileImportMode mode = ProfileImportMode.createNew,
    int? targetProfileId,
  }) => _profileDraftCoordinator._runProfileMutation((
    _ProfileDraftMutation mutation,
  ) async {
    // Do not decide this from [state] before entering the lock: a queued
    // switch can make [targetProfileId] active before the overwrite runs.
    final int activeProfileId = await _repo.getActiveProfileId();
    final bool overwritesActiveProfile =
        mode == ProfileImportMode.overwrite &&
        targetProfileId == activeProfileId;
    if (overwritesActiveProfile) {
      mutation.invalidateDrafts();
    }

    final int writtenId = await _repo.importProfileFromJson(
      json,
      mode: mode,
      targetProfileId: targetProfileId,
    );
    state = state.copyWith(profiles: await _repo.getAllProfiles());
    if (overwritesActiveProfile && writtenId == activeProfileId) {
      await _repo.applyProfile(writtenId);
      await _onProfileApplied();
    }
    return writtenId;
  });
}

final fushiDatabaseProvider = Provider<FushiDatabase>((ref) {
  final appModel = ref.watch(appProvider);
  return appModel.database;
});

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  final db = ref.watch(fushiDatabaseProvider);
  // 裸本机仓库（默认 = live Anki 设置存储）：快照 / 应用配置读写的是**激活配置**的 live
  // 设置，绝不能经制卡链（[ankiRepositoryProvider] 读的是叠了作品会话的存储）——否则在书里
  // 切配置会把作品配置的牌组快照进激活配置。
  final ankiRepo = ref.watch(platformServicesProvider).createAnkiRepository();
  return ProfileRepository(
    db,
    ankiRepo,
    // BUG-1994：回插被旧 prune 删掉的词典行时，「装没装」只认磁盘目录。
    isDictionaryInstalled: ref.read(appProvider).isDictionaryInstalledOnDisk,
  );
});

/// 临时 UI 草稿所绑定的 Profile 应用代次。
///
/// 它刻意独立于 [ProfileViewModel] 的异步初始加载：首次加载期间
/// `activeProfileId` 会从 -1 变成真实 id，但 AppModel 并未切换 Profile，
/// 因而不应误杀用户刚输入的草稿。只有真正应用/替换 Profile 的操作才轮换
/// 这个对象。它还串行化 Profile 应用与草稿保存，封住单次 scope guard 后的
/// 异步交叉写入窗口。
final profileDraftCoordinatorProvider = Provider<ProfileDraftCoordinator>(
  (ref) => ProfileDraftCoordinator(),
);

final profileViewModelProvider =
    StateNotifierProvider<ProfileViewModel, ProfileUiState>((ref) {
      final repo = ref.watch(profileRepositoryProvider);
      final ProfileDraftCoordinator profileDraftCoordinator = ref.watch(
        profileDraftCoordinatorProvider,
      );
      Future<void> onApplied() async {
        final PlatformServices platformServices = ref.read(
          platformServicesProvider,
        );
        final AnkiSettings ankiSettings = await ref
            .read(ankiRepositoryProvider)
            .loadSettings();
        platformServices.setUseAnkiConnectOnMobile(
          ankiSettings.useAnkiConnectOnMobile,
          apiKey: ankiSettings.ankiConnectApiKey,
        );
        platformServices.setUseAnkiSyncClient(ankiSettings.useAnkiSyncClient);
        ref.invalidate(ankiRepositoryProvider);
        final appModel = ref.read(appProvider);
        await appModel.refreshPrefCache();
        // TODO-1077: the profile switch replaced the dictionary_metadata table, so
        // reload the dictionary cache + native engine to pick up the new enable
        // list / order / language visibility for the switched-to profile.
        await appModel.reloadDictionariesFromDb();
        await ReaderFushiSource.readerSettings?.refreshFromDb();
      }

      // 先取好：游戏会话的进入在启动之后才发起，那时本 provider 可能已因切配置重建。
      final AppModel workScopeApp = ref.read(appProvider);
      return ProfileViewModel(
        repo,
        onApplied,
        profileDraftCoordinator,
        deletionCascade: srsProfileCleanupFor(ref),
        onWorkScopeSettled: () => workScopeApp.workProfileScopeSettled,
      );
    });

/// 另一个进程 / engine 改过偏好（[AppModel.refreshPrefCacheIfChanged] 返回 true）后，
/// 丢掉本 engine 里由 Anki 设置派生的 Riverpod 状态：仓库装饰链（后端选择已由
/// `refreshPrefCache` 重新推导）、[AnkiViewModel] 里缓存的设置快照、Profile 视图。
/// 常驻的 `:popup` / 悬浮词典据此在下一次查词时显示主 app 刚切的牌组 / 配置
/// （fiwDIpFep7）。三者都 watch [ankiRepositoryProvider]，逐个点名只是让意图可读。
void invalidateAnkiStateAfterPrefsChange(WidgetRef ref) {
  ref.invalidate(ankiRepositoryProvider);
  ref.invalidate(ankiViewModelProvider);
  ref.invalidate(profileViewModelProvider);
}

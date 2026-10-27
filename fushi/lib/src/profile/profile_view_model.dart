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
  });
  final List<ProfileRow> profiles;
  final int activeProfileId;
  final Map<String, int> mediaTypeBindings;

  /// 语言绑定：key = 归一化语言标签（`ja` / `zh-Hant`），value = profileId。
  /// 与 [mediaTypeBindings] 不同，它是**开放值域**——没有固定枚举可以铺死，UI 只
  /// 能列出已有绑定 + 一个添加入口。
  final Map<String, int> languageBindings;
  final bool isLoading;

  ProfileRow? get activeProfile {
    for (final p in profiles) {
      if (p.id == activeProfileId) return p;
    }
    return profiles.isNotEmpty ? profiles.first : null;
  }

  ProfileUiState copyWith({
    List<ProfileRow>? profiles,
    int? activeProfileId,
    Map<String, int>? mediaTypeBindings,
    Map<String, int>? languageBindings,
    bool? isLoading,
  }) =>
      ProfileUiState(
        profiles: profiles ?? this.profiles,
        activeProfileId: activeProfileId ?? this.activeProfileId,
        mediaTypeBindings: mediaTypeBindings ?? this.mediaTypeBindings,
        languageBindings: languageBindings ?? this.languageBindings,
        isLoading: isLoading ?? this.isLoading,
      );
}

class ProfileViewModel extends StateNotifier<ProfileUiState> {
  ProfileViewModel(
    this._repo,
    this._onProfileApplied,
    this._profileDraftCoordinator, {
    ProfileDeletionCascade? deletionCascade,
  })  : _deletionCascade = deletionCascade,
        super(const ProfileUiState()) {
    _load();
    // BUG-3148：别处（互联下载 / 对端上传入站）写进 profiles 表的新配置，列表要跟着
    // 刷新，不必等重启。只重读列表本身——激活 id 与绑定的切换都经本类，不受影响。
    _profilesChanged = _repo.watchProfilesChanged().listen((_) {
      unawaited(_refreshProfileList());
    });
  }

  StreamSubscription<void>? _profilesChanged;

  Future<void> _refreshProfileList() async {
    final List<ProfileRow> profiles = await _repo.getAllProfiles();
    if (!mounted) return;
    state = state.copyWith(profiles: profiles);
  }

  @override
  void dispose() {
    _profilesChanged?.cancel();
    _repo.snapshotCurrentSettings(state.activeProfileId).catchError((Object e) {
      debugPrint('[profile] snapshot on dispose failed: $e');
    });
    super.dispose();
  }

  final ProfileRepository _repo;
  final Future<void> Function() _onProfileApplied;
  final ProfileDraftCoordinator _profileDraftCoordinator;

  /// 删 Profile 时连带清理的、主库外键级联管不到的数据（复习数据在 srs.db）；null = 不清（测试）。
  final ProfileDeletionCascade? _deletionCascade;

  Future<T> _whileInvalidatingProfileDrafts<T>(
    Future<T> Function() action,
  ) =>
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
    );
  }

  Future<void> reload() => _load();

  /// TODO-2936：解析绑定（book 级 > 语言级 > 媒体类型级 > 当前激活）并在结果与当前激活
  /// 不同时切换。各媒体入口（阅读器 / 视频 / 漫画开页、gal launch/attach、浏览
  /// 器扩展查词）共用的非致命入口：失败只记日志，绝不打断调用方的加载/查词链。
  /// [languageTag]：该条目的**内容语言**原始串（`EpubBooks.language` /
  /// `VideoBooks.language` / `Galgames.language` 等列的值），由 repository 归一。
  /// 拿不到就不传——绝不要拿全局默认内容语言来填（理由见 [ProfileRepository.
  /// resolveProfileId] 的文档）。
  ///
  /// [restoreFallback]：没有绑定命中时，是否回到「绑定切换前用户自己选的配置」。
  /// 只有**打开一个具体条目**的入口（阅读器 / 视频 / 漫画开页、从库里启动 gal）
  /// 传 true——换了条目，上一个条目的绑定配置才该退场。浏览器扩展查词、附着任意
  /// 外部窗口这类旁路活动传 false：它们与正在看的条目并存，无绑定时绝不能把条目
  /// 背后的配置换掉、也不能消费回退点（否则阅读器开着时在浏览器查一次词，书的
  /// 词典 / 阅读器设置 / Anki 就全换成别的配置）。必填，逼每个新入口显式表态。
  Future<void> autoApplyBinding({
    String? bookUid,
    String? languageTag,
    required ProfileMediaKind mediaType,
    required bool restoreFallback,
  }) async {
    try {
      // 读回退点 / 读激活 id / 写回退点 / 切换必须是一个原子操作：中间隔着 await，
      // 并发的另一趟会读到旧状态（例如把刚记下的回退点清掉）。与手动切换 / 草稿
      // 保存同一把锁；只有真的切换时才作废在飞的草稿。
      await _profileDraftCoordinator._runProfileMutation(
        (_ProfileDraftMutation mutation) => _applyBindingLocked(
          mutation,
          bookUid: bookUid,
          languageTag: languageTag,
          mediaType: mediaType,
          restoreFallback: restoreFallback,
        ),
      );
    } catch (e, st) {
      debugPrint('[profile] auto-apply "${mediaType.dbValue}" binding failed '
          '(non-fatal): $e\n$st');
    }
  }

  /// [autoApplyBinding] 的锁内本体；只能在 [ProfileDraftCoordinator] 的配置变更
  /// 锁里调用。
  Future<void> _applyBindingLocked(
    _ProfileDraftMutation mutation, {
    required String? bookUid,
    required String? languageTag,
    required ProfileMediaKind mediaType,
    required bool restoreFallback,
  }) async {
    final int? boundId = await _repo.resolveBoundProfileId(
      bookUid: bookUid,
      languageTag: languageTag,
      mediaType: mediaType,
    );
    final int currentActiveId = await _repo.getActiveProfileId();
    final int? fallbackId = await _repo.getFallbackProfileId();
    if (boundId != null) {
      if (boundId == currentActiveId) return;
      // 绑定只是「这本书临时用」：第一次离开用户自己选的配置时记下它，之后
      // 无绑定的条目才有地方回去（否则切过去的绑定配置就成了新的默认）。
      if (fallbackId == null) {
        await _repo.setFallbackProfileId(currentActiveId);
      }
      await _switchLocked(mutation, boundId);
      return;
    }
    if (!restoreFallback || fallbackId == null) return;
    await _repo.setFallbackProfileId(null);
    final List<ProfileRow> profiles = await _repo.getAllProfiles();
    final bool stillExists = profiles.any((ProfileRow p) => p.id == fallbackId);
    if (stillExists && fallbackId != currentActiveId) {
      await _switchLocked(mutation, fallbackId);
    }
  }

  /// 用户手动切换：这是新的「自己选的配置」，作废绑定留下的回退点。清回退点与
  /// 切换在同一把锁里，不会被并发的绑定应用夹在中间。
  Future<void> switchProfile(int profileId) => _profileDraftCoordinator
          ._runProfileMutation((_ProfileDraftMutation mutation) async {
        await _repo.setFallbackProfileId(null);
        await _switchLocked(mutation, profileId);
      });

  /// 切换激活配置的本体；只能在配置变更锁里调用（[mutation] 就是那把锁的凭据）。
  Future<void> _switchLocked(
    _ProfileDraftMutation mutation,
    int profileId,
  ) async {
    mutation.invalidateDrafts();
    await _repo.snapshotCurrentSettings(state.activeProfileId);
    await _repo.setActiveProfileId(profileId);
    await _repo.applyProfile(profileId);
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
    state = state.copyWith(
      profiles: await _repo.getAllProfiles(),
    );
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
      _profileDraftCoordinator
          ._runProfileMutation((_ProfileDraftMutation mutation) async {
        final List<ProfileRow> before = await _repo.getAllProfiles();
        final ProfileRow? target = _profileById(before, id);
        if (target == null || before.length <= 1) return null;
        final ProfileDeletionCleanup? cleanup =
            await _deletionCascade?.prepare(target);

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
      ProfileMediaKind mediaType, int? profileId) async {
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
  Future<String> exportProfile(
    int profileId, {
    String? fontsRootDirectory,
  }) =>
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
  }) =>
      _profileDraftCoordinator
          ._runProfileMutation((_ProfileDraftMutation mutation) async {
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
  final ankiRepo = ref.watch(ankiRepositoryProvider);
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
  final ProfileDraftCoordinator profileDraftCoordinator =
      ref.watch(profileDraftCoordinatorProvider);
  Future<void> onApplied() async {
    final PlatformServices platformServices =
        ref.read(platformServicesProvider);
    final AnkiSettings ankiSettings =
        await ref.read(ankiRepositoryProvider).loadSettings();
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

  return ProfileViewModel(
    repo,
    onApplied,
    profileDraftCoordinator,
    deletionCascade: srsProfileCleanupFor(ref),
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

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
import 'package:fushi/src/profile/profile_repository.dart';

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
    this.isLoading = false,
  });
  final List<ProfileRow> profiles;
  final int activeProfileId;
  final Map<String, int> mediaTypeBindings;
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
    bool? isLoading,
  }) =>
      ProfileUiState(
        profiles: profiles ?? this.profiles,
        activeProfileId: activeProfileId ?? this.activeProfileId,
        mediaTypeBindings: mediaTypeBindings ?? this.mediaTypeBindings,
        isLoading: isLoading ?? this.isLoading,
      );
}

class ProfileViewModel extends StateNotifier<ProfileUiState> {
  ProfileViewModel(
    this._repo,
    this._onProfileApplied,
    this._profileDraftCoordinator,
  ) : super(const ProfileUiState()) {
    _load();
  }

  @override
  void dispose() {
    _repo.snapshotCurrentSettings(state.activeProfileId).catchError((Object e) {
      debugPrint('[profile] snapshot on dispose failed: $e');
    });
    super.dispose();
  }

  final ProfileRepository _repo;
  final Future<void> Function() _onProfileApplied;
  final ProfileDraftCoordinator _profileDraftCoordinator;

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
    state = ProfileUiState(
      profiles: profiles,
      activeProfileId: activeId,
      mediaTypeBindings: bindings,
    );
  }

  Future<void> reload() => _load();

  Future<void> switchProfile(int profileId) =>
      _whileInvalidatingProfileDrafts(() async {
        await _repo.snapshotCurrentSettings(state.activeProfileId);
        await _repo.setActiveProfileId(profileId);
        await _repo.applyProfile(profileId);
        state = state.copyWith(activeProfileId: profileId);
        await _onProfileApplied();
      });

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

  Future<void> deleteProfile(int id) => _profileDraftCoordinator
          ._runProfileMutation((_ProfileDraftMutation mutation) async {
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
      });

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
  return ProfileRepository(db, ankiRepo);
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
    ref.invalidate(ankiRepositoryProvider);
    final appModel = ref.read(appProvider);
    await appModel.refreshPrefCache();
    // TODO-1077: the profile switch replaced the dictionary_metadata table, so
    // reload the dictionary cache + native engine to pick up the new enable
    // list / order / language visibility for the switched-to profile.
    await appModel.reloadDictionariesFromDb();
    await ReaderFushiSource.readerSettings?.refreshFromDb();
  }

  return ProfileViewModel(repo, onApplied, profileDraftCoordinator);
});

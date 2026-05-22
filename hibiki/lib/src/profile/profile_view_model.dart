import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/sources/reader_hoshi_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/profile/profile_repository.dart';

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
  ProfileViewModel(this._repo, this._onProfileApplied)
      : super(const ProfileUiState()) {
    _load();
  }

  @override
  void dispose() {
    _repo.snapshotCurrentSettings(state.activeProfileId).catchError((_) {});
    super.dispose();
  }

  final ProfileRepository _repo;
  final void Function() _onProfileApplied;

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

  Future<void> switchProfile(int profileId) async {
    await _repo.snapshotCurrentSettings(state.activeProfileId);
    await _repo.setActiveProfileId(profileId);
    await _repo.applyProfile(profileId);
    state = state.copyWith(activeProfileId: profileId);
    _onProfileApplied();
  }

  Future<void> createProfile(String name) async {
    await _repo.snapshotCurrentSettings(state.activeProfileId);
    final newId = await _repo.createProfile(name);
    await _repo.snapshotCurrentSettings(newId);
    await _repo.setActiveProfileId(newId);
    state = state.copyWith(
      profiles: await _repo.getAllProfiles(),
      activeProfileId: newId,
    );
  }

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

  Future<void> deleteProfile(int id) async {
    final previousActiveId = state.activeProfileId;
    await _repo.deleteProfile(id);
    final profiles = await _repo.getAllProfiles();
    final activeId = await _repo.getActiveProfileId();
    state = state.copyWith(profiles: profiles, activeProfileId: activeId);
    if (activeId != previousActiveId) {
      _onProfileApplied();
    }
  }

  Future<void> setMediaTypeBinding(String mediaType, int? profileId) async {
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
}

final hibikiDatabaseProvider = Provider<HibikiDatabase>((ref) {
  final appModel = ref.watch(appProvider);
  return appModel.database;
});

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  final db = ref.watch(hibikiDatabaseProvider);
  final ankiRepo = ref.watch(ankiRepositoryProvider);
  return ProfileRepository(db, ankiRepo);
});

final profileViewModelProvider =
    StateNotifierProvider<ProfileViewModel, ProfileUiState>((ref) {
  final repo = ref.watch(profileRepositoryProvider);
  void onApplied() {
    ref.invalidate(ankiViewModelProvider);
    final appModel = ref.read(appProvider);
    appModel.refreshPrefCache();
    ReaderHoshiSource.readerSettings?.refreshFromDb();
  }

  return ProfileViewModel(repo, onApplied);
});

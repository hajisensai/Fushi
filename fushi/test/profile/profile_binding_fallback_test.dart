import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';

/// 反馈 #emN0S3Kypf：打开绑定专用配置的书后，再打开无绑定的书，应回到用户自己
/// 选的配置，而不是停在上一本书的绑定配置上（绑定切换曾直接写 active_profile_id，
/// 绑定配置就此变成「默认」）。
void main() {
  late FushiDatabase db;
  late ProfileRepository repo;
  late ProfileViewModel vm;
  late int defaultId;
  late int boundId;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = ProfileRepository(db, FakeAnkiRepository());
    vm = ProfileViewModel(repo, () async {}, ProfileDraftCoordinator());
    final ProfileUiState loaded = await vm.stream.firstWhere(
      (ProfileUiState s) => !s.isLoading && s.profiles.isNotEmpty,
    );
    defaultId = loaded.activeProfileId;
    boundId = await repo.createProfile('bound');
    await repo.setBookProfile('book-bound', boundId);
  });

  tearDown(() async {
    vm.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await db.close();
  });

  test('无绑定的条目回到绑定切换前自己选的配置', () async {
    await vm.autoApplyBinding(
      bookUid: 'book-bound',
      mediaType: ProfileMediaKind.epub,
    );
    expect(await repo.getActiveProfileId(), boundId);

    await vm.autoApplyBinding(
      bookUid: 'book-free',
      mediaType: ProfileMediaKind.epub,
    );
    expect(await repo.getActiveProfileId(), defaultId);
    expect(await repo.getFallbackProfileId(), isNull);
  });

  test('连续打开两本绑定书后回退点仍是最初那份', () async {
    final int second = await repo.createProfile('bound2');
    await repo.setBookProfile('book-bound2', second);
    await vm.autoApplyBinding(
      bookUid: 'book-bound',
      mediaType: ProfileMediaKind.epub,
    );
    await vm.autoApplyBinding(
      bookUid: 'book-bound2',
      mediaType: ProfileMediaKind.epub,
    );
    await vm.autoApplyBinding(
      bookUid: 'book-free',
      mediaType: ProfileMediaKind.epub,
    );
    expect(await repo.getActiveProfileId(), defaultId);
  });

  test('用户手动切换后，回退点作废，无绑定条目不再被拉回旧配置', () async {
    await vm.autoApplyBinding(
      bookUid: 'book-bound',
      mediaType: ProfileMediaKind.epub,
    );
    await vm.switchProfile(boundId);
    await vm.autoApplyBinding(
      bookUid: 'book-free',
      mediaType: ProfileMediaKind.epub,
    );
    expect(await repo.getActiveProfileId(), boundId);
  });
}

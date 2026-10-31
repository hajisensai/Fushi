import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';

/// 反馈 #emN0S3Kypf：打开绑定专用配置的书后，再打开无绑定的书，应回到用户自己
/// 选的配置，而不是停在上一本书的绑定配置上（绑定切换曾直接写 active_profile_id，
/// 绑定配置就此变成「默认」）。
///
/// 回退只属于「打开一个新条目」：浏览器扩展查词、附着外部窗口与正在看的条目
/// 并存，无绑定时既不能把条目背后的配置换掉，也不能消费回退点（review of
/// PR #2088）。
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

  Future<void> openBook(String bookUid) => vm.autoApplyBinding(
    bookUid: bookUid,
    mediaType: ProfileMediaKind.epub,
    restoreFallback: true,
  );

  test('无绑定的条目回到绑定切换前自己选的配置', () async {
    await openBook('book-bound');
    expect(await repo.getActiveProfileId(), boundId);

    await openBook('book-free');
    expect(await repo.getActiveProfileId(), defaultId);
    expect(await repo.getFallbackProfileId(), isNull);
  });

  test('连续打开两本绑定书后回退点仍是最初那份', () async {
    final int second = await repo.createProfile('bound2');
    await repo.setBookProfile('book-bound2', second);
    await openBook('book-bound');
    await openBook('book-bound2');
    await openBook('book-free');
    expect(await repo.getActiveProfileId(), defaultId);
  });

  test('用户手动切换后，回退点作废，无绑定条目不再被拉回旧配置', () async {
    await openBook('book-bound');
    await vm.switchProfile(boundId);
    await openBook('book-free');
    expect(await repo.getActiveProfileId(), boundId);
  });

  test('阅读器开着时浏览器查词（无浏览器绑定）不换配置、不消费回退点', () async {
    await openBook('book-bound');
    expect(await repo.getActiveProfileId(), boundId);
    expect(await repo.getFallbackProfileId(), defaultId);

    // 扩展每次 termEntries / tokenize 都会走这条。
    await vm.autoApplyBinding(
      mediaType: ProfileMediaKind.browser,
      restoreFallback: false,
    );
    await vm.autoApplyBinding(
      mediaType: ProfileMediaKind.game,
      restoreFallback: false,
    );

    expect(
      await repo.getActiveProfileId(),
      boundId,
      reason: '书背后的配置不能被一次查词 / 附着窗口换掉',
    );
    expect(
      await repo.getFallbackProfileId(),
      defaultId,
      reason: '回退点要留给下一次打开无绑定条目',
    );

    // 回退点还在：之后打开无绑定的书照样回到自选配置。
    await openBook('book-free');
    expect(await repo.getActiveProfileId(), defaultId);
  });

  test('旁路活动命中自己的绑定时照常切换，回退点仍是最初自选的那份', () async {
    final int browserProfile = await repo.createProfile('browser');
    await repo.setMediaTypeBinding(ProfileMediaKind.browser, browserProfile);
    await openBook('book-bound');

    await vm.autoApplyBinding(
      mediaType: ProfileMediaKind.browser,
      restoreFallback: false,
    );
    expect(await repo.getActiveProfileId(), browserProfile);
    expect(await repo.getFallbackProfileId(), defaultId);
  });

  test('并发的绑定应用串行执行，回退点不会被夹在中间清掉', () async {
    final int second = await repo.createProfile('bound2');
    await repo.setBookProfile('book-bound2', second);
    await openBook('book-bound');

    // 同时发起：先回到自选配置，再切到第二本书的绑定配置。串行时第二趟必须看到
    // 第一趟清掉回退点、切回 default 之后的状态，于是重新把 default 记成回退点。
    await Future.wait(<Future<void>>[
      openBook('book-free'),
      openBook('book-bound2'),
    ]);

    expect(await repo.getActiveProfileId(), second);
    expect(
      await repo.getFallbackProfileId(),
      defaultId,
      reason: '回退点丢了 = 之后打开无绑定条目会停在 bound2 上',
    );
    expect(vm.debugState.activeProfileId, second);
  });

  // 源码守卫：旁路入口必须显式传 restoreFallback: false。参数是 required 的，编译
  // 已经逼每个入口表态；这里钉的是「表态的值对不对」。Tests run with CWD = `fushi/`.
  test('附着外部窗口旁路入口不回退；浏览器绑定不再切换 App', () {
    // 反馈 biLEesNqWb：「浏览器」绑定只决定扩展请求读哪份配置的只读视图，不再
    // autoApplyBinding 切 App——main.dart 不得再出现这条旁路切换。
    final String main = File('lib/main.dart').readAsStringSync();
    expect(
      main.contains('mediaType: ProfileMediaKind.browser'),
      isFalse,
      reason: '浏览器查词不得再切换 App 的激活配置',
    );

    final String texthooker = File(
      'lib/src/pages/implementations/texthooker_page.dart',
    ).readAsStringSync();
    expect(
      RegExp(
        r'autoApplyBinding\(\s*mediaType: ProfileMediaKind\.game,\s*'
        r'restoreFallback: false',
      ).hasMatch(texthooker),
      isTrue,
      reason:
          '附着外部窗口（不对应库条目、不传 languageTag）必须 '
          'restoreFallback: false',
    );
  });
}

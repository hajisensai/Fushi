import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v100：新表 `language_profiles`（语言级 Profile 绑定）。
///
/// 纯新增表，无损：旧库升级后表为空 = 没有任何语言绑定 = Profile 解析链在语言这
/// 一级恒空转、直接落到 mediaType，与升级前逐字节一致。下面三条分别钉住「旧数据
/// 零丢失」「新表可用且带索引」「FK cascade 生效」。
void main() {
  /// 造一个 v99 形态的库：建好全表后把 v100 的产物删掉、版本号写回 99。
  Future<String> seedV99Database(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    final int profileId = await original.insertProfile(
      ProfilesCompanion.insert(
        name: '日语',
        createdAt: 111,
        updatedAt: 222,
      ),
    );
    await original.setMediaTypeProfile('epub', profileId);
    await original.setBookProfile('book-key-1', profileId);
    await original.close();

    final sqlite3.Database raw = sqlite3.sqlite3.open(path);
    try {
      raw.execute('DROP INDEX IF EXISTS idx_language_profiles_profile');
      raw.execute('DROP TABLE IF EXISTS language_profiles');
      raw.execute('PRAGMA user_version = 99');
    } finally {
      raw.dispose();
    }
    return path;
  }

  test('v99 → v100 建出 language_profiles，且既有 Profile 绑定零丢失', () async {
    final Directory directory =
        Directory.systemTemp.createTempSync('language_profiles_v100');
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await seedV99Database(directory);

    final FushiDatabase upgraded = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(upgraded.close);

    // 迁移终点 = 代码版本。
    expect(
      (await upgraded.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      upgraded.schemaVersion,
    );
    expect(upgraded.schemaVersion, 104);

    // 升级前就有的 Profile 与两类既有绑定原样还在（Never break userspace）。
    final List<ProfileRow> profiles = await upgraded.getAllProfiles();
    expect(profiles, hasLength(1));
    expect(profiles.single.name, '日语');
    expect(profiles.single.createdAt, 111);
    expect((await upgraded.getMediaTypeProfile('epub'))?.profileId,
        profiles.single.id);
    expect((await upgraded.getBookProfile('book-key-1'))?.profileId,
        profiles.single.id);

    // 新表存在且为空 —— 空 = 语言级绑定整级空转 = 升级前行为。
    expect(await upgraded.getAllLanguageProfiles(), isEmpty);

    // 新表可读写，主键 upsert 生效。
    await upgraded.setLanguageProfile('ja', profiles.single.id);
    expect((await upgraded.getLanguageProfile('ja'))?.profileId,
        profiles.single.id);
    await upgraded.setLanguageProfile('ja', profiles.single.id);
    expect(await upgraded.getAllLanguageProfiles(), hasLength(1));

    await upgraded.deleteLanguageProfile('ja');
    expect(await upgraded.getLanguageProfile('ja'), isNull);
  });

  test('v100 迁移路径上索引一并建出（_ensureIndexes 不跑升级路径）', () async {
    final Directory directory =
        Directory.systemTemp.createTempSync('language_profiles_v100_idx');
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await seedV99Database(directory);

    final FushiDatabase upgraded = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    // drift 是惰性打开：构造 FushiDatabase 不会跑迁移，必须先发一条真查询。
    // 少了这一句，下面的探针查到的是**没迁移过**的库，断言会以「索引没建出来」
    // 的形态假红，指向一个并不存在的实现缺陷。
    expect(await upgraded.getAllLanguageProfiles(), isEmpty);
    await upgraded.close();

    final sqlite3.Database probe = sqlite3.sqlite3.open(path);
    try {
      final sqlite3.ResultSet indexes = probe.select(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND tbl_name = 'language_profiles'",
      );
      expect(
        indexes.map((sqlite3.Row r) => r['name']),
        contains('idx_language_profiles_profile'),
        reason: '升级路径不跑 _ensureIndexes，索引必须由 v100 台阶内联建出',
      );
    } finally {
      probe.dispose();
    }
  });

  test('删 Profile 时语言绑定随之 cascade 清除', () async {
    final Directory directory =
        Directory.systemTemp.createTempSync('language_profiles_v100_fk');
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await seedV99Database(directory);

    final FushiDatabase upgraded = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(upgraded.close);

    final ProfileRow profile = (await upgraded.getAllProfiles()).single;
    await upgraded.setLanguageProfile('zh-Hant', profile.id);
    expect(await upgraded.getAllLanguageProfiles(), hasLength(1));

    await upgraded.deleteProfile(profile.id);
    expect(
      await upgraded.getAllLanguageProfiles(),
      isEmpty,
      reason: 'profileId 是 cascade 外键，删 Profile 不能留下悬空绑定',
    );
  });
}

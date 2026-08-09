import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/storage/legacy_support_dir_migration.dart';
import 'package:path/path.dart' as p;

// ---------------------------------------------------------------------------
// Hibiki → Fushi 桌面原地改名升级的 app-support 根搬迁。
//
// 这段代码是「用户打开 app 看到空库」与「什么都没发生」之间唯一的分界线，且失败
// 时不会有任何报错，所以每条分支都必须钉死：四种存在性组合 + 中断重入 + 失败时
// 旧数据完好 + prefs 里绝对路径的 rebase。
// ---------------------------------------------------------------------------

/// 造一个「已经跑过的旧安装」：主库 + prefs + 一个子目录。
void _seedLegacyInstall(Directory legacy, {String? prefsJson}) {
  legacy.createSync(recursive: true);
  File(p.join(legacy.path, 'fushi.db')).writeAsStringSync('DB-CONTENT');
  Directory(p.join(legacy.path, 'updates')).createSync();
  File(p.join(legacy.path, 'updates', 'note.txt')).writeAsStringSync('u');
  if (prefsJson != null) {
    File(p.join(legacy.path, kDesktopPrefsFileName)).writeAsStringSync(
      prefsJson,
    );
  }
}

void main() {
  late Directory sandbox;
  late Directory legacy;
  late Directory current;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('fushi-support-migration');
    legacy = Directory(p.join(sandbox.path, 'Hibiki', 'Hibiki'));
    current = Directory(p.join(sandbox.path, 'Fushi', 'Fushi'));
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  group('migrateSupportDirTree 四种存在性组合', () {
    test('只有旧根存在 → 整棵搬到新根（旧根消失）', () {
      _seedLegacyInstall(legacy);

      final LegacySupportMigrationOutcome outcome =
          migrateSupportDirTree(legacy: legacy, current: current);

      expect(outcome, LegacySupportMigrationOutcome.moved);
      expect(outcome.movedData, isTrue);
      expect(File(p.join(current.path, 'fushi.db')).readAsStringSync(),
          'DB-CONTENT');
      expect(File(p.join(current.path, 'updates', 'note.txt')).existsSync(),
          isTrue);
      expect(legacy.existsSync(), isFalse);
    });

    test('新根已有数据（两者都在）→ 绝不覆盖，旧根原样留着', () {
      _seedLegacyInstall(legacy);
      current.createSync(recursive: true);
      File(p.join(current.path, 'fushi.db')).writeAsStringSync('NEW-DB');

      final LegacySupportMigrationOutcome outcome =
          migrateSupportDirTree(legacy: legacy, current: current);

      expect(outcome, LegacySupportMigrationOutcome.alreadyPopulated);
      expect(outcome.movedData, isFalse);
      expect(
          File(p.join(current.path, 'fushi.db')).readAsStringSync(), 'NEW-DB');
      expect(File(p.join(legacy.path, 'fushi.db')).readAsStringSync(),
          'DB-CONTENT');
    });

    test('新根是 path_provider 刚建出来的空壳 → 照样搬（空壳不算已有数据）', () {
      _seedLegacyInstall(legacy);
      current.createSync(recursive: true); // path_provider 建的空目录

      final LegacySupportMigrationOutcome outcome =
          migrateSupportDirTree(legacy: legacy, current: current);

      expect(outcome, LegacySupportMigrationOutcome.moved);
      expect(File(p.join(current.path, 'fushi.db')).readAsStringSync(),
          'DB-CONTENT');
    });

    test('两者都不存在 → noLegacy，不创建任何东西', () {
      final LegacySupportMigrationOutcome outcome =
          migrateSupportDirTree(legacy: legacy, current: current);

      expect(outcome, LegacySupportMigrationOutcome.noLegacy);
      expect(current.existsSync(), isFalse);
    });

    test('只有新根存在（全新安装已落数据）→ noLegacy，新数据不受影响', () {
      current.createSync(recursive: true);
      File(p.join(current.path, 'fushi.db')).writeAsStringSync('NEW-DB');

      expect(migrateSupportDirTree(legacy: legacy, current: current),
          LegacySupportMigrationOutcome.noLegacy);
      expect(
          File(p.join(current.path, 'fushi.db')).readAsStringSync(), 'NEW-DB');
    });
  });

  group('幂等与中断重入', () {
    test('连搬两次：第二次是 noLegacy，新根内容不变', () {
      _seedLegacyInstall(legacy);
      expect(migrateSupportDirTree(legacy: legacy, current: current),
          LegacySupportMigrationOutcome.moved);
      expect(migrateSupportDirTree(legacy: legacy, current: current),
          LegacySupportMigrationOutcome.noLegacy);
      expect(File(p.join(current.path, 'fushi.db')).readAsStringSync(),
          'DB-CONTENT');
    });

    test('上一轮跨卷复制中断（暂存目录残缺）→ 本轮清掉残缺副本重来，不被误认为已搬完', () {
      _seedLegacyInstall(legacy);
      // 模拟「复制到一半断电」：暂存目录里只有半个库，没有 updates/。
      final Directory staging =
          Directory(current.path + kSupportMigrationStagingSuffix);
      staging.createSync(recursive: true);
      File(p.join(staging.path, 'fushi.db')).writeAsStringSync('HALF');

      final LegacySupportMigrationOutcome outcome =
          migrateSupportDirTree(legacy: legacy, current: current);

      // 同卷 rename 直接成功；关键是残缺暂存目录不会被留下、也不会污染新根。
      expect(outcome, LegacySupportMigrationOutcome.moved);
      expect(staging.existsSync(), isFalse);
      expect(File(p.join(current.path, 'fushi.db')).readAsStringSync(),
          'DB-CONTENT');
      expect(File(p.join(current.path, 'updates', 'note.txt')).existsSync(),
          isTrue);
    });

    test('残缺暂存目录 + 新根已有数据 → alreadyPopulated 同时把暂存目录清掉', () {
      _seedLegacyInstall(legacy);
      current.createSync(recursive: true);
      File(p.join(current.path, 'fushi.db')).writeAsStringSync('NEW-DB');
      final Directory staging =
          Directory(current.path + kSupportMigrationStagingSuffix);
      staging.createSync(recursive: true);
      File(p.join(staging.path, 'fushi.db')).writeAsStringSync('HALF');

      expect(migrateSupportDirTree(legacy: legacy, current: current),
          LegacySupportMigrationOutcome.alreadyPopulated);
      expect(staging.existsSync(), isFalse);
      expect(
          File(p.join(current.path, 'fushi.db')).readAsStringSync(), 'NEW-DB');
    });

    test('跨卷回退：经暂存目录整树复制就位，旧根刻意保留（不做不可回滚的删除）', () {
      _seedLegacyInstall(legacy);

      final LegacySupportMigrationOutcome outcome = migrateSupportDirTree(
        legacy: legacy,
        current: current,
        debugForceCopyFallback: true,
      );

      expect(outcome, LegacySupportMigrationOutcome.copied);
      expect(outcome.movedData, isTrue);
      expect(File(p.join(current.path, 'fushi.db')).readAsStringSync(),
          'DB-CONTENT');
      expect(File(p.join(current.path, 'updates', 'note.txt')).existsSync(),
          isTrue);
      // 复制成功不删旧根：宁可留一份副本，也不做失败即丢数据的删除。
      expect(File(p.join(legacy.path, 'fushi.db')).readAsStringSync(),
          'DB-CONTENT');
      expect(
          Directory(current.path + kSupportMigrationStagingSuffix).existsSync(),
          isFalse);
    });

    test('跨卷回退全程不往新根里增量写：复制完成那一刻新根还不存在', () {
      _seedLegacyInstall(legacy);
      final Directory staging =
          Directory(current.path + kSupportMigrationStagingSuffix);
      bool observed = false;

      final LegacySupportMigrationOutcome outcome = migrateSupportDirTree(
        legacy: legacy,
        current: current,
        debugForceCopyFallback: true,
        debugAfterStagingCopy: () {
          observed = true;
          expect(File(p.join(staging.path, 'fushi.db')).readAsStringSync(),
              'DB-CONTENT');
          expect(File(p.join(staging.path, 'updates', 'note.txt')).existsSync(),
              isTrue);
          // 这一刻断电 = 下次启动看到「新根不存在」→ 重来；新根若在这里已经
          // 非空，残缺状态就会被 alreadyPopulated 永久固化。
          expect(current.existsSync(), isFalse);
        },
      );

      expect(observed, isTrue, reason: '跨卷回退必须经过暂存目录。');
      expect(outcome, LegacySupportMigrationOutcome.copied);
    });

    test('跨卷复制中断后重入：残缺暂存副本被丢弃，重来一次拿到完整结果', () {
      _seedLegacyInstall(legacy);
      final Directory staging =
          Directory(current.path + kSupportMigrationStagingSuffix);
      staging.createSync(recursive: true);
      File(p.join(staging.path, 'fushi.db')).writeAsStringSync('HALF');

      final LegacySupportMigrationOutcome outcome = migrateSupportDirTree(
        legacy: legacy,
        current: current,
        debugForceCopyFallback: true,
      );

      expect(outcome, LegacySupportMigrationOutcome.copied);
      // 残缺的 'HALF' 绝不能就位。
      expect(File(p.join(current.path, 'fushi.db')).readAsStringSync(),
          'DB-CONTENT');
      expect(File(p.join(current.path, 'updates', 'note.txt')).existsSync(),
          isTrue);
      expect(staging.existsSync(), isFalse);
    });

    test('暂存目录名与新根不同名：不会被 alreadyPopulated 的非空判据看见', () {
      // 暂存目录是新根的**兄弟**（同父目录），不是新根的子项——否则「非空」判据
      // 会把半成品当成已搬完的数据。
      expect(p.dirname(current.path + kSupportMigrationStagingSuffix),
          p.dirname(current.path));
      expect(current.path + kSupportMigrationStagingSuffix,
          isNot(equals(current.path)));
    });
  });

  group('legacySupportDirFor：由当前根反推旧根', () {
    final p.Context win = p.Context(style: p.Style.windows);
    final p.Context posix = p.Context(style: p.Style.posix);

    test('Windows：Roaming 下 Fushi/Fushi 反推 Hibiki/Hibiki', () {
      final Directory? legacyDir = legacySupportDirFor(
        Directory(r'C:\Users\u\AppData\Roaming\Fushi\Fushi'),
        isMacOS: false,
        context: win,
      );
      expect(legacyDir, isNotNull);
      expect(legacyDir!.path, r'C:\Users\u\AppData\Roaming\Hibiki\Hibiki');
    });

    test('Windows：不是 Fushi/Fushi 布局 → null（不认识就别动）', () {
      expect(
        legacySupportDirFor(
          Directory(r'C:\Users\u\AppData\Roaming\Hibiki\Hibiki'),
          isMacOS: false,
          context: win,
        ),
        isNull,
      );
      expect(
        legacySupportDirFor(
          Directory(r'C:\Users\u\AppData\Roaming\Fushi'),
          isMacOS: false,
          context: win,
        ),
        isNull,
      );
    });

    test('macOS：app.fushi.reader → 同级 com.example.hibiki', () {
      final Directory? legacyDir = legacySupportDirFor(
        Directory('/Users/u/Library/Application Support/app.fushi.reader'),
        isMacOS: true,
        context: posix,
      );
      expect(legacyDir, isNotNull);
      expect(legacyDir!.path,
          '/Users/u/Library/Application Support/com.example.hibiki');
    });

    test('macOS：沙盒容器等非预期 bundle id 落点 → null', () {
      expect(
        legacySupportDirFor(
          Directory('/Users/u/Library/Containers/app.fushi.reader/Data'),
          isMacOS: true,
          context: posix,
        ),
        isNull,
      );
    });
  });

  group('prefs 里指向旧根的绝对路径 rebase', () {
    test('真实现场：app_icon_custom_path 被改写到新根，其余键一字不动', () {
      const String legacyRoot = r'C:\Users\u\AppData\Roaming\Hibiki\Hibiki';
      const String newRoot = r'C:\Users\u\AppData\Roaming\Fushi\Fushi';
      final String before = jsonEncode(<String, Object>{
        // 注意分隔符是混的：写入方是「dir.path + '/name'」。
        'flutter.app_icon_custom_path': '$legacyRoot/window_icon_custom.png',
        'flutter.data_root': r'D:\APP\FUSHI_date',
        'flutter.debug_log_enabled': true,
      });

      final String? after = rebaseSupportPathsInPrefsJson(
        before,
        legacyRoot: legacyRoot,
        newRoot: newRoot,
        caseInsensitive: true,
      );

      expect(after, isNotNull);
      final Map<String, dynamic> decoded =
          jsonDecode(after!) as Map<String, dynamic>;
      expect(decoded['flutter.app_icon_custom_path'],
          '$newRoot/window_icon_custom.png');
      expect(decoded['flutter.data_root'], r'D:\APP\FUSHI_date');
      expect(decoded['flutter.debug_log_enabled'], true);
    });

    test('Windows 大小写不敏感前缀命中', () {
      const String legacyRoot = r'C:\Users\u\AppData\Roaming\Hibiki\Hibiki';
      final String? after = rebaseSupportPathsInPrefsJson(
        jsonEncode(<String, Object>{
          'flutter.x': r'c:\users\u\appdata\roaming\hibiki\hibiki\a.png',
        }),
        legacyRoot: legacyRoot,
        newRoot: r'C:\Users\u\AppData\Roaming\Fushi\Fushi',
        caseInsensitive: true,
      );
      expect(after, isNotNull);
      expect((jsonDecode(after!) as Map<String, dynamic>)['flutter.x'],
          r'C:\Users\u\AppData\Roaming\Fushi\Fushi\a.png');
    });

    test('无命中 / 非法 JSON → null（不写盘）', () {
      expect(
        rebaseSupportPathsInPrefsJson(
          jsonEncode(<String, Object>{'flutter.a': 'D:/elsewhere/x.png'}),
          legacyRoot: r'C:\legacy',
          newRoot: r'C:\new',
          caseInsensitive: true,
        ),
        isNull,
      );
      expect(
        rebaseSupportPathsInPrefsJson(
          'not json at all',
          legacyRoot: r'C:\legacy',
          newRoot: r'C:\new',
          caseInsensitive: true,
        ),
        isNull,
      );
    });

    test('搬迁后整链：prefs 文件被就地改写', () {
      const String iconName = 'window_icon_custom.png';
      _seedLegacyInstall(
        legacy,
        prefsJson: jsonEncode(<String, Object>{
          'flutter.app_icon_custom_path': '${legacy.path}/$iconName',
        }),
      );
      File(p.join(legacy.path, iconName)).writeAsStringSync('PNG');

      expect(migrateSupportDirTree(legacy: legacy, current: current),
          LegacySupportMigrationOutcome.moved);
      expect(
        rebaseSupportPathsInPrefsFile(
          prefsFile: File(p.join(current.path, kDesktopPrefsFileName)),
          legacyRoot: legacy.path,
          newRoot: current.path,
          caseInsensitive: Platform.isWindows,
        ),
        isTrue,
      );

      final Map<String, dynamic> decoded = jsonDecode(
        File(p.join(current.path, kDesktopPrefsFileName)).readAsStringSync(),
      ) as Map<String, dynamic>;
      final String rebased = decoded['flutter.app_icon_custom_path'] as String;
      expect(rebased, '${current.path}/$iconName');
      expect(File(rebased).existsSync(), isTrue);
    });
  });

  group('macOS 旧 NSUserDefaults 域的锚点回捞', () {
    test('只捞新域缺失的键，已有的不覆盖', () {
      expect(
        missingMacosContinuityPrefKeys(<String>{'documents_layout'}),
        <String>['data_root', 'documents_container'],
      );
      expect(
        missingMacosContinuityPrefKeys(kMacosContinuityPrefKeys.toSet()),
        isEmpty,
      );
      // 自定义数据根是「丢了就等于数据消失」的那一个，必须在清单里。
      expect(kMacosContinuityPrefKeys, contains('data_root'));
    });

    test('旧域有 data_root → 写进新域（键名带 flutter. 前缀去读）', () async {
      final List<String> readKeys = <String>[];
      final Map<String, String> written = <String, String>{};

      final int count = await recoverLegacyMacosPrefs(
        isMacOSOverride: true,
        existingKeys: () async => <String>{'documents_layout'},
        writeKey: (String key, String value) async => written[key] = value,
        legacyReader: (String prefixedKey) async {
          readKeys.add(prefixedKey);
          return prefixedKey == 'flutter.data_root'
              ? '/Volumes/Ext/fushi'
              : null;
        },
      );

      expect(count, 1);
      expect(written, <String, String>{'data_root': '/Volumes/Ext/fushi'});
      expect(readKeys,
          <String>['flutter.data_root', 'flutter.documents_container']);
    });

    test('非 macOS / 旧域为空 → 一个字都不写', () async {
      final Map<String, String> written = <String, String>{};
      expect(
        await recoverLegacyMacosPrefs(
          isMacOSOverride: false,
          existingKeys: () async => <String>{},
          writeKey: (String key, String value) async => written[key] = value,
          legacyReader: (String key) async => '/should/not/be/read',
        ),
        0,
      );
      expect(
        await recoverLegacyMacosPrefs(
          isMacOSOverride: true,
          existingKeys: () async => <String>{},
          writeKey: (String key, String value) async => written[key] = value,
          legacyReader: (String key) async => null,
        ),
        0,
      );
      expect(written, isEmpty);
    });

    test('读旧域抛错不致命：返回 0 且不写', () async {
      final Map<String, String> written = <String, String>{};
      expect(
        await recoverLegacyMacosPrefs(
          isMacOSOverride: true,
          existingKeys: () async => <String>{},
          writeKey: (String key, String value) async => written[key] = value,
          legacyReader: (String key) async => throw const ProcessException(
            'defaults',
            <String>['read'],
          ),
        ),
        0,
      );
      expect(written, isEmpty);
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/media_source.dart' show dbSourcePrefKey;
import 'package:fushi/src/storage/path_rebase_coverage.dart';
import '../helpers/scan_scale.dart';

/// BUG-1174 守卫：**路径 rebase 覆盖率**。
///
/// 「加了新列/新 pref，忘了改数据根迁移器」这件事已经发生过三轮：TODO-1255
/// （`video_books.cover_path`）、BUG-1174（`galgames.cover_path` +
/// `video_books.subtitle_source`×2 + `media_items.image_url` + 整张 `profile_settings`
/// + 5 个 pref key）。人的记忆靠不住，把它变成 CI。
///
/// 本测试扫源码、与 `path_rebase_coverage.dart` 的声明**双向**比对：
///  1. tables.dart 里名字形似路径的 TextColumn 必须在 [kPathRebaseColumns] 里登记；
///  2. 登记的列必须真实存在（删了列就要删声明，杜绝陈旧豁免）；
///  3. 每条声明必须给出非空理由（豁免要说得出为什么）；
///  4. 标了「必须 rebase」的列，其列名必须真的出现在 `data_root_migrator.dart` 里；
///  5. pref 侧同规则：lib/ 里名字形似路径的 pref key 字面量必须登记；
///  6. 字体 key 的硬编码字面值必须与单一真相编码器 [dbSourcePrefKey] 一致。
///
/// **正则刻意宽松**（`path|dir|root|url|source|file|json`）：宁可多要求几条
/// `notAPath` 声明，也不放过一个真的存绝对路径的新列。
void main() {
  final String tablesPath = p.join(
      '..', 'packages', 'fushi_core', 'lib', 'src', 'database', 'tables.dart');
  final String migratorPath =
      p.join('lib', 'src', 'storage', 'data_root_migrator.dart');

  final RegExp tableDecl = RegExp(r'^\s*class\s+(\w+)\s+extends\s+Table\b');
  final RegExp textColumnDecl = RegExp(r'^\s*TextColumn\s+get\s+(\w+)');
  final RegExp pathLikeName =
      RegExp('path|dir|root|url|source|file|json', caseSensitive: false);
  final RegExp pathLikePrefKey =
      RegExp('path|dir|root|file', caseSensitive: false);
  final RegExp prefCall = RegExp(r"(?:get|set)Pref\(\s*'([^']+)'");

  /// tables.dart 里的 (表类名, 列 getter 名) 全集。
  Set<String> allTextColumns() {
    final File file = File(tablesPath);
    expect(file.existsSync(), isTrue,
        reason: '本测试假定 cwd 为 hibiki/（flutter test 默认）：$tablesPath');
    final Set<String> out = <String>{};
    String? table;
    for (final String line in file.readAsLinesSync()) {
      final RegExpMatch? t = tableDecl.firstMatch(line);
      if (t != null) table = t.group(1);
      final RegExpMatch? c = textColumnDecl.firstMatch(line);
      if (c != null && table != null) out.add('$table.${c.group(1)}');
    }
    expect(out, isNotEmpty);
    return out;
  }

  test('tables.dart 里每个路径形 TextColumn 都在 kPathRebaseColumns 里登记', () {
    final Set<String> declared = kPathRebaseColumns
        .map((PathRebaseColumn c) => '${c.table}.${c.column}')
        .toSet();
    final List<String> missing = allTextColumns()
        .where((String id) => pathLikeName.hasMatch(id.split('.').last))
        .where((String id) => !declared.contains(id))
        .toList()
      ..sort();
    expect(
      missing,
      isEmpty,
      reason: '这些列名形似路径却没在 kPathRebaseColumns 登记。请判定它是否存数据根内'
          '绝对路径：是 → 在 DataRootMigrator 里补改写并声明 documentsRooted/'
          'supportRooted；否 → 声明 notAPath/externalUserPath 并写清理由。'
          '漏改的代价是用户换数据位置后这一列指向的内容全部失效：$missing',
    );
  });

  test('kPathRebaseColumns 里没有陈旧声明（列必须真实存在）', () {
    final Set<String> actual = allTextColumns();
    final List<String> stale = kPathRebaseColumns
        .map((PathRebaseColumn c) => '${c.table}.${c.column}')
        .where((String id) => !actual.contains(id))
        .toList()
      ..sort();
    expect(stale, isEmpty,
        reason: '这些声明指向 tables.dart 里已不存在的列，删列时请一并删声明：$stale');
  });

  test('每条列声明都给出了非空理由', () {
    for (final PathRebaseColumn c in kPathRebaseColumns) {
      expect(c.reason.trim(), isNotEmpty, reason: '$c 缺理由');
    }
    final Set<String> ids = kPathRebaseColumns
        .map((PathRebaseColumn c) => '${c.table}.${c.column}')
        .toSet();
    expect(ids.length, equals(kPathRebaseColumns.length), reason: '有重复声明');
  });

  test('标为必须 rebase 的列，列名真的出现在 data_root_migrator.dart 里', () {
    final String src = File(migratorPath).readAsStringSync();
    final List<String> notWired = <String>[];
    for (final PathRebaseColumn c in kPathRebaseColumns) {
      if (!c.mustRebase) continue;
      // 迁移器有的走裸 SQL（snake_case 列名），有的走 drift 生成的具名参数（Dart 名），
      // 两种写法都算已接线。
      if (src.contains(c.sqlColumn) || src.contains(c.column)) continue;
      notWired.add(c.toString());
    }
    expect(notWired, isEmpty,
        reason: '这些列声明为必须 rebase，但迁移器源码里根本没提到它们：$notWired');
  });

  test('每张含必须 rebase 列的表，迁移器都有 _rebase<Table> 入口且在事务里被调用', () {
    final String src = File(migratorPath).readAsStringSync();
    // 命名约定：一张表一个 `_rebase<Dart 表类名>` 静态方法，全部在 db.transaction 里
    // 依次调用。上一条按列名比对的守卫抓不到「整张表的改写被整段删掉」（列名会与别的
    // 表撞名而侥幸通过）——这一条抓得到。
    final Set<String> tables = kPathRebaseColumns
        .where((PathRebaseColumn c) => c.mustRebase)
        .map((PathRebaseColumn c) => c.table)
        .toSet();
    final List<String> missing = <String>[];
    for (final String table in tables) {
      // Preferences 表的 KV 入口按语义命名为 _rebasePreferences。
      final String entry = '_rebase$table';
      final int declared = 'static Future<void> $entry('.allMatches(src).length;
      final int called = 'await $entry(db, docs'.allMatches(src).length;
      if (declared != 1 || called != 1) {
        missing.add('$entry(declared=$declared, called=$called)');
      }
    }
    expect(missing, isEmpty,
        reason: '这些表声明了必须 rebase 的列，但迁移器缺少对应的 _rebase<Table> 入口，'
            '或该入口没有在 DB 改写事务里被调用：$missing');
  });

  test('lib/ 里每个路径形 pref key 字面量都在 kPathRebasePrefs 里登记', () {
    final Set<String> declared =
        kPathRebasePrefs.map((PathRebasePref s) => s.key).toSet();
    final Map<String, String> missing = <String, String>{};
    int scanned = 0;
    for (final FileSystemEntity e
        in Directory('lib').listSync(recursive: true, followLinks: false)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      scanned++;
      final String src = e.readAsStringSync();
      for (final RegExpMatch m in prefCall.allMatches(src)) {
        final String key = m.group(1)!;
        // 插值键（`${type.uniqueKey}/last_picked_file`）不是字面量，另行声明在
        // kPathRebasePrefs 的注释里；这里只管字面量。
        if (key.contains(r'$')) continue;
        if (!pathLikePrefKey.hasMatch(key)) continue;
        if (declared.contains(key)) continue;
        missing[key] = e.path;
      }
    }
    expectScanScale(scanned,
        what: 'lib/ 下的 .dart', atLeast: 750, measured: 939);

    expect(
      missing,
      isEmpty,
      reason: '这些 pref key 名字形似路径却没在 kPathRebasePrefs 登记。若它承载数据根内'
          '绝对路径，DataRootMigrator 不改写它 = 用户换数据位置后该配置失效（且会经 '
          'profile_settings 快照被写回来）。请补声明并给理由：$missing',
    );
  });

  test('kPathRebasePrefs 里的 key 都还在 lib/ 里被真实使用（无陈旧声明）', () {
    final StringBuffer all = StringBuffer();
    int scanned = 0;
    for (final FileSystemEntity e
        in Directory('lib').listSync(recursive: true, followLinks: false)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      scanned++;
      all.write(e.readAsStringSync());
    }
    expectScanScale(scanned,
        what: 'lib/ 下的 .dart', atLeast: 750, measured: 939);
    final String src = all.toString();
    final List<String> stale = <String>[];
    for (final PathRebasePref spec in kPathRebasePrefs) {
      // 字体 key 由 dbSourcePrefKey 生成，源码里只出现 body 段（'font_catalog' 等）。
      final String needle =
          spec.key.startsWith('src:') ? spec.key.split(':').last : spec.key;
      if (!src.contains(needle)) stale.add(spec.key);
    }
    expect(stale, isEmpty, reason: '这些 pref 声明在 lib/ 里已无任何引用，请删声明：$stale');
  });

  test('每条 pref 声明都给出了非空理由，且 key 不重复', () {
    for (final PathRebasePref spec in kPathRebasePrefs) {
      expect(spec.reason.trim(), isNotEmpty, reason: '$spec 缺理由');
    }
    final Set<String> keys =
        kPathRebasePrefs.map((PathRebasePref s) => s.key).toSet();
    expect(keys.length, equals(kPathRebasePrefs.length), reason: '有重复声明');
  });

  test('字体 pref key 由 dbSourcePrefKey 编码器生成且已登记', () {
    // BUG-1174：声明表用编码器生成 key（不硬编码 media_source 私有前缀格式，见
    // db_source_pref_key_test）。这里断言编码器产出的 5 个字体 key 确实都在表里——
    // 编码格式若变化，两侧会同步变化而不会静默漏登记。
    for (final String body in <String>[
      'font_catalog',
      'custom_fonts',
      'app_ui_fonts',
      'dict_fonts',
      'video_sub_fonts',
    ]) {
      final String expected = dbSourcePrefKey('reader_ttu', body);
      expect(
        pathRebasePrefFor(expected),
        isNotNull,
        reason: 'dbSourcePrefKey(reader_ttu, $body) = $expected 未在 '
            'kPathRebasePrefs 里登记（编码格式改了？）',
      );
    }
  });

  test('迁移器里所有 documents 路径改写都必须过同一个作用域谓词（无旁路）', () {
    final String src = File(migratorPath).readAsStringSync();

    // ① 裸 rebasePath（startsWith 判据）在迁移器里只准出现一次：就是
    //    DocumentsPathRebaser.rebase 里那次，且必须被 isInScope 守住。多一次就是旁路。
    final List<String> bare = RegExp(r'^.*\brebasePath\(.*$', multiLine: true)
        .allMatches(src)
        .map((RegExpMatch m) => m.group(0)!.trim())
        .toList();
    expect(bare.length, equals(1),
        reason: '迁移器里出现了 ${bare.length} 处裸 rebasePath 调用：$bare');
    expect(bare.single, contains('isInScope(path)'),
        reason: '唯一那处 rebasePath 必须由 DocumentsPathRebaser.isInScope 守住');

    // ② 复用 backup_service 的字体 JSON 遍历器时**必须**注入 rewritePath —— 它们默认
    //    走裸 rebasePath。这正是 BUG-1174 被幂等测试抓到的那条旁路：新根落在旧根内部
    //    时字体路径被改写两遍，产出 .../Hibiki/data/Hibiki/data/custom_fonts/...。
    final int fontCalls =
        RegExp(r'rebaseFontCatalogJson\(').allMatches(src).length +
            RegExp(r'rebaseFontListJson\(').allMatches(src).length;
    final int injected =
        RegExp(r'rewritePath: documents.rebase').allMatches(src).length;
    expect(injected, equals(fontCalls),
        reason: '$fontCalls 处字体 JSON 改写调用里只有 $injected 处注入了作用域改写器；'
            '漏注入的那些会绕过作用域谓词、在新根嵌套于旧根时把路径改写两遍（静默毁库）');
  });
}

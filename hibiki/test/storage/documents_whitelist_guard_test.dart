import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/storage/app_paths.dart';

/// TODO-1226 守卫：documents 根顶层派生点 ↔ 迁移白名单
/// [AppPaths.hibikiOwnedDocumentsEntries] 一致性。
///
/// 默认数据根时 documents 根 = 共享用户 `Documents`，数据根迁移引擎只搬白名单命中的
/// 顶层项。若有人新增 `<documents>/<child>` 派生点而忘了收进白名单，那个子目录会在
/// 数据根迁移时被留在旧位置（数据分家）。本测试扫描源码派生点，漏项即红。
///
/// 扫描范围（与派生方式一一对应）：
///  1. `AppPaths.documentsSubdirectory('<child>')` 的字面量调用；
///  2. `appDirectory.path, '<child>'`（`p.join` / `path.join` 形式）；
///  3. `${...appDirectory.path}/<child>`（字符串插值形式）。
///
/// 直连 `getApplicationDocumentsDirectory()` 而**不随数据根走**的固定落点
/// （`ErrorLogService` 的 error_log/面包屑、`video_clips`、桌面导出目录 `Hibiki`、
/// `AudiobookStorage`——后者子目录名 `audiobooks` 已在白名单）刻意不在扫描范围：
/// 它们不解析到迁移后的新根，搬走反而与其读写方脱节（见 AppPaths 白名单文档）。
void main() {
  final RegExp subdirectoryCall = RegExp(r"documentsSubdirectory\('([^']+)'\)");
  final RegExp joinLiteral = RegExp(r"appDirectory\.path,\s*'([^']+)'");
  final RegExp interpolation =
      RegExp(r'appDirectory\.path\}/([A-Za-z0-9_.\-]+)');

  List<File> dartSources(Directory root) => root
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList();

  String firstSegment(String raw) => raw.split('/').first.split(r'\').first;

  test('lib/ 里所有 documents 根顶层派生点都收进了迁移白名单', () {
    final Directory lib = Directory('lib');
    expect(lib.existsSync(), isTrue,
        reason: '本测试假定 cwd 为 hibiki/（flutter test 默认）');

    final Map<String, Set<String>> missing = <String, Set<String>>{};
    for (final File f in dartSources(lib)) {
      final String src = f.readAsStringSync();
      final Set<String> found = <String>{};
      for (final RegExp re in <RegExp>[
        subdirectoryCall,
        joinLiteral,
        interpolation,
      ]) {
        for (final RegExpMatch m in re.allMatches(src)) {
          found.add(firstSegment(m.group(1)!));
        }
      }
      final Set<String> notWhitelisted = found
          .where((String name) =>
              !AppPaths.hibikiOwnedDocumentsEntries.contains(name))
          .toSet();
      if (notWhitelisted.isNotEmpty) {
        missing[f.path] = notWhitelisted;
      }
    }

    expect(
      missing,
      isEmpty,
      reason: '发现未收进 AppPaths.hibikiOwnedDocumentsEntries 的 documents 根顶层'
          '派生点（数据根迁移会把它们留在旧位置）。请把这些子目录名加进白名单，或改用'
          '已白名单的目录：$missing',
    );
  });

  test('白名单项是合法的顶层基名（非空、不含路径分隔符）', () {
    expect(AppPaths.hibikiOwnedDocumentsEntries, isNotEmpty);
    for (final String name in AppPaths.hibikiOwnedDocumentsEntries) {
      expect(name.trim(), equals(name));
      expect(name, isNotEmpty);
      expect(name.contains('/'), isFalse, reason: name);
      expect(name.contains(r'\'), isFalse, reason: name);
      expect(name, isNot(equals('.')));
      expect(name, isNot(equals('..')));
    }
  });

  test('生产迁移入口把白名单接给了引擎（data_root.part.dart 引用白名单常量）', () {
    final File wiring =
        File('lib/src/sync/sync_settings_schema/data_root.part.dart');
    expect(wiring.existsSync(), isTrue);
    final String src = wiring.readAsStringSync();
    expect(
      src.contains('hibikiOwnedDocumentsEntries'),
      isTrue,
      reason: '数据根迁移 UI 必须在默认根（共享 Documents）时把 '
          'AppPaths.hibikiOwnedDocumentsEntries 传给 DataRootMigrationRequest.'
          'documentsTopLevelIncludeNames，否则会整树搬移用户 Documents（TODO-1226）。',
    );
  });
}

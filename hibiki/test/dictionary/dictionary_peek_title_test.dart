import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/dictionary_import_manager.dart';
import 'package:path/path.dart' as path;

/// TODO-839：peekDictionaryTitle 纯函数单测。
///
/// 「从文件重选覆盖更新」在导入前廉价探出 yomitan zip 包内 index.json 的 title，用于
/// 判断新包是否与被更新词典异名（异名弹确认，避免静默改判成新增导入）。这是该判据的
/// 唯一可自动化验证点（真导入需 native FFI，headless 起不来）。
File _writeZip(Directory dir, String name, List<ArchiveFile> files) {
  final Archive archive = Archive();
  for (final ArchiveFile f in files) {
    archive.addFile(f);
  }
  final List<int> bytes = ZipEncoder().encode(archive)!;
  final File out = File(path.join(dir.path, name));
  out.writeAsBytesSync(Uint8List.fromList(bytes));
  return out;
}

ArchiveFile _jsonFile(String name, Object json) {
  final List<int> bytes = utf8.encode(jsonEncode(json));
  return ArchiveFile(name, bytes.length, bytes);
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('peek_title_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('reads title from a yomitan zip index.json', () {
    final File zip = _writeZip(tmp, 'dict.zip', <ArchiveFile>[
      _jsonFile('index.json', <String, dynamic>{
        'title': '三省堂',
        'format': 3,
        'revision': '2026-01-01',
      }),
    ]);
    expect(DictionaryImportManager.peekDictionaryTitle(zip), '三省堂');
  });

  test('reads title when index.json is nested under a top folder', () {
    final File zip = _writeZip(tmp, 'nested.zip', <ArchiveFile>[
      _jsonFile('pkg/index.json', <String, dynamic>{'title': '明鏡'}),
    ]);
    expect(DictionaryImportManager.peekDictionaryTitle(zip), '明鏡');
  });

  test('sanitizes path-separator characters in the title', () {
    final File zip = _writeZip(tmp, 'evil.zip', <ArchiveFile>[
      _jsonFile('index.json', <String, dynamic>{'title': 'a/b\\c'}),
    ]);
    // _sanitizeTitle 取 basename 并把分隔符替换掉，不应返回带路径的字符串。
    final String? title = DictionaryImportManager.peekDictionaryTitle(zip);
    expect(title, isNotNull);
    expect(title!.contains('/'), isFalse);
    expect(title.contains('\\'), isFalse);
  });

  test('returns null when index.json has no title', () {
    final File zip = _writeZip(tmp, 'notitle.zip', <ArchiveFile>[
      _jsonFile('index.json', <String, dynamic>{'format': 3}),
    ]);
    expect(DictionaryImportManager.peekDictionaryTitle(zip), isNull);
  });

  test('returns null when zip has no index.json', () {
    final File zip = _writeZip(tmp, 'noindex.zip', <ArchiveFile>[
      _jsonFile('term_bank_1.json', <dynamic>[]),
    ]);
    expect(DictionaryImportManager.peekDictionaryTitle(zip), isNull);
  });

  test('returns null for a corrupt / non-zip file', () {
    final File bad = File(path.join(tmp.path, 'broken.zip'));
    bad.writeAsBytesSync(<int>[0, 1, 2, 3, 4, 5]);
    expect(DictionaryImportManager.peekDictionaryTitle(bad), isNull);
  });

  test('returns null for dsl / mdx (title not cheaply peekable)', () {
    final File dsl = File(path.join(tmp.path, 'dict.dsl'));
    dsl.writeAsStringSync('#NAME "x"');
    expect(DictionaryImportManager.peekDictionaryTitle(dsl), isNull);
  });
}

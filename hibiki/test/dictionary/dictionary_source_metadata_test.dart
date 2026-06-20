import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:path/path.dart' as path;

/// TODO-609：readSourceMetadataFromIndex 纯函数——导入成功后，C++ importer 已把
/// 完整 index.json（含 revision/isUpdatable/indexUrl/downloadUrl）写回
/// <resourceDir>/<词典名>/index.json（importer.cpp:1146，glaze 全字段反射）。
/// 这里纯 Dart 读回该文件，把来源信息提取成 metadata Map（只填存在非空字段）。
/// 坏 JSON / 缺文件 → 返回空 Map（向后兼容，不崩）。
void main() {
  late Directory finalDir;

  setUp(() {
    finalDir = Directory.systemTemp.createTempSync('hibiki_src_meta_');
  });

  tearDown(() {
    if (finalDir.existsSync()) finalDir.deleteSync(recursive: true);
  });

  void writeIndex(String body) {
    File(path.join(finalDir.path, 'index.json')).writeAsStringSync(body);
  }

  group('readSourceMetadataFromIndex', () {
    test('完整 yomitan index → 提取全部 4 字段', () {
      writeIndex('''
{
  "title": "JMdict",
  "format": 3,
  "revision": "2026-06-20",
  "isUpdatable": true,
  "indexUrl": "https://example.com/index.json",
  "downloadUrl": "https://example.com/JMdict.zip"
}
''');
      final Map<String, String> m = readSourceMetadataFromIndex(finalDir);
      expect(m['revision'], '2026-06-20');
      expect(m['isUpdatable'], 'true');
      expect(m['indexUrl'], 'https://example.com/index.json');
      expect(m['downloadUrl'], 'https://example.com/JMdict.zip');
    });

    test('isUpdatable false → 落 "false"（字符串）', () {
      writeIndex('{"revision":"r1","isUpdatable":false}');
      final Map<String, String> m = readSourceMetadataFromIndex(finalDir);
      expect(m['isUpdatable'], 'false');
      expect(m['revision'], 'r1');
    });

    test('只填存在非空字段（缺 indexUrl/downloadUrl 不出现 key）', () {
      writeIndex('{"revision":"r2","isUpdatable":true}');
      final Map<String, String> m = readSourceMetadataFromIndex(finalDir);
      expect(m.containsKey('indexUrl'), isFalse);
      expect(m.containsKey('downloadUrl'), isFalse);
      expect(m['revision'], 'r2');
      expect(m['isUpdatable'], 'true');
    });

    test('空字符串字段不落 key', () {
      writeIndex('{"revision":"","indexUrl":"  ","downloadUrl":"u"}');
      final Map<String, String> m = readSourceMetadataFromIndex(finalDir);
      expect(m.containsKey('revision'), isFalse);
      expect(m.containsKey('indexUrl'), isFalse);
      expect(m['downloadUrl'], 'u');
    });

    test('坏 JSON → 空 Map（不崩）', () {
      writeIndex('{ this is not json ');
      expect(readSourceMetadataFromIndex(finalDir), isEmpty);
    });

    test('缺 index.json → 空 Map', () {
      expect(readSourceMetadataFromIndex(finalDir), isEmpty);
    });

    test('index.json 是数组（非对象）→ 空 Map', () {
      writeIndex('[1,2,3]');
      expect(readSourceMetadataFromIndex(finalDir), isEmpty);
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// BUG-045: native hoshidicts must never reintroduce ANSI/narrow-codepage
// filesystem access on Windows. memory.cpp must use CreateFileW (not
// CreateFileA), and all other UTF-8 path access (importer/query/stardict)
// must route through hoshi::fs_path / hoshi::fs_to_utf8 instead of building a
// std::filesystem::path from a std::string (decoded as ANSI on Windows) or
// letting glaze open files via a narrow path.
void main() {
  final String root = _repoRoot();
  final String nativeSrc =
      p.join(root, 'native', 'hoshidicts', 'hoshidicts_src');

  test('fs_utf8 boundary helper exists', () {
    final File helper = File(p.join(nativeSrc, 'util', 'fs_utf8.hpp'));
    expect(helper.existsSync(), isTrue,
        reason: 'fs_utf8.hpp boundary helper must exist');
    final String src = helper.readAsStringSync();
    expect(src.contains('fs_path'), isTrue);
    expect(src.contains('fs_to_utf8'), isTrue);
  });

  test('memory.cpp uses wide Win32 APIs, never the ANSI variants', () {
    final String src =
        File(p.join(nativeSrc, 'memory', 'memory.cpp')).readAsStringSync();
    expect(src.contains('CreateFileA'), isFalse,
        reason: 'CreateFileA mis-decodes UTF-8 paths as ANSI on Windows');
    expect(src.contains('CreateFileMappingA'), isFalse,
        reason: 'use CreateFileMappingW');
    expect(src.contains('CreateFileW'), isTrue);
    expect(src.contains('MultiByteToWideChar'), isTrue,
        reason: 'UTF-8 -> UTF-16 conversion must be present');
  });

  test('importer/query/stardict route filesystem access through fs_utf8', () {
    final Map<String, String> files = {
      'importer.cpp': p.join(nativeSrc, 'importer.cpp'),
      'query.cpp': p.join(nativeSrc, 'query.cpp'),
      'stardict_reader.cpp':
          p.join(nativeSrc, 'stardict', 'stardict_reader.cpp'),
    };
    for (final MapEntry<String, String> e in files.entries) {
      final String src = File(e.value).readAsStringSync();
      expect(src.contains('fs_utf8.hpp'), isTrue,
          reason: '${e.key} must include the fs_utf8 helper');
      // glaze's *_file_json open files via a narrow (ANSI) path internally.
      expect(src.contains('glz::write_file_json'), isFalse,
          reason: '${e.key} must write via fs_path, not glz::write_file_json');
      expect(src.contains('glz::read_file_json'), isFalse,
          reason: '${e.key} must read via fs_path, not glz::read_file_json');
    }
  });
}

String _repoRoot() {
  Directory dir = Directory.current;
  while (!File(p.join(dir.path, 'native', 'hoshidicts', 'CMakeLists.txt'))
      .existsSync()) {
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate repo root from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir.path;
}

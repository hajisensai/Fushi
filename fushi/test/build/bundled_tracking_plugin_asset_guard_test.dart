// The packed Bangumi plugin checked in as an app asset must be exactly the
// source in plugins/tracking/bangumi/ (spec
// docs/specs/2026-11-11-bangumi-bundled-plugin.md §3). Repack after changing
// the source:
//   node tools/tracking-plugin-sdk/fushi-tracking-plugin.mjs pack plugins/tracking/bangumi --out fushi/assets/tracking_plugins/moe.fushi.tracking.bangumi.fushiplug
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

const String _source = '../plugins/tracking/bangumi';
const String _asset =
    'assets/tracking_plugins/moe.fushi.tracking.bangumi.fushiplug';
const String _repack =
    'Repack: node tools/tracking-plugin-sdk/fushi-tracking-plugin.mjs pack '
    'plugins/tracking/bangumi --out fushi/$_asset';

/// The files the kit packs: `manifest.json` and every `.js` file, skipping
/// dot entries and node_modules (tools/music-plugin-sdk/lib/pkg.mjs
/// `listPackFiles`).
Map<String, String> _sourceFiles() {
  final Directory root = Directory(_source);
  final Map<String, String> out = <String, String>{};
  void walk(Directory dir, String rel) {
    for (final FileSystemEntity entity in dir.listSync()) {
      final String name = entity.uri.pathSegments
          .where((String s) => s.isNotEmpty)
          .last;
      if (name.startsWith('.') || name == 'node_modules') continue;
      final String path = rel.isEmpty ? name : '$rel/$name';
      if (entity is Directory) {
        walk(entity, path);
      } else if (entity is File &&
          ((path.endsWith('.js') && !path.endsWith('.d.ts')) ||
              path == 'manifest.json')) {
        out[path] = sha256.convert(entity.readAsBytesSync()).toString();
      }
    }
  }

  walk(root, '');
  return out;
}

void main() {
  test('the bundled Bangumi package matches plugins/tracking/bangumi', () {
    final Archive zip = ZipDecoder().decodeBytes(
      File(_asset).readAsBytesSync(),
    );
    final Map<String, List<int>> entries = <String, List<int>>{
      for (final ArchiveFile file in zip.files)
        if (file.isFile) file.name: file.content as List<int>,
    };
    final Object? listing = jsonDecode(utf8.decode(entries['files.json']!));
    final Map<String, String> packed = <String, String>{
      for (final MapEntry<String, Object?> e
          in ((listing! as Map<String, Object?>)['files']!
                  as Map<String, Object?>)
              .entries)
        e.key: e.value! as String,
    };
    final Map<String, String> source = _sourceFiles();
    expect(source, isNotEmpty);
    expect(packed, source, reason: _repack);
    // The zip carries exactly the listed files (plus files.json), each with
    // the listed hash.
    expect(entries.keys.toSet(), <String>{
      ...packed.keys,
      'files.json',
    }, reason: _repack);
    for (final MapEntry<String, String> e in packed.entries) {
      expect(
        sha256.convert(entries[e.key]!).toString(),
        e.value,
        reason: '${e.key}: $_repack',
      );
    }
    // Shipped unsigned: the app pins it by digest, not by signer.
    expect(entries.containsKey('signature.json'), isFalse);
  });
}

// Every packed tracking plugin checked in as an app asset must be exactly its
// source in plugins/tracking/<name>/ (spec
// docs/specs/2026-11-11-bangumi-bundled-plugin.md §3 and §9), and the assets
// folder holds exactly the bundled plugins the app knows. Repack after
// changing a source:
//   node tools/tracking-plugin-sdk/fushi-tracking-plugin.mjs pack plugins/tracking/<name> --out fushi/assets/tracking_plugins/<id>.fushiplug
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fushi/src/media/tracking/plugin/bundled_tracking_plugins.dart';
import 'package:test/test.dart';

const String _assetDir = 'assets/tracking_plugins';

/// Source folder of each bundled plugin, by package id.
const Map<String, String> _sources = <String, String>{
  'moe.fushi.tracking.bangumi': '../plugins/tracking/bangumi',
  'moe.fushi.tracking.anilist': '../plugins/tracking/anilist',
  'moe.fushi.tracking.mangabaka': '../plugins/tracking/mangabaka',
};

String _repack(String source, String asset) =>
    'Repack: node tools/tracking-plugin-sdk/fushi-tracking-plugin.mjs pack '
    '${source.substring(3)} --out fushi/$asset';

/// The files the kit packs: `manifest.json` and every `.js` file, skipping
/// dot entries and node_modules (tools/music-plugin-sdk/lib/pkg.mjs
/// `listPackFiles`).
Map<String, String> _sourceFiles(String source) {
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

  walk(Directory(source), '');
  return out;
}

void _expectPackedMatchesSource(BundledTrackingPlugin plugin) {
  final String source = _sources[plugin.id]!;
  final String repack = _repack(source, plugin.asset);
  final Archive zip = ZipDecoder().decodeBytes(
    File(plugin.asset).readAsBytesSync(),
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
  final Map<String, String> sourceFiles = _sourceFiles(source);
  expect(sourceFiles, isNotEmpty);
  expect(packed, sourceFiles, reason: repack);
  // The zip carries exactly the listed files (plus files.json), each with
  // the listed hash.
  expect(entries.keys.toSet(), <String>{
    ...packed.keys,
    'files.json',
  }, reason: repack);
  for (final MapEntry<String, String> e in packed.entries) {
    expect(
      sha256.convert(entries[e.key]!).toString(),
      e.value,
      reason: '${e.key}: $repack',
    );
  }
  // The manifest's id is the one the app expects under this asset name.
  final Object? manifest = jsonDecode(utf8.decode(entries['manifest.json']!));
  expect((manifest! as Map<String, Object?>)['id'], plugin.id);
  // Shipped unsigned: the app knows the package by its digest, not a signer.
  expect(entries.containsKey('signature.json'), isFalse);
}

void main() {
  test('every bundled plugin has a source folder; Bangumi is the only built-in '
      'one', () {
    expect(<String>{
      for (final BundledTrackingPlugin p in kBundledTrackingPlugins) p.id,
    }, _sources.keys.toSet());
    expect(
      <String>[
        for (final BundledTrackingPlugin p in kBundledTrackingPlugins)
          if (!p.removable) p.id,
      ],
      <String>[kBundledBangumiPluginId],
    );
  });

  test('the assets folder holds exactly the bundled plugins', () {
    expect(
      <String>{
        for (final FileSystemEntity e in Directory(_assetDir).listSync())
          e.uri.pathSegments.last,
      },
      <String>{
        for (final BundledTrackingPlugin p in kBundledTrackingPlugins)
          '${p.id}.fushiplug',
      },
    );
  });

  for (final BundledTrackingPlugin plugin in kBundledTrackingPlugins) {
    test('the bundled package ${plugin.id} matches its source', () {
      _expectPackedMatchesSource(plugin);
    });
  }
}

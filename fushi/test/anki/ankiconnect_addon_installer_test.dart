import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/ankiconnect_addon_installer.dart';
import 'package:path/path.dart' as p;

Uint8List _zipOf(Map<String, String> files) {
  final Archive archive = Archive();
  files.forEach((String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ankiconnect_installer_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('missing Anki data dir reports ankiDataDirNotFound', () async {
    final AnkiConnectAddonInstallResult result = await installAnkiConnectAddon(
      addonZipBytes: _zipOf(<String, String>{'__init__.py': 'x'}),
      ankiDataDir: Directory(p.join(tmp.path, 'does-not-exist')),
    );
    expect(result.status, AnkiConnectAddonInstallStatus.ankiDataDirNotFound);
  });

  test('extracts into addons21/<id> and writes an enabled meta.json', () async {
    final AnkiConnectAddonInstallResult result = await installAnkiConnectAddon(
      addonZipBytes: _zipOf(<String, String>{
        '__init__.py': 'print("hi")',
        'config.json': '{}',
      }),
      ankiDataDir: tmp,
    );
    expect(result.status, AnkiConnectAddonInstallStatus.installed);
    final Directory addonDir =
        Directory(p.join(tmp.path, 'addons21', kAnkiConnectAddonId));
    expect(addonDir.existsSync(), isTrue);
    expect(
      File(p.join(addonDir.path, '__init__.py')).readAsStringSync(),
      'print("hi")',
    );
    final Map<String, dynamic> meta =
        json.decode(File(p.join(addonDir.path, 'meta.json')).readAsStringSync())
            as Map<String, dynamic>;
    expect(meta['disabled'], isFalse);
    expect(meta['name'], 'AnkiConnect');
  });

  test('re-install keeps user meta config and re-enables a disabled addon',
      () async {
    final Directory addonDir =
        Directory(p.join(tmp.path, 'addons21', kAnkiConnectAddonId))
          ..createSync(recursive: true);
    File(p.join(addonDir.path, 'meta.json'))
        .writeAsStringSync(json.encode(<String, dynamic>{
      'disabled': true,
      'config': <String, dynamic>{'webBindPort': 9999},
      'mod': 12345,
    }));

    final AnkiConnectAddonInstallResult result = await installAnkiConnectAddon(
      addonZipBytes: _zipOf(<String, String>{'__init__.py': 'x'}),
      ankiDataDir: tmp,
    );
    expect(result.status, AnkiConnectAddonInstallStatus.installed);
    final Map<String, dynamic> meta =
        json.decode(File(p.join(addonDir.path, 'meta.json')).readAsStringSync())
            as Map<String, dynamic>;
    // 禁用位拉回 false，但用户配置与 mod 原样保留。
    expect(meta['disabled'], isFalse);
    expect((meta['config'] as Map<String, dynamic>)['webBindPort'], 9999);
    expect(meta['mod'], 12345);
  });

  test('zip-slip entries are skipped', () async {
    await installAnkiConnectAddon(
      addonZipBytes: _zipOf(<String, String>{
        '__init__.py': 'ok',
        '../evil.py': 'nope',
      }),
      ankiDataDir: tmp,
    );
    expect(File(p.join(tmp.path, 'addons21', 'evil.py')).existsSync(), isFalse);
    expect(
      File(p.join(tmp.path, 'addons21', kAnkiConnectAddonId, '__init__.py'))
          .existsSync(),
      isTrue,
    );
  });

  test('bundled asset is a valid addon zip with the real plugin inside', () {
    // 直接读仓库文件（flutter test 的 cwd 是包根），守住「资产被误删/换成
    // 坏包」——真装的就是这份字节。
    final File asset = File('assets/anki/ankiconnect.ankiaddon');
    expect(asset.existsSync(), isTrue, reason: '内置 AnkiConnect 插件包资产缺失');
    final Archive archive = ZipDecoder().decodeBytes(asset.readAsBytesSync());
    final List<String> names =
        archive.files.map((ArchiveFile f) => f.name).toList();
    expect(names, contains('__init__.py'));
    expect(names, contains('config.json'));
    final ArchiveFile init =
        archive.files.firstWhere((ArchiveFile f) => f.name == '__init__.py');
    final String source = utf8.decode(init.content as List<int>);
    expect(source, contains('anki_version'));
    final ArchiveFile config =
        archive.files.firstWhere((ArchiveFile f) => f.name == 'config.json');
    expect(utf8.decode(config.content as List<int>), contains('8765'));
  });

  test('bundled asset ships every module its __init__.py imports', () {
    // 这一条不是形式主义：入库的资产曾经只打了 `__init__.py`/`config.json`/
    // `config.md` 三个文件，而 `__init__.py` 顶部就 `from .web import …` /
    // `from .edit import Edit` / `from . import web, util`。装上去的插件在 Anki
    // 加载时必 ImportError，AnkiConnect 根本不会开始监听——用户只看到「连不上
    // Anki」，看不出插件压根没起来。上面那条守卫只查文件在不在、字符串对不对，
    // 结构上抓不到「少打了包内模块」。
    //
    // 判据是**行为反推**（扫源码里的相对导入），不是硬编码一份文件清单：将来换
    // 上游版本、模块增减，这条守卫照样成立。
    final File asset = File('assets/anki/ankiconnect.ankiaddon');
    final Archive archive = ZipDecoder().decodeBytes(asset.readAsBytesSync());
    final Set<String> packaged =
        archive.files.map((ArchiveFile f) => f.name).toSet();
    final ArchiveFile init =
        archive.files.firstWhere((ArchiveFile f) => f.name == '__init__.py');
    final String source = utf8.decode(init.content as List<int>);

    final Set<String> imported = <String>{};
    // `from .mod import x` / `from .mod.sub import x`
    for (final RegExpMatch m
        in RegExp(r'^from\s+\.(\w+)', multiLine: true).allMatches(source)) {
      imported.add(m.group(1)!);
    }
    // `from . import a, b`
    for (final RegExpMatch m
        in RegExp(r'^from\s+\.\s+import\s+([\w,\s]+)$', multiLine: true)
            .allMatches(source)) {
      for (final String name in m.group(1)!.split(',')) {
        final String trimmed = name.trim();
        if (trimmed.isNotEmpty) imported.add(trimmed);
      }
    }

    expect(imported, isNotEmpty,
        reason: '解析不出任何相对导入，正则跟不上上游写法了，这条守卫已经空转');
    for (final String module in imported) {
      expect(
        packaged.contains('$module.py') || packaged.contains('$module/'),
        isTrue,
        reason: '__init__.py 导入了 $module，但插件包里没有它——装上去会 ImportError',
      );
    }
  });
}

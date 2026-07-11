import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/dictionary_font_css.dart';

/// TODO-049: the dictionary popup is an isolated WebView with no font-file
/// serving and (on Windows) an about:blank origin. These tests pin the two
/// zero-cross-platform injection paths: system family names become a plain CSS
/// `font-family`, and imported files are inlined as base64 `data:` URL
/// `@font-face` declarations (gated by the allowed-directory whitelist).
Map<String, dynamic> _e(String name, {String? path, bool enabled = true}) =>
    <String, dynamic>{'name': name, 'path': path, 'enabled': enabled};

void main() {
  test('system font (no path) yields a font-family, no @font-face', () {
    final result = DictionaryFontCss.build(<Map<String, dynamic>>[
      _e('Noto Sans JP'),
    ]);
    expect(result.fontFamily, '"Noto Sans JP"');
    expect(result.fontFaces, isEmpty);
  });

  test('disabled entries are skipped', () {
    final result = DictionaryFontCss.build(<Map<String, dynamic>>[
      _e('Disabled Font', enabled: false),
      _e('Active Font'),
    ]);
    expect(result.fontFamily, '"Active Font"');
  });

  test('empty/whitespace names are skipped, empty input → empty CSS', () {
    expect(DictionaryFontCss.build(const <Map<String, dynamic>>[]).fontFamily,
        isEmpty);
    final result = DictionaryFontCss.build(<Map<String, dynamic>>[
      _e('   '),
      _e('Good'),
    ]);
    expect(result.fontFamily, '"Good"');
  });

  test('imported file inside the allowed dir → base64 data: @font-face',
      () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('hibiki_dictfont');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final File fontFile = File('${dir.path}/MyFont.ttf');
    await fontFile.writeAsBytes(<int>[0x00, 0x01, 0x02, 0x03]);

    final result = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('MyFont', path: fontFile.path)],
      allowedDirectories: <String>[dir.path],
    );

    expect(result.fontFamily, '"MyFont"');
    expect(result.fontFaces, contains('@font-face'));
    expect(result.fontFaces, contains('data:font/ttf;base64,'));
    expect(result.fontFaces, contains('format("truetype")'));
    // The four bytes 00 01 02 03 encode to "AAECAw==".
    expect(result.fontFaces, contains('AAECAw=='));
  });

  test('file outside the allowed dir is rejected (no inlining)', () async {
    final Directory allowed =
        await Directory.systemTemp.createTemp('hibiki_allowed');
    final Directory other =
        await Directory.systemTemp.createTemp('hibiki_other');
    addTearDown(() async {
      if (allowed.existsSync()) await allowed.delete(recursive: true);
      if (other.existsSync()) await other.delete(recursive: true);
    });
    final File outside = File('${other.path}/Evil.ttf');
    await outside.writeAsBytes(<int>[0x00, 0x01]);

    final result = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('Evil', path: outside.path)],
      allowedDirectories: <String>[allowed.path],
    );

    expect(result.fontFamily, isEmpty);
    expect(result.fontFaces, isEmpty);
  });

  test('oversized file is skipped (data: payload bound)', () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('hibiki_bigfont');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final File big = File('${dir.path}/Big.ttf');
    await big.writeAsBytes(List<int>.filled(64, 0));

    final result = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('Big', path: big.path)],
      allowedDirectories: <String>[dir.path],
      maxFileBytes: 16,
    );

    expect(result.fontFamily, isEmpty);
    expect(result.fontFaces, isEmpty);
  });

  test('unknown extension is skipped', () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('hibiki_badext');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final File f = File('${dir.path}/NotAFont.exe');
    await f.writeAsBytes(<int>[0x00]);

    final result = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('NotAFont', path: f.path)],
      allowedDirectories: <String>[dir.path],
    );

    expect(result.fontFamily, isEmpty);
  });

  test('woff2 maps to the correct mime + format hint', () async {
    final Directory dir = await Directory.systemTemp.createTemp('hibiki_woff2');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final File f = File('${dir.path}/Web.woff2');
    await f.writeAsBytes(<int>[0x10, 0x20]);

    final result = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('Web', path: f.path)],
      allowedDirectories: <String>[dir.path],
    );
    expect(result.fontFaces, contains('data:font/woff2;base64,'));
    expect(result.fontFaces, contains('format("woff2")'));
  });

  // ── BUG-712 P3: (path → mtime+size) data-url 缓存 ─────────────────────
  //
  // 查词每次推结果都会重建注入串，导入字体无缓存时每次数十 ms 的同步读盘
  // +base64 是查词热路径的纯浪费。缓存键是 (mtimeUs, size)：命中不重读盘，
  // 文件被原地覆盖（mtime/size 变）自动失效。
  //
  // 缓存命中无法用 identical() 从公开 API 观测（dataUrl 会被插值进新建的
  // @font-face 串），所以用更强的行为证据：覆写同 size 的不同内容并把 mtime
  // 恢复原值——键不变时若返回的仍是旧字节的 base64，就证明没有重读磁盘。

  test('BUG-712 P3: unchanged (mtime,size) hits the cache — no disk re-read',
      () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('hibiki_fontcache');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final File f = File('${dir.path}/Cached.ttf');
    await f.writeAsBytes(<int>[0x00, 0x01, 0x02, 0x03]); // base64 AAECAw==
    // 把 mtime 钉到一个确定的整秒值，两次 build 前都用同一个值恢复。
    // 不能沿用「读原始 stat.modified 再 setLastModified 恢复」：`FileStat.modified`
    // 由 `DateTime.fromMillisecondsSinceEpoch` 构造，Linux 会带亚秒毫秒分量，而
    // `File.setLastModified` 在 POSIX 上经 utime() 落到整秒——恢复值与原始亚秒不
    // 一致，缓存键 (mtimeUs,size) 变化，测试在 Linux/CI 误判缓存失效（Windows
    // 的 stat.modified 本就是整秒故侥幸通过）。改为两侧 setLastModified 同一整秒：
    // 同一落盘 mtime → 同一 stat 读回 → 缓存键跨平台恒定；缓存若真被删仍读到 CQkJCQ==。
    final DateTime pinned = DateTime.fromMillisecondsSinceEpoch(
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) * 1000);
    await f.setLastModified(pinned);

    final r1 = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('Cached', path: f.path)],
      allowedDirectories: <String>[dir.path],
    );
    expect(r1.fontFaces, contains('AAECAw=='));

    // 同 size 覆写不同内容，再把 mtime 恢复到同一整秒：缓存键 (mtimeUs,size) 不变。
    // 若缓存被删（每次重读盘），这里必然读到新字节 CQkJCQ==。
    await f.writeAsBytes(<int>[0x09, 0x09, 0x09, 0x09]); // base64 CQkJCQ==
    await f.setLastModified(pinned);

    final r2 = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('Cached', path: f.path)],
      allowedDirectories: <String>[dir.path],
    );
    expect(r2.fontFaces, contains('AAECAw=='),
        reason: '同 (path,mtime,size) 必须命中缓存，查词热路径不得重读盘');
    expect(r2.fontFaces, r1.fontFaces);
  });

  test('BUG-712 P3: overwrite with a changed mtime invalidates the cache',
      () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('hibiki_fontstale');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final File f = File('${dir.path}/Stale.ttf');
    await f.writeAsBytes(<int>[0x00, 0x01, 0x02, 0x03]); // base64 AAECAw==

    final r1 = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('Stale', path: f.path)],
      allowedDirectories: <String>[dir.path],
    );
    expect(r1.fontFaces, contains('AAECAw==')); // 先进缓存

    // 原地覆盖为不同内容（同 size），显式把 mtime 拨后 2s——比 sleep 20ms 更稳
    // （不受文件系统 mtime 粒度影响），确保缓存键变化。
    await f.writeAsBytes(<int>[0x09, 0x09, 0x09, 0x09]); // base64 CQkJCQ==
    await f.setLastModified(DateTime.now().add(const Duration(seconds: 2)));

    final r2 = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('Stale', path: f.path)],
      allowedDirectories: <String>[dir.path],
    );
    expect(r2.fontFaces, contains('CQkJCQ=='), reason: 'mtime 变化必须失效缓存并返回新内容');
    expect(r2.fontFaces, isNot(contains('AAECAw==')),
        reason: '旧内容的 stale dataUrl 不得存活');
  });

  test(
      'BUG-712 P3: cached oversized font is still rejected by a smaller '
      'maxFileBytes', () async {
    // 守回归：maxBytes 检查必须留在缓存命中之前——大文件已被（默认上限的调用方）
    // 缓存后，更小 maxFileBytes 的调用方仍须拒绝它，不得因命中缓存而绕过上限。
    final Directory dir =
        await Directory.systemTemp.createTemp('hibiki_fontcap');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final File big = File('${dir.path}/BigCached.ttf');
    await big.writeAsBytes(List<int>.filled(64, 7));

    final ok = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('BigCached', path: big.path)],
      allowedDirectories: <String>[dir.path],
    );
    expect(ok.fontFaces, contains('@font-face')); // 默认上限下成功 → 进缓存

    final rejected = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('BigCached', path: big.path)],
      allowedDirectories: <String>[dir.path],
      maxFileBytes: 16,
    );
    expect(rejected.fontFamily, isEmpty,
        reason: '缓存命中不得绕过调用方更小的 maxFileBytes 上限');
    expect(rejected.fontFaces, isEmpty);
  });
}

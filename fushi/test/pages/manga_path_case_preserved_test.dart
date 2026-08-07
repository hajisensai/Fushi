import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:path/path.dart' as p;

/// BUG-1221：漫画页图解析出的路径必须保留磁盘上的**真实大小写**。
///
/// `p.canonicalize` 在 Windows 上会把整条路径折成小写（`path` 包
/// `style/windows.dart:181` `canonicalizePart(part) => part.toLowerCase()`；POSIX
/// 无此覆写）。[MangaFushiPage.resolveMangaResource] 此前直接返回它的结果，于是
/// 漫画包里 `Vol1/P001.JPG` 被记成 `vol1/p001.jpg`。
///
/// 本地跑在 Windows 上时 `File.exists` 不区分大小写，所以**只断言 existsSync 抓不到
/// 这个 bug**；这里改为把解析结果与 `listSync` 列出的真实磁盘条目名做**逐字节比对**，
/// 从而在任何平台上都能复现大小写敏感平台的查找语义。
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('manga_path_case_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 磁盘上真实存在的、相对 [root] 的正斜杠路径集合（大小写原样）。
  Set<String> onDiskEntries() => <String>{
        for (final FileSystemEntity e in root.listSync(recursive: true))
          if (e is File)
            p.relative(e.path, from: root.path).replaceAll('\\', '/'),
      };

  void writeImage(String relative) {
    final File f = File(p.join(root.path, p.joinAll(relative.split('/'))));
    f.parent.createSync(recursive: true);
    // 最小 JPEG 头，内容无关紧要——本组只关心路径大小写。
    f.writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00]);
  }

  /// 解析结果转成相对 root 的正斜杠路径，便于与磁盘条目集合逐字节比对。
  String relOf(String absolute) =>
      p.relative(absolute, from: root.path).replaceAll('\\', '/');

  for (final String entry in <String>[
    'Vol1/P001.JPG',
    'CH02/Page_01.Jpeg',
    'MixedCase/SubDir/IMG_0001.PNG',
  ]) {
    test('解析「$entry」保留真实大小写，与磁盘条目逐字节一致', () {
      writeImage(entry);
      final String? resolved =
          MangaFushiPage.resolveMangaResource(root.path, entry);

      expect(resolved, isNotNull, reason: '文件真实存在，解析不该返回 null');
      expect(onDiskEntries(), contains(relOf(resolved!)),
          reason: '解析出的「${relOf(resolved)}」与磁盘大小写不符 —— 大小写敏感的 '
              'Android/Linux 上 existsSync 会失败（页图 404、制卡无封面），'
              '在 Windows 上则让 Anki 封面媒体名被小写化');
      // 返回值契约：绝对路径（canonicalize 会绝对化，normalize 不会，故实现里
      // 显式补了 p.absolute；这条断言锁住那个补偿别被删掉）。
      expect(p.isAbsolute(resolved), isTrue);
    });
  }

  test('URL 入口 resolveImageUrlToFile 同样保留大小写', () {
    writeImage('Vol1/P001.JPG');
    final String? resolved = MangaFushiPage.resolveImageUrlToFile(
      root.path,
      'https://${MangaFushiPage.kMangaHost}/img/Vol1/P001.JPG',
    );
    expect(resolved, isNotNull);
    expect(onDiskEntries(), contains(relOf(resolved!)));
  });

  test('百分号编码的混合大小写条目解码后仍保留大小写', () {
    writeImage('Vol 1/P001.JPG');
    final String? resolved = MangaFushiPage.resolveMangaResource(
      root.path,
      'Vol%201/P001.JPG',
    );
    expect(resolved, isNotNull);
    expect(onDiskEntries(), contains(relOf(resolved!)));
  });

  group('大小写保留不削弱穿越守卫', () {
    test('../ 逃逸仍被拒绝', () {
      writeImage('Vol1/P001.JPG');
      expect(
        MangaFushiPage.resolveMangaResource(root.path, '../escaped.jpg'),
        isNull,
      );
      expect(
        MangaFushiPage.resolveMangaResource(
            root.path, 'Vol1/../../escaped.jpg'),
        isNull,
      );
    });

    test('大小写不同的 ../ 逃逸也被拒绝（校验侧仍走 canonicalize）', () {
      // 逃逸判定不能因为大小写差异被绕过：即便根目录名大小写写反，
      // 越界校验用的 canonicalize 仍把两侧折平，`../` 照样拦下。
      final Directory outside =
          Directory.systemTemp.createTempSync('manga_outside_');
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync(recursive: true);
      });
      File(p.join(outside.path, 'Secret.JPG'))
          .writeAsBytesSync(<int>[0xFF, 0xD8]);
      final String escape =
          p.relative(p.join(outside.path, 'Secret.JPG'), from: root.path);
      expect(
        MangaFushiPage.resolveMangaResource(root.path, escape),
        isNull,
        reason: '解析到 root 之外的真实文件必须被拒绝',
      );
    });

    test('缺文件返回 null（不因大小写保留而误判存在）', () {
      writeImage('Vol1/P001.JPG');
      expect(
        MangaFushiPage.resolveMangaResource(root.path, 'Vol1/missing.JPG'),
        isNull,
      );
    });
  });
}

/// [FontDownloadService]：从「自定义字体」页搬出来的文件层，页面与浏览器扩展字体
/// 端点共用。这里钉住：魔数嗅探、单文件落地命名、zip 解包（含 overrideName 挑
/// regular）、多源回退下载与「回的不是字体就换下一源」。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/font_download_service.dart';
import 'package:path/path.dart' as p;

Uint8List _bytes(List<int> header, {int pad = 16}) =>
    Uint8List.fromList(<int>[...header, ...List<int>.filled(pad, 0x41)]);

final Uint8List kTtf = _bytes(<int>[0x00, 0x01, 0x00, 0x00]);
final Uint8List kOtf = _bytes(<int>[0x4F, 0x54, 0x54, 0x4F]);
final Uint8List kWoff =
    _bytes(<int>[0x77, 0x4F, 0x46, 0x46, 0x00, 0x01, 0x00, 0x00]);
// WOFF1 包 CFF：flavor 是 'OTTO'，仍是 WOFF1（旧实现误判成 woff2）。
final Uint8List kWoffOtto =
    _bytes(<int>[0x77, 0x4F, 0x46, 0x46, 0x4F, 0x54, 0x54, 0x4F]);
// 真正的 WOFF2 魔数是 'wOF2'（旧实现根本不认，WOFF2 直链一律被判非字体）。
final Uint8List kWoff2 =
    _bytes(<int>[0x77, 0x4F, 0x46, 0x32, 0x00, 0x01, 0x00, 0x00]);
final Uint8List kTtc = _bytes(<int>[0x74, 0x74, 0x63, 0x66]);

Future<File> _write(Directory dir, String name, List<int> bytes) async {
  final File f = File(p.join(dir.path, name));
  await f.writeAsBytes(bytes);
  return f;
}

Uint8List _zipOf(Map<String, List<int>> entries) {
  final Archive archive = Archive();
  entries.forEach((String name, List<int> bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  late Directory tmp;
  late Directory fontsDir;
  late FontDownloadService service;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_font_dl_');
    fontsDir = Directory(p.join(tmp.path, 'custom_fonts'));
    service = FontDownloadService(fontsDir: fontsDir, dioFactory: () => Dio());
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('detectFontExtension', () {
    test('识别 ttf / otf / woff / woff2 / ttc', () async {
      final List<(String, Uint8List)> cases = <(String, Uint8List)>[
        ('.ttf', kTtf),
        ('.otf', kOtf),
        ('.woff', kWoff),
        ('.woff', kWoffOtto),
        ('.woff2', kWoff2),
        ('.ttc', kTtc),
      ];
      for (int i = 0; i < cases.length; i++) {
        final (String ext, Uint8List bytes) = cases[i];
        final File f = await _write(tmp, 'probe$i.bin', bytes);
        expect(
          await FontDownloadService.detectFontExtension(f),
          ext,
          reason: 'case $i → $ext',
        );
      }
    });

    test('非字体 / 过短文件返回 null', () async {
      final File html = await _write(tmp, 'a.html', utf8.encode('<html>'));
      expect(await FontDownloadService.detectFontExtension(html), isNull);
      final File short = await _write(tmp, 'short', <int>[0x00, 0x01]);
      expect(await FontDownloadService.detectFontExtension(short), isNull);
      expect(await FontDownloadService.isValidFontFile(html), isFalse);
    });

    test('isZipFile 只认 PK\\x03\\x04', () async {
      final File zip = await _write(
        tmp,
        'a.zip',
        _zipOf(<String, List<int>>{'x.ttf': kTtf}),
      );
      expect(await FontDownloadService.isZipFile(zip), isTrue);
      final File ttf = await _write(tmp, 'a.ttf', kTtf);
      expect(await FontDownloadService.isZipFile(ttf), isFalse);
    });
  });

  group('importFile', () {
    test('单字体文件复制为 <name>_<epochMs><ext>', () async {
      final File src = await _write(tmp, 'KleeOne-Regular.ttf', kTtf);
      final List<ImportedFontFile> out = await service.importFile(
        src,
        fileName: 'KleeOne-Regular.ttf',
      );
      expect(out, hasLength(1));
      expect(out.single.name, 'KleeOne-Regular');
      final String base = p.basename(out.single.path);
      expect(RegExp(r'^KleeOne-Regular_\d+\.ttf$').hasMatch(base), isTrue,
          reason: base);
      expect(p.dirname(out.single.path), fontsDir.path);
      expect(await File(out.single.path).readAsBytes(), kTtf);
      // 源文件不动。
      expect(await src.exists(), isTrue);
    });

    test('overrideName 决定显示名；无扩展名文件按魔数定扩展名', () async {
      final File src = await _write(tmp, 'download', kWoff2);
      final List<ImportedFontFile> out = await service.importFile(
        src,
        fileName: 'download',
        overrideName: 'Klee One',
      );
      expect(out.single.name, 'Klee One');
      expect(p.extension(out.single.path), '.woff2');
    });

    test('zip 解出全部字体条目，忽略非字体条目', () async {
      final File zip = await _write(
        tmp,
        'pack.zip',
        _zipOf(<String, List<int>>{
          'Foo-Regular.ttf': kTtf,
          'sub/Foo-Bold.otf': kOtf,
          'OFL.txt': utf8.encode('license'),
        }),
      );
      final List<ImportedFontFile> out = await service.importFile(
        zip,
        fileName: 'pack.zip',
      );
      expect(
        out.map((ImportedFontFile f) => f.name).toList(),
        <String>['Foo-Regular', 'Foo-Bold'],
      );
      for (final ImportedFontFile f in out) {
        expect(await File(f.path).exists(), isTrue);
      }
    });

    test('zip + overrideName 只挑 regular/[wght] 那一份并按名落地', () async {
      final File zip = await _write(
        tmp,
        'pack.zip',
        _zipOf(<String, List<int>>{
          'Foo-Bold.ttf': kOtf,
          'Foo-Regular.ttf': kTtf,
        }),
      );
      final List<ImportedFontFile> out = await service.importFile(
        zip,
        fileName: 'pack.zip',
        overrideName: 'Foo Bar',
      );
      expect(out, hasLength(1));
      expect(out.single.name, 'Foo Bar');
      expect(p.basename(out.single.path), startsWith('Foo Bar_'));
      expect(await File(out.single.path).readAsBytes(), kTtf);
    });

    test('既不是字体也不是 zip → FormatException', () async {
      final File junk = await _write(tmp, 'x.7z', utf8.encode('7z?'));
      expect(
        () => service.importFile(junk, fileName: 'x.7z'),
        throwsA(isA<FormatException>()),
      );
      expect(fontsDir.existsSync() ? fontsDir.listSync() : <FileSystemEntity>[],
          isEmpty);
    });
  });

  group('download', () {
    late HttpServer server;
    late String base;
    final List<String> hits = <String>[];

    setUp(() async {
      hits.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((HttpRequest req) async {
        hits.add(req.uri.path);
        switch (req.uri.path) {
          case '/html':
            req.response.headers.contentType = ContentType.html;
            req.response.write('<html>not a font</html>');
          case '/missing':
            req.response.statusCode = HttpStatus.notFound;
          case '/font.ttf':
            req.response.headers.contentType = ContentType('font', 'ttf');
            req.response.add(kTtf);
          case '/pack.zip':
            req.response.headers.contentType =
                ContentType('application', 'zip');
            req.response.add(_zipOf(<String, List<int>>{
              'Bar-Regular.ttf': kTtf,
            }));
          default:
            req.response.statusCode = HttpStatus.notFound;
        }
        await req.response.close();
      });
    });

    tearDown(() async => server.close(force: true));

    test('HTML / 404 源被跳过，回退到真字体源', () async {
      final List<double?> progress = <double?>[];
      final FontDownloadResult r = await service.download(
        <String>['$base/html', '$base/missing', '$base/font.ttf'],
        overrideName: 'Klee One',
        onProgress: progress.add,
      );
      expect(r.error, isNull);
      expect(r.cancelled, isFalse);
      expect(r.files, hasLength(1));
      expect(r.files.single.name, 'Klee One');
      expect(p.extension(r.files.single.path), '.ttf');
      expect(await File(r.files.single.path).readAsBytes(), kTtf);
      expect(hits, <String>['/html', '/missing', '/font.ttf']);
      // 每换一源先清一次进度。
      expect(progress.where((double? v) => v == null).length, 3);
      // 临时文件已清理，目录里只剩落地字体。
      expect(
          fontsDir.listSync().map((FileSystemEntity e) => p.basename(e.path)),
          isNot(contains(startsWith('_tmp_'))));
    });

    test('全部源都不是字体 → error，且不落任何文件', () async {
      final FontDownloadResult r = await service.download(
        <String>['$base/html', '$base/missing'],
      );
      expect(r.error, isNotNull);
      expect(r.files, isEmpty);
      expect(r.succeeded, isFalse);
      expect(fontsDir.listSync(), isEmpty);
    });

    test('zip 源按 overrideName 解出一份', () async {
      final FontDownloadResult r = await service.download(
        <String>['$base/pack.zip'],
        overrideName: 'Bar',
      );
      expect(r.succeeded, isTrue);
      expect(r.files.single.name, 'Bar');
      expect(p.basename(r.files.single.path), startsWith('Bar_'));
    });

    test('取消 → cancelled，不报错不落地', () async {
      final CancelToken token = CancelToken()..cancel();
      final FontDownloadResult r = await service.download(
        <String>['$base/font.ttf'],
        cancelToken: token,
      );
      expect(r.cancelled, isTrue);
      expect(r.error, isNull);
      expect(r.files, isEmpty);
    });
  });
}

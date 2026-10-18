// CRC-32 与内存 / 整文件 SHA-256 的调用点基准：现有 Dart 写法 vs native/fushi_compute。
//
// 用法（在 packages/fushi_engine 下；AOT 更接近 app：先 dart compile exe）：
//   dart run benchmark/crc32_sha256_benchmark.dart [临时目录=系统临时目录]
//
// 每项 3 次取中位数，两条路径结果必须一致：
// - EPUB 解析：`ZipDecoder().decodeBytes(bytes, verify: true)` + 取出全部条目内容（解压缩），
//   对比 `verify: false` + 同样取内容 + 逐条 ffcCrc32（epub_parser 的三处调用）。合成 EPUB：
//   200 个 deflate 的 XHTML（约 40 MiB 文本）+ 40 张 1 MiB 不可压缩「图片」。
// - 漫画页 CRC：archive 的 `getCrc32(content)` vs ffcCrc32，200 页 × 2 MiB（manga_archive_importer）。
// - EPUB 构建 CRC：fushi_audio epub_builder 手写的逐字节 `_crc32`（原样复制）vs ffcCrc32。
// - SHA-256：内存 64 MiB `sha256.convert` vs ffcSha256Bytes；整文件 256 MiB
//   `sha256.bind(openRead())` vs ffcSha256File（异步）。
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fushi_compute/fushi_compute.dart';

Future<void> main(List<String> args) async {
  final Directory root = args.isNotEmpty
      ? Directory(args[0])
      : Directory.systemTemp;
  FushiCompute.require();
  stdout.writeln(
    '${Platform.operatingSystem} dart ${Platform.version.split(' ').first}',
  );
  final Random random = Random(20261018);

  // ── EPUB 解析（解压 + CRC 校验）────────────────────────────────────────────
  final Uint8List epub = _syntheticEpub(random);
  stdout.writeln('synthetic EPUB: ${epub.length} bytes');
  final int dartEpub = _median(
    'EPUB decode verify:true (Dart CRC)',
    () => _decodeDartVerify(epub),
  );
  final int nativeEpub = _median(
    'EPUB decode verify:false + ffcCrc32',
    () => _decodeNativeVerify(epub),
  );
  _same(dartEpub, nativeEpub, 'epub');

  // ── 漫画页 CRC ─────────────────────────────────────────────────────────────
  final List<Uint8List> pages = List<Uint8List>.generate(
    200,
    (int i) => _randomBytes(random, 2 << 20),
  );
  final int dartPages = _median('manga pages getCrc32 (400 MiB)', () {
    int x = 0;
    for (final Uint8List page in pages) {
      x ^= getCrc32(page);
    }
    return x;
  });
  final int nativePages = _median('manga pages ffcCrc32 (400 MiB)', () {
    int x = 0;
    for (final Uint8List page in pages) {
      x ^= ffcCrc32(page);
    }
    return x;
  });
  _same(dartPages, nativePages, 'manga');

  // ── epub_builder 的手写 CRC ────────────────────────────────────────────────
  final int dartBuilder = _median('epub_builder _crc32 (400 MiB)', () {
    int x = 0;
    for (final Uint8List page in pages) {
      x ^= _builderCrc32(page);
    }
    return x;
  });
  _same(dartBuilder, nativePages, 'epub_builder');

  // ── SHA-256 ───────────────────────────────────────────────────────────────
  final Uint8List blob = _randomBytes(random, 64 << 20);
  final String dartBlob = _median(
    'sha256.convert 64 MiB',
    () => sha256.convert(blob).toString(),
  );
  final String nativeBlob = _median(
    'ffcSha256Bytes 64 MiB',
    () => ffcSha256Bytes(blob),
  );
  _same(dartBlob, nativeBlob, 'sha256 bytes');

  final Directory dir = await root.createTemp('fushi-crc-bench-');
  try {
    final File file = File('${dir.path}${Platform.pathSeparator}f.bin');
    final RandomAccessFile out = await file.open(mode: FileMode.write);
    for (int i = 0; i < 4; i++) {
      await out.writeFrom(blob);
    }
    await out.close();
    await file.readAsBytes(); // 预热页缓存
    final String dartFile = await _medianAsync(
      'sha256.bind(openRead()) 256 MiB file',
      () async => (await sha256.bind(file.openRead()).first).toString(),
    );
    final String nativeFile = await _medianAsync(
      'ffcSha256File 256 MiB file',
      () => ffcSha256File(file.path),
    );
    _same(dartFile, nativeFile, 'sha256 file');
  } finally {
    await dir.delete(recursive: true);
  }
}

Uint8List _syntheticEpub(Random random) {
  final Archive archive = Archive();
  archive.addFile(
    ArchiveFile.noCompress(
      'mimetype',
      20,
      ascii.encode('application/epub+zip'),
    ),
  );
  const String sentence =
      '吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。'
      '何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。';
  for (int i = 0; i < 200; i++) {
    final StringBuffer text = StringBuffer('<html><body>');
    while (text.length < 70000) {
      text.write('<p>$sentence ${random.nextInt(1 << 30)}</p>');
    }
    text.write('</body></html>');
    final List<int> bytes = utf8.encode(text.toString());
    archive.addFile(ArchiveFile('OEBPS/text/c$i.xhtml', bytes.length, bytes));
  }
  for (int i = 0; i < 40; i++) {
    final Uint8List image = _randomBytes(random, 1 << 20);
    archive.addFile(ArchiveFile('OEBPS/image/p$i.jpg', image.length, image));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

int _decodeDartVerify(Uint8List bytes) {
  final Archive archive = ZipDecoder().decodeBytes(bytes, verify: true);
  int total = 0;
  for (final ArchiveFile f in archive) {
    total += (f.content as List<int>).length;
  }
  return total;
}

int _decodeNativeVerify(Uint8List bytes) {
  final Archive archive = ZipDecoder().decodeBytes(bytes);
  int total = 0;
  for (final ArchiveFile f in archive) {
    final List<int> content = f.content as List<int>;
    if (ffcCrc32(content) != f.crc32) {
      throw ArchiveException('Invalid CRC for file in archive.');
    }
    total += content.length;
  }
  return total;
}

final Uint32List _table = () {
  final Uint32List t = Uint32List(256);
  for (int n = 0; n < 256; n++) {
    int c = n;
    for (int k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

/// fushi_audio epub_builder.dart 的 `_crc32` 原样。
int _builderCrc32(Uint8List data) {
  int crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc = _table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

Uint8List _randomBytes(Random random, int length) {
  final Uint8List out = Uint8List(length);
  final ByteData view = ByteData.sublistView(out);
  for (int i = 0; i + 4 <= length; i += 4) {
    view.setUint32(i, random.nextInt(1 << 32));
  }
  return out;
}

void _same(Object a, Object b, String what) {
  if (a != b) throw StateError('$what mismatch: $a vs $b');
}

T _median<T>(String label, T Function() run) {
  final List<int> times = <int>[];
  late T result;
  for (int i = 0; i < 3; i++) {
    final Stopwatch sw = Stopwatch()..start();
    result = run();
    times.add(sw.elapsedMilliseconds);
  }
  times.sort();
  stdout.writeln('$label: median ${times[1]} ms runs=$times');
  return result;
}

Future<T> _medianAsync<T>(String label, Future<T> Function() run) async {
  final List<int> times = <int>[];
  late T result;
  for (int i = 0; i < 3; i++) {
    final Stopwatch sw = Stopwatch()..start();
    result = await run();
    times.add(sw.elapsedMilliseconds);
  }
  times.sort();
  stdout.writeln('$label: median ${times[1]} ms runs=$times');
  return result;
}

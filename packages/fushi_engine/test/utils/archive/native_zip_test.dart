import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:fushi_engine/utils/archive/native_zip.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 原生 zlib 的 zip 读写通道（替代 archive 3.6.1 的纯 Dart Inflate / Deflate）。
///
/// 钉住：产物能被 archive 校验 CRC 解开（与旧读端兼容）、archive 纯 Dart 产出的
/// DEFLATE 条目能被原生通道解开（与旧写端兼容）、跨多个 4 MB 读块逐字节一致、
/// 已压缩格式 / 不变小的内容走 STORE、zip-slip 条目被跳过、坏数据抛错不静默。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_native_zip_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// 前 [randomBytes] 字节伪随机（不可压，让压缩后仍跨多个读块），其余是可压的文本。
  Uint8List payload(int totalBytes, {int randomBytes = 0, int seed = 1017}) {
    final Random random = Random(seed);
    final Uint8List bytes = Uint8List(totalBytes);
    for (int i = 0; i < totalBytes; i++) {
      bytes[i] = i < randomBytes ? random.nextInt(256) : 0x61 + (i % 23);
    }
    return bytes;
  }

  /// 解码并校验每个条目的 CRC（坏 CRC 抛错）。注意 verify 会先解压条目，解完
  /// `compressionType` 被置成 STORE，所以压缩方式要用 [methodOf] 读。
  Archive decodeVerified(String zipPath) =>
      ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync(), verify: true);

  /// 条目在 zip 里的压缩方式（不解压、不校验）。
  int? methodOf(List<int> zipBytes, String name) => ZipDecoder()
      .decodeBytes(zipBytes)
      .files
      .singleWhere((ArchiveFile f) => f.name == name)
      .compressionType;

  ArchiveFile entryNamed(Archive archive, String name) =>
      archive.files.singleWhere((ArchiveFile f) => f.name == name);

  test(
    'addFileNativeDeflate：可压文件走 DEFLATE、图片与空文件走 STORE，archive 校验 CRC 解开逐字一致',
    () {
      final Uint8List text = payload(
        9 * 1024 * 1024,
        randomBytes: 5 * 1024 * 1024,
      );
      final File textFile = File(p.join(tmp.path, 'term_bank_1.json'))
        ..writeAsBytesSync(text);
      final Uint8List jpeg = payload(64 * 1024);
      final File jpegFile = File(p.join(tmp.path, 'cover.jpg'))
        ..writeAsBytesSync(jpeg);
      final File emptyFile = File(p.join(tmp.path, 'empty.txt'))
        ..writeAsBytesSync(const <int>[]);
      final Uint8List noise = payload(4096, randomBytes: 4096);
      final File noiseFile = File(p.join(tmp.path, 'noise.bin'))
        ..writeAsBytesSync(noise);

      final String zipPath = p.join(tmp.path, 'out.zip');
      final ZipFileEncoder encoder = ZipFileEncoder()..create(zipPath);
      addFileNativeDeflate(encoder, textFile, 'dict/term_bank_1.json');
      addFileNativeDeflate(encoder, jpegFile, 'cover.jpg');
      addFileNativeDeflate(encoder, emptyFile, 'empty.txt');
      addFileNativeDeflate(encoder, noiseFile, 'noise.bin');
      encoder.closeSync();

      final Archive archive = decodeVerified(zipPath);
      final ArchiveFile textEntry = entryNamed(
        archive,
        'dict/term_bank_1.json',
      );
      expect(
        methodOf(File(zipPath).readAsBytesSync(), 'dict/term_bank_1.json'),
        ArchiveFile.DEFLATE,
      );
      expect(textEntry.content, text);
      expect(File(zipPath).lengthSync(), lessThan(text.length));

      final ArchiveFile jpegEntry = entryNamed(archive, 'cover.jpg');
      expect(
        methodOf(File(zipPath).readAsBytesSync(), 'cover.jpg'),
        ArchiveFile.STORE,
      );
      expect(jpegEntry.content, jpeg);

      expect(entryNamed(archive, 'empty.txt').content, isEmpty);

      // 压缩后不变小 → STORE（不付解压代价换不来体积）。
      final ArchiveFile noiseEntry = entryNamed(archive, 'noise.bin');
      expect(
        methodOf(File(zipPath).readAsBytesSync(), 'noise.bin'),
        ArchiveFile.STORE,
      );
      expect(noiseEntry.content, noise);
    },
  );

  test('addDirectoryNativeDeflate：条目集合与命名对齐 archive 的 addDirectory', () {
    final Directory src = Directory(p.join(tmp.path, 'book'))..createSync();
    File(
      p.join(src.path, 'mimetype'),
    ).writeAsStringSync('application/epub+zip');
    File(p.join(src.path, 'OEBPS', 'text', 'ch1.xhtml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('<p>${'本文' * 2000}</p>');
    Directory(p.join(src.path, 'empty_dir')).createSync();

    final String nativePath = p.join(tmp.path, 'native.zip');
    final ZipFileEncoder nativeEncoder = ZipFileEncoder()..create(nativePath);
    addDirectoryNativeDeflate(nativeEncoder, src, includeDirName: false);
    nativeEncoder.closeSync();

    final String legacyPath = p.join(tmp.path, 'legacy.zip');
    ZipFileEncoder().zipDirectory(src, filename: legacyPath);

    Set<String> names(Archive a) =>
        a.files.map((ArchiveFile f) => f.name).toSet();
    final Archive native = decodeVerified(nativePath);
    expect(names(native), names(decodeVerified(legacyPath)));
    expect(
      utf8.decode(
        entryNamed(native, 'OEBPS/text/ch1.xhtml').content as List<int>,
      ),
      '<p>${'本文' * 2000}</p>',
    );
    // 20 字节的 mimetype 压了反而变大 → STORE（EPUB 规范也要求它不压缩）。
    expect(
      methodOf(File(nativePath).readAsBytesSync(), 'mimetype'),
      ArchiveFile.STORE,
    );
  });

  test(
    'writeZipEntryStreaming：解开 archive 纯 Dart 写出的 DEFLATE 条目，跨多块逐字一致、逐块回报进度',
    () {
      final Uint8List data = payload(
        11 * 1024 * 1024,
        randomBytes: 6 * 1024 * 1024,
      );
      final Archive source = Archive()
        ..addFile(ArchiveFile('big.db', data.length, data));
      final String zipPath = p.join(tmp.path, 'legacy_deflate.zip');
      File(zipPath).writeAsBytesSync(ZipEncoder().encode(source)!);

      final InputFileStream input = InputFileStream(zipPath);
      try {
        final ArchiveFile entry = ZipDecoder().decodeBuffer(input).files.single;
        expect(entry.compressionType, ArchiveFile.DEFLATE);

        final String outPath = p.join(tmp.path, 'out', 'big.db');
        final List<int> reported = <int>[];
        final int written = extractZipEntryToFile(
          entry,
          outPath,
          onBytes: reported.add,
        );

        expect(written, data.length);
        expect(reported.length, greaterThan(1), reason: '进度应随解压逐块推进');
        expect(reported.fold<int>(0, (int a, int b) => a + b), data.length);
        expect(File(outPath).readAsBytesSync(), data);

        // 原始窗口被读过之后再写一次：必须从头读，而不是接着读出空 / 截断。
        final String again = p.join(tmp.path, 'again.db');
        expect(extractZipEntryToFile(entry, again), data.length);
        expect(File(again).readAsBytesSync(), data);
      } finally {
        input.closeSync();
      }
    },
  );

  test('nativeDeflatedArchiveFile 交给 ZipEncoder 原样透传，CRC 正确', () {
    final List<int> json = utf8.encode(
      jsonEncode(<String, Object?>{
        'notes': List<int>.generate(5000, (int i) => i),
      }),
    );
    final Uint8List noise = payload(2048, randomBytes: 2048);
    final Archive archive = Archive()
      ..addFile(nativeDeflatedArchiveFile('collection.json', json))
      ..addFile(nativeDeflatedArchiveFile('0', noise))
      ..addFile(nativeDeflatedArchiveFile('empty', const <int>[]));
    final List<int> zip = ZipEncoder().encode(archive)!;

    final Archive decoded = ZipDecoder().decodeBytes(zip, verify: true);
    final ArchiveFile jsonEntry = entryNamed(decoded, 'collection.json');
    expect(methodOf(zip, 'collection.json'), ArchiveFile.DEFLATE);
    expect(jsonEntry.content, json);
    expect(methodOf(zip, '0'), ArchiveFile.STORE);
    expect(entryNamed(decoded, '0').content, noise);
    expect(entryNamed(decoded, 'empty').content, isEmpty);
  });

  test('extractZipFileToDirectory：保留目录层级，越界条目跳过', () {
    final Uint8List mdd = payload(5 * 1024 * 1024, randomBytes: 1024 * 1024);
    final Archive archive = Archive()
      ..addFile(ArchiveFile('A/a.mdx', 3, utf8.encode('mdx')))
      ..addFile(ArchiveFile('A/a.mdd', mdd.length, mdd))
      ..addFile(ArchiveFile('B/style.css', 4, utf8.encode('body')))
      ..addFile(ArchiveFile('../escape.txt', 4, utf8.encode('evil')));
    final String zipPath = p.join(tmp.path, 'bundle.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive)!);

    final String out = p.join(tmp.path, 'work');
    extractZipFileToDirectory(zipPath, out);

    expect(File(p.join(out, 'A', 'a.mdx')).readAsStringSync(), 'mdx');
    expect(File(p.join(out, 'A', 'a.mdd')).readAsBytesSync(), mdd);
    expect(File(p.join(out, 'B', 'style.css')).readAsStringSync(), 'body');
    expect(File(p.join(tmp.path, 'escape.txt')).existsSync(), isFalse);
  });

  test('DEFLATE 数据损坏时抛错，不静默写出半截文件当成功', () {
    final Uint8List data = payload(256 * 1024);
    final Archive archive = Archive()
      ..addFile(nativeDeflatedArchiveFile('x.txt', data));
    final Uint8List zip = Uint8List.fromList(ZipEncoder().encode(archive)!);
    // 本地文件头 30 字节 + 文件名 5 字节之后就是压缩数据：把开头一段改成垃圾。
    for (int i = 35; i < 35 + 64; i++) {
      zip[i] = 0xff;
    }
    final ArchiveFile entry = ZipDecoder().decodeBytes(zip).files.single;
    expect(
      () => writeZipEntryStreaming(entry, OutputStream()),
      throwsA(isA<FormatException>()),
    );
  });

  test('DEFLATE 流被截断（dart:io 不报错只产出半截）时按条目大小核对抛错', () {
    final Uint8List data = payload(256 * 1024);
    final List<int> compressed = ZLibCodec(raw: true).encode(data);
    final ArchiveFile entry = ArchiveFile(
      'x.txt',
      data.length,
      InputStream(compressed.sublist(0, compressed.length ~/ 2)),
      ArchiveFile.DEFLATE,
    );
    expect(
      () => writeZipEntryStreaming(entry, OutputStream()),
      throwsA(isA<FormatException>()),
    );
  });
}

// 剩余 CRC-32 调用点改走 native/fushi_compute 的基准：旧写法（archive 纯 Dart
// `getCrc32` / `package:crypto`）vs 新写法（`ffcCrc32` / `FfcSha256Hasher`）。
//
// 用法（在 packages/fushi_engine 下；AOT 更接近 app：先 dart compile exe，再设
// FUSHI_COMPUTE_LIB 指向 native/fushi_compute/prebuilt/<平台>/ 下的库）：
//   dart compile exe benchmark/zip_crc_callsites_benchmark.dart -o <exe>
//   FUSHI_COMPUTE_LIB=<库> <exe> [临时目录=系统临时目录]
//
// 每项 3 次取中位数，新旧结果必须一致：
// 1. native_zip `nativeDeflatedArchiveFile`：内存 64 MiB 一次性算 CRC。
// 2. native_zip `addFileNativeDeflate`：4 MiB 读块链式 CRC，共 256 MiB（只量 CRC，
//    deflate 部分两边相同不计）。
// 3. 备份 / 音频同步包的 STORE：`ZipFileEncoder.addFile(file, name, STORE)` vs
//    `addFileStored`，4 × 128 MiB 不可压文件写进一个 zip（端到端，含读写盘）。
// 4. 备份元数据条目：`ArchiveFile(meta)`（纯 Dart Deflate + CRC）vs
//    `nativeDeflatedArchiveFile`，64 KiB JSON（小对象：看跨 FFI 有没有变慢）。
// 5. 复习备份 `_deflateFile`：`openRead().map(CRC+SHA).transform(ZLibEncoder)`
//    落盘，64 MiB JSONL（端到端）。
// 6. AACS KEYDB.cfg：解压后正文整块 CRC，16 MiB 与 256 KiB 两档。
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' hide ZLibEncoder;
import 'package:crypto/crypto.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/utils/archive/native_zip.dart';

Future<void> main(List<String> args) async {
  final Directory root = args.isNotEmpty
      ? Directory(args[0])
      : Directory.systemTemp;
  FushiCompute.require();
  stdout.writeln(
    '${Platform.operatingSystem} dart ${Platform.version.split(' ').first}',
  );
  final Random random = Random(20261018);
  final Directory dir = await root.createTemp('fushi-zip-crc-bench-');
  try {
    // ── 1. nativeDeflatedArchiveFile：整块 CRC ───────────────────────────────
    final Uint8List blob = _randomBytes(random, 64 << 20);
    _same(
      _median('1 getCrc32 64 MiB', () => getCrc32(blob)),
      _median('1 ffcCrc32 64 MiB', () => ffcCrc32(blob)),
      'whole crc',
    );

    // ── 2. addFileNativeDeflate：4 MiB 读块链式 CRC ─────────────────────────
    final List<Uint8List> chunks = <Uint8List>[
      for (int i = 0; i < 16; i++)
        Uint8List.sublistView(
          blob,
          (i % 16) * (4 << 20),
          (i % 16 + 1) * (4 << 20),
        ),
    ];
    int chained(int Function(List<int>, int) crc32) {
      int crc = 0;
      for (int round = 0; round < 4; round++) {
        for (final Uint8List c in chunks) {
          crc = crc32(c, crc);
        }
      }
      return crc;
    }

    _same(
      _median(
        '2 getCrc32 chained 4 MiB x 64 (256 MiB)',
        () => chained((List<int> b, int c) => getCrc32(b, c)),
      ),
      _median(
        '2 ffcCrc32 chained 4 MiB x 64 (256 MiB)',
        () => chained((List<int> b, int c) => ffcCrc32(b, c)),
      ),
      'chained crc',
    );

    // ── 3. STORE 端到端 ──────────────────────────────────────────────────────
    final List<File> sources = <File>[];
    for (int i = 0; i < 4; i++) {
      final File f = File('${dir.path}${Platform.pathSeparator}src$i.m4b');
      final RandomAccessFile out = f.openSync(mode: FileMode.write);
      out.writeFromSync(blob);
      out.writeFromSync(blob);
      out.closeSync();
      sources.add(f);
      f.readAsBytesSync(); // 预热页缓存
    }
    final String zipPath = '${dir.path}${Platform.pathSeparator}out.zip';
    Future<String> storeZip(bool native) async {
      final ZipFileEncoder encoder = ZipFileEncoder()..create(zipPath);
      for (int i = 0; i < sources.length; i++) {
        if (native) {
          addFileStored(encoder, sources[i], 'resources/$i.m4b');
        } else {
          // 旧写法是 `await encoder.addFile(...)`，与同步 `_addFile` 同一条路径。
          await encoder.addFile(
            sources[i],
            'resources/$i.m4b',
            ZipFileEncoder.STORE,
          );
        }
      }
      encoder.closeSync();
      return _crcsOf(zipPath);
    }

    _same(
      await _medianAsync(
        '3 ZipFileEncoder.addFile STORE 4 x 128 MiB',
        () => storeZip(false),
      ),
      await _medianAsync('3 addFileStored 4 x 128 MiB', () => storeZip(true)),
      'store zip',
    );
    File(zipPath).deleteSync();
    for (final File f in sources) {
      f.deleteSync();
    }

    // ── 4. 备份元数据条目（小对象）──────────────────────────────────────────
    final List<int> meta = utf8.encode(
      jsonEncode(<String, Object?>{
        'entries': <Map<String, Object?>>[
          for (int i = 0; i < 700; i++)
            <String, Object?>{'path': 'fushi_books/b$i/x.epub', 'size': i},
        ],
      }),
    );
    stdout.writeln('meta json: ${meta.length} bytes');
    int encodeMeta(ArchiveFile Function() make) {
      int total = 0;
      for (int i = 0; i < 200; i++) {
        final ZipEncoder enc = ZipEncoder();
        final OutputStream out = OutputStream();
        enc.startEncode(out);
        enc.addFile(make());
        enc.endEncode();
        total += ZipDecoder()
            .decodeBytes(out.getBytes(), verify: true)
            .files
            .single
            .size;
      }
      return total;
    }

    _same(
      _median(
        '4 ArchiveFile(meta) Dart Deflate+CRC x 200',
        () => encodeMeta(
          () => ArchiveFile('backup_meta.json', meta.length, meta),
        ),
      ),
      _median(
        '4 nativeDeflatedArchiveFile(meta) x 200',
        () => encodeMeta(
          () => nativeDeflatedArchiveFile('backup_meta.json', meta),
        ),
      ),
      'meta',
    );

    // ── 5. 复习备份 _deflateFile ────────────────────────────────────────────
    final File events = File(
      '${dir.path}${Platform.pathSeparator}events.jsonl',
    );
    final IOSink sink = events.openWrite();
    int written = 0;
    int n = 0;
    while (written < (64 << 20)) {
      final String line =
          '{"id":"${random.nextInt(1 << 32)}","kind":"note.update","n":$n,'
          '"fields":{"Expression":"単語$n","Sentence":"単語$n を使った例文です。"}}\n';
      final List<int> bytes = utf8.encode(line);
      sink.add(bytes);
      written += bytes.length;
      n++;
    }
    await sink.close();
    events.readAsBytesSync();
    stdout.writeln('events.jsonl: $written bytes');
    final File deflated = File('${events.path}.deflate');
    final String oldDeflate = await _medianAsync(
      '5 _deflateFile old (getCrc32 + crypto) 64 MiB',
      () async => (await _deflateFileOld(events, deflated)).toString(),
    );
    final String newDeflate = await _medianAsync(
      '5 _deflateFile new (ffcCrc32 + FfcSha256Hasher) 64 MiB',
      () async => (await _deflateFileNew(events, deflated)).toString(),
    );
    _same(oldDeflate, newDeflate, 'deflateFile');

    // ── 6. AACS KEYDB.cfg 整块 CRC ─────────────────────────────────────────
    for (final int size in <int>[16 << 20, 256 << 10]) {
      final Uint8List keydb = Uint8List.sublistView(blob, 0, size);
      final int reps = size >= (1 << 20) ? 1 : 64;
      _same(
        _median('6 getCrc32 keydb $size B x $reps', () {
          int x = 0;
          for (int i = 0; i < reps; i++) {
            x ^= getCrc32(keydb) + i;
          }
          return x;
        }),
        _median('6 ffcCrc32 keydb $size B x $reps', () {
          int x = 0;
          for (int i = 0; i < reps; i++) {
            x ^= ffcCrc32(keydb) + i;
          }
          return x;
        }),
        'keydb $size',
      );
    }
  } finally {
    await dir.delete(recursive: true);
  }
}

/// srs_backup_store.dart `_deflateFile` 改动前原样（返回 size/crc/sha）。
Future<(int, int, String)> _deflateFileOld(File src, File dst) async {
  int size = 0;
  int crc = 0;
  final _DigestCapture digest = _DigestCapture();
  final ByteConversionSink sha = sha256.startChunkedConversion(digest);
  final IOSink out = dst.openWrite();
  try {
    await out.addStream(
      src
          .openRead()
          .map((List<int> chunk) {
            size += chunk.length;
            crc = getCrc32(chunk, crc);
            sha.add(chunk);
            return chunk;
          })
          .transform(ZLibEncoder(raw: true)),
    );
  } finally {
    await out.close();
  }
  sha.close();
  return (size, crc, digest.value.toString());
}

/// srs_backup_store.dart `_deflateFile` 改动后。
Future<(int, int, String)> _deflateFileNew(File src, File dst) async {
  int size = 0;
  int crc = 0;
  final FfcSha256Hasher sha = FfcSha256Hasher.create();
  try {
    final IOSink out = dst.openWrite();
    try {
      await out.addStream(
        src
            .openRead()
            .map((List<int> chunk) {
              size += chunk.length;
              crc = ffcCrc32(chunk, crc);
              sha.add(chunk);
              return chunk;
            })
            .transform(ZLibEncoder(raw: true)),
      );
    } finally {
      await out.close();
    }
    return (size, crc, sha.finishHex());
  } finally {
    sha.close();
  }
}

class _DigestCapture implements Sink<Digest> {
  Digest? _value;
  Digest get value => _value!;
  @override
  void add(Digest data) => _value = data;
  @override
  void close() {}
}

/// zip 里每个条目头记录的 CRC（用来比对新旧产物）。
String _crcsOf(String zipPath) {
  final InputFileStream input = InputFileStream(zipPath);
  try {
    return <String>[
      for (final ArchiveFile f in ZipDecoder().decodeBuffer(input).files)
        '${f.name}:${f.crc32}:${f.size}',
    ].join(',');
  } finally {
    input.closeSync();
  }
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

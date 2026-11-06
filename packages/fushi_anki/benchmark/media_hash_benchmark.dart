// Anki 媒体哈希基准：制卡媒体文件名（fushiAnkiMediaFilenameForBytes）与媒体去重
// （AnkiConnectRepository 的全文件 sha256 + 删除前逐字节复核）两个调用点。
//
// 用法（在 packages/fushi_anki 下；AOT 更接近 app，先编再跑）：
//   dart compile exe benchmark/media_hash_benchmark.dart -o <临时目录>/mhb.exe
//   FUSHI_COMPUTE_LIB=<仓库>/native/fushi_compute/prebuilt/windows-x64/fushi_compute.dll \
//     <临时目录>/mhb.exe [临时目录=系统临时目录]
// AOT 产物不是测试宿主，不会去仓库里找 prebuilt，必须用 FUSHI_COMPUTE_LIB 指库。
//
// 各项跑若干轮取中位数：
// - 文件名：单卡外字（50 × 3 KiB，逐个算）、封面（200 KiB）、句子音频（4 MiB）；
//   `current` 是 fushiAnkiMediaFilenameForBytes 当前实现（已走 Rust），`crypto` 是对照；
// - 去重哈希：大小撞车的候选逐个全文件 sha256（旧：readAsBytes + package:crypto；
//   ffcSha256File 1 MiB 流式；readAsBytes + ffcSha256Bytes）；
// - 删除前复核：两个等长同内容文件（旧：两次 readAsBytes + Dart 逐字节循环；
//   A：两次 readAsBytes + ffcBytesEqual；B：两路 1 MiB 流式 readInto + ffcBytesEqual）。
// 产品取法（AnkiConnectRepository._readsWhole）：≤ 1 MiB 整读（哈希 readAsBytes +
// ffcSha256Bytes、复核 A），更大的流式（ffcSha256File、复核 B）——小文件整读的异步 IO
// 次数最少，大文件流式不把两份视频整读进内存且不慢。
// 纯 Dart SHA-256（旧 _sha256Hex）已删除，删除前的读数见 PR 说明；package:crypto 只作对照。
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_compute/fushi_compute.dart';

Future<void> main(List<String> args) async {
  FushiCompute.require(); // 库缺失直接抛出带原因的异常。
  final Directory root = args.isNotEmpty
      ? Directory(args[0])
      : Directory.systemTemp;
  stdout.writeln(
    '${Platform.operatingSystem} dart ${Platform.version.split(' ').first}',
  );

  // ---- 文件名 ----
  final List<Uint8List> gaiji = List<Uint8List>.generate(
    50,
    (int i) => _bytes(3 * 1024, seed: i),
  );
  _sync('filename gaiji 50x3KiB  crypto', 21, () {
    for (final Uint8List b in gaiji) {
      crypto.sha256.convert(b).toString();
    }
  });
  _sync('filename gaiji 50x3KiB  current', 21, () {
    for (final Uint8List b in gaiji) {
      fushiAnkiMediaFilenameForBytes(
        prefix: 'fushi_dict_',
        bytes: b,
        sourceName: 'x.svg',
      );
    }
  });
  for (final (String label, int size) in <(String, int)>[
    ('cover 200KiB', 200 * 1024),
    ('audio 4MiB', 4 << 20),
  ]) {
    final Uint8List b = _bytes(size, seed: size);
    _sync('filename $label  crypto', 7, () {
      crypto.sha256.convert(b).toString();
    });
    _sync('filename $label  current', 7, () {
      fushiAnkiMediaFilenameForBytes(
        prefix: 'fushi_audio_',
        bytes: b,
        sourceName: 'x.mp3',
      );
    });
  }

  // ---- 去重 ----
  final Directory dir = await root.createTemp('fushi-anki-hash-bench-');
  try {
    final List<File> small = <File>[];
    for (int i = 0; i < 200; i++) {
      final File f = File('${dir.path}${Platform.pathSeparator}s$i.bin');
      f.writeAsBytesSync(_bytes(30 * 1024, seed: i));
      small.add(f);
    }
    final List<File> big = <File>[];
    for (int i = 0; i < 4; i++) {
      final File f = File('${dir.path}${Platform.pathSeparator}b$i.bin');
      f.writeAsBytesSync(_bytes(32 << 20, seed: 1000 + i));
      big.add(f);
    }
    for (final File f in <File>[...small, ...big]) {
      f.readAsBytesSync(); // 预热页缓存。
    }
    for (final (String label, List<File> files) in <(String, List<File>)>[
      ('dedup hash 200x30KiB', small),
      ('dedup hash 4x32MiB', big),
    ]) {
      await _async('$label  old readAsBytes+crypto', 5, () async {
        for (final File f in files) {
          crypto.sha256.convert(await f.readAsBytes()).toString();
        }
      });
      await _async('$label  new ffcSha256File', 5, () async {
        for (final File f in files) {
          await ffcSha256File(f.path);
        }
      });
      await _async('$label  alt readAsBytes+ffcSha256Bytes', 5, () async {
        for (final File f in files) {
          ffcSha256Bytes(await f.readAsBytes());
        }
      });
    }

    for (final (String label, int size) in <(String, int)>[
      ('verify 30KiB', 30 * 1024),
      ('verify 32MiB', 32 << 20),
    ]) {
      final Uint8List content = _bytes(size, seed: 7);
      final File a = File('${dir.path}${Platform.pathSeparator}va$size.bin')
        ..writeAsBytesSync(content);
      final File b = File('${dir.path}${Platform.pathSeparator}vb$size.bin')
        ..writeAsBytesSync(content);
      final int reps = size < (1 << 20) ? 200 : 1;
      final List<bool> results = <bool>[];
      Future<void> loop(Future<bool> Function() body) async {
        for (int i = 0; i < reps; i++) {
          results.add(await body());
        }
      }

      await _async('$label x$reps  old readAsBytes+Dart loop', 7, () async {
        await loop(() async {
          final Uint8List x = await a.readAsBytes();
          final Uint8List y = await b.readAsBytes();
          if (x.length != y.length) return false;
          for (int i = 0; i < x.length; i++) {
            if (x[i] != y[i]) return false;
          }
          return true;
        });
      });
      await _async(
        '$label x$reps  new A readAsBytes+ffcBytesEqual',
        7,
        () async {
          await loop(
            () async =>
                ffcBytesEqual(await a.readAsBytes(), await b.readAsBytes()),
          );
        },
      );
      await _async('$label x$reps  new B stream+ffcBytesEqual', 7, () async {
        await loop(() => _streamEqual(a, b));
      });
      if (results.contains(false)) throw StateError('equal files compared !=');
    }
  } finally {
    await dir.delete(recursive: true);
  }
}

Future<bool> _streamEqual(File a, File b) async {
  const int slice = 1 << 20;
  final RandomAccessFile ra = await a.open();
  try {
    final RandomAccessFile rb = await b.open();
    try {
      if (await ra.length() != await rb.length()) return false;
      final Uint8List ba = Uint8List(slice);
      final Uint8List bb = Uint8List(slice);
      while (true) {
        final int na = await ra.readInto(ba);
        final int nb = await rb.readInto(bb);
        if (na != nb) return false;
        if (na == 0) return true;
        if (!ffcBytesEqual(
          Uint8List.sublistView(ba, 0, na),
          Uint8List.sublistView(bb, 0, nb),
        )) {
          return false;
        }
      }
    } finally {
      await rb.close();
    }
  } finally {
    await ra.close();
  }
}

Uint8List _bytes(int length, {required int seed}) {
  final Random r = Random(seed);
  final Uint8List out = Uint8List(length);
  for (int i = 0; i < length; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

void _sync(String label, int runs, void Function() body) {
  body(); // 预热。
  final List<int> us = <int>[];
  for (int i = 0; i < runs; i++) {
    final Stopwatch sw = Stopwatch()..start();
    body();
    us.add(sw.elapsedMicroseconds);
  }
  _report(label, us);
}

Future<void> _async(
  String label,
  int runs,
  Future<void> Function() body,
) async {
  await body();
  final List<int> us = <int>[];
  for (int i = 0; i < runs; i++) {
    final Stopwatch sw = Stopwatch()..start();
    await body();
    us.add(sw.elapsedMicroseconds);
  }
  _report(label, us);
}

void _report(String label, List<int> us) {
  us.sort();
  final double ms = us[us.length ~/ 2] / 1000;
  stdout.writeln('${label.padRight(56)} median ${ms.toStringAsFixed(3)} ms');
}

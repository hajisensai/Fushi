// 整文件哈希吞吐基准：native/fushi_compute 的 ED2K 与 SHA-256，按 app 实际读法跑。
//
// 用法（在 packages/fushi_engine 下；AOT 更接近 app：先 dart compile exe）：
//   dart run benchmark/file_hash_benchmark.dart [MiB=1024] [临时目录=系统临时目录]
//
// 现场生成一个 MiB 大小的伪随机文件（测完删除），先整读一遍预热页缓存，然后各跑 3 次取中位数：
// - ED2K：hashAnidbFile 的 worker 读法（1 MiB 异步 readInto 直接读进原生缓冲区）；
// - SHA-256：VideoSourceFingerprint 的读法（ffcSha256FileSync）。
// SHA-256 另跑一遍 package:crypto 作对照（结果必须一致）。
// 改用 Rust 之前的纯 Dart 基线（2026-10-18，i5-12600KF / Windows 11，1 GiB，AOT）见
// native/fushi_compute/README.md「哈希域」。
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_compute/fushi_compute.dart';

Future<void> main(List<String> args) async {
  final int mib = args.isNotEmpty ? int.parse(args[0]) : 1024;
  final Directory root = args.length > 1
      ? Directory(args[1])
      : Directory.systemTemp;
  FushiCompute.require(); // 库缺失直接抛出带原因的异常。
  final Directory dir = await root.createTemp('fushi-hash-bench-');
  try {
    final File file = File('${dir.path}${Platform.pathSeparator}sample.bin');
    await _generate(file, mib);
    await _drain(file);
    stdout.writeln(
      'file: $mib MiB (${file.lengthSync()} bytes), '
      '${Platform.operatingSystem} dart ${Platform.version.split(' ').first}',
    );
    final (String, String?) ed2k = await _median(
      'ED2K native',
      mib,
      () => _nativeEd2k(file),
    );
    final String nativeSha = await _median(
      'SHA-256 native',
      mib,
      () async => ffcSha256FileSync(file.path),
    );
    final String dartSha = await _median(
      'SHA-256 package:crypto',
      mib,
      () async => (await sha256.bind(file.openRead()).first).toString(),
    );
    if (dartSha != nativeSha) {
      throw StateError('SHA-256 mismatch: $dartSha vs $nativeSha');
    }
    stdout.writeln('ed2k=${ed2k.$1} sha256=$nativeSha');
  } finally {
    await dir.delete(recursive: true);
  }
}

Future<T> _median<T>(String label, int mib, Future<T> Function() run) async {
  final List<int> times = <int>[];
  late T result;
  for (int i = 0; i < 3; i++) {
    final Stopwatch sw = Stopwatch()..start();
    result = await run();
    times.add(sw.elapsedMilliseconds);
  }
  times.sort();
  final int ms = max(times[1], 1);
  stdout.writeln(
    '$label: median $ms ms '
    '(${(mib * 1000 / ms).toStringAsFixed(0)} MiB/s) runs=$times',
  );
  return result;
}

Future<(String, String?)> _nativeEd2k(File file) async {
  final FfcEd2kHasher hasher = FfcEd2kHasher.create();
  try {
    final RandomAccessFile input = await file.open();
    try {
      while (true) {
        final int count = await input.readInto(hasher.buffer);
        if (count == 0) break;
        hasher.update(count);
      }
    } finally {
      await input.close();
    }
    return hasher.finish();
  } finally {
    hasher.close();
  }
}

Future<void> _generate(File file, int mib) async {
  final Random random = Random(20261018);
  final Uint8List block = Uint8List(1 << 20);
  for (int i = 0; i < block.length; i++) {
    block[i] = random.nextInt(256);
  }
  final RandomAccessFile out = await file.open(mode: FileMode.write);
  try {
    for (int i = 0; i < mib; i++) {
      block[0] = i & 255;
      await out.writeFrom(block);
    }
  } finally {
    await out.close();
  }
}

Future<void> _drain(File file) async {
  await for (final List<int> _ in file.openRead()) {}
}

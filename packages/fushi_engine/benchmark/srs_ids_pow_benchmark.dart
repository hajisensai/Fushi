// SRS 确定性 ID（uuidV5 / hash53）、同步文件摘要与排行榜安装工作量证明的吞吐基准
// （native/fushi_compute）。改 Rust 之前的纯 Dart 基线见 native/fushi_compute/README.md。
//
// 用法（在 packages/fushi_engine 下；AOT 更接近 app：先 dart compile exe）：
//   dart run benchmark/srs_ids_pow_benchmark.dart
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/leaderboard/install_identity.dart';
import 'package:fushi_srs/fushi_srs.dart';

int _median(void Function() f) {
  final List<int> t = <int>[];
  for (int i = 0; i < 3; i++) {
    final Stopwatch sw = Stopwatch()..start();
    f();
    t.add(sw.elapsedMilliseconds);
  }
  t.sort();
  return t[1];
}

void main() {
  FushiCompute.require();
  const int n = 100000;
  const String card = '0190a5c1-1234-7abc-8def-0123456789ab';
  final List<int> revlogs = <int>[
    for (int i = 0; i < n; i++) 1700000000000 + i,
  ];
  print(
    'uuidV5 single x$n: ${_median(() {
      for (final int r in revlogs) {
        SrsIds.importedRevlog(card, r);
      }
    })} ms',
  );
  print(
    'uuidV5 batch (importedRevlogs) x$n: '
    '${_median(() => SrsIds.importedRevlogs(card, revlogs))} ms',
  );
  final List<String> ids = SrsIds.importedRevlogs(card, revlogs);
  print(
    'hash53 single (ankiNumericId) x$n: ${_median(() {
      for (final String id in ids) {
        SrsIds.ankiNumericId(id);
      }
    })} ms',
  );
  print(
    'hash53 batch (ankiNumericIds) x$n: '
    '${_median(() => SrsIds.ankiNumericIds(ids))} ms',
  );
  for (final String id in <String>[
    'test-install',
    'abcdef0123456789abcdef0123456789',
  ]) {
    String nonce = '';
    print(
      'install PoW 18 bits $id: '
      '${_median(() => nonce = solveInstallPow(id))} ms -> $nonce',
    );
  }
  for (final int size in <int>[4 << 10, 1 << 20, 16 << 20]) {
    final Uint8List body = Uint8List(size);
    for (int i = 0; i < size; i++) {
      body[i] = i * 31;
    }
    final int reps = (64 << 20) ~/ size;
    print(
      'ffcSha256Bytes ${size}B x$reps: ${_median(() {
        for (int i = 0; i < reps; i++) {
          ffcSha256Bytes(body);
        }
      })} ms',
    );
  }
}

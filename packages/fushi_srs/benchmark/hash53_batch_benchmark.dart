// `SrsIds.ankiNumericIds`锛坄srs_db_store.dart` 閲嶅缓鏈満鏁板瓧绱㈠紩鐨勭湡瀹炲叆鍙ｏ級鐨勭鍒扮鑰楁椂锛?// 10 涓囦釜 UUID 涓?鈫?53 浣嶆暟瀛?id锛屽惈 UTF-8 缂栫爜 / 鎵撳寘杩涘師鐢熷唴瀛?/ FFI / 缁撴灉鎷峰洖銆?// 棰勭儹涓€娆″悗鍙?5 娆′腑浣嶆暟銆?//
// 鐢ㄦ硶锛堝湪 packages/fushi_srs 涓嬶紱AOT 鏇存帴杩?app锛夛細
//   dart compile exe benchmark/hash53_batch_benchmark.dart -o <out>.exe && <out>.exe
import 'dart:io';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_srs/fushi_srs.dart';

void main() {
  FushiCompute.require();
  const int n = 100000;
  const String card = '0190a5c1-1234-7abc-8def-0123456789ab';
  final List<String> ids = SrsIds.importedRevlogs(card, <int>[
    for (int i = 0; i < n; i++) 1700000000000 + i,
  ]);
  int checksum = 0;
  void once() {
    final List<int> nums = SrsIds.ankiNumericIds(ids);
    checksum += nums[n ~/ 2];
  }

  once();
  final List<int> us = <int>[];
  for (int i = 0; i < 5; i++) {
    final Stopwatch sw = Stopwatch()..start();
    once();
    us.add(sw.elapsedMicroseconds);
  }
  us.sort();
  stdout.writeln(
    'SrsIds.ankiNumericIds x$n: ${(us[2] / 1000).toStringAsFixed(2)} ms median '
    '(min ${(us.first / 1000).toStringAsFixed(2)}, '
    'max ${(us.last / 1000).toStringAsFixed(2)}) checksum=$checksum',
  );
}

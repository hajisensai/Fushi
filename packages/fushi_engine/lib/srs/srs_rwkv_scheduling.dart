/// [SrsDbStore] 作答时从 RWKV 取间隔的接口（实现：`SrsRwkvService`；store 不依赖实现，测试可替换）。
library;

import 'package:fushi_srs/fushi_srs.dart';

abstract interface class SrsRwkvScheduling {
  /// 卡 [cardId] 此刻作答时 Again / Hard / Good / Easy 的间隔（天）；没准备好返回 null。
  Future<List<int>?> intervalsFor(
    String cardId, {
    required SrsSchedulingConfig config,
    required int nowMs,
  });

  /// 本机评分已落库（[log] 是这张卡新的最后一条有效日志）。
  Future<void> onAnswered(String cardId, SrsReviewLog log);
}

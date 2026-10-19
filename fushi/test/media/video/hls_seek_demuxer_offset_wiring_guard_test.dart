// BUG-3618：在线源 HLS 往缓冲外 seek 落点比目标晚（「往回跳不动」）。判据是纯函数
// `hrSeekDemuxerOffsetForSeek`（单测在 mpv_cache_snapshot_test.dart）；这里钉住它在
// VideoPlayerController 里的接线——三个 seek 入口都要在 `player.seek` 之前下发前移量，
// 网络流采样要读出容器格式与缓冲段。接线缺失是静默的（功能照常、只是落点又变晚），
// 没有真 libmpv 的单测覆盖不到，所以按源码钉。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _body(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, isNonNegative, reason: '找不到 `$signature`');
  // 取到下一个同缩进成员声明为止，够覆盖方法体。
  final int next = source.indexOf('\n  Future<', start + signature.length);
  final int nextVoid = source.indexOf('\n  void ', start + signature.length);
  final List<int> ends = <int>[next, nextVoid].where((int i) => i > 0).toList()
    ..sort();
  return source.substring(start, ends.isEmpty ? source.length : ends.first);
}

void main() {
  final String source = File(
    'lib/src/media/video/video_player_controller.dart',
  ).readAsStringSync();

  for (final String signature in <String>[
    'Future<void> seekMs(int positionMs) async {',
    'Future<void> _rawSeekMs(int positionMs) async {',
  ]) {
    test('`$signature` 在 player.seek 之前下发 hr-seek-demuxer-offset', () {
      final String body = _body(source, signature);
      final int apply = body.indexOf('_applyHrSeekDemuxerOffsetFor(clampedMs)');
      final int seek = body.indexOf('_player?.seek(');
      expect(apply, isNonNegative);
      expect(seek, isNonNegative);
      expect(apply, lessThan(seek));
    });
  }

  test('进度条 / 横滑外部 seek 的落点通知也下发前移量', () {
    final String body = _body(
      source,
      'void notifyExternalSeek(int targetMs) {',
    );
    expect(body, contains('_applyHrSeekDemuxerOffsetFor(clampedMs)'));
  });

  test('网络流采样读出容器格式与缓冲段，判据用的正是它们', () {
    final String body = _body(
      source,
      'void _startCacheSpeedSampling(Player player, int loadToken) {',
    );
    expect(body, contains("'file-format'"));
    expect(body, contains("'demuxer-cache-state'"));
    expect(body, contains('_seekStreamIsHls ='));
    expect(body, contains('_seekableRangesSnapshot = parseMpvSeekableRanges('));
    expect(body, contains('_appliedHrSeekDemuxerOffset = null'));
    final String apply = _body(
      source,
      'void _applyHrSeekDemuxerOffsetFor(int targetMs) {',
    );
    expect(apply, contains('hrSeekDemuxerOffsetForSeek('));
    expect(apply, contains("'hr-seek-demuxer-offset'"));
  });
}

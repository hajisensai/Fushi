import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 书架流媒体书（YouTube/直链，TODO-1157）进度写穿源码守卫。
///
/// 根因背景：流媒体书**有** VideoBooks 行却走互联远端（无行）的持久化路径，位置只写
/// prefs 不写 `lastPositionMs`/`lastPlayedAt`，观看统计采集器也被 `!_isRemote` 一刀切
/// 关掉——书架「继续观看 / 在看筛选 / 看完角标 / 合集续播选集」与观看统计对在 app 内
/// 看 YouTube 全部失明。修复统一判据 `_bookRow != null`（= 书架书）：
/// ① [_persistRemotePosition] 对书架流媒体书补写 DB 行（updatePosition）；
/// ② 观看统计采集器按 `_bookRow != null` 建（互联远端仍不采集）。
///
/// 页面依赖 media_kit 原生播放器，widget 层不可离线测试 → 落最强可落地层：源码切片守卫
/// （删掉任一步即红），与 TODO-1307 守卫同构。
void main() {
  final String pageSrc =
      File('lib/src/pages/implementations/video_fushi_page.dart')
          .readAsStringSync()
          .replaceAll(String.fromCharCode(13), '');

  // [_persistRemotePosition] 函数体切片（到下一个方法 doc 注释为止的窄窗口，避免同形
  // token 在别处抢匹配）。
  String persistRemoteSlice() {
    final int start =
        pageSrc.indexOf('Future<void> _persistRemotePosition(String uid');
    expect(start, greaterThan(0), reason: '_persistRemotePosition 必须存在');
    final int end = pageSrc.indexOf('Future<void> _loadSingle', start);
    expect(end, greaterThan(start));
    return pageSrc.substring(start, end);
  }

  test('① 书架流媒体书位置写穿 DB：_persistRemotePosition 含 _bookRow 门 + updatePosition',
      () {
    final String slice = persistRemoteSlice();
    expect(
      slice.contains('if (_bookRow != null)'),
      isTrue,
      reason: '书架书判据必须是 _bookRow != null（本地/流媒体书有行，互联远端无行）',
    );
    expect(
      // dart format 会按行宽折行，去掉全部空白后断言完整调用形态。
      slice.replaceAll(RegExp(r'\s+'), '').contains(
          'widget.repo.updatePosition(widget.bookUid,clamped,playedAt:nowMs)'),
      isTrue,
      reason: '书架流媒体书必须把断点写穿 VideoBooks（lastPositionMs/lastPlayedAt），'
          '否则书架「继续观看/在看筛选/合集续播」对流媒体书失明',
    );
    // DB 写必须在「真观看」阈值之后（BUG-996 同款考虑：近起点假进度不落 DB）。
    final int iThreshold = slice.indexOf('kMeaningfulRemoteWatchMs');
    // 折行安全锚：方法名带左括号（widget.repo 与 .updatePosition 可能被 format 拆行）。
    final int iDbWrite = slice.indexOf('.updatePosition(');
    expect(iThreshold, greaterThan(0));
    expect(iDbWrite, greaterThan(iThreshold),
        reason: 'DB 写穿必须在 5s 真观看阈值之后（避免慢流 resume 未落地时的 ~0 假进度）');
  });

  test('② 观看统计采集器按书架书（_bookRow）建，而非按 !_isRemote 一刀切', () {
    expect(
      pageSrc.contains('if (_bookRow != null && _watchTracker == null)'),
      isTrue,
      reason: '流媒体书（YouTube 等）在本机播放必须计观看时长/字幕字数/看完标记',
    );
    expect(
      pageSrc.contains('if (!_isRemote && _watchTracker == null)'),
      isFalse,
      reason: '不得再用 !_isRemote 门控统计采集器（会把书架流媒体书一并关掉）',
    );
  });
}

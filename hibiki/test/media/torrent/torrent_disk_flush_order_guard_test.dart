// 守卫：`embedded_pipeline_test` 里「下载内容的逐字节比对」必须发生在
// **leecher session 关闭之后**。
//
// 为什么需要它（BUG-1147）：`isFinished` / `progress==1.0` / `left==0` /
// `haveCount==numPieces` 说的都是「piece 已在内存里校验通过」，**不是**「字节
// 已经躺在文件系统里」——写盘 job 还排在 libtorrent 的 disk io 线程上，且 2.x
// 的 mmap 磁盘后端写进去的是映射视图，Windows 不保证映射视图与 ReadFile 之间
// 的一致性；内容文件又是稀疏的，尚未落实的尾部区域会被读成 0。CI 的 Windows
// job 因此约 24% 的跑次挂在那条比对上（失败偏移恒在距文件尾 ~114KB）。
//
// 唯一确定性的落盘完成信号是销毁 session：`lt::session` 析构会等 disk io 线程
// 把写盘 job 做完、解除映射并关句柄。这条守卫钉住这个顺序，并禁止有人把它
// 「改回去」或者用 sleep / 重试来等落盘。
//
// 纯文本扫描：不需要 DLL、不需要 native 工具链，因此能跟着主 app 测试套件在任何
// 平台的 CI 上跑 —— `packages/hibiki_torrent` 自己的测试在无 DLL 的平台整组 skip。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // 测试的工作目录是 `hibiki/`，packages 在它的上一级。
  final File pipelineTest =
      File('../packages/hibiki_torrent/test/embedded_pipeline_test.dart');

  test('下载内容的逐字节比对必须排在 leecher.close() 之后', () {
    expect(pipelineTest.existsSync(), isTrue,
        reason: '找不到 ${pipelineTest.path} —— 守卫失去意义，先修路径');
    final String source = pipelineTest.readAsStringSync();

    const String compareMarker =
        "reason: 'downloaded bytes must equal seeded bytes'";
    final int compareAt = source.indexOf(compareMarker);
    expect(compareAt, greaterThanOrEqualTo(0),
        reason: '逐字节比对断言不见了。它是「引擎报完成 = 磁盘上真有这些字节」'
            '的唯一证明，不能删；要改先想清楚拿什么替代。');

    final int closeAt = source.indexOf('leecher.close();');
    expect(closeAt, greaterThanOrEqualTo(0),
        reason: '找不到 leecher.close() —— 比对前必须先销毁 session 让 '
            'libtorrent 把写盘 job 落完，否则 Windows 上会读到未落盘的 0。');

    final int readAt = source.indexOf('readAsBytesSync()');
    expect(readAt, greaterThan(closeAt),
        reason: '读盘比对排在了 leecher.close() 之前。isFinished / progress==1.0 '
            '/ left==0 / haveCount==numPieces 都只反映内存里的 piece 状态，'
            '写盘 job 可能还在 disk io 线程上排队 —— 这正是 CI Windows job '
            '约 24% 概率挂在字节比对上的原因。');

    // 关掉 session 到比对之间不许塞任何「等它落盘」的延时/重试。
    final String between = source.substring(closeAt, compareAt);
    for (final String banned in const <String>[
      'Future<void>.delayed',
      'Future.delayed',
      'sleep(',
      '_pollUntil',
    ]) {
      expect(between.contains(banned), isFalse,
          reason: '关闭 session 与字节比对之间出现了 `$banned`。落盘竞态只能用'
              '确定性的完成信号（销毁 session）消除，延时/重试只是把概率压小。');
    }
  });
}

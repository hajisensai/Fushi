import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart' show MediaKind;

import 'package:fushi/src/utils/misc/dashboard_remote_continue_feed.dart';
import 'package:fushi/src/utils/misc/dashboard_remote_merge.dart';

/// 首页互联远端补位 → 桌面小组件「继续」的接线板：按库实例一份，发布 / 撤下都通知。
void main() {
  const RemoteContinueCandidate book = RemoteContinueCandidate(
    kind: MediaKind.epub,
    id: 'k1',
    title: 'Host book',
    recentMs: 10,
    percent: 40,
  );

  test('one feed per owner; empty until the dashboard publishes', () {
    final Object a = Object();
    final Object b = Object();
    expect(
      identical(RemoteContinueFeed.of(a), RemoteContinueFeed.of(a)),
      isTrue,
    );
    expect(
      identical(RemoteContinueFeed.of(a), RemoteContinueFeed.of(b)),
      isFalse,
    );
    expect(RemoteContinueFeed.of(a).current, isEmpty);
    expect(RemoteContinueFeed.of(a).deviceName, isNull);
  });

  test('publish and clear notify and replace the snapshot', () async {
    final RemoteContinueFeed feed = RemoteContinueFeed();
    int updates = 0;
    final StreamSubscription<void> sub = feed.updates.listen((_) => updates++);
    final List<RemoteContinueCandidate> list = <RemoteContinueCandidate>[book];
    feed.publish(list, deviceName: 'Desk PC');
    list.clear(); // the feed keeps its own copy
    expect(feed.current.single.id, 'k1');
    expect(feed.deviceName, 'Desk PC');
    feed.clear();
    expect(feed.current, isEmpty);
    expect(feed.deviceName, isNull);
    feed.clear(); // nothing to clear: no extra notification
    await Future<void>.delayed(Duration.zero);
    expect(updates, 2);
    await sub.cancel();
  });

  test('republishing the same content in a fresh list stays silent', () async {
    final RemoteContinueFeed feed = RemoteContinueFeed();
    int updates = 0;
    final StreamSubscription<void> sub = feed.updates.listen((_) => updates++);
    feed.publish(<RemoteContinueCandidate>[book], deviceName: 'Desk PC');
    // 首页每轮取数都给一份新 List、新对象，但内容不变：不该再通知小组件重采集。
    // 标题运行时拼出来，确保是另一个实例（const 会被规范化成同一对象）。
    final String title = <String>['Host', 'book'].join(' ');
    feed.publish(<RemoteContinueCandidate>[
      RemoteContinueCandidate(
        kind: MediaKind.epub,
        id: 'k1',
        title: title,
        recentMs: 10,
        percent: 40,
      ),
    ], deviceName: 'Desk PC');
    await Future<void>.delayed(Duration.zero);
    expect(updates, 1);
    // 进度变了 / 设备名变了：照常通知。
    feed.publish(<RemoteContinueCandidate>[
      const RemoteContinueCandidate(
        kind: MediaKind.epub,
        id: 'k1',
        title: 'Host book',
        recentMs: 10,
        percent: 41,
      ),
    ], deviceName: 'Desk PC');
    feed.publish(feed.current, deviceName: 'Laptop');
    await Future<void>.delayed(Duration.zero);
    expect(updates, 3);
    await sub.cancel();
  });
}

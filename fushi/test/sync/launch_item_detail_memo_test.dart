// LaunchItemDetailMemo：媒体服务器一次起播内的条目详情短复用（video-7 /
// gap-remote-1）。纯逻辑，时钟注入。客户端接线见 plex_video_client_test.dart 与
// jellyfin_media_versions_test.dart。

import 'dart:async';

import 'package:test/test.dart';
import 'package:fushi/src/sync/launch_item_detail_memo.dart';

void main() {
  late DateTime now;
  late LaunchItemDetailMemo<String> memo;
  late int fetches;

  Future<String> fetch() async => 'detail-${++fetches}';

  setUp(() {
    now = DateTime.utc(2026, 11, 17, 12);
    fetches = 0;
    memo = LaunchItemDetailMemo<String>(now: () => now);
  });

  test('窗口内同一条复用；过了窗口重新取', () async {
    expect(
      await memo.fetchAndRemember('a', fetch, keepFailure: true),
      'detail-1',
    );
    now = now.add(kLaunchItemDetailReuseWindow);
    expect(await memo.reuseOrFetch('a', fetch), 'detail-1');
    expect(fetches, 1);

    now = now.add(const Duration(milliseconds: 1));
    expect(await memo.reuseOrFetch('a', fetch), 'detail-2');
    expect(fetches, 2);
  });

  test('窗口从请求落定起算，不是从发起起算', () async {
    final Completer<String> slow = Completer<String>();
    final Future<String> first = memo.fetchAndRemember(
      'a',
      () => slow.future,
      keepFailure: true,
    );
    // 请求本身就挂了很久（接近一轮超时）。
    now = now.add(const Duration(seconds: 15));
    slow.complete('late');
    expect(await first, 'late');
    await pumpEventQueue();
    now = now.add(const Duration(seconds: 5));
    expect(await memo.reuseOrFetch('a', fetch), 'late');
    expect(fetches, 0);
  });

  test('只留一格：换了一条就不复用上一条', () async {
    await memo.fetchAndRemember('a', fetch, keepFailure: true);
    expect(await memo.reuseOrFetch('b', fetch), 'detail-2');
    expect(await memo.reuseOrFetch('a', fetch), 'detail-3');
    expect(fetches, 3);
  });

  test('在途的那一发直接共用（取流与取字幕同时来）', () async {
    final Completer<String> pending = Completer<String>();
    int started = 0;
    Future<String> slowFetch() {
      started++;
      return pending.future;
    }

    final Future<String> a = memo.reuseOrFetch('a', slowFetch);
    final Future<String> b = memo.reuseOrFetch('a', slowFetch);
    final Future<String> c = memo.fetchAndRemember(
      'a',
      slowFetch,
      keepFailure: true,
    );
    pending.complete('shared');
    expect(await Future.wait(<Future<String>>[a, b, c]), <String>[
      'shared',
      'shared',
      'shared',
    ]);
    expect(started, 1);
  });

  test('fetchAndRemember 不用已落定的旧结果（重开入口要最新断点）', () async {
    await memo.fetchAndRemember('a', fetch, keepFailure: true);
    expect(
      await memo.fetchAndRemember('a', fetch, keepFailure: true),
      'detail-2',
    );
    // 随后的读取拿到的是新的那份。
    expect(await memo.reuseOrFetch('a', fetch), 'detail-2');
    expect(fetches, 2);
  });

  test('重开入口的失败只交给下一次读取一次', () async {
    final StateError boom = StateError('unreachable');
    await expectLater(
      memo.fetchAndRemember('a', () async => throw boom, keepFailure: true),
      throwsA(same(boom)),
    );
    await expectLater(memo.reuseOrFetch('a', fetch), throwsA(same(boom)));
    expect(fetches, 0, reason: '没有重新请求');
    expect(await memo.reuseOrFetch('a', fetch), 'detail-1');
  });

  test('记下的失败过了窗口不再抛', () async {
    await expectLater(
      memo.fetchAndRemember(
        'a',
        () async => throw StateError('x'),
        keepFailure: true,
      ),
      throwsStateError,
    );
    now = now.add(kLaunchItemDetailReuseWindow + const Duration(seconds: 1));
    expect(await memo.reuseOrFetch('a', fetch), 'detail-1');
  });

  test('不留失败的取详情（详情页）：失败后下一次读取照常重新请求；成功照常复用', () async {
    await expectLater(
      memo.fetchAndRemember(
        'a',
        () async => throw StateError('x'),
        keepFailure: false,
      ),
      throwsStateError,
    );
    expect(await memo.reuseOrFetch('a', fetch), 'detail-1');
    expect(fetches, 1);

    expect(
      await memo.fetchAndRemember('a', fetch, keepFailure: false),
      'detail-2',
    );
    expect(await memo.reuseOrFetch('a', fetch), 'detail-2');
    expect(fetches, 2);
  });

  test('在途共用后失败：错只交给已接上的读取方，下一次读取重新请求', () async {
    final Completer<String> pending = Completer<String>();
    final StateError boom = StateError('timeout');
    final Future<String> launch = memo.fetchAndRemember(
      'a',
      () => pending.future,
      keepFailure: true,
    );
    // 取流在详情还没落定时就来了，接上同一发。
    final Future<String> stream = memo.reuseOrFetch('a', fetch);
    expect(fetches, 0);
    final Future<void> launchFailed = expectLater(launch, throwsA(same(boom)));
    final Future<void> streamFailed = expectLater(stream, throwsA(same(boom)));
    pending.completeError(boom);
    await launchFailed;
    await streamFailed;

    // 这次失败已经交到取流手里，不能再留一格给重试。
    expect(await memo.reuseOrFetch('a', fetch), 'detail-1');
    expect(fetches, 1);
  });

  test('重开入口接上别处发起的在途那一发：失败照样留给取流一次', () async {
    final Completer<String> pending = Completer<String>();
    final StateError boom = StateError('timeout');
    final Future<String> page = memo.fetchAndRemember(
      'a',
      () => pending.future,
      keepFailure: false,
    );
    final Future<String> launch = memo.fetchAndRemember(
      'a',
      fetch,
      keepFailure: true,
    );
    final Future<void> pageFailed = expectLater(page, throwsA(same(boom)));
    final Future<void> launchFailed = expectLater(launch, throwsA(same(boom)));
    pending.completeError(boom);
    await pageFailed;
    await launchFailed;
    await expectLater(memo.reuseOrFetch('a', fetch), throwsA(same(boom)));
    expect(fetches, 0);
    expect(await memo.reuseOrFetch('a', fetch), 'detail-1');
  });

  test('reuseOrFetch 自己现取失败不留记录', () async {
    await expectLater(
      memo.reuseOrFetch('a', () async => throw StateError('x')),
      throwsStateError,
    );
    expect(await memo.reuseOrFetch('a', fetch), 'detail-1');
  });
}

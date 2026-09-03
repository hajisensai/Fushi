// BUG-1832 守卫：YouTube 多 client 兜底链的构成、超时预算不变式，以及「逐 client 取首个
// 非空」的短路行为。
//
// 原始失败：`https://www.youtube.com/watch?v=D8uACXBAqkE` 打不开。根因是兜底链
// `[androidVr, ios, tv]` 里没有 `android`——该视频对 androidVr/tv 是 unplayable、对 ios 的
// 首流 HEAD 是 403，三个 client 全挂即抛 StateError；而 `android` 一次就能出流。同一根因在
// 字幕侧的表现是 `_fetchCaptionTracks` 钉死 androidVr（该视频 androidVr 返回 0 条字幕轨，
// android/ios 返回 7 条含 2 条 ja），日语字幕静默消失。
//
// 这里不做网络断言（CI 无外网，且 YouTube 的 client 行为本就会漂），只锁住三件**本地可判定**
// 且一旦回退就会重现该 bug 的事实。
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'package:fushi/src/media/video/youtube_source_resolver.dart';

/// 取 client 的 innertube clientName（兜底链的可读身份，用于断言链的构成与顺序）。
String _clientName(yt.YoutubeApiClient client) =>
    (client.payload['context']['client']
        as Map<String, dynamic>)['clientName'] as String;

void main() {
  group('BUG-1832 兜底链构成', () {
    test('链里必须含 ANDROID，且顺序为 androidVr → android → ios → tv', () {
      // ANDROID 缺席正是原始 bug：只有它能给 D8uACXBAqkE 出流。
      expect(
        kYoutubeManifestClientFallback.map(_clientName).toList(),
        <String>['ANDROID_VR', 'ANDROID', 'IOS', 'TVHTML5'],
      );
    });

    test('链内无重复 client（重复 = 白白多等一轮超时）', () {
      final List<String> names =
          kYoutubeManifestClientFallback.map(_clientName).toList();
      expect(names.toSet().length, names.length);
    });
  });

  group('BUG-1832 超时预算不变式', () {
    test('外层总超时 ≥ 每 client 上限 × 链长（增删 client 时自动跟随）', () {
      // 旧代码把这个关系写在注释里靠人肉维护，加第 4 个 client 时必然失配。
      final Duration needed = kYoutubePerClientManifestTimeout *
          kYoutubeManifestClientFallback.length;
      expect(
        kYoutubeResolveTimeout,
        greaterThanOrEqualTo(needed),
        reason: '总预算 ${kYoutubeResolveTimeout.inSeconds}s 容不下 '
            '${kYoutubeManifestClientFallback.length} 个 client × '
            '${kYoutubePerClientManifestTimeout.inSeconds}s',
      );
    });

    test('每 client 上限为正（0 会让每个 client 立即超时 = 永远解析失败）', () {
      expect(kYoutubePerClientManifestTimeout, greaterThan(Duration.zero));
    });
  });

  group('BUG-1832 fetchFirstNonEmptyByClient', () {
    test('首个 client 返回空时继续试下一个', () async {
      final List<String> called = <String>[];
      final List<int> got = await fetchFirstNonEmptyByClient<int>(
        kYoutubeManifestClientFallback,
        (yt.YoutubeApiClient c) async {
          called.add(_clientName(c));
          // 只有第二个（ANDROID）有数据——正是 D8uACXBAqkE 的实测形状。
          return _clientName(c) == 'ANDROID' ? <int>[1, 2, 3] : <int>[];
        },
      );
      expect(got, <int>[1, 2, 3]);
      expect(called, <String>['ANDROID_VR', 'ANDROID']);
    });

    test('拿到非空即短路，不再调用后续 client', () async {
      final List<String> called = <String>[];
      final List<int> got = await fetchFirstNonEmptyByClient<int>(
        kYoutubeManifestClientFallback,
        (yt.YoutubeApiClient c) async {
          called.add(_clientName(c));
          return <int>[7];
        },
      );
      expect(got, <int>[7]);
      expect(called, <String>['ANDROID_VR'],
          reason: '首个非空后仍调用后续 client = 每次解析都多打 3 次无谓请求');
    });

    test('全部 client 都空时返回空表（不抛，字幕是 best-effort）', () async {
      int calls = 0;
      final List<int> got = await fetchFirstNonEmptyByClient<int>(
        kYoutubeManifestClientFallback,
        (yt.YoutubeApiClient _) async {
          calls++;
          return <int>[];
        },
      );
      expect(got, isEmpty);
      expect(calls, kYoutubeManifestClientFallback.length);
    });

    test('空 client 列表返回空表（不抛）', () async {
      final List<int> got = await fetchFirstNonEmptyByClient<int>(
        const <yt.YoutubeApiClient>[],
        (yt.YoutubeApiClient _) async => <int>[1],
      );
      expect(got, isEmpty);
    });
  });
}

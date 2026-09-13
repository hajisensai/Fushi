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

import 'package:fushi_engine/media/video/youtube_source_resolver.dart';

/// 取 client 的 innertube clientName（兜底链的可读身份，用于断言链的构成与顺序）。
String _clientName(yt.YoutubeApiClient client) =>
    (client.payload['context']['client'] as Map<String, dynamic>)['clientName']
        as String;

void main() {
  group('BUG-1832 兜底链构成', () {
    test('链里必须含 ANDROID，且顺序为 visionos → androidVr → android → ios → tv', () {
      // ANDROID 缺席正是原始 bug：只有它能给 D8uACXBAqkE 出流。
      // BUG-2526：VISIONOS 必须在链首——ANDROID 的 DASH 流无 PO token 只放前 60 秒。
      expect(
        kYoutubeManifestClientFallback.map(_clientName).toList(),
        <String>['VISIONOS', 'ANDROID_VR', 'ANDROID', 'IOS', 'TVHTML5'],
      );
    });

    test('链内无重复 client（重复 = 白白多等一轮超时）', () {
      final List<String> names =
          kYoutubeManifestClientFallback.map(_clientName).toList();
      expect(names.toSet().length, names.length);
    });
  });

  group('BUG-2526 visionos client', () {
    // yt-dlp 2026.08.19 `INNERTUBE_CLIENTS['visionos']`（`_DEFAULT_JSLESS_CLIENTS` 里唯一
    // 一个）：字段与上游一致是 YouTube 不判「Sign in to confirm you're not a bot」的前提。
    // 这里锁字段而不锁网络：CI 无外网，且一旦有人「顺手」改版本号/设备型号就会静默回到
    // 60 秒窗口（本地与 CI 全绿、只有真机播到 60s 才断）。
    Map<String, dynamic> clientContext() =>
        (kYoutubeVisionOsClient.payload['context']
            as Map<String, dynamic>)['client'] as Map<String, dynamic>;

    test('innertube context 与 yt-dlp 2026.08.19 逐字一致', () {
      expect(clientContext(), <String, dynamic>{
        'clientName': 'VISIONOS',
        'clientVersion': '1.02',
        'deviceMake': 'Apple',
        'deviceModel': 'RealityDevice17,1',
        'userAgent': kYoutubeVisionOsUserAgent,
        'osName': 'visionOS',
        'osVersion': '26.5.23O471',
        'hl': 'en',
      });
      expect(
        kYoutubeVisionOsClient.apiUrl,
        'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
      );
    });

    test('链首就是它（identical，不是同名副本）', () {
      expect(
        identical(kYoutubeManifestClientFallback.first, kYoutubeVisionOsClient),
        isTrue,
      );
    });

    test('回放 UA 不随 visionos 走：仍用 youtube_explode 铸流 UA（五端 libmpv 零改动）', () {
      // googlevideo 对该 client 的流不校验 UA（Chrome UA / visionOS UA 实测均 206），
      // 回放头保持 BUG-678 的口径，不引入第二个 UA 常量到 libmpv/ffmpeg 侧。
      expect(
        youtubeStreamReplayHeaders()['User-Agent'],
        kYoutubeStreamReplayUserAgent,
      );
      expect(kYoutubeStreamReplayUserAgent, isNot(kYoutubeVisionOsUserAgent));
    });
  });

  group('BUG-2526 字幕链', () {
    test('字幕链 = 取流链去掉 visionos（裸 innertube 请求被判 bot，轨表恒空，纯空转）', () {
      expect(
        kYoutubeCaptionClientFallback.map(_clientName).toList(),
        <String>['ANDROID_VR', 'ANDROID', 'IOS', 'TVHTML5'],
      );
      expect(
        kYoutubeCaptionClientFallback.any(
            (yt.YoutubeApiClient c) => identical(c, kYoutubeVisionOsClient)),
        isFalse,
      );
    });

    test('字幕链由取流链派生（取流链其余成员一个不少、顺序一致）', () {
      final List<String> expected = kYoutubeManifestClientFallback
          .where(
              (yt.YoutubeApiClient c) => !identical(c, kYoutubeVisionOsClient))
          .map(_clientName)
          .toList();
      expect(kYoutubeCaptionClientFallback.map(_clientName).toList(), expected);
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
      expect(called, <String>['VISIONOS', 'ANDROID_VR', 'ANDROID']);
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
      expect(called, <String>['VISIONOS'],
          reason: '首个非空后仍调用后续 client = 每次解析都多打 4 次无谓请求');
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

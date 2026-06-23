import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

/// TODO-766 防御层：被访问的音频 token 命中即续期。
///
/// 远端 host 给词音频文件 URL 签一个 5 分钟过期的 token（[_pruneAudioTokens]）。
/// 制卡音频静默丢的根因是制卡复用查词缓存的过期 URL（主修在 popup.js）；这里加一道
/// 服务端防御：`_handleAudioFile` 成功命中 token 时刷新其时间戳，重置 5 分钟窗口，
/// 让「正在被访问」的音频 token 不会在使用途中（播放→制卡之间）被 prune 掉。
///
/// 用可控时钟做确定性时间旅行：t=0 签发 → t=4min 访问（刷新）→ t=8min 再访问。
/// 距首次签发已 8min（>5min），但距上次访问只 4min（<5min）：命中续期下仍 200，
/// 撤掉续期则 404。
class _FakeAudioLookupService implements HibikiRemoteLookupService {
  _FakeAudioLookupService(this._bytes);

  final Uint8List _bytes;
  int lookupCount = 0;

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async {
    lookupCount += 1;
    return RemoteAudioLookup(bytes: _bytes, contentType: 'audio/mpeg');
  }

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async =>
      null;
}

void main() {
  late HibikiSyncServer server;
  late _FakeAudioLookupService lookup;
  const String token = 'test-token-refresh';
  late String base;
  late DateTime clock;

  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  setUp(() async {
    clock = DateTime(2026, 1, 1, 12, 0, 0);
    lookup = _FakeAudioLookupService(
      Uint8List.fromList(utf8.encode('MP3-AUDIO-BYTES')),
    );
    server = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_tok_refresh').path,
      port: 0,
      token: token,
      allowLan: false,
      remoteLookupService: lookup,
      now: () => clock,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async => server.stop());

  /// 经查词端点取一个签名好的 file URL（带新鲜 token）。
  Future<String> resolveFileUrl() async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.postUrl(Uri.parse('$base/api/lookup/audio'));
    req.headers.set('authorization', authHeader());
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(<String, String>{
      'expression': '猫',
      'reading': 'ねこ',
    })));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    final Map<String, dynamic> json =
        jsonDecode(await res.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    c.close();
    final String? url = json['url'] as String?;
    expect(url, isNotNull,
        reason: 'audio lookup must return a signed file URL');
    return url!;
  }

  Future<int> getFile(String url) async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.getUrl(Uri.parse(url));
    final HttpClientResponse res = await req.close();
    final int code = res.statusCode;
    await res.drain<void>();
    c.close();
    return code;
  }

  test('accessing an audio file refreshes its token TTL (no mid-use expiry)',
      () async {
    // t=0: mint a token-signed file URL.
    final String url = await resolveFileUrl();

    // t=+4min (within the 5-min window): access it → 200 AND refreshes the TTL.
    clock = clock.add(const Duration(minutes: 4));
    expect(await getFile(url), 200,
        reason: 'a 4-minute-old token is still inside the 5-minute window');

    // t=+8min total (8 > 5 since mint, but only 4 since the refreshing hit):
    // the refresh must keep it alive.
    clock = clock.add(const Duration(minutes: 4));
    expect(await getFile(url), 200,
        reason:
            'the previous hit refreshed the token TTL, so 8 minutes after MINT '
            '(but 4 minutes after the last access) it must NOT have expired');
  });

  test('an unaccessed audio token still expires after 5 minutes', () async {
    // Without any intervening access, the original 5-min prune still applies —
    // the refresh is a hit-driven extension, not an immortality grant.
    final String url = await resolveFileUrl();
    clock = clock.add(const Duration(minutes: 6));
    expect(await getFile(url), 404,
        reason:
            'an audio token never accessed within 5 minutes must still be pruned');
  });
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart'
    show youtubeMineResolveErrorKind;
import 'package:fushi_engine/media/video/youtube_source_resolver.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/immersion_mine_payload.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

/// TODO-1303 契约守卫：`/api/mine` 响应体现在除 `result` 外，还摊开诊断
/// `message`（失败原因 / 音频落空警告）与 `detail`（技术细节）——浏览器扩展 content.js
/// 据此 toast 显因、区分「真成功 / 卡建了但没音频」。此前只回 `{result}`，失败原因被
/// [buildRemoteMineResponse] 丢弃 → 「制卡失败报成功 + 诊断黑洞」。
class _DiagMining implements FushiRemoteMiningService {
  RemoteMineResult entryResult = const RemoteMineResult(result: 'success');
  RemoteMineResult immersionResult = const RemoteMineResult(result: 'success');

  @override
  Future<RemoteMineResult> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  }) async => entryResult;

  @override
  Future<RemoteMineResult> mineImmersion(ImmersionMinePayload payload) async =>
      immersionResult;

  @override
  Future<RemoteMineResult> mineForwarded(ForwardedMinePayload payload) async =>
      immersionResult;

  @override
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  }) async => false;

  @override
  Future<AnkiOpenWordOutcome> openWordInAnki({
    required String expression,
    required String reading,
  }) async => AnkiOpenWordOutcome.failed;

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(
    String modelName,
  ) async => null;

  @override
  Future<bool> updateNoteTypeStyling(String modelName, String css) async =>
      false;

  @override
  Future<bool> updateNoteTypeTemplates(
    String modelName,
    List<AnkiCardTemplate> templates,
  ) async => false;

  @override
  Future<bool> probeMediaMaintenance() async => false;

  @override
  Future<AnkiMediaDedupReport?> runMediaDedup({bool dryRun = true}) async =>
      null;
}

Map<String, dynamic> _entryBody() => <String, dynamic>{
  'fields': <String, dynamic>{'expression': 'x'},
  'sentence': 's',
};

void main() {
  group('TODO-1303 buildRemoteMineResponse 摊开诊断到响应体', () {
    test('error -> result + message + detail 全部回传', () async {
      final mining = _DiagMining()
        ..entryResult = const RemoteMineResult(
          result: 'error',
          message: 'card export failed: boom',
          detail: 'boom',
        );
      final Map<String, dynamic> out = await buildRemoteMineResponse(
        _entryBody(),
        mining: mining,
      );
      expect(out['result'], 'error');
      expect(out['message'], 'card export failed: boom');
      expect(out['detail'], 'boom');
    });

    test(
      'success + audioWarning -> result success + message（无 detail）',
      () async {
        final mining = _DiagMining()
          ..entryResult = const RemoteMineResult(
            result: 'success',
            message: 'audio 404',
          );
        final Map<String, dynamic> out = await buildRemoteMineResponse(
          _entryBody(),
          mining: mining,
        );
        expect(out['result'], 'success');
        expect(out['message'], 'audio 404');
        expect(out.containsKey('detail'), isFalse);
      },
    );

    test('plain success -> 只有 result（不带 message/detail，向后兼容）', () async {
      final mining = _DiagMining()
        ..entryResult = const RemoteMineResult(result: 'success');
      final Map<String, dynamic> out = await buildRemoteMineResponse(
        _entryBody(),
        mining: mining,
      );
      expect(out['result'], 'success');
      expect(out.containsKey('message'), isFalse);
      expect(out.containsKey('detail'), isFalse);
    });

    test('沉浸 payload（截图）走 mineImmersion 且回传诊断', () async {
      final mining = _DiagMining()
        ..immersionResult = const RemoteMineResult(
          result: 'error',
          message: 'Netflix 制卡失败：required audio missing',
          detail: 'required audio missing',
        );
      final Map<String, dynamic> body = <String, dynamic>{
        'fields': <String, dynamic>{'expression': 'x'},
        'sentence': 's',
        'netflixVideoId': '81',
        'clipBase64': 'AAAA',
      };
      final Map<String, dynamic> out = await buildRemoteMineResponse(
        body,
        mining: mining,
      );
      expect(out['result'], 'error');
      expect(out['message'], contains('required audio missing'));
      expect(out['detail'], 'required audio missing');
    });
  });

  // EMI05fe8RJ：失败分型——扩展据 errorKind 把永久失败移出待生成队列。
  group('EMI05fe8RJ errorKind 分型', () {
    test('errorKind 摊进 /api/mine 响应体；未分型不带该字段', () async {
      final mining = _DiagMining()
        ..entryResult = const RemoteMineResult(
          result: 'error',
          message: 'YouTube 视频流解析失败，未制卡',
          errorKind: RemoteMineErrorKind.permanent,
        );
      final Map<String, dynamic> out = await buildRemoteMineResponse(
        _entryBody(),
        mining: mining,
      );
      expect(out['errorKind'], 'permanent');
      mining.entryResult = const RemoteMineResult(result: 'error');
      final Map<String, dynamic> legacy = await buildRemoteMineResponse(
        _entryBody(),
        mining: mining,
      );
      expect(legacy.containsKey('errorKind'), isFalse);
    });

    test('全部 client 都回「需购买 / 不可用」→ permanent；混入传输层失败 → transient', () {
      final yt.VideoId id = yt.VideoId('dQw4w9WgXcQ');
      final YoutubeManifestException paid =
          YoutubeManifestException(id.value, <YoutubeClientFailure>[
            YoutubeClientFailure(
              'ANDROID_VR',
              yt.VideoRequiresPurchaseException(id),
            ),
            YoutubeClientFailure(
              'IOS',
              yt.VideoUnavailableException.unavailable(id),
            ),
          ]);
      expect(paid.isPermanentlyUnavailable, isTrue);
      expect(youtubeMineResolveErrorKind(paid), RemoteMineErrorKind.permanent);

      final YoutubeManifestException mixed =
          YoutubeManifestException(id.value, <YoutubeClientFailure>[
            YoutubeClientFailure(
              'ANDROID_VR',
              yt.VideoRequiresPurchaseException(id),
            ),
            YoutubeClientFailure('IOS', TimeoutException('slow')),
          ]);
      expect(mixed.isPermanentlyUnavailable, isFalse);
      expect(youtubeMineResolveErrorKind(mixed), RemoteMineErrorKind.transient);
      expect(
        youtubeMineResolveErrorKind(StateError('x')),
        RemoteMineErrorKind.transient,
      );
    });
  });
}

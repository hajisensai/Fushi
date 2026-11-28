import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/media/video/subtitle/library_subtitle_fill.dart';

import 'package:fushi/src/media/video/subtitle/library_subtitle_fill_controller.dart';
import 'package:fushi/src/ops/ctl_video_subtitle_fill_routes.dart';

Matcher _status(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

CtlCall _post(Map<String, Object?> body) =>
    CtlCall(method: 'POST', path: kCtlVideoSubtitleFillPath, body: body);

/// 校验分支都在碰 controller / database 之前返回；碰到就说明校验漏了。
CtlVideoSubtitleFillHandlers _handlers({bool enabled = true}) =>
    CtlVideoSubtitleFillHandlers(
      controller: () => throw StateError('controller must not be reached'),
      database: () => throw StateError('database must not be reached'),
      videoModuleEnabled: () => enabled,
    );

void main() {
  group('CtlVideoSubtitleFillHandlers 校验', () {
    test('视频模块关闭时三个入口都拒绝', () async {
      final CtlVideoSubtitleFillHandlers h = _handlers(enabled: false);
      await expectLater(
        h.start(_post(<String, Object?>{'language': 'ja'})),
        _status(422),
      );
      await expectLater(
        h.status(const CtlCall(method: 'GET', path: kCtlVideoSubtitleFillPath)),
        _status(422),
      );
      await expectLater(
        h.undo(_post(<String, Object?>{'jobId': 'fill-20261126153012345'})),
        _status(422),
      );
    });

    test('缺 language / 认不出的 language → 400', () async {
      final CtlVideoSubtitleFillHandlers h = _handlers();
      await expectLater(
        h.start(_post(const <String, Object?>{})),
        _status(400),
      );
      await expectLater(
        h.start(_post(<String, Object?>{'language': '???'})),
        _status(400),
      );
    });

    test('collectionId 与 bookUids 同给 → 400', () async {
      await expectLater(
        _handlers().start(
          _post(<String, Object?>{
            'language': 'ja',
            'collectionId': 3,
            'bookUids': 'a,b',
          }),
        ),
        _status(400),
      );
    });

    test('undo 缺 jobId → 400', () async {
      await expectLater(
        _handlers().undo(_post(const <String, Object?>{})),
        _status(400),
      );
    });

    test('undo 的 jobId 不是任务 id（含路径穿越）→ 400，不碰 controller', () async {
      for (final String bad in <String>[
        '../../secrets',
        r'..\fill-20261126153012',
        'fill-1',
        'fill-20261126153012/../../x',
      ]) {
        await expectLater(
          _handlers().undo(_post(<String, Object?>{'jobId': bad})),
          _status(400),
          reason: bad,
        );
      }
    });
  });

  test('bookUids：数组原样认（uid 可带逗号），字符串按逗号切', () {
    expect(
      subtitleFillBookUidsParam(<Object?>[
        'video/Kamiina Botan, Yoeru Sugata wa Yuri no Hana - S01E01',
        ' video/b ',
        '',
      ]),
      <String>[
        'video/Kamiina Botan, Yoeru Sugata wa Yuri no Hana - S01E01',
        'video/b',
      ],
    );
    expect(subtitleFillBookUidsParam('a, b,,c'), <String>['a', 'b', 'c']);
    expect(subtitleFillBookUidsParam(null), isNull);
    expect(subtitleFillBookUidsParam(const <Object?>[]), isNull);
    expect(() => subtitleFillBookUidsParam(3), _status(400));
  });

  test('报告 JSON 往返保留撤销需要的字段', () {
    const SubtitleFillOutcome original = SubtitleFillOutcome(
      bookUid: 'disc-a.p01.mpls',
      title: 'EP1',
      videoPath: r'D:\video\A\BDMV\PLAYLIST\00001.p01.mpls',
      action: SubtitleFillAction.downloadedRetimed,
      path: r'C:\support\video_subtitles\disc-a.ja.srt',
      previousSubtitleSource: 'embedded:2',
      selectionChanged: true,
      extraFiles: <String>[r'C:\support\jobs\disc_out\ep1.ja.srt'],
    );
    final SubtitleFillOutcome back = subtitleFillOutcomeFromJson(
      original.toJson(),
    );
    expect(back.bookUid, original.bookUid);
    expect(back.action, SubtitleFillAction.downloadedRetimed);
    expect(back.path, original.path);
    expect(back.previousSubtitleSource, 'embedded:2');
    expect(back.selectionChanged, isTrue);
    expect(back.extraFiles, original.extraFiles);
    expect(back.wroteFile, isTrue);
  });

  test('任务 id 形状：秒级旧 id 与毫秒级新 id 都认', () {
    expect(isLibrarySubtitleFillJobId('fill-20261126153012'), isTrue);
    expect(isLibrarySubtitleFillJobId('fill-20261126153012345'), isTrue);
    expect(isLibrarySubtitleFillJobId('fill-2026'), isFalse);
    expect(isLibrarySubtitleFillJobId('../fill-20261126153012'), isFalse);
  });

  test('报告里认不出的 action 按 failed 处理（撤销不动它）', () {
    final SubtitleFillOutcome back = subtitleFillOutcomeFromJson(
      <String, Object?>{'bookUid': 'x', 'action': 'fromTheFuture'},
    );
    expect(back.action, SubtitleFillAction.failed);
    expect(back.wroteFile, isFalse);
  });
}

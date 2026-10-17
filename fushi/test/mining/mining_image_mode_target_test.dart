import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/mining_image_mode_target.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';

/// [answer] = 仓库对「目标模板能否承载同步片段」的回答；[failure] 非空时改为抛它。
class _Repo implements BaseAnkiRepository {
  _Repo({this.answer, this.failure});

  final bool? answer;
  final Object? failure;
  int probes = 0;

  @override
  Future<bool?> rendersSynchronizedClip() async {
    probes++;
    if (failure != null) {
      Error.throwWithStackTrace(failure!, StackTrace.current);
    }
    return answer;
  }

  @override
  Future<AnkiSettings> loadSettings() async =>
      const AnkiSettings(selectedNoteTypeName: 'Kiku');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<VideoMiningImageMode> _clip(_Repo repo) =>
    resolveTargetMiningImageMode(VideoMiningImageMode.videoClip, repo: repo);

void main() {
  tearDown(() => onSynchronizedClipTemplateFallback = null);

  test('降级到 gif 时通知笔记类型名；保留片段时不通知', () async {
    final List<String> notified = <String>[];
    onSynchronizedClipTemplateFallback = notified.add;

    await _clip(_Repo(answer: true));
    await _clip(_Repo());
    await _clip(_Repo(failure: Exception('AnkiConnect unreachable')));
    expect(notified, isEmpty);

    await _clip(_Repo(answer: false));
    expect(notified, <String>['Kiku']);
  });

  test('非片段模式原样返回，不探测模板', () async {
    final _Repo repo = _Repo(answer: false);
    for (final VideoMiningImageMode mode in VideoMiningImageMode.values) {
      if (mode.isVideoClip) continue;
      expect(await resolveTargetMiningImageMode(mode, repo: repo), mode);
    }
    expect(repo.probes, 0);
  });

  test('模板承载不了 → gif；承载得了 → 保留片段', () async {
    expect(await _clip(_Repo(answer: false)), VideoMiningImageMode.gif);
    expect(await _clip(_Repo(answer: true)), VideoMiningImageMode.videoClip);
  });

  test('无法判定 / 后端异常 → 保留片段（制卡仍可能被待补发队列接住）', () async {
    expect(await _clip(_Repo()), VideoMiningImageMode.videoClip);
    expect(
      await _clip(_Repo(failure: Exception('AnkiConnect unreachable'))),
      VideoMiningImageMode.videoClip,
    );
  });

  test('编程错误不吞', () async {
    await expectLater(
      _clip(_Repo(failure: StateError('bug'))),
      throwsStateError,
    );
  });
}

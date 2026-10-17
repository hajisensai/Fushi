import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/remote_video_subtitle_refetch.dart';
import 'package:fushi/src/media/video/video_subtitle_attach.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:path/path.dart' as p;

/// 假服务端：按「默认字幕 / 内封轨流号」回不同的字幕正文，[subtitleBody] 可在测试中
/// 途改（模拟服务端换了字幕）。其余 [RemoteVideoClient] 能力本测试不涉及。
class _FakeSubtitleServer implements RemoteVideoClient {
  String subtitleBody = '';
  final Map<int, String> trackBodies = <int, String>{};
  final List<int?> requestedStreams = <int?>[];

  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    int episodeIndex = 0,
    void Function(double progress)? onProgress,
  }) async {
    requestedStreams.add(embeddedStreamIndex);
    final String body = embeddedStreamIndex == null
        ? subtitleBody
        : trackBodies[embeddedStreamIndex]!;
    await dest.writeAsString(body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _srt(List<String> lines) {
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < lines.length; i++) {
    out
      ..writeln('${i + 1}')
      ..writeln('00:00:0$i,000 --> 00:00:0${i + 1},000')
      ..writeln(lines[i])
      ..writeln();
  }
  return out.toString();
}

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late VideoBookRepository repo;
  late _FakeSubtitleServer server;
  late String destDir;
  const String uid = 'remote-video-42';

  const RemoteVideoInfo video = RemoteVideoInfo(
    id: uid,
    title: 'ep01',
    hasSubtitle: true,
    subtitleFileName: 'ep01.ja.srt',
    embeddedSubtitleTracks: <RemoteVideoEmbeddedSubtitleTrack>[
      RemoteVideoEmbeddedSubtitleTrack(
        streamIndex: 2,
        codec: 'ass',
        language: 'jpn',
        title: '日本語',
        fileName: 'ep01.s2.ass',
      ),
      // 图形轨：解不出 cue，不能出现在选项里。
      RemoteVideoEmbeddedSubtitleTrack(
        streamIndex: 3,
        codec: 'hdmv_pgs_subtitle',
        isText: false,
      ),
    ],
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_sub_refetch_');
    destDir = p.join(tmp.path, 'video_subtitles');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    server = _FakeSubtitleServer();

    // 模拟「当初从服务端下载」的状态：字幕 v1（落在 video_subtitles/<uid>.srt，与
    // 首次下载同名）+ cue v1 + 已看到 12 分钟。
    await repo.saveVideoBook(
      VideoBooksCompanion(
        bookUid: const Value(uid),
        title: const Value('ep01'),
        videoPath: Value(p.join(tmp.path, 'ep01.mp4')),
        lastPositionMs: const Value(720000),
      ),
    );
    final Directory src = Directory(p.join(tmp.path, 'first'))
      ..createSync(recursive: true);
    final File v1 = File(p.join(src.path, '$uid.srt'))
      ..writeAsStringSync(_srt(<String>['旧い字幕その一', '旧い字幕その二']));
    final SubtitleAttachResult seeded = await attachSubtitleToVideoBook(
      repo: repo,
      book: (await repo.getByBookUid(uid))!,
      subtitlePath: v1.path,
      destDirOverride: destDir,
    );
    expect(seeded.outcome, SubtitleAttachOutcome.attached);
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('选项：默认字幕在前，只列文本内封轨（图形轨不列）', () {
    final List<RemoteSubtitleRefetchOption> options =
        remoteSubtitleRefetchOptions(video);
    expect(options, hasLength(2));
    expect(options[0].track, isNull);
    expect(options[0].localFileName(uid), '$uid.srt');
    expect(options[1].track!.streamIndex, 2);
    expect(options[1].localFileName(uid), '$uid.s2.ass');
    expect(
      remoteSubtitleRefetchOptions(const RemoteVideoInfo(id: 'x', title: 'x')),
      isEmpty,
    );
  });

  test('服务端字幕变了 → 重新拉取默认字幕：本机字幕与 cue 换新、观看进度保留', () async {
    server.subtitleBody = _srt(<String>['新しい字幕その一', '新しい字幕その二', '三行目']);
    final VideoBookRow book = (await repo.getByBookUid(uid))!;

    final SubtitleAttachResult result = await refetchRemoteVideoSubtitle(
      client: server,
      video: video,
      option: remoteSubtitleRefetchOptions(video).first,
      repo: repo,
      book: book,
      tempDir: Directory(p.join(tmp.path, 'tmp')),
      destDirOverride: destDir,
    );

    expect(result.outcome, SubtitleAttachOutcome.attached);
    expect(result.cueCount, 3);
    expect(server.requestedStreams, <int?>[null]);
    final VideoBookRow after = (await repo.getByBookUid(uid))!;
    // 与首次下载同名 → 原位覆盖，不在 video_subtitles 里堆副本。
    expect(after.subtitleSource, p.join(destDir, '$uid.srt'));
    expect(
      File(after.subtitleSource!).readAsStringSync(),
      contains('新しい字幕その一'),
    );
    final List<AudioCue> cues = await repo.loadCues(uid);
    expect(cues.map((AudioCue c) => c.text), <String>[
      '新しい字幕その一',
      '新しい字幕その二',
      '三行目',
    ]);
    // 观看进度不受影响。
    expect(after.lastPositionMs, 720000);
    // 只剩一行视频书（没有重复导入）。
    expect(await repo.listAll(), hasLength(1));
  });

  test('重新拉取内封文本轨：按流号请求、落成独立文件，不覆盖默认字幕', () async {
    server.trackBodies[2] =
        '[Script Info]\nScriptType: v4.00+\n\n'
        '[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, '
        'MarginV, Effect, Text\n'
        'Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,内封の台詞\n';
    final VideoBookRow book = (await repo.getByBookUid(uid))!;

    final SubtitleAttachResult result = await refetchRemoteVideoSubtitle(
      client: server,
      video: video,
      option: remoteSubtitleRefetchOptions(video)[1],
      repo: repo,
      book: book,
      tempDir: Directory(p.join(tmp.path, 'tmp')),
      destDirOverride: destDir,
    );

    expect(result.outcome, SubtitleAttachOutcome.attached);
    expect(server.requestedStreams, <int?>[2]);
    final VideoBookRow after = (await repo.getByBookUid(uid))!;
    expect(after.subtitleSource, p.join(destDir, '$uid.s2.ass'));
    expect((await repo.loadCues(uid)).single.text, '内封の台詞');
    // 默认字幕文件原样保留，用户随时能切回去。
    expect(
      File(p.join(destDir, '$uid.srt')).readAsStringSync(),
      contains('旧い字幕その一'),
    );
  });

  test('服务端回来的字幕解析不出 cue：本机字幕文件与 cue 一个字节都不动', () async {
    server.subtitleBody = 'this is not a subtitle';
    final VideoBookRow book = (await repo.getByBookUid(uid))!;

    final SubtitleAttachResult result = await refetchRemoteVideoSubtitle(
      client: server,
      video: video,
      option: remoteSubtitleRefetchOptions(video).first,
      repo: repo,
      book: book,
      tempDir: Directory(p.join(tmp.path, 'tmp')),
      destDirOverride: destDir,
    );

    expect(result.outcome, SubtitleAttachOutcome.cueLoadFailed);
    expect(
      File(p.join(destDir, '$uid.srt')).readAsStringSync(),
      contains('旧い字幕その一'),
    );
    expect((await repo.loadCues(uid)).map((AudioCue c) => c.text), <String>[
      '旧い字幕その一',
      '旧い字幕その二',
    ]);
  });
}

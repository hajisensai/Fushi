import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/remote_video_subtitle_service.dart';
import 'package:fushi/src/sync/interconnect_job_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart'
    show VideoSubtitleStage;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

HostJobTarget hostTarget(List<String> kinds) => HostJobTarget(
  baseUrl: 'http://host-a.invalid:8080',
  deviceName: 'Desk PC',
  kinds: kinds,
  capability: const <String, Object?>{},
);

/// host 替身：每次 [run] 按脚本推进一集。
class FakeHostPort implements RemoteVideoSubtitleHostPort {
  FakeHostPort({this.target, this.script});

  HostJobTarget? target;

  /// (videoId, outputDir, controller) → 推事件。null = 永不结束（取消用）。
  final Future<void> Function(
    String videoId,
    Directory outputDir,
    StreamController<HostJobEvent> controller,
  )?
  script;
  final List<Map<String, Object?>> submitted = <Map<String, Object?>>[];
  int cancelled = 0;

  @override
  Future<HostJobTarget?> probe() async => target;

  @override
  Stream<HostJobEvent> run({
    required HostJobTarget target,
    required Map<String, Object?> params,
    required Directory outputDir,
  }) {
    submitted.add(params);
    late final StreamController<HostJobEvent> controller;
    controller = StreamController<HostJobEvent>(
      onListen: () {
        final Future<void> Function(
          String,
          Directory,
          StreamController<HostJobEvent>,
        )?
        s = script;
        if (s != null) {
          unawaited(s(params['videoId']! as String, outputDir, controller));
        }
      },
      onCancel: () => cancelled++,
    );
    return controller.stream;
  }
}

/// 正常完成一集：一条进度，再写出 SRT + summary。
Future<void> exportEpisode(
  String videoId,
  Directory out,
  StreamController<HostJobEvent> c, {
  String status = 'exported',
}) async {
  c.add(const HostJobRunning(0.3, 'recognize: transcribing'));
  c.add(const HostJobRunning(0.7, 'proofread: proofreading 3/5'));
  await out.create(recursive: true);
  final bool exported = status == 'exported';
  final File srt = File(p.join(out.path, '$videoId.ja.srt'));
  if (exported) srt.writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\n唯\n');
  final File summary = File(p.join(out.path, 'summary.json'))
    ..writeAsStringSync(
      jsonEncode(<String, Object?>{
        'episodes': <Object?>[
          <String, Object?>{
            'video': '$videoId.mkv',
            'status': status,
            if (exported) 'output': '$videoId.ja.srt',
            if (!exported) 'reason': 'short clip classified as song',
          },
        ],
      }),
    );
  c.add(
    HostJobDone(<String, File>{
      if (exported) '$videoId.ja.srt': srt,
      'summary.json': summary,
    }),
  );
  await c.close();
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('remote_vsub_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  RemoteVideoSubtitleService service(FakeHostPort host) =>
      RemoteVideoSubtitleService(
        host: host,
        workRoot: () async => Directory(p.join(tmp.path, 'work')),
        subtitlesDir: () async => Directory(p.join(tmp.path, 'subs')),
      );

  const RemoteVideoSubtitleTarget single = RemoteVideoSubtitleTarget(
    title: 'K-ON 01',
    episodes: <RemoteVideoSubtitleEpisode>[
      RemoteVideoSubtitleEpisode(videoId: 'v1', title: 'K-ON 01'),
    ],
  );

  test('host 版本不支持 video_subtitle：unsupported，不提交任务', () async {
    final FakeHostPort host = FakeHostPort(target: hostTarget(<String>['asr']));
    final RemoteVideoSubtitleJob job = service(
      host,
    ).start(single, const RemoteVideoSubtitleOptions());
    await job.done;
    expect(job.status, RemoteVideoSubtitleJobStatus.unsupported);
    expect(job.hostLabel, 'Desk PC');
    expect(host.submitted, isEmpty);
  });

  test('连不上 host：unreachable', () async {
    final RemoteVideoSubtitleJob job = service(
      FakeHostPort(),
    ).start(single, const RemoteVideoSubtitleOptions());
    await job.done;
    expect(job.status, RemoteVideoSubtitleJobStatus.unreachable);
  });

  test('单集：参数带 videoId 与选项；阶段从进度文本解析；SRT 取回进字幕目录', () async {
    final FakeHostPort host = FakeHostPort(
      target: hostTarget(<String>['asr', 'video_subtitle']),
      script: exportEpisode,
    );
    final RemoteVideoSubtitleService svc = service(host);
    final List<VideoSubtitleStage?> stages = <VideoSubtitleStage?>[];
    final RemoteVideoSubtitleJob job = svc.start(
      single,
      const RemoteVideoSubtitleOptions(
        proofread: true,
        segmenter: VideoSubtitleSegmenterMode.window,
        mossBackend: MossBackendPreference.cpu,
      ),
    )..addListener(() {});
    job.addListener(() => stages.add(job.episodes.single.stage));
    await job.done;
    expect(job.status, RemoteVideoSubtitleJobStatus.succeeded);
    expect(host.submitted.single, <String, Object?>{
      'videoId': 'v1',
      'proofread': true,
      'segmenter': 'window',
      'mossBackend': 'cpu',
    });
    expect(
      stages,
      containsAllInOrder(<VideoSubtitleStage>[
        VideoSubtitleStage.recognize,
        VideoSubtitleStage.proofread,
      ]),
    );
    final File srt = job.episodes.single.subtitle!;
    expect(p.dirname(srt.path), p.join(tmp.path, 'subs'));
    expect(srt.readAsStringSync(), contains('唯'));
    expect(job.episodes.single.status, 'exported');
    expect(svc.latestJobFor(single), same(job));
    expect(svc.activeJob, isNull);
  });

  test('host 另出了套样式的 ASS：取回 ASS 而不是 SRT', () async {
    final FakeHostPort host = FakeHostPort(
      target: hostTarget(<String>['video_subtitle']),
      script:
          (String id, Directory out, StreamController<HostJobEvent> c) async {
            await out.create(recursive: true);
            final File srt = File(p.join(out.path, '$id.ja.srt'))
              ..writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\n唯\n');
            final File ass = File(p.join(out.path, '$id.ja.ass'))
              ..writeAsStringSync('[Script Info]\n');
            final File summary = File(p.join(out.path, 'summary.json'))
              ..writeAsStringSync(
                jsonEncode(<String, Object?>{
                  'episodes': <Object?>[
                    <String, Object?>{
                      'video': '$id.mkv',
                      'status': 'exported',
                      'output': '$id.ja.srt',
                      'styledOutput': '$id.ja.ass',
                    },
                  ],
                }),
              );
            c.add(
              HostJobDone(<String, File>{
                '$id.ja.srt': srt,
                '$id.ja.ass': ass,
                'summary.json': summary,
              }),
            );
            await c.close();
          },
    );
    final RemoteVideoSubtitleJob job = service(
      host,
    ).start(single, const RemoteVideoSubtitleOptions());
    await job.done;
    expect(job.status, RemoteVideoSubtitleJobStatus.succeeded);
    expect(job.episodes.single.subtitle!.path, endsWith('v1.ja.ass'));
  });

  test('host 报错（没指派提供商等）：failed，报错原样给用户，后面的集不再提交', () async {
    final FakeHostPort host = FakeHostPort(
      target: hostTarget(<String>['video_subtitle']),
      script: (String id, Directory out, StreamController<HostJobEvent> c) async {
        c.addError(
          const HostJobRemoteException(
            'http_400',
            '{"error":"bad_request","message":"video_subtitle: proofread needs an AI provider assigned to subtitleProofread"}',
          ),
        );
      },
    );
    final RemoteVideoSubtitleJob job = service(host).start(
      const RemoteVideoSubtitleTarget(
        title: 'K-ON',
        wholeSeason: true,
        episodes: <RemoteVideoSubtitleEpisode>[
          RemoteVideoSubtitleEpisode(videoId: 'v1', title: '01'),
          RemoteVideoSubtitleEpisode(videoId: 'v2', title: '02'),
        ],
      ),
      const RemoteVideoSubtitleOptions(proofread: true),
    );
    await job.done;
    expect(job.status, RemoteVideoSubtitleJobStatus.failed);
    expect(
      job.error,
      'video_subtitle: proofread needs an AI provider assigned to subtitleProofread',
    );
    expect(host.submitted, hasLength(1));
  });

  test('整季：逐集提交；判为歌曲的集记下原因、不取 SRT', () async {
    final FakeHostPort host = FakeHostPort(
      target: hostTarget(<String>['video_subtitle']),
      script: (String id, Directory out, StreamController<HostJobEvent> c) =>
          exportEpisode(
            id,
            out,
            c,
            status: id == 'op' ? 'skippedSong' : 'exported',
          ),
    );
    final RemoteVideoSubtitleJob job = service(host).start(
      const RemoteVideoSubtitleTarget(
        title: 'K-ON',
        wholeSeason: true,
        episodes: <RemoteVideoSubtitleEpisode>[
          RemoteVideoSubtitleEpisode(videoId: 'v1', title: '01'),
          RemoteVideoSubtitleEpisode(videoId: 'op', title: 'NCOP'),
        ],
      ),
      const RemoteVideoSubtitleOptions(),
    );
    await job.done;
    expect(job.status, RemoteVideoSubtitleJobStatus.succeeded);
    expect(
      host.submitted.map((Map<String, Object?> m) => m['videoId']),
      <String>['v1', 'op'],
    );
    expect(job.episodes[0].subtitle, isNotNull);
    expect(job.episodes[1].subtitle, isNull);
    expect(job.episodes[1].status, 'skippedSong');
    expect(job.episodes[1].reason, 'short clip classified as song');
  });

  test('取消：断开订阅（客户端据此 DELETE 远端任务），任务 cancelled', () async {
    final Completer<void> started = Completer<void>();
    final FakeHostPort host = FakeHostPort(
      target: hostTarget(<String>['video_subtitle']),
      script:
          (String id, Directory out, StreamController<HostJobEvent> c) async {
            c.add(const HostJobRunning(0.1, 'recognize: extracting audio'));
            started.complete();
          },
    );
    final RemoteVideoSubtitleJob job = service(
      host,
    ).start(single, const RemoteVideoSubtitleOptions());
    await started.future;
    await Future<void>.delayed(Duration.zero);
    job.cancel();
    await job.done;
    expect(job.status, RemoteVideoSubtitleJobStatus.cancelled);
    expect(host.cancelled, 1);
  });

  test('进度文本解析与报错原文', () {
    expect(
      parseRemoteVideoSubtitleStage('consistency: unifying spellings'),
      VideoSubtitleStage.consistency,
    );
    expect(parseRemoteVideoSubtitleStage('uploading'), isNull);
    expect(
      remoteVideoSubtitleErrorText(
        const HostJobRemoteException(
          'remote_error',
          'paused: AI request failed (quota_exhausted)',
        ),
      ),
      'paused: AI request failed (quota_exhausted)',
    );
    expect(
      remoteVideoSubtitleErrorText(const HostJobRemoteException('http_502')),
      'http_502',
    );
  });

  group('InterconnectJobClient.probeHost', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('只问放视频的那台 host；老 host 返回空 kinds（区分「不支持」与连不上）', () async {
      final SyncRepository repo = SyncRepository(db);
      await repo.setFushiClientToken('tok');
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://host-a.invalid:8080', deviceName: 'A'),
        FushiClientUrl(url: 'http://host-b.invalid:8080', deviceName: 'B'),
      ]);
      final List<String> asked = <String>[];
      final InterconnectJobClient client = InterconnectJobClient(
        repo: repo,
        httpClient: MockClient((http.Request r) async {
          asked.add(r.url.host);
          if (r.url.host == 'host-b.invalid') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'jobs': <String, Object?>{
                  'kinds': <String>['asr', 'video_subtitle'],
                },
              }),
              200,
            );
          }
          return http.Response(jsonEncode(<String, Object?>{}), 200);
        }),
      );
      final HostJobTarget? b = await client.probeHost(
        'http://host-b.invalid:8080/',
      );
      expect(b?.deviceName, 'B');
      expect(b?.supports('video_subtitle'), isTrue);
      expect(asked, <String>['host-b.invalid']);

      final HostJobTarget? a = await client.probeHost(
        'http://host-a.invalid:8080',
      );
      expect(a, isNotNull);
      expect(a!.kinds, isEmpty);
      expect(await client.probeHost('http://unknown.invalid'), isNull);
    });
  });
}

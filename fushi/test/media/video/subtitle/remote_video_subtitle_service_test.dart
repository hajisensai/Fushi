import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/remote_video_subtitle_service.dart';
import 'package:fushi/src/sync/interconnect_job_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_language.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart'
    show VideoSubtitleStage;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

HostJobTarget hostTarget(
  List<String> kinds, {
  Map<String, Object?> capability = const <String, Object?>{},
}) => HostJobTarget(
  baseUrl: 'http://host-a.invalid:8080',
  deviceName: 'Desk PC',
  kinds: kinds,
  capability: capability,
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

  group('host 播放列表第 2 集起（集下标 > 0）', () {
    const RemoteVideoSubtitleTarget episode2 = RemoteVideoSubtitleTarget(
      title: 'K-ON 02',
      episodes: <RemoteVideoSubtitleEpisode>[
        RemoteVideoSubtitleEpisode(
          videoId: 'v1',
          episodeIndex: 1,
          title: 'K-ON 02',
        ),
      ],
    );

    test(
      '老 host（capability 没有 acceptsEpisode）：episodeUnsupported，不提交任务',
      () async {
        final FakeHostPort host = FakeHostPort(
          target: hostTarget(
            <String>['video_subtitle'],
            capability: const <String, Object?>{
              'video_subtitle': <String, Object?>{'acceptsVideoId': true},
            },
          ),
          script: exportEpisode,
        );
        final RemoteVideoSubtitleJob job = service(
          host,
        ).start(episode2, const RemoteVideoSubtitleOptions());
        await job.done;
        expect(job.status, RemoteVideoSubtitleJobStatus.episodeUnsupported);
        expect(host.submitted, isEmpty, reason: '老 host 会静默跑第 1 集，一个任务都不能发');
      },
    );

    test('老 host 上的第 1 集照常提交，不带 episode', () async {
      final FakeHostPort host = FakeHostPort(
        target: hostTarget(<String>['video_subtitle']),
        script: exportEpisode,
      );
      final RemoteVideoSubtitleJob job = service(
        host,
      ).start(single, const RemoteVideoSubtitleOptions());
      await job.done;
      expect(job.status, RemoteVideoSubtitleJobStatus.succeeded);
      expect(host.submitted.single.containsKey('episode'), isFalse);
    });

    test('新 host：参数带 episode；同一 videoId 的各集任务键与落盘名互不相同', () async {
      final FakeHostPort host = FakeHostPort(
        target: hostTarget(
          <String>['video_subtitle'],
          capability: const <String, Object?>{
            'video_subtitle': <String, Object?>{'acceptsEpisode': true},
          },
        ),
        script: exportEpisode,
      );
      final RemoteVideoSubtitleService svc = service(host);
      final RemoteVideoSubtitleJob first = svc.start(
        single,
        const RemoteVideoSubtitleOptions(),
      );
      await first.done;
      final RemoteVideoSubtitleJob second = svc.start(
        episode2,
        const RemoteVideoSubtitleOptions(),
      );
      await second.done;
      expect(second.status, RemoteVideoSubtitleJobStatus.succeeded);
      expect(host.submitted.last, <String, Object?>{
        'videoId': 'v1',
        'episode': 1,
        'proofread': false,
        'segmenter': 'auto',
        'mossBackend': 'auto',
      });
      expect(single.key, isNot(episode2.key));
      expect(svc.latestJobFor(single), same(first));
      expect(svc.latestJobFor(episode2), same(second));
      final File a = first.episodes.single.subtitle!;
      final File b = second.episodes.single.subtitle!;
      expect(a.path, isNot(b.path), reason: '第 2 集取回的字幕不能覆盖第 1 集的');
      expect(a.existsSync(), isTrue);
      expect(b.existsSync(), isTrue);
      expect(second.episodes.single.episode.matches('v1', 1), isTrue);
      expect(second.episodes.single.episode.matches('v1', 0), isFalse);
    });
  });

  group('远端原盘会话的 title', () {
    const RemoteVideoSubtitleTarget mainTitle = RemoteVideoSubtitleTarget(
      title: 'Disc · 00001',
      episodes: <RemoteVideoSubtitleEpisode>[
        RemoteVideoSubtitleEpisode(videoId: 'disc-main', title: 'Disc · 00001'),
      ],
    );
    const RemoteVideoSubtitleTarget bonus = RemoteVideoSubtitleTarget(
      title: 'Disc · 00005',
      episodes: <RemoteVideoSubtitleEpisode>[
        RemoteVideoSubtitleEpisode(
          videoId: 'disc-main',
          discTitle: 'BDMV/PLAYLIST/00005.mpls',
          title: 'Disc · 00005',
        ),
      ],
    );

    test('老 host（没有 acceptsDiscTitle）：discTitleUnsupported，不提交任务', () async {
      final FakeHostPort host = FakeHostPort(
        target: hostTarget(
          <String>['video_subtitle'],
          capability: const <String, Object?>{
            'video_subtitle': <String, Object?>{'acceptsEpisode': true},
          },
        ),
        script: exportEpisode,
      );
      final RemoteVideoSubtitleJob job = service(
        host,
      ).start(bonus, const RemoteVideoSubtitleOptions());
      await job.done;
      expect(job.status, RemoteVideoSubtitleJobStatus.discTitleUnsupported);
      expect(host.submitted, isEmpty, reason: '老 host 会静默跑锚点那一行');
    });

    test('DVD title：host 没声明 acceptsDiscTitleDvd 不发，声明了才带 DVD title', () async {
      const RemoteVideoSubtitleTarget dvd = RemoteVideoSubtitleTarget(
        title: 'DVD · TITLE_02',
        episodes: <RemoteVideoSubtitleEpisode>[
          RemoteVideoSubtitleEpisode(
            videoId: 'dvd-main',
            discTitle: 'VIDEO_TS/TITLE_02.dvdtitle',
            title: 'DVD · TITLE_02',
          ),
        ],
      );
      expect(dvd.needsDiscTitleDvdSupport, isTrue);
      expect(bonus.needsDiscTitleDvdSupport, isFalse);
      final FakeHostPort old = FakeHostPort(
        target: hostTarget(
          <String>['video_subtitle'],
          capability: const <String, Object?>{
            'video_subtitle': <String, Object?>{
              'acceptsDiscTitle': true,
              'acceptsDiscTitleAngle': true,
            },
          },
        ),
        script: exportEpisode,
      );
      final RemoteVideoSubtitleJob rejected = service(
        old,
      ).start(dvd, const RemoteVideoSubtitleOptions());
      await rejected.done;
      expect(
        rejected.status,
        RemoteVideoSubtitleJobStatus.discTitleUnsupported,
      );
      expect(old.submitted, isEmpty, reason: '老 host 判 DVD title 读不到');

      final FakeHostPort host = FakeHostPort(
        target: hostTarget(
          <String>['video_subtitle'],
          capability: const <String, Object?>{
            'video_subtitle': <String, Object?>{
              'acceptsDiscTitle': true,
              'acceptsDiscTitleDvd': true,
            },
          },
        ),
        script: exportEpisode,
      );
      final RemoteVideoSubtitleJob job = service(
        host,
      ).start(dvd, const RemoteVideoSubtitleOptions());
      await job.done;
      expect(job.status, RemoteVideoSubtitleJobStatus.succeeded);
      expect(host.submitted.single['discTitle'], 'VIDEO_TS/TITLE_02.dvdtitle');
    });

    test(
      'DVD 多角度 title：host 没声明 acceptsDiscTitleDvdAngle 不发，声明了才带角度成员路径',
      () async {
        const RemoteVideoSubtitleTarget dvdAngle = RemoteVideoSubtitleTarget(
          title: 'DVD · TITLE_02',
          episodes: <RemoteVideoSubtitleEpisode>[
            RemoteVideoSubtitleEpisode(
              videoId: 'dvd-main',
              discTitle: 'VIDEO_TS/TITLE_02.a2.dvdtitle',
              title: 'DVD · TITLE_02',
            ),
          ],
        );
        expect(dvdAngle.needsDiscTitleDvdSupport, isTrue);
        expect(dvdAngle.needsDiscTitleDvdAngleSupport, isTrue);
        expect(dvdAngle.needsDiscTitleAngleSupport, isFalse);
        expect(bonus.needsDiscTitleDvdAngleSupport, isFalse);
        // 上一版 host：DVD title 与蓝光角度都认，但认不出 DVD 角度成员路径。
        final HostJobTarget oldTarget = hostTarget(
          <String>['video_subtitle'],
          capability: const <String, Object?>{
            'video_subtitle': <String, Object?>{
              'acceptsDiscTitle': true,
              'acceptsDiscTitleAngle': true,
              'acceptsDiscTitleDvd': true,
            },
          },
        );
        expect(dvdAngle.discTitlesSupportedBy(oldTarget), isFalse);
        final FakeHostPort old = FakeHostPort(
          target: oldTarget,
          script: exportEpisode,
        );
        final RemoteVideoSubtitleJob rejected = service(
          old,
        ).start(dvdAngle, const RemoteVideoSubtitleOptions());
        await rejected.done;
        expect(
          rejected.status,
          RemoteVideoSubtitleJobStatus.discTitleUnsupported,
        );
        expect(old.submitted, isEmpty, reason: '老 host 认不出 DVD 角度成员路径');

        final HostJobTarget newTarget = hostTarget(
          <String>['video_subtitle'],
          capability: const <String, Object?>{
            'video_subtitle': <String, Object?>{
              'acceptsDiscTitle': true,
              'acceptsDiscTitleDvd': true,
              'acceptsDiscTitleDvdAngle': true,
            },
          },
        );
        expect(dvdAngle.discTitlesSupportedBy(newTarget), isTrue);
        final FakeHostPort host = FakeHostPort(
          target: newTarget,
          script: exportEpisode,
        );
        final RemoteVideoSubtitleJob job = service(
          host,
        ).start(dvdAngle, const RemoteVideoSubtitleOptions());
        await job.done;
        expect(job.status, RemoteVideoSubtitleJobStatus.succeeded);
        expect(
          host.submitted.single['discTitle'],
          'VIDEO_TS/TITLE_02.a2.dvdtitle',
        );
      },
    );

    test('多角度 title：host 没声明 acceptsDiscTitleAngle 不发，声明了才带角度成员路径', () async {
      const RemoteVideoSubtitleTarget angle = RemoteVideoSubtitleTarget(
        title: 'Disc · 00001',
        episodes: <RemoteVideoSubtitleEpisode>[
          RemoteVideoSubtitleEpisode(
            videoId: 'disc-main',
            discTitle: 'BDMV/PLAYLIST/00001.a2.mpls',
            title: 'Disc · 00001',
          ),
        ],
      );
      expect(angle.needsDiscTitleAngleSupport, isTrue);
      expect(bonus.needsDiscTitleAngleSupport, isFalse);
      final FakeHostPort old = FakeHostPort(
        target: hostTarget(
          <String>['video_subtitle'],
          capability: const <String, Object?>{
            'video_subtitle': <String, Object?>{'acceptsDiscTitle': true},
          },
        ),
        script: exportEpisode,
      );
      final RemoteVideoSubtitleJob rejected = service(
        old,
      ).start(angle, const RemoteVideoSubtitleOptions());
      await rejected.done;
      expect(
        rejected.status,
        RemoteVideoSubtitleJobStatus.discTitleUnsupported,
      );
      expect(old.submitted, isEmpty, reason: '老 host 读不到角度成员路径');

      final FakeHostPort host = FakeHostPort(
        target: hostTarget(
          <String>['video_subtitle'],
          capability: const <String, Object?>{
            'video_subtitle': <String, Object?>{
              'acceptsDiscTitle': true,
              'acceptsDiscTitleAngle': true,
            },
          },
        ),
        script: exportEpisode,
      );
      final RemoteVideoSubtitleJob job = service(
        host,
      ).start(angle, const RemoteVideoSubtitleOptions());
      await job.done;
      expect(job.status, RemoteVideoSubtitleJobStatus.succeeded);
      expect(host.submitted.single['discTitle'], 'BDMV/PLAYLIST/00001.a2.mpls');
      expect(
        job.episodes.single.episode.matchesDiscTitle(
          'disc-main',
          'BDMV/PLAYLIST/00001.a2.mpls',
        ),
        isTrue,
      );
    });

    test('库里有行的 title 在老 host 上照常提交，不带 discTitle', () async {
      final FakeHostPort host = FakeHostPort(
        target: hostTarget(<String>['video_subtitle']),
        script: exportEpisode,
      );
      final RemoteVideoSubtitleJob job = service(
        host,
      ).start(mainTitle, const RemoteVideoSubtitleOptions());
      await job.done;
      expect(job.status, RemoteVideoSubtitleJobStatus.succeeded);
      expect(host.submitted.single.containsKey('discTitle'), isFalse);
      expect(
        job.episodes.single.episode.matchesDiscTitle('disc-main', null),
        isTrue,
      );
    });

    test('新 host：参数带 discTitle；与锚点行的任务键、落盘名互不相同', () async {
      final FakeHostPort host = FakeHostPort(
        target: hostTarget(
          <String>['video_subtitle'],
          capability: const <String, Object?>{
            'video_subtitle': <String, Object?>{'acceptsDiscTitle': true},
          },
        ),
        script: exportEpisode,
      );
      final RemoteVideoSubtitleService svc = service(host);
      final RemoteVideoSubtitleJob first = svc.start(
        mainTitle,
        const RemoteVideoSubtitleOptions(),
      );
      await first.done;
      final RemoteVideoSubtitleJob second = svc.start(
        bonus,
        const RemoteVideoSubtitleOptions(),
      );
      await second.done;
      expect(second.status, RemoteVideoSubtitleJobStatus.succeeded);
      expect(host.submitted.last, <String, Object?>{
        'videoId': 'disc-main',
        'discTitle': 'BDMV/PLAYLIST/00005.mpls',
        'proofread': false,
        'segmenter': 'auto',
        'mossBackend': 'auto',
      });
      expect(mainTitle.key, isNot(bonus.key));
      expect(svc.latestJobFor(bonus), same(second));
      final File a = first.episodes.single.subtitle!;
      final File b = second.episodes.single.subtitle!;
      expect(a.path, isNot(b.path), reason: '特典 title 取回的字幕不能覆盖正片的');
      final RemoteVideoSubtitleEpisode e = second.episodes.single.episode;
      expect(
        e.matchesDiscTitle('disc-main', 'BDMV/PLAYLIST/00005.mpls'),
        isTrue,
      );
      expect(e.matchesDiscTitle('disc-main', null), isFalse);
      expect(e.matches('disc-main', 0), isFalse, reason: '不能当成锚点那一行');
    });
  });

  group('播放器当前音轨（audioTrack）', () {
    const RemoteVideoSubtitleTarget episodeTrack = RemoteVideoSubtitleTarget(
      title: 'K-ON 02',
      episodes: <RemoteVideoSubtitleEpisode>[
        RemoteVideoSubtitleEpisode(
          videoId: 'v1',
          episodeIndex: 1,
          title: 'K-ON 02',
          audioTrack: 1,
        ),
      ],
    );
    const RemoteVideoSubtitleTarget discTrack = RemoteVideoSubtitleTarget(
      title: 'Disc · 00005',
      episodes: <RemoteVideoSubtitleEpisode>[
        RemoteVideoSubtitleEpisode(
          videoId: 'disc-main',
          discTitle: 'BDMV/PLAYLIST/00005.mpls',
          title: 'Disc · 00005',
          audioTrack: 2,
        ),
      ],
    );

    test(
      '新 host（acceptsAudioTrack）：参数带 audioTrack，可与 episode / discTitle 组合',
      () async {
        final FakeHostPort host = FakeHostPort(
          target: hostTarget(
            <String>['video_subtitle'],
            capability: const <String, Object?>{
              'video_subtitle': <String, Object?>{
                'acceptsEpisode': true,
                'acceptsDiscTitle': true,
                'acceptsAudioTrack': true,
              },
            },
          ),
          script: exportEpisode,
        );
        final RemoteVideoSubtitleService svc = service(host);
        expect(episodeTrack.wantsAudioTrack, isTrue);
        expect(single.wantsAudioTrack, isFalse);
        await svc.start(episodeTrack, const RemoteVideoSubtitleOptions()).done;
        final RemoteVideoSubtitleJob disc = svc.start(
          discTrack,
          const RemoteVideoSubtitleOptions(),
        );
        await disc.done;
        expect(disc.status, RemoteVideoSubtitleJobStatus.succeeded);
        expect(host.submitted.first['episode'], 1);
        expect(host.submitted.first['audioTrack'], 1);
        expect(host.submitted.last, <String, Object?>{
          'videoId': 'disc-main',
          'discTitle': 'BDMV/PLAYLIST/00005.mpls',
          'audioTrack': 2,
          'proofread': false,
          'segmenter': 'auto',
          'mossBackend': 'auto',
        });
      },
    );

    test(
      '老 host（没有 acceptsAudioTrack）：照常提交、不带 audioTrack（按语言挑，降级不拦）',
      () async {
        final FakeHostPort host = FakeHostPort(
          target: hostTarget(
            <String>['video_subtitle'],
            capability: const <String, Object?>{
              'video_subtitle': <String, Object?>{'acceptsEpisode': true},
            },
          ),
          script: exportEpisode,
        );
        final RemoteVideoSubtitleJob job = service(
          host,
        ).start(episodeTrack, const RemoteVideoSubtitleOptions());
        await job.done;
        expect(job.status, RemoteVideoSubtitleJobStatus.succeeded);
        expect(host.submitted.single['episode'], 1);
        expect(host.submitted.single.containsKey('audioTrack'), isFalse);
        expect(hostAcceptsVideoSubtitleAudioTrack(host.target!), isFalse);
      },
    );

    test('没有播放上下文（audioTrack 为 null）：新 host 上也不带', () async {
      final FakeHostPort host = FakeHostPort(
        target: hostTarget(
          <String>['video_subtitle'],
          capability: const <String, Object?>{
            'video_subtitle': <String, Object?>{'acceptsAudioTrack': true},
          },
        ),
        script: exportEpisode,
      );
      await service(
        host,
      ).start(single, const RemoteVideoSubtitleOptions()).done;
      expect(host.submitted.single.containsKey('audioTrack'), isFalse);
    });
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

  group('生成语言（capability 的 languages）', () {
    HostJobTarget languageHost() => hostTarget(
      <String>['video_subtitle'],
      capability: const <String, Object?>{
        'video_subtitle': <String, Object?>{
          'languages': <String>['ja', 'zh'],
        },
      },
    );

    test('老 host（没列 languages）选普通话：languageUnsupported，不提交任务', () async {
      final FakeHostPort host = FakeHostPort(
        target: hostTarget(<String>['video_subtitle']),
        script: exportEpisode,
      );
      final RemoteVideoSubtitleJob job = service(host).start(
        single,
        const RemoteVideoSubtitleOptions(
          language: VideoSubtitleLanguage.mandarin,
        ),
      );
      await job.done;
      expect(job.status, RemoteVideoSubtitleJobStatus.languageUnsupported);
      expect(host.submitted, isEmpty);
    });

    test('老 host 上的日语任务照常提交，不带 language', () async {
      final FakeHostPort host = FakeHostPort(
        target: hostTarget(<String>['video_subtitle']),
        script: exportEpisode,
      );
      final RemoteVideoSubtitleJob job = service(
        host,
      ).start(single, const RemoteVideoSubtitleOptions());
      await job.done;
      expect(job.status, RemoteVideoSubtitleJobStatus.succeeded);
      expect(host.submitted.single.containsKey('language'), isFalse);
    });

    test('新 host：参数带 language；任务键按语言分', () async {
      final FakeHostPort host = FakeHostPort(
        target: languageHost(),
        script: exportEpisode,
      );
      final RemoteVideoSubtitleService svc = service(host);
      final RemoteVideoSubtitleJob ja = svc.start(
        single,
        const RemoteVideoSubtitleOptions(),
      );
      await ja.done;
      final RemoteVideoSubtitleJob zh = svc.start(
        single,
        const RemoteVideoSubtitleOptions(
          language: VideoSubtitleLanguage.mandarin,
        ),
      );
      await zh.done;
      expect(zh.status, RemoteVideoSubtitleJobStatus.succeeded);
      expect(
        host.submitted.map((Map<String, Object?> m) => m['language']),
        <String>['ja', 'zh'],
      );
      expect(
        svc.latestJobFor(single, language: VideoSubtitleLanguage.japanese),
        same(ja),
      );
      expect(
        svc.latestJobFor(single, language: VideoSubtitleLanguage.mandarin),
        same(zh),
      );
      // 不指定语言：最近起的那个（面板据此恢复语言）。
      expect(svc.latestJobFor(single), same(zh));
    });

    test('整季：已有字幕跳过按语言算', () {
      final RemoteVideoSubtitleTarget season = RemoteVideoSubtitleTarget.season(
        title: 'K-ON',
        members: const <RemoteVideoSubtitleSeasonMember>[
          RemoteVideoSubtitleSeasonMember(
            episode: RemoteVideoSubtitleEpisode(videoId: 'v1', title: '01'),
            subtitleFileName: 'K-ON 01.ja.srt',
          ),
          RemoteVideoSubtitleSeasonMember(
            episode: RemoteVideoSubtitleEpisode(videoId: 'v2', title: '02'),
            subtitleFileName: 'K-ON 02.ZH.srt',
          ),
          RemoteVideoSubtitleSeasonMember(
            episode: RemoteVideoSubtitleEpisode(videoId: 'v3', title: '03'),
          ),
        ],
      );
      expect(season.wholeSeason, isTrue);
      expect(
        season.episodes.map((RemoteVideoSubtitleEpisode e) => e.videoId),
        <String>['v2', 'v3'],
      );
      expect(season.skippedExisting, <String>['01']);
      final RemoteVideoSubtitleTarget zh = season.forLanguage(
        VideoSubtitleLanguage.mandarin,
      );
      expect(
        zh.episodes.map((RemoteVideoSubtitleEpisode e) => e.videoId),
        <String>['v1', 'v3'],
      );
      expect(zh.skippedExisting, <String>['02']);
      expect(zh.key, isNot(season.key));
      // 换回日语与原目标同一组成员。
      expect(zh.forLanguage(VideoSubtitleLanguage.japanese).key, season.key);
      // 单集目标不受语言影响。
      expect(
        identical(single.forLanguage(VideoSubtitleLanguage.mandarin), single),
        isTrue,
      );
    });
  });

  group('BUG-4909 产物临时目录', () {
    List<FileSystemEntity> workLeft() {
      final Directory work = Directory(p.join(tmp.path, 'work'));
      return work.existsSync() ? work.listSync() : const <FileSystemEntity>[];
    }

    /// host 先往产物目录写了半截文件，再按 [end] 结束。
    Future<void> Function(String, Directory, StreamController<HostJobEvent>)
    partialThen(void Function(StreamController<HostJobEvent> c) end) =>
        (String id, Directory out, StreamController<HostJobEvent> c) async {
          await out.create(recursive: true);
          File(p.join(out.path, '$id.ja.srt.part')).writeAsStringSync('1');
          c.add(const HostJobRunning(0.5, 'recognize: transcribing'));
          end(c);
        };

    test('成功：取回后删掉', () async {
      final FakeHostPort host = FakeHostPort(
        target: hostTarget(<String>['video_subtitle']),
        script: exportEpisode,
      );
      final RemoteVideoSubtitleJob job = service(
        host,
      ).start(single, const RemoteVideoSubtitleOptions());
      await job.done;
      expect(job.status, RemoteVideoSubtitleJobStatus.succeeded);
      expect(workLeft(), isEmpty);
    });

    test('host 报错：任务收尾时目录已删', () async {
      final FakeHostPort host = FakeHostPort(
        target: hostTarget(<String>['video_subtitle']),
        script: partialThen(
          (StreamController<HostJobEvent> c) =>
              c.addError(const HostJobRemoteException('remote_error', 'boom')),
        ),
      );
      final RemoteVideoSubtitleJob job = service(
        host,
      ).start(single, const RemoteVideoSubtitleOptions());
      await job.done;
      expect(job.status, RemoteVideoSubtitleJobStatus.failed);
      expect(workLeft(), isEmpty);
    });

    test('流没给结果就结束：任务收尾时目录已删', () async {
      final FakeHostPort host = FakeHostPort(
        target: hostTarget(<String>['video_subtitle']),
        script: partialThen(
          (StreamController<HostJobEvent> c) => unawaited(c.close()),
        ),
      );
      final RemoteVideoSubtitleJob job = service(
        host,
      ).start(single, const RemoteVideoSubtitleOptions());
      await job.done;
      expect(job.status, RemoteVideoSubtitleJobStatus.failed);
      expect(workLeft(), isEmpty);
    });

    test('取消：任务收尾时目录已删', () async {
      final Completer<void> started = Completer<void>();
      final FakeHostPort host = FakeHostPort(
        target: hostTarget(<String>['video_subtitle']),
        script: partialThen(
          (StreamController<HostJobEvent> _) => started.complete(),
        ),
      );
      final RemoteVideoSubtitleJob job = service(
        host,
      ).start(single, const RemoteVideoSubtitleOptions());
      await started.future;
      await Future<void>.delayed(Duration.zero);
      job.cancel();
      await job.done;
      expect(job.status, RemoteVideoSubtitleJobStatus.cancelled);
      expect(workLeft(), isEmpty);
    });
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
        plainClientFactory: () => MockClient((http.Request r) async {
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

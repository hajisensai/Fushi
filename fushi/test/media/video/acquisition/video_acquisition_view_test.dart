import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_view.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart'
    show VideoDownloadBackendUnavailable;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

/// 视图是跨设备的 wire：与语言无关、JSON 往返无损、对新版 host 的未知字段宽容。
void main() {
  VideoAcquisitionView roundTrip(VideoAcquisitionView view) =>
      VideoAcquisitionView.fromJson(
        (jsonDecode(jsonEncode(view.toJson())) as Map).cast<String, Object?>(),
      );

  test('投影 + JSON 往返：发言、问题、作品类别、操作条都原样过线', () {
    final VideoAcquisitionState state = VideoAcquisitionState(
      stage: VideoAcquisitionStage.awaitingWorkChoice,
      transcript: const <VideoAcquisitionMessage>[
        VideoAcquisitionUserMessage('下 Show'),
        VideoAcquisitionAssistantMessage(
          VideoAcquisitionSay(
            VideoAcquisitionSayKind.summary,
            args: <String, Object?>{
              'releaseGroup': 'Group',
              'count': 3,
              'batch': false,
              'missing': <int>[4, 5],
              'confidence': 0.9,
            },
          ),
        ),
      ],
      question: const VideoAcquisitionQuestion(
        slot: VideoAcquisitionSlot.work,
        options: <VideoAcquisitionOption>[
          VideoAcquisitionOption(id: '0', label: 'Show', hint: '2026'),
          VideoAcquisitionOption(id: kVideoAcquisitionOptionNone),
        ],
        rememberToggle: true,
        rememberDefault: false,
        preselectedIndex: 0,
        args: <String, Object?>{'wanted': '1080p'},
      ),
      workCandidates: <VideoDiscoveryItem>[_item()],
    );

    final VideoAcquisitionView view = roundTrip(
      projectVideoAcquisitionView(state),
    );

    expect(view.stage, VideoAcquisitionStage.awaitingWorkChoice);
    expect(view.transcript, hasLength(2));
    expect(
      (view.transcript.first as VideoAcquisitionUserMessage).text,
      '下 Show',
    );
    final VideoAcquisitionSay say =
        (view.transcript.last as VideoAcquisitionAssistantMessage).say;
    expect(say.kind, VideoAcquisitionSayKind.summary);
    expect(say.args['releaseGroup'], 'Group');
    expect(say.args['count'], 3);
    expect(say.args['missing'], <int>[4, 5]);
    expect(say.args['confidence'], 0.9);
    final VideoAcquisitionQuestion q = view.question!;
    expect(q.slot, VideoAcquisitionSlot.work);
    expect(q.options.map((VideoAcquisitionOption o) => o.id), <String>[
      '0',
      kVideoAcquisitionOptionNone,
    ]);
    expect(q.options.first.label, 'Show');
    expect(q.options.first.hint, '2026');
    expect(q.options.last.label, isNull);
    expect(q.rememberToggle, isTrue);
    expect(q.rememberDefault, isFalse);
    expect(q.preselectedIndex, 0);
    expect(q.args['wanted'], '1080p');
    expect(view.workCandidateCategories, <VideoDiscoveryCategory?>[
      VideoDiscoveryCategory.anime,
    ]);
  });

  // BUG-2958：候选版本的比较事实挂在选项 args 上过线；旧 host 不带 args 时为空。
  test('选项 args 原样过线；没有 args 的选项不写这个键', () {
    const VideoAcquisitionView view = VideoAcquisitionView(
      stage: VideoAcquisitionStage.awaitingResourceConfirm,
      question: VideoAcquisitionQuestion(
        slot: VideoAcquisitionSlot.resource,
        options: <VideoAcquisitionOption>[
          VideoAcquisitionOption(id: kVideoAcquisitionOptionConfirm),
          VideoAcquisitionOption(
            id: '${kVideoAcquisitionOptionAltPrefix}1',
            args: <String, Object?>{
              'releaseGroup': 'Erai-raws',
              'traits': 'HEVC 10bit',
              'seeders': 30,
              'batch': true,
              'missing': <int>[3],
            },
          ),
        ],
      ),
    );
    final List<Object?> wireOptions =
        (view.toJson()['question']! as Map)['options']! as List<Object?>;
    expect((wireOptions[0]! as Map).containsKey('args'), isFalse);

    final List<VideoAcquisitionOption> options = roundTrip(
      view,
    ).question!.options;
    expect(options[0].args, isEmpty);
    expect(options[1].args, <String, Object?>{
      'releaseGroup': 'Erai-raws',
      'traits': 'HEVC 10bit',
      'seeders': 30,
      'batch': true,
      'missing': <int>[3],
    });
  });

  test('失败按钮提示从原始异常推出、过线后仍在', () {
    final VideoAcquisitionView view = roundTrip(
      projectVideoAcquisitionView(
        const VideoAcquisitionState(),
        lastError: const VideoDownloadBackendUnavailable('embedded'),
      ),
    );
    expect(view.failureHint, VideoAcquisitionFailureHint.configureBackend);
    expect(
      projectVideoAcquisitionView(
        const VideoAcquisitionState(),
        lastError: ArgumentError('no backend'),
      ).failureHint,
      VideoAcquisitionFailureHint.backendNotConfigured,
    );
  });

  test('新版 host 的未知发言种类 / 槽位 / 阶段整条跳过，不让整页解析失败', () {
    final VideoAcquisitionView view = VideoAcquisitionView.fromJson(
      <String, Object?>{
        'stage': 'somethingNew',
        'transcript': <Object?>[
          <String, Object?>{'role': 'assistant', 'kind': 'brandNewKind'},
          <String, Object?>{
            'role': 'assistant',
            'kind': 'question',
            'question': <String, Object?>{'slot': 'brandNewSlot'},
          },
          <String, Object?>{'role': 'user', 'text': 'hi'},
          'garbage',
        ],
        'question': <String, Object?>{'slot': 'brandNewSlot'},
      },
    );
    expect(view.stage, VideoAcquisitionStage.idle);
    expect(view.transcript, hasLength(1));
    expect(view.question, isNull);
  });

  test('参数里混进非 JSON 值时转成字符串，保证编码不炸', () {
    final VideoAcquisitionView view = VideoAcquisitionView(
      transcript: <VideoAcquisitionMessage>[
        VideoAcquisitionAssistantMessage(
          VideoAcquisitionSay(
            VideoAcquisitionSayKind.failed,
            args: <String, Object?>{'message': Uri.parse('x://y')},
          ),
        ),
      ],
    );
    final VideoAcquisitionView back = roundTrip(view);
    expect(
      (back.transcript.single as VideoAcquisitionAssistantMessage)
          .say
          .args['message'],
      'x://y',
    );
  });
}

VideoDiscoveryItem _item() => VideoDiscoveryItem(
  reference: VideoMediaReference(
    providerId: 'mal',
    mediaId: '1',
    mediaKind: VideoMetadataMediaKind.tv,
    discoveryCategory: VideoDiscoveryCategory.anime,
    title: 'Show',
    year: 2026,
  ),
);

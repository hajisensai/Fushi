import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/remote_subtitle_catalog.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoEmbeddedSubtitleTrack;

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 反馈 wCQIR4Pvz9「Jellyfin 标为默认的字幕起播不显示」。
///
/// 根因：① `JellyfinApi.parseMediaSource` 构造字幕流时不读 `IsDefault`（音轨才读）；
/// ② 远端起播只认后端默认**外挂**字幕（`subtitleUrl`），内嵌轨只能手选——服务器标了
/// 默认的内嵌字幕永远不会自动挂上。
///
/// 拍板：app 字幕偏好优先，偏好未命中再用服务器默认标记。
/// [pickRemoteStartupSubtitleTrack] 是这条优先级的唯一判据；页面接线用源码守卫钉住
/// （播放页在 headless test 里起不了真播放器）。
RemoteVideoEmbeddedSubtitleTrack _track(
  int index, {
  String? language,
  String? title,
  bool isText = true,
  bool isDefault = false,
  bool isExternalFile = false,
}) => RemoteVideoEmbeddedSubtitleTrack(
  streamIndex: index,
  codec: isText ? 'subrip' : 'PGSSUB',
  language: language,
  title: title,
  isText: isText,
  isDefault: isDefault,
  isExternalFile: isExternalFile,
);

void main() {
  group('pickRemoteStartupSubtitleTrack', () {
    final List<RemoteVideoEmbeddedSubtitleTrack> tracks =
        <RemoteVideoEmbeddedSubtitleTrack>[
          _track(2, language: 'eng', title: 'English - SRT'),
          _track(
            3,
            language: 'jpn',
            title: 'Japanese - Default - ASS',
            isDefault: true,
          ),
          _track(4, language: 'chi', title: '简体中文 ASS'),
        ];

    test('偏好为空 → 服务器默认标记那条', () {
      expect(
        pickRemoteStartupSubtitleTrack(
          tracks,
          preferences: const <String>[],
        )?.streamIndex,
        3,
      );
    });

    test('偏好命中 → 压过服务器默认标记', () {
      expect(
        pickRemoteStartupSubtitleTrack(
          tracks,
          preferences: const <String>['chs'],
        )?.streamIndex,
        4,
      );
      expect(
        pickRemoteStartupSubtitleTrack(
          tracks,
          preferences: const <String>['english'],
        )?.streamIndex,
        2,
      );
    });

    test('偏好按条目顺序：第一条没命中就看第二条', () {
      expect(
        pickRemoteStartupSubtitleTrack(
          tracks,
          preferences: const <String>['kor', 'eng'],
        )?.streamIndex,
        2,
      );
    });

    test('偏好全不命中 → 回到服务器默认标记', () {
      expect(
        pickRemoteStartupSubtitleTrack(
          tracks,
          preferences: const <String>['kor'],
        )?.streamIndex,
        3,
      );
    });

    test('没偏好命中也没默认标记 → null（调用方落回后端默认外挂字幕）', () {
      expect(
        pickRemoteStartupSubtitleTrack(
          <RemoteVideoEmbeddedSubtitleTrack>[
            _track(2, language: 'eng'),
            _track(5, language: 'jpn', isExternalFile: true),
          ],
          preferences: const <String>['kor'],
        ),
        isNull,
      );
      expect(
        pickRemoteStartupSubtitleTrack(
          const <RemoteVideoEmbeddedSubtitleTrack>[],
          preferences: const <String>['jpn'],
        ),
        isNull,
      );
    });

    test('只挑能转文本的轨：图形轨即使标了默认 / 命中偏好也不自动挂', () {
      final List<RemoteVideoEmbeddedSubtitleTrack> graphic =
          <RemoteVideoEmbeddedSubtitleTrack>[
            _track(2, language: 'jpn', isText: false, isDefault: true),
            _track(3, language: 'eng'),
          ];
      expect(
        pickRemoteStartupSubtitleTrack(graphic, preferences: const <String>[]),
        isNull,
      );
      expect(
        pickRemoteStartupSubtitleTrack(
          graphic,
          preferences: const <String>['jpn', 'eng'],
        )?.streamIndex,
        3,
      );
    });

    test('偏好可按标题词命中（DisplayTitle 带语言全名，轨语言码缺失）', () {
      expect(
        pickRemoteStartupSubtitleTrack(
          <RemoteVideoEmbeddedSubtitleTrack>[
            _track(2, title: 'English SDH', isDefault: true),
            _track(3, title: 'Japanese Full'),
          ],
          preferences: const <String>['japanese'],
        )?.streamIndex,
        3,
      );
    });

    test('偏好命中外挂文件轨也可以（它同样在轨列表里、可下载）', () {
      expect(
        pickRemoteStartupSubtitleTrack(
          <RemoteVideoEmbeddedSubtitleTrack>[
            _track(2, language: 'eng', isDefault: true),
            _track(7, language: 'jpn', isExternalFile: true),
          ],
          preferences: const <String>['ja'],
        )?.streamIndex,
        7,
      );
    });
  });

  group('服务器默认标记的数据通路', () {
    test('Jellyfin MediaStreams 的 IsDefault 读进字幕流', () {
      final JellyfinMediaSource source = JellyfinApi.parseMediaSource(
        <String, Object?>{
          'Id': 'src',
          'MediaStreams': <Object?>[
            <String, Object?>{'Type': 'Video', 'Index': 0, 'Codec': 'h264'},
            <String, Object?>{
              'Type': 'Subtitle',
              'Index': 2,
              'Codec': 'subrip',
              'Language': 'eng',
              'IsExternal': false,
              'IsTextSubtitleStream': true,
            },
            <String, Object?>{
              'Type': 'Subtitle',
              'Index': 3,
              'Codec': 'ass',
              'Language': 'jpn',
              'IsDefault': true,
              'IsExternal': false,
              'IsTextSubtitleStream': true,
            },
          ],
        },
      );
      expect(
        source.subtitleStreams.map((JellyfinSubtitleStream s) => s.isDefault),
        <bool>[false, true],
      );
    });

    test('isDefault 过 JSON 往返与 copyWith 不丢（互联 wire）', () {
      final RemoteVideoEmbeddedSubtitleTrack round =
          RemoteVideoEmbeddedSubtitleTrack.fromJson(
            _track(3, language: 'jpn', isDefault: true).toJson(),
          );
      expect(round.isDefault, isTrue);
      expect(
        RemoteVideoEmbeddedSubtitleTrack.fromJson(_track(2).toJson()).isDefault,
        isFalse,
      );
      expect(
        _track(3, isDefault: true).copyWith(url: 'x').isDefault,
        isTrue,
        reason: 'copyWith（libmpv 回落换本地文件）不得丢默认标记',
      );
    });

    test('Jellyfin 客户端把 isDefault 交给播放页的轨', () {
      final String src = maskComments(
        File(
          'lib/src/sync/jellyfin_video_client.dart',
        ).readAsStringSync().replaceAll('\r\n', '\n'),
      );
      final int at = src.indexOf('RemoteVideoEmbeddedSubtitleTrack(');
      expect(at, greaterThan(-1));
      final int end = src.indexOf('\n        ),', at);
      expect(end, greaterThan(at));
      expect(src.substring(at, end).contains('isDefault: s.isDefault'), isTrue);
    });
  });

  group('播放页接线（源码守卫）', () {
    late String load;
    setUpAll(() {
      final String src = maskComments(readVideoFushiSource());
      final int start = src.indexOf('Future<void> _loadRemoteEpisode(');
      expect(start, greaterThan(-1));
      final int end = src.indexOf('\n  }\n', start);
      load = src.substring(start, end);
    });

    test('没有持久化选择时才自动挑轨，偏好取主字幕语言偏好', () {
      final int pickAt = load.indexOf('pickRemoteStartupSubtitleTrack(');
      expect(pickAt, greaterThan(-1));
      final int guardAt = load.lastIndexOf('persistedSub == null', pickAt);
      expect(guardAt, greaterThan(-1), reason: '持久化选择（含显式关闭）压过自动挑轨');
      expect(
        load.indexOf('appModel.videoSubtitlePreferredLanguages', pickAt),
        greaterThan(pickAt),
      );
    });

    test('自动挑中的轨走 embedded:<n> 重放路径，且先于后端默认字幕计划', () {
      final int startupAt = load.indexOf('persistedSub ??');
      expect(startupAt, greaterThan(-1));
      final int branchAt = load.indexOf('if (startupSub != null)');
      expect(branchAt, greaterThan(startupAt));
      expect(
        load.indexOf(
          'startupSub.startsWith(SubtitleSource.embeddedPrefix)',
          branchAt,
        ),
        greaterThan(branchAt),
      );
      final int planAt = load.indexOf('planRemoteBackendDefaultSubtitle(');
      expect(planAt, greaterThan(branchAt));
      // 旧写法：重放分支只认持久化选择。
      expect(load.contains('if (persistedSub != null) {'), isFalse);
    });

    test('自动挑轨不写持久化选择', () {
      expect(load.contains('setRemoteSubtitleSource('), isFalse);
    });
  });
}

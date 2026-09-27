import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_window_video.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/utils/misc/synchronized_video_exporter.dart';

/// 音画同步片段格式（[MiningClipFormat]）：默认 WebM 让卡片内 `<video>` 能播（Anki 桌面
/// Qt WebEngine 无 H.264/AAC）。钉住：枚举契约、各档 ffmpeg 参数、gal 窗口片段参数、
/// 偏好默认值的推导（老 MP4 片段用户保持 MP4）。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  group('MiningClipFormat', () {
    test('wireName 稳定、扩展名与内嵌判据', () {
      expect(MiningClipFormat.webmVp9.wireName, 'webm_vp9');
      expect(MiningClipFormat.webmAv1.wireName, 'webm_av1');
      expect(MiningClipFormat.mp4H264.wireName, 'mp4_h264');
      expect(MiningClipFormat.webmVp9.playsInline, isTrue);
      expect(MiningClipFormat.webmAv1.playsInline, isTrue);
      expect(MiningClipFormat.mp4H264.playsInline, isFalse);
    });

    test('降级链：AV1 → VP9 → MP4，MP4 是链尾', () {
      expect(MiningClipFormat.webmAv1.encodeAttempts, <MiningClipFormat>[
        MiningClipFormat.webmAv1,
        MiningClipFormat.webmVp9,
        MiningClipFormat.mp4H264,
      ]);
      expect(MiningClipFormat.webmVp9.encodeAttempts, <MiningClipFormat>[
        MiningClipFormat.webmVp9,
        MiningClipFormat.mp4H264,
      ]);
      expect(MiningClipFormat.mp4H264.encodeAttempts, <MiningClipFormat>[
        MiningClipFormat.mp4H264,
      ]);
    });

    test('平台默认：iOS MP4（AnkiMobile 放不了 WebM），其余 VP9', () {
      expect(
        MiningClipFormat.defaultFor(isIOS: true),
        MiningClipFormat.mp4H264,
      );
      expect(
        MiningClipFormat.defaultFor(isIOS: false),
        MiningClipFormat.webmVp9,
      );
    });

    test('fromWireName 往返，未知/null → fallback', () {
      for (final MiningClipFormat f in MiningClipFormat.values) {
        expect(
          MiningClipFormat.fromWireName(
            f.wireName,
            fallback: MiningClipFormat.mp4H264,
          ),
          f,
        );
      }
      expect(
        MiningClipFormat.fromWireName(null, fallback: MiningClipFormat.webmAv1),
        MiningClipFormat.webmAv1,
      );
      expect(
        MiningClipFormat.fromWireName('x', fallback: MiningClipFormat.webmVp9),
        MiningClipFormat.webmVp9,
      );
    });

    test('isMiningClipPath 认 webm / mp4，不认图片', () {
      expect(isMiningClipPath('/t/immersion_video.webm'), isTrue);
      expect(isMiningClipPath('/t/recording.MP4'), isTrue);
      expect(isMiningClipPath('/t/clip.gif'), isFalse);
      expect(isMiningClipPath('/t/clip.avif'), isFalse);
    });
  });

  group('buildSynchronizedVideoClipArgs', () {
    List<String> args(MiningClipFormat format, String out) =>
        buildSynchronizedVideoClipArgs(
          videoPath: '/v.mkv',
          audioPath: '/a.aac',
          audioStartMs: 0,
          startMs: 1000,
          endMs: 3000,
          outputPath: out,
          format: format,
        );

    test('MP4 档与改动前逐字相同（H.264 + AAC + faststart）', () {
      final List<String> a = args(MiningClipFormat.mp4H264, '/o.mp4');
      expect(a.join(' '), contains('-c:v libx264 -preset veryfast -crf 23'));
      expect(a.join(' '), contains('-c:a aac -b:a 128k'));
      expect(a, contains('+faststart'));
      expect(a.sublist(a.length - 3), <String>['-f', 'mp4', '/o.mp4']);
    });

    test('VP9 档：libvpx-vp9 + Opus，WebM 容器，无 faststart', () {
      final List<String> a = args(MiningClipFormat.webmVp9, '/o.webm');
      expect(a.join(' '), contains('-c:v libvpx-vp9'));
      expect(a.join(' '), contains('-b:v 0'));
      expect(a.join(' '), contains('-c:a libopus'));
      expect(a, isNot(contains('aac')));
      expect(a, isNot(contains('+faststart')));
      expect(a.sublist(a.length - 3), <String>['-f', 'webm', '/o.webm']);
      // 两路输入与必需音轨映射不随格式变。
      expect(a.join(' '), contains('-map 0:v:0 -map 1:a:0'));
    });

    test('AV1 档：libsvtav1 + Opus，WebM 容器', () {
      final List<String> a = args(MiningClipFormat.webmAv1, '/o.webm');
      expect(a.join(' '), contains('-c:v libsvtav1'));
      expect(a.join(' '), contains('-c:a libopus'));
      expect(a.sublist(a.length - 3), <String>['-f', 'webm', '/o.webm']);
    });
  });

  group('buildGalWindowVideoArgs', () {
    test('MP4（默认）与改动前逐字相同', () {
      expect(
        buildGalWindowVideoArgs(
          listPath: 'l.ffconcat',
          outputPath: 'clip.mp4',
          audioPath: 's.aac',
        ),
        <String>[
          '-y', '-f', 'concat', '-safe', '0', '-i', 'l.ffconcat', //
          '-i', 's.aac', '-c:v', 'libx264', '-preset', 'veryfast', //
          '-crf', '26', '-pix_fmt', 'yuv420p', '-vf', //
          'scale=trunc(iw/2)*2:trunc(ih/2)*2', '-c:a', 'aac', '-b:a', //
          '128k', '-movflags', '+faststart', 'clip.mp4',
        ],
      );
    });

    test('WebM：VP9 + Opus，有音频才映射音频编码器', () {
      final List<String> withAudio = buildGalWindowVideoArgs(
        listPath: 'l.ffconcat',
        outputPath: 'clip.webm',
        audioPath: 's.aac',
        format: MiningClipFormat.webmVp9,
      );
      expect(withAudio.join(' '), contains('-c:v libvpx-vp9'));
      expect(withAudio.join(' '), contains('-c:a libopus'));
      expect(withAudio, contains('scale=trunc(iw/2)*2:trunc(ih/2)*2'));
      expect(withAudio, isNot(contains('+faststart')));
      expect(withAudio.sublist(withAudio.length - 3), <String>[
        '-f',
        'webm',
        'clip.webm',
      ]);
      final List<String> silent = buildGalWindowVideoArgs(
        listPath: 'l.ffconcat',
        outputPath: 'clip.webm',
        format: MiningClipFormat.webmVp9,
      );
      expect(silent, isNot(contains('-c:a')));
    });
  });

  group('偏好推导', () {
    late FushiDatabase db;
    late PreferencesRepository repo;
    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });
    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    final MiningClipFormat platformDefault = MiningClipFormat.defaultFor(
      isIOS: Platform.isIOS,
    );

    test('从没设过：模式默认 videoClip，格式取平台默认', () {
      expect(repo.videoMiningImageMode, VideoMiningImageMode.videoClip);
      expect(repo.galMiningImageMode, VideoMiningImageMode.videoClip);
      expect(repo.videoMiningClipFormat, platformDefault);
      expect(repo.galMiningClipFormat, platformDefault);
    });

    test('老用户显式选过 video_clip（MP4 时代）→ 格式保持 MP4', () async {
      await db.setPref(
        'video_mining_image_mode',
        PrefCodec.encode(VideoMiningImageMode.videoClip.wireName),
      );
      await db.setPref(
        'gal_mining_image_mode',
        PrefCodec.encode(VideoMiningImageMode.videoClip.wireName),
      );
      final PreferencesRepository legacy = PreferencesRepository(db);
      await legacy.loadFromDb();
      expect(legacy.videoMiningClipFormat, MiningClipFormat.mp4H264);
      expect(legacy.galMiningClipFormat, MiningClipFormat.mp4H264);
      legacy.dispose();
    });

    test('新选片段模式先钉格式，不被误判成老 MP4 用户', () async {
      repo.setVideoMiningImageMode(VideoMiningImageMode.gif);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      repo.setVideoMiningImageMode(VideoMiningImageMode.videoClip);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.videoMiningImageMode, VideoMiningImageMode.videoClip);
      expect(repo.videoMiningClipFormat, platformDefault);
      final PreferencesRepository restored = PreferencesRepository(db);
      await restored.loadFromDb();
      expect(restored.videoMiningClipFormat, platformDefault);
      restored.dispose();
    });

    test('显式设过的格式写穿 Drift 且优先于推导', () async {
      repo.setVideoMiningClipFormat(MiningClipFormat.webmAv1);
      repo.setGalMiningClipFormat(MiningClipFormat.mp4H264);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final PreferencesRepository restored = PreferencesRepository(db);
      await restored.loadFromDb();
      expect(restored.videoMiningClipFormat, MiningClipFormat.webmAv1);
      expect(restored.galMiningClipFormat, MiningClipFormat.mp4H264);
      restored.dispose();
    });
  });
}

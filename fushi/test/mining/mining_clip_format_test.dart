import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/galgame_window_video.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/anki_settings_page.dart'
    show miningClipFormatLabel;
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/utils/misc/synchronized_video_exporter.dart';

/// 音画同步片段格式（[MiningClipFormat]）：默认 WebM 让卡片内 `<video>` 能播（Anki 桌面
/// Qt WebEngine 无 H.264/AAC）。钉住：枚举契约、各档 ffmpeg 参数、gal 窗口片段参数、
/// 偏好默认值的推导（老 MP4 片段用户保持 MP4）。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  // 设置页文案用例要切 slang 语言，slang_flutter 依赖 WidgetsBinding。
  TestWidgetsFlutterBinding.ensureInitialized();

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

    test('设置页文案：五端都编得出 VP9（标推荐），AV1 写明仅桌面端', () {
      // 所有者 #1717 b94ecd1a1ed 起 iOS xcframework 也带 libvpx-vp9 + libopus，两档 WebM
      // 不再有「本机编不出、退回 MP4」的平台分支；AV1 在移动端（无 SVT-AV1）降级 VP9，
      // 仍内嵌播放，文案里的「desktop only」就是它的全部平台差异。
      LocaleSettings.setLocale(AppLocale.en);
      expect(
        miningClipFormatLabel(MiningClipFormat.webmVp9),
        contains('recommended'),
      );
      expect(
        miningClipFormatLabel(MiningClipFormat.webmAv1),
        contains('desktop only'),
      );
      expect(miningClipFormatLabel(MiningClipFormat.mp4H264), contains('MP4'));
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
      // 制卡是前台等待操作：realtime / cpu-used 8（实测比 good/5 快约 4 倍）。
      expect(a.join(' '), contains('-deadline realtime -cpu-used 8 -row-mt 1'));
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
      // 与视频页片段同样封顶 960 宽（窗口录像是游戏原生分辨率，按原尺寸编 VP9 既慢
      // 又大），偶数维度靠 trunc(/2)*2 与 h=-2。
      expect(withAudio, contains("scale=w='trunc(min(960,iw)/2)*2':h=-2"));
      expect(withAudio, isNot(contains('scale=trunc(iw/2)*2:trunc(ih/2)*2')));
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

  group('exportWithClipFormatFallback 只在格式编不出时降级', () {
    Future<(ClipFormatExport, List<MiningClipFormat>)> run(
      VideoClipExportResult Function(MiningClipFormat) outcome,
    ) async {
      final List<MiningClipFormat> tried = <MiningClipFormat>[];
      final ClipFormatExport produced = await exportWithClipFormatFallback(
        format: MiningClipFormat.webmAv1,
        outputStem: '/t/clip',
        attempt: (MiningClipFormat f, String _) async {
          tried.add(f);
          return outcome(f);
        },
      );
      return (produced, tried);
    }

    test('缺编码器 / muxer：沿 AV1 → VP9 → MP4 降级', () async {
      for (final String detail in <String>[
        "Unknown encoder 'libsvtav1'",
        'Error opening output files: Encoder not found',
        "Requested output format 'webm' is not known.",
        "Requested output format 'webm' is not a suitable output format",
        'Default encoder for format webm (codec vp9) is probably disabled.',
      ]) {
        final (
          ClipFormatExport produced,
          List<MiningClipFormat> tried,
        ) = await run(
          (MiningClipFormat f) => f == MiningClipFormat.mp4H264
              ? const VideoClipExportResult.success('/t/clip-mp4_h264.mp4')
              : VideoClipExportResult.failure(
                  VideoClipExportFailure.ffmpegFailed,
                  detail: 'returnCode=1; stderr=$detail',
                ),
        );
        expect(tried, MiningClipFormat.webmAv1.encodeAttempts, reason: detail);
        expect(produced.format, MiningClipFormat.mp4H264, reason: detail);
        expect(produced.result.isSuccess, isTrue, reason: detail);
      }
    });

    test('远端超时 / 输入打不开 / ffmpeg 不可用：不换格式，原样返回首个失败', () async {
      for (final VideoClipExportResult failure in <VideoClipExportResult>[
        const VideoClipExportResult.failure(
          VideoClipExportFailure.ffmpegFailed,
          detail: 'returnCode=timeout; stderr=Connection timed out',
        ),
        const VideoClipExportResult.failure(
          VideoClipExportFailure.ffmpegFailed,
          detail:
              'returnCode=1; stderr=https://x/v.m3u8: '
              'Server returned 403 Forbidden (access denied)',
        ),
        const VideoClipExportResult.failure(
          VideoClipExportFailure.ffmpegUnavailable,
          detail: 'No such file or directory',
        ),
        const VideoClipExportResult.failure(
          VideoClipExportFailure.inputMissing,
        ),
      ]) {
        final (ClipFormatExport produced, List<MiningClipFormat> tried) =
            await run((MiningClipFormat _) => failure);
        expect(tried, <MiningClipFormat>[
          MiningClipFormat.webmAv1,
        ], reason: failure.detail);
        expect(produced.format, MiningClipFormat.webmAv1);
        expect(produced.result.failure, failure.failure);
        expect(produced.result.detail, failure.detail);
      }
    });

    test('isClipFormatUnsupportedFailure 只认 ffmpegFailed + 缺编码器 / muxer', () {
      expect(
        isClipFormatUnsupportedFailure(
          const VideoClipExportResult.failure(
            VideoClipExportFailure.ffmpegFailed,
            detail: "UNKNOWN ENCODER 'libvpx-vp9'",
          ),
        ),
        isTrue,
      );
      expect(
        isClipFormatUnsupportedFailure(
          const VideoClipExportResult.failure(
            VideoClipExportFailure.ffmpegUnavailable,
            detail: "Unknown encoder 'libvpx-vp9'",
          ),
        ),
        isFalse,
      );
      expect(
        isClipFormatUnsupportedFailure(
          const VideoClipExportResult.failure(
            VideoClipExportFailure.ffmpegFailed,
          ),
        ),
        isFalse,
      );
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

    Future<PreferencesRepository> seeded(Map<String, String> prefs) async {
      for (final MapEntry<String, String> e in prefs.entries) {
        await db.setPref(e.key, PrefCodec.encode(e.value));
      }
      final PreferencesRepository seededRepo = PreferencesRepository(db);
      await seededRepo.loadFromDb();
      return seededRepo;
    }

    const String markerKey =
        PreferencesRepository.miningImageModeInstallDefaultKey;

    test('全新安装：模式默认 videoClip，格式取平台默认，不写模式键', () async {
      await repo.settleMiningImageModeInstallDefault();
      expect(repo.videoMiningImageMode, VideoMiningImageMode.videoClip);
      expect(repo.galMiningImageMode, VideoMiningImageMode.videoClip);
      expect(repo.videoMiningClipFormat, platformDefault);
      expect(repo.galMiningClipFormat, platformDefault);
      final PreferencesRepository restored = PreferencesRepository(db);
      await restored.loadFromDb();
      expect(restored.videoMiningImageMode, VideoMiningImageMode.videoClip);
      // 模式键没被写成显式 video_clip：否则格式推导会把新用户误判成老 MP4 用户。
      expect(
        restored.prefsSnapshot.containsKey('video_mining_image_mode'),
        isFalse,
      );
      expect(
        restored.prefsSnapshot.containsKey('gal_mining_image_mode'),
        isFalse,
      );
      expect(
        restored.prefsSnapshot[markerKey],
        PrefCodec.encode(VideoMiningImageMode.videoClip.wireName),
      );
      expect(restored.videoMiningClipFormat, platformDefault);
      restored.dispose();
    });

    test('还没跑迁移（弹窗入口）：没设过的模式取 videoClip', () {
      expect(repo.videoMiningImageMode, VideoMiningImageMode.videoClip);
      expect(repo.galMiningImageMode, VideoMiningImageMode.videoClip);
    });

    test('被 09-28 钉成 gif 的存量安装：迁到片段，格式钉平台默认（不推成 MP4）', () async {
      final PreferencesRepository legacy = await seeded(<String, String>{
        markerKey: VideoMiningImageMode.gif.wireName,
        'video_mining_image_mode': VideoMiningImageMode.gif.wireName,
        'gal_mining_image_mode': VideoMiningImageMode.gif.wireName,
      });
      await legacy.settleMiningImageModeInstallDefault();
      expect(legacy.videoMiningImageMode, VideoMiningImageMode.videoClip);
      expect(legacy.galMiningImageMode, VideoMiningImageMode.videoClip);
      expect(legacy.videoMiningClipFormat, platformDefault);
      expect(legacy.galMiningClipFormat, platformDefault);
      legacy.dispose();
      final PreferencesRepository restored = PreferencesRepository(db);
      await restored.loadFromDb();
      expect(restored.videoMiningImageMode, VideoMiningImageMode.videoClip);
      expect(restored.galMiningImageMode, VideoMiningImageMode.videoClip);
      expect(restored.videoMiningClipFormat, platformDefault);
      expect(restored.galMiningClipFormat, platformDefault);
      expect(
        restored.prefsSnapshot[markerKey],
        PrefCodec.encode(VideoMiningImageMode.videoClip.wireName),
      );
      restored.dispose();
    });

    test('迁移只改 gif：其它显式模式与显式格式原样保留', () async {
      final PreferencesRepository legacy = await seeded(<String, String>{
        markerKey: VideoMiningImageMode.gif.wireName,
        'video_mining_image_mode': VideoMiningImageMode.currentFrame.wireName,
        'gal_mining_image_mode': VideoMiningImageMode.gif.wireName,
        'gal_mining_clip_format': MiningClipFormat.webmAv1.wireName,
      });
      await legacy.settleMiningImageModeInstallDefault();
      expect(legacy.videoMiningImageMode, VideoMiningImageMode.currentFrame);
      expect(legacy.galMiningImageMode, VideoMiningImageMode.videoClip);
      expect(legacy.galMiningClipFormat, MiningClipFormat.webmAv1);
      expect(
        legacy.prefsSnapshot.containsKey('video_mining_clip_format'),
        isFalse,
      );
      legacy.dispose();
    });

    test('只迁一次：迁完后用户再选 gif 不会被改回片段', () async {
      final PreferencesRepository legacy = await seeded(<String, String>{
        markerKey: VideoMiningImageMode.gif.wireName,
        'video_mining_image_mode': VideoMiningImageMode.gif.wireName,
      });
      await legacy.settleMiningImageModeInstallDefault();
      legacy.setVideoMiningImageMode(VideoMiningImageMode.gif);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      legacy.dispose();
      final PreferencesRepository nextLaunch = PreferencesRepository(db);
      await nextLaunch.loadFromDb();
      await nextLaunch.settleMiningImageModeInstallDefault();
      expect(nextLaunch.videoMiningImageMode, VideoMiningImageMode.gif);
      nextLaunch.dispose();
    });

    test('标记缺失（09-28 之前的版本直接升级）：显式 gif 是用户自己选的，不改', () async {
      final PreferencesRepository legacy = await seeded(<String, String>{
        'video_mining_image_mode': VideoMiningImageMode.gif.wireName,
      });
      await legacy.settleMiningImageModeInstallDefault();
      expect(legacy.videoMiningImageMode, VideoMiningImageMode.gif);
      expect(legacy.galMiningImageMode, VideoMiningImageMode.videoClip);
      expect(
        legacy.prefsSnapshot[markerKey],
        PrefCodec.encode(VideoMiningImageMode.videoClip.wireName),
      );
      legacy.dispose();
    });

    test('迁移标记键登记为已知偏好，且不随 Profile 快照走', () {
      expect(
        kKnownPreferenceKeys,
        contains(PreferencesRepository.miningImageModeInstallDefaultKey),
      );
      expect(
        ProfileKeys.isExcludedPref(
          PreferencesRepository.miningImageModeInstallDefaultKey,
        ),
        isTrue,
      );
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

    test('老 MP4 用户切走再切回来，仍是 MP4（任何一次切换都钉格式）', () async {
      await db.setPref(
        'video_mining_image_mode',
        PrefCodec.encode(VideoMiningImageMode.videoClip.wireName),
      );
      final PreferencesRepository legacy = PreferencesRepository(db);
      await legacy.loadFromDb();
      legacy.setVideoMiningImageMode(VideoMiningImageMode.gif);
      legacy.setVideoMiningImageMode(VideoMiningImageMode.videoClip);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(legacy.videoMiningClipFormat, MiningClipFormat.mp4H264);
      legacy.dispose();
      final PreferencesRepository restored = PreferencesRepository(db);
      await restored.loadFromDb();
      expect(restored.videoMiningClipFormat, MiningClipFormat.mp4H264);
      restored.dispose();
    });

    test('切换模式同步生效，连续两次按调用顺序落盘', () async {
      repo.setVideoMiningImageMode(VideoMiningImageMode.gif);
      // 不 await：设置页调用后紧接着 setState 读值，必须已是新值。
      expect(repo.videoMiningImageMode, VideoMiningImageMode.gif);
      repo.setVideoMiningImageMode(VideoMiningImageMode.videoClip);
      repo.setVideoMiningImageMode(VideoMiningImageMode.currentFrame);
      expect(repo.videoMiningImageMode, VideoMiningImageMode.currentFrame);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final PreferencesRepository restored = PreferencesRepository(db);
      await restored.loadFromDb();
      expect(restored.videoMiningImageMode, VideoMiningImageMode.currentFrame);
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

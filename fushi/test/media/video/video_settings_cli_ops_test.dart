import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/media/video/video_quick_settings_host.dart';
import 'package:fushi/src/media/video/video_settings_cli_ops.dart';
import 'package:fushi/src/media/video/video_shader_downloader.dart';
import 'package:fushi/src/media/video/video_shader_manager.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi/src/settings/settings_context.dart';

import '../../helpers/video_quick_settings_harness.dart';

/// 播放页在前台：登记进 [videoPlaybackRemotes] 的遥控面，借出快捷设置宿主。
class _Remote implements VideoPlaybackRemote, VideoQuickSettingsHostProvider {
  _Remote(this.host);

  final VideoQuickSettingsHost host;

  @override
  Object? quickSettingsHost() => host;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

/// 在真实异步区里跑 [body]，把它抛的异常当返回值交回（runAsync 自己会把异常
/// 报成测试失败）。
Future<Object?> caught(WidgetTester tester, Future<Object?> Function() body) =>
    tester.runAsync<Object?>(() async {
      try {
        await body();
        return null;
      } catch (e) {
        return e;
      }
    });

/// 「拖动调字幕位置」与着色器视图的控制通道入口：没有播放页时写偏好，播放页在
/// 前台时走页面同一组回调（拖动松手的 commit / 选档的 onSelectShaderTier）。
void main() {
  late VideoSheetHarness harness;
  late SettingsContext settings;

  Future<void> capture(WidgetTester tester) async {
    harness =
        await tester.runAsync(VideoSheetHarness.create) as VideoSheetHarness;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? _) {
              settings = SettingsContext(
                context: context,
                appModel: harness.appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  tearDown(() async {
    await harness.dispose();
  });

  testWidgets('字幕位置：不给参数只读；给了写偏好（无播放页）', (WidgetTester tester) async {
    await capture(tester);
    final Map<String, Object?> before =
        await tester.runAsync(
              () => videoSubtitlePositionForCli(
                settings,
                const <String, String>{},
              ),
            )
            as Map<String, Object?>;
    expect(before['anchor'], 'bottom');
    expect(before['appliedToPlayer'], isFalse);

    final Map<String, Object?> after =
        await tester.runAsync(
              () =>
                  videoSubtitlePositionForCli(settings, const <String, String>{
                    'position': '180',
                    'anchor': 'top',
                    'secondary_position': '30',
                    'secondary_anchor': 'bottom',
                  }),
            )
            as Map<String, Object?>;
    expect(after['position'], 180.0);
    expect(after['anchor'], 'top');
    final VideoSubtitleStyle saved = VideoSubtitleStyle.decode(
      harness.appModel.videoSubtitleStyle,
    );
    expect(saved.mainAnchor, SubtitleLayerVAnchor.top);
    expect(saved.bottomPadding, 180);
    expect(saved.secondaryBottomPadding, 30);
    expect(saved.secondaryAnchor, SubtitleLayerVAnchor.bottom);

    expect(
      await caught(
        tester,
        () => videoSubtitlePositionForCli(settings, const <String, String>{
          'position': '401',
        }),
      ),
      isArgumentError,
    );
    expect(
      await caught(
        tester,
        () => videoSubtitlePositionForCli(settings, const <String, String>{
          'anchor': 'middle',
        }),
      ),
      isArgumentError,
    );
  });

  testWidgets('字幕位置：播放页在前台走页面 commit（拖动松手同一处）', (WidgetTester tester) async {
    await capture(tester);
    final List<VideoSubtitleStyle> commits = <VideoSubtitleStyle>[];
    final _Remote remote = _Remote(
      buildTestVideoHost(onSubtitleStyleCommit: commits.add),
    );
    videoPlaybackRemotes.register(remote);
    addTearDown(() => videoPlaybackRemotes.unregister(remote));

    final Map<String, Object?> out =
        await tester.runAsync(
              () => videoSubtitlePositionForCli(
                settings,
                const <String, String>{'position': '90'},
              ),
            )
            as Map<String, Object?>;
    expect(out['appliedToPlayer'], isTrue);
    expect(commits.single.bottomPadding, 90);
  });

  testWidgets('选档：无播放页写「内置缩放 + 启用集」两项偏好；播放页在前台走 onSelectShaderTier', (
    WidgetTester tester,
  ) async {
    await capture(tester);
    final Map<String, Object?> low =
        await tester.runAsync(
              () => selectVideoShaderTierForCli(
                settings,
                'low',
                listFiles: () async => <String>['other.glsl'],
                ensurePreset: (Anime4kPreset _) async => fail('低档不该下载'),
              ),
            )
            as Map<String, Object?>;
    expect(low['highQuality'], isTrue);
    expect(low['enabled'], isEmpty);
    expect(low['appliedToPlayer'], isFalse);
    expect(
      VideoMpvConfig.decode(harness.appModel.videoMpvConfig).highQuality,
      isTrue,
    );
    expect(videoShaderTierNameFromPrefs(settings), 'low');

    final List<(VideoShaderTier, bool)> selected = <(VideoShaderTier, bool)>[];
    final _Remote remote = _Remote(
      buildTestVideoHost(
        onSelectShaderTier: (VideoShaderTier t, bool hq) =>
            selected.add((t, hq)),
      ),
    );
    videoPlaybackRemotes.register(remote);
    addTearDown(() => videoPlaybackRemotes.unregister(remote));
    final Map<String, Object?> off =
        await tester.runAsync(
              () => selectVideoShaderTierForCli(
                settings,
                'off',
                listFiles: () async => const <String>[],
              ),
            )
            as Map<String, Object?>;
    expect(off['appliedToPlayer'], isTrue);
    expect(selected.single, (VideoShaderTier.off, false));

    expect(
      await caught(tester, () => selectVideoShaderTierForCli(settings, 'max')),
      isArgumentError,
    );
  });

  test('选档启用集：缺文件先补齐，补不齐不切档；按档位叠加顺序只启用存在的', () async {
    final VideoShaderTierSpec high = shaderTierSpec(
      VideoShaderTier.high,
      isMobile: false,
    );
    final List<String> want = high.shaderFileNames;
    expect(want, isNotEmpty);

    final List<String> disk = <String>[];
    int downloads = 0;
    final List<String>? enabled = await resolveShaderTierEnabledNames(
      VideoShaderTier.high,
      isMobile: false,
      listFiles: () async => List<String>.of(disk),
      ensurePreset: (Anime4kPreset preset) async {
        downloads++;
        disk.addAll(preset.fileNames.reversed);
        return true;
      },
    );
    expect(downloads, 1);
    expect(enabled, want, reason: '按档位叠加顺序，不按目录顺序');

    final List<String>? refused = await resolveShaderTierEnabledNames(
      VideoShaderTier.high,
      isMobile: false,
      listFiles: () async => const <String>[],
      ensurePreset: (Anime4kPreset _) async => false,
    );
    expect(refused, isNull);

    final List<String>? noDownload = await resolveShaderTierEnabledNames(
      VideoShaderTier.high,
      isMobile: false,
      listFiles: () async => want,
      ensurePreset: (Anime4kPreset _) async => fail('文件齐了不该下载'),
    );
    expect(noDownload, want);
    expect(encodeEnabledShaders(noDownload!), isNotEmpty);
  });
}

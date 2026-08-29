import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_shader_downloader.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';
import 'package:fushi/src/media/video/web_video_shaders.dart';
import 'package:path/path.dart' as p;

void main() {
  test('偏好解析：档位名 → 枚举；缺省 / 未知 → off', () {
    expect(webVideoShaderTierFromPref('high'), VideoShaderTier.high);
    expect(webVideoShaderTierFromPref('ultra'), VideoShaderTier.ultra);
    expect(webVideoShaderTierFromPref(null), VideoShaderTier.off);
    expect(webVideoShaderTierFromPref('nope'), VideoShaderTier.off);
  });

  test('通道名与方法名与 fork C++ 字面量一致（两侧各写一份，守卫比对）', () {
    final File cc = File(
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.cc',
    );
    expect(cc.existsSync(), isTrue, reason: cc.path);
    final String src = cc.readAsStringSync();
    expect(src, contains('"$kWebVideoPlatformViewChannelPrefix"'));
    expect(src, contains('kMethodSetShaders = "$kWebVideoSetShadersMethod"'));
    expect(
      src,
      contains('texture_bridge_->SetShaders(texts)'),
      reason: 'setShaders 必须真喂给 GPU 桥',
    );
  });

  test('off / low 无 GLSL 档回空表且不触发下载', () async {
    int downloads = 0;
    final Directory dir = Directory.systemTemp.createTempSync('wv-shaders-');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final VideoShaderTier t in <VideoShaderTier>[
      VideoShaderTier.off,
      VideoShaderTier.low,
    ]) {
      final List<String> texts = await loadWebVideoShaderTexts(
        t,
        shaderDir: dir,
        download: (Anime4kPreset preset, Directory d) async {
          downloads++;
          return const Anime4kDownloadResult(
            downloaded: <String>[],
            failed: <String>[],
          );
        },
      );
      expect(texts, isEmpty);
    }
    expect(downloads, 0);
  });

  test('medium 档：缺文件先下载（注入的下载器落盘），再按预设顺序读出文本；缺的跳过', () async {
    final Directory dir = Directory.systemTemp.createTempSync('wv-shaders-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final List<String> wanted = shaderFilesForTier(VideoShaderTier.medium);
    expect(wanted.length, greaterThan(2));
    int downloads = 0;
    final List<String> texts = await loadWebVideoShaderTexts(
      VideoShaderTier.medium,
      shaderDir: dir,
      download: (Anime4kPreset preset, Directory d) async {
        downloads++;
        // 只落前两个文件，模拟第三个镜像全失败。
        for (final String name in wanted.take(2)) {
          File(
            p.join(d.path, name),
          ).writeAsStringSync('//!HOOK MAIN\n// $name\n');
        }
        return Anime4kDownloadResult(
          downloaded: wanted.take(2).toList(),
          failed: wanted.skip(2).toList(),
        );
      },
    );
    expect(downloads, 1);
    expect(texts.length, 2, reason: '缺的文件跳过，链缩短但不空转');
    expect(texts[0], contains(wanted[0]));
    expect(texts[1], contains(wanted[1]));

    // 第二次：文件已齐（补齐第三个）→ 不再下载。
    for (final String name in wanted) {
      File(
        p.join(dir.path, name),
      ).writeAsStringSync('//!HOOK MAIN\n// $name\n');
    }
    final List<String> again = await loadWebVideoShaderTexts(
      VideoShaderTier.medium,
      shaderDir: dir,
      download: (Anime4kPreset preset, Directory d) async {
        downloads++;
        return const Anime4kDownloadResult(
          downloaded: <String>[],
          failed: <String>[],
        );
      },
    );
    expect(downloads, 1, reason: '文件齐了不再下载');
    expect(again.length, wanted.length);
  });

  test(
    'applyWebVideoShaders：按视图 id 拼通道名、方法 setShaders、原样传文本；fork 回 true 才算启用',
    () async {
      final List<(String, String, Object?)> calls =
          <(String, String, Object?)>[];
      Future<Object?> fake(String channel, String method, Object? args) async {
        calls.add((channel, method, args));
        return true;
      }

      expect(
        await applyWebVideoShaders(42, <String>['a', 'b'], invoke: fake),
        isTrue,
      );
      expect(calls.single.$1, '${kWebVideoPlatformViewChannelPrefix}42');
      expect(calls.single.$2, kWebVideoSetShadersMethod);
      expect(calls.single.$3, <String>['a', 'b']);
      expect(
        await applyWebVideoShaders(null, <String>['a'], invoke: fake),
        isFalse,
        reason: '没有视图 id（WebView 未创建）→ false 不调通道',
      );
      expect(calls.length, 1);
      expect(
        await applyWebVideoShaders(
          7,
          const <String>[],
          invoke: (String c, String m, Object? a) async => false,
        ),
        isFalse,
        reason: 'fork 回 false（DLL 缺失 / 窗口档）→ false',
      );
    },
  );
}

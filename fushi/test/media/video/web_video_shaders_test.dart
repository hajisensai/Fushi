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

  test('Windows GPU bridge 仅在 shader 启用时缩放，普通 WebView 保持 1:1', () {
    final File bridge = File(
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge_gpu.cc',
    );
    final File pass = File(
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/placebo_pass.cc',
    );
    final File bridgeHeader = File(
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.h',
    );
    final File platformView = File(
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.cc',
    );
    final File inAppWebView = File(
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp',
    );
    for (final File file in <File>[
      bridge,
      bridgeHeader,
      pass,
      platformView,
      inAppWebView,
    ]) {
      expect(file.existsSync(), isTrue, reason: file.path);
    }

    final String bridgeSrc = bridge.readAsStringSync();
    final String bridgeHeaderSrc = bridgeHeader.readAsStringSync();
    final String passSrc = pass.readAsStringSync();
    final String platformViewSrc = platformView.readAsStringSync();
    final String inAppWebViewSrc = inAppWebView.readAsStringSync();

    expect(bridgeSrc, contains('output_size_ = next_size'));
    expect(
      bridgeSrc,
      contains('capture_scale_factor = scale_factor / kShaderUpscaleFactor'),
      reason: '启用 shader 时 capture 必须是 output device DPR 的 1/2',
    );
    expect(
      bridgeSrc,
      contains(
        'callback(logical_size, capture_scale_factor, device_scale_factor)',
      ),
      reason: 'shader 状态切换必须在锁外重新设置 source surface',
    );
    expect(bridgeSrc, contains('bool shader_enabled = false;'));
    expect(
      bridgeSrc,
      contains('shader_enabled = placebo_ && placebo_->enabled();'),
      reason: '是否允许重采样必须只由显式 shader 状态决定',
    );
    // BUG-3895 / BUG-3913 起共享纹理按容量分配（见
    // test/build/webview_texture_capacity_guard_test.dart），不再与捕获源等大，
    // 所以 1:1 的落点从「CopyResource 整张拷」换成「CopySubresourceRegion 拷进
    // 左上角」。这里钉的语义不变：只有显式 shader 才重采样，普通 WebView 的可见
    // 区域 = WGC 有效内容，原样 1:1 拷贝。
    final int processStart = bridgeSrc.indexOf(
      'void TextureBridgeGpu::ProcessFrame(',
    );
    final int processEnd = bridgeSrc.indexOf(
      'bool TextureBridgeGpu::SetShaders(',
      processStart,
    );
    expect(processStart, greaterThanOrEqualTo(0));
    expect(processEnd, greaterThan(processStart));
    final String processSrc = bridgeSrc.substring(processStart, processEnd);
    expect(
      processSrc,
      contains(
        'const Size visible = shader_enabled && output_size_.width > 0 &&\n'
        '      output_size_.height > 0\n'
        '      ? output_size_\n'
        '      : content;',
      ),
      reason: '普通 WebView 必须沿用 WGC 源尺寸，不能拿晚到的 output 尺寸触发缩放',
    );
    expect(
      bridgeSrc,
      isNot(contains('needs_placebo')),
      reason: '1px 的 DPI 取整差不是超分请求，不能自动送进 libplacebo',
    );
    expect(
      bridgeHeaderSrc,
      contains('requested_scale_factor_ == scale_factor'),
      reason: '重复逻辑尺寸 + DPI 不得再次反馈 WebView 并重建 WGC pool',
    );
    final int shaderGate = processSrc.indexOf('if (shader_enabled) {');
    final int render = processSrc.indexOf('placebo_->Render(');
    final int shaderGateEnd = processSrc.indexOf('#endif', shaderGate);
    final int plainCopy = processSrc.indexOf(
      'CopyIntoSurface(src_texture.get(), content);',
    );
    expect(
      shaderGate,
      greaterThanOrEqualTo(0),
      reason: '重采样分支必须由显式 shader 状态把门',
    );
    expect(
      render,
      greaterThan(shaderGate),
      reason: 'libplacebo 只能在 shader 分支里调用',
    );
    expect(shaderGateEnd, greaterThan(render));
    expect(
      processSrc.indexOf('placebo_->Render(', render + 1),
      -1,
      reason: 'shader 分支之外不得再有 libplacebo 渲染入口',
    );
    expect(
      plainCopy,
      greaterThan(shaderGateEnd),
      reason: '普通 WebView 必须在 shader 分支之外按 WGC 有效内容尺寸 1:1 拷贝',
    );
    final int copyStart = bridgeSrc.indexOf(
      'void TextureBridgeGpu::CopyIntoSurface(',
    );
    expect(copyStart, greaterThanOrEqualTo(0));
    final String copySrc = bridgeSrc.substring(
      copyStart,
      bridgeSrc.indexOf('void TextureBridgeGpu::ProcessFrame(', copyStart),
    );
    expect(
      copySrc,
      contains(
        'device_context->CopySubresourceRegion(surface_.get(), 0, 0, 0, 0, src, 0,',
      ),
      reason: '普通 WebView 的落点必须是无缩放的像素拷贝（左上角对齐），保持文字锐度',
    );
    expect(
      passSrc,
      isNot(contains('hooks_.empty() || !src || !dst')),
      reason: '空 hook 链也必须允许 libplacebo 做直通缩放',
    );
    expect(
      passSrc,
      contains('if (!all_ok) {\n      // 解析失败必须整链 fail-open'),
      reason: '解析失败必须清空半成品链并恢复 full-DPR capture',
    );
    expect(
      platformViewSrc,
      contains('texture_bridge_->SetOnSurfaceSizeChanged('),
      reason: 'bridge 记录目标尺寸后必须只通过回调更新 WebView/WGC 源',
    );
    expect(
      platformViewSrc,
      contains('texture_bridge_->SetOutputSize(logical_width, logical_height,'),
    );
    expect(
      inAppWebViewSrc,
      contains('put_RasterizationScale(capture_scale_factor)'),
    );
    expect(
      inAppWebViewSrc,
      contains('deviceScaleFactor_ = scale_factor;'),
      reason: 'position 只更新 device DPR，不能覆盖 captureScaleFactor_',
    );
    expect(
      inAppWebViewSrc,
      contains('point.x = static_cast<LONG>(x * captureScaleFactor_)'),
      reason: 'WebView raw pointer 坐标必须跟随降采样 capture surface',
    );
    expect(
      inAppWebViewSrc,
      contains('{"scale", deviceScaleFactor_}'),
      reason: 'CDP screenshot 绕过 WGC/shader，保持原 device-DPR 输出语义',
    );
    expect(
      inAppWebViewSrc,
      isNot(contains('scaleFactor_ = scale_factor;')),
      reason: '旧单比例状态会让 position 把 capture scale 恢复成 DPR',
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

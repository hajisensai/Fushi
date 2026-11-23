import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// 引擎补丁 `engine-gpu-texture-from-image.patch` 的源码守卫（2026-11-23 镜台整机卡死）。
///
/// 上游 3.50.0 的 Flutter GPU `Texture.fromImage` 在 UI 线程现造 `AiksContext`；其
/// `ContentContext` 构造时提交的命令缓冲在 GLES 上永远不完成，卡死 `GpuSubmissionTracker`，
/// 之后真渲染器每帧 `HostBuffer::Reset` 都退役整格 arena 再新分配，进程私有提交无界上涨。
/// 补丁丢了不会编译失败，只会静默回到「用过一次镜台就每帧漏几 MB」，所以把这些点咬住。
void main() {
  final String fushi = _fushiDir();
  final String repo = Directory(fushi).parent.path;
  final String flutterVersion = _fvmFlutterVersion(fushi);
  final String patchPath =
      '$repo/ci/patches/flutter-engine/$flutterVersion/'
      'engine-gpu-texture-from-image.patch';

  test('补丁存在、是 LF，且构建脚本在 raster 线程纹理补丁之后打它', () {
    expect(File(patchPath).existsSync(), isTrue);
    expect(File(patchPath).readAsBytesSync().contains(13), isFalse);
    final String script = _read(
      '$repo/tool/flutter_engine/build_patched_engine.ps1',
    );
    final int raster = script.indexOf(
      "'engine-texture-frame-raster-thread.patch'",
    );
    final int fromImage = script.indexOf(
      "'engine-gpu-texture-from-image.patch'",
    );
    expect(raster, greaterThan(0));
    expect(fromImage, greaterThan(raster));
  });

  test('只改 Flutter GPU 纹理与 DlImageImpeller 三个实现', () {
    final List<String> files = RegExp(
      r'^\+\+\+ b/(.+)$',
      multiLine: true,
    ).allMatches(_read(patchPath)).map((RegExpMatch m) => m.group(1)!).toList();
    expect(files, <String>[
      'engine/src/flutter/impeller/display_list/dl_image_impeller.h',
      'engine/src/flutter/lib/gpu/texture.cc',
      'engine/src/flutter/lib/ui/painting/display_list_deferred_image_gpu_impeller.cc',
      'engine/src/flutter/lib/ui/painting/display_list_deferred_image_gpu_impeller.h',
      'engine/src/flutter/lib/ui/painting/pixel_deferred_image_gpu_impeller.cc',
      'engine/src/flutter/lib/ui/painting/pixel_deferred_image_gpu_impeller.h',
    ]);
  });

  test('fromImage 不再在 UI 线程构造 AiksContext，改取已有纹理', () {
    final String patch = _read(patchPath);
    expect(
      patch,
      contains(
        '-  impeller::AiksContext aiks_context(gpu_context->GetContextShared(), nullptr);',
      ),
    );
    expect(patch, contains('+  return impeller_image->GetResolvedTexture();'));
    expect(patch, contains('-#include "impeller/display_list/aiks_context.h"'));
    expect(
      patch,
      contains(
        '+  virtual std::shared_ptr<Texture> GetResolvedTexture() const {',
      ),
    );
    // 三个实现都要覆盖，否则对应来源的图会被 fromImage 拒绝。
    expect(
      RegExp(
        r'^\+.*GetResolvedTexture\(\)',
        multiLine: true,
      ).allMatches(patch).length,
      greaterThanOrEqualTo(6),
    );
  });
}

String _fushiDir() {
  final Directory cwd = Directory.current;
  if (File('${cwd.path}/pubspec.yaml').existsSync() &&
      Directory('${cwd.path}/windows/runner').existsSync()) {
    return cwd.path;
  }
  return '${cwd.path}/fushi';
}

String _fvmFlutterVersion(String fushi) {
  final Object? json = jsonDecode(_read('$fushi/.fvmrc'));
  return (json! as Map<String, Object?>)['flutter']! as String;
}

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

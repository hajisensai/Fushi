/// Flutter app 对 `fushi_engine`（以及 fushi_core / fushi_audio）平台装配点的
/// 一次性接线。
///
/// 引擎包不依赖 Flutter，它需要的日志、数据根、ffmpeg 平台后端、图片缓存失效、
/// 调试打印全靠宿主在进程入口装配。与 `installAsrHostBindings()` 同一范式、同一
/// 调用位置（`main()`，不放 `AppModel.initialise()`：弹窗词典与悬浮词典两个入口
/// 绕开 initialise）。`flutter_test_config.dart` 也调它，保证测试里的引擎代码拿到
/// 与从前逐字节一致的行为（`AppPaths` 路径、`ErrorLogService` 记录）。
///
/// 幂等：重复调用只是重复赋同一批值。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show RootIsolateToken;
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/src/media/video/ffmpeg_kit_backend.dart';
import 'package:fushi/src/ocr/ocr_inference_ort.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiDicts;
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/dictionary/dictionary_engine_hooks.dart';
import 'package:fushi_engine/foundation/engine_platform_hooks.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/ocr/ocr_host_bindings.dart';

/// `AppPaths` 静态便捷层 → 引擎 [EnginePaths]。三个根逐一委派，子目录派生规则
/// 在引擎基类里与 `AppPaths.documentsSubdirectory` 同构。
class AppPathsEngineBridge extends EnginePaths {
  const AppPathsEngineBridge();

  @override
  Future<Directory> documentsRootDirectory() => AppPaths.documentsRootDirectory();

  @override
  Future<Directory> supportRootDirectory() => AppPaths.supportRootDirectory();

  @override
  Future<Directory> tempRootDirectory() => AppPaths.tempRootDirectory();
}

/// 写后驱逐：与 `MediaCoverService` 历来的收口同一份双键 evict（裸 FileImage +
/// resizedFileImage），只动这一条路径的条目，不清整表——刮削几百张封面时整表
/// clear 会把书架滚动变成重解码风暴。
Future<void> _evictImageCacheForFile(File file) => evictLocalCoverCache(file.path);

/// 删前释放：与 develop 上 `VideoStorage._evictImageCacheForFile` 逐字同义——
/// 整表 clear 是「锁释放提示」（Windows 上解码器持有的句柄让 delete 失败），
/// 纯存储测试没有 painting binding 时吞掉，不能挡住真正的删除。
Future<void> _releaseImageCacheBeforeDelete(File file) async {
  try {
    final ImageCache imageCache = PaintingBinding.instance.imageCache;
    imageCache.clearLiveImages();
    imageCache.clear();
    await FileImage(file).evict();
  } catch (_) {
    // 见上：缺 binding 只意味着没有缓存可放，不影响删除。
  }
}

FfmpegBackend _platformFfmpegBackend() {
  if (Platform.isAndroid || Platform.isIOS) return const KitFfmpegBackend();
  return const CliFfmpegBackend();
}

void installEngineHostBindings() {
  fushiDebugPrint = debugPrint;
  engineLog = ErrorLogService.instance;
  enginePaths = const AppPathsEngineBridge();
  evictImageCacheForFile = _evictImageCacheForFile;
  releaseImageCacheBeforeDelete = _releaseImageCacheBeforeDelete;
  // 词典导入/删除前释放 FFI 引擎的文件映射（BUG-1756）。
  releaseDictionaryMappings = FushiDicts.releaseAllMappings;
  ffmpegPlatformBackendProvider = _platformFfmpegBackend;
  // fushi_audio 的两个插件级装配点（charset 探测 method channel、just_audio 时长探测 +
  // path_provider 文档根）：纯 Dart 一半住 fushi_audio_core，插件实现由这里写入。
  installPlatformCharsetDetector();
  installAudiobookStoragePlatform();
  // 漫画 OCR 整卷任务的后台 isolate：插件后端会话工厂 + MethodChannel 引导。
  ocrSessionFactoryBuilder = buildOrtOcrFactory;
  ocrIsolateBootstrap = fushiOcrIsolateBootstrap;
  ocrIsolateBootstrapArg = RootIsolateToken.instance;
}

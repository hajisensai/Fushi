/// 漫画 OCR 整卷任务的宿主装配点。
///
/// `MangaOcrServiceImpl` 把整卷任务下放到后台 isolate；isolate 里要做两件宿主
/// 相关的事：(1) 可选的引导（Flutter app 要 `BackgroundIsolateBinaryMessenger.
/// ensureInitialized(RootIsolateToken)` 才能从后台 isolate 发 MethodChannel）；
/// (2) 构造 ONNX 会话工厂（app 是 flutter_onnxruntime 插件后端，服务端是
/// `asr_onnx_ffi` 的 FFI 后端）。两者都是**顶层函数**——只有顶层/静态函数能穿过
/// `Isolate.spawn` 的消息边界，闭包不行。
///
/// 与 `asr_host.dart` 里 `AsrIsolateBackend(buildFactory, bootstrap, bootstrapArg)`
/// 同一范式。未装配 [ocrSessionFactoryBuilder] 就启动整卷任务是编程错误，
/// `IsolateMangaOcrVolumeJobRunner.start` 直接抛 [StateError]。
library;

import 'package:fushi_engine/ocr/ocr_inference.dart';

/// isolate 引导回调签名：收到 [ocrIsolateBootstrapArg]。
typedef OcrIsolateBootstrap = void Function(Object? arg);

/// 在后台 isolate 里构造 OCR 会话工厂（顶层函数）。
OcrSessionFactory Function()? ocrSessionFactoryBuilder;

/// 后台 isolate 启动后第一件事（顶层函数；null = 不需要引导）。
OcrIsolateBootstrap? ocrIsolateBootstrap;

/// 传给 [ocrIsolateBootstrap] 的参数（必须可跨 isolate 发送，如 `RootIsolateToken`）。
Object? ocrIsolateBootstrapArg;

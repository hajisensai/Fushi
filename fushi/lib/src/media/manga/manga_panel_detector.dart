import 'package:fushi_engine/media/manga/panel_detection.dart';

/// 宿主在安装 ONNX 模型后设置的分镜检测器工厂。
///
/// 阅读器只依赖引擎接口，模型目录和 Flutter ONNX 插件均由 app 装配；测试可直接
/// 注入 fake。未装配或模型未下载时返回 null，阅读器保持原有翻页。
typedef MangaPanelDetectorFactory = Future<PanelDetector?> Function();

MangaPanelDetectorFactory? mangaPanelDetectorFactory;

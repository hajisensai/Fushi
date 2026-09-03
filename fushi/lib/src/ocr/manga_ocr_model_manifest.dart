/// 漫画 OCR 模型清单：文件名、下载直链（HF resolve）、预期字节数。
///
/// 已核实（2026-07-24，HF API `?blobs=true` 精确字节数）：
/// - 检测器取 ogkalu/comic-text-and-bubble-detector 的 **int8 小档**
///   `detector-v4-s_int8.onnx`（11,120,765 B，Apache-2.0）——与
///   `text_detector.dart` 的 RT-DETR-v2 IO 规格（640 输入 / 300 query / 3 类）
///   同仓同规格；fp32 全量档 `detector.onnx`（168MB）刻意不下。
/// - 识别器取 mayocream/manga-ocr-onnx（Apache-2.0）双模型导出 + 词表：
///   `encoder_model.onnx`（343,454,249 B）/ `decoder_model.onnx`
///   （117,480,262 B）/ `vocab.txt`（30,216 B）。
///
/// 本层是纯数据 + 纯函数（就绪判定），没有 IO 副作用；下载与磁盘管理见
/// `manga_ocr_model_downloader.dart` / `manga_ocr_service_impl.dart`。
library;

import 'dart:io';

/// 模型文件归属：检测 / 识别（[MangaOcrModelStatus] 的两个就绪位分别聚合）。
enum MangaOcrModelRole { detector, recognizer }

/// 清单里的一个模型文件。
class MangaOcrModelFile {
  const MangaOcrModelFile({
    required this.fileName,
    required this.url,
    required this.expectedBytes,
    required this.role,
  });

  /// 落盘文件名（与远端 basename 一致，Range 续传直接复用同 URL）。
  final String fileName;

  /// HF resolve 直链。
  final String url;

  /// 预期字节数（HF API 精确值；用于 totalBytes 展示与下载后长度校验）。
  final int expectedBytes;

  final MangaOcrModelRole role;
}

/// 全套模型清单（检测器 int8 + 识别 encoder/decoder + vocab）。
const List<MangaOcrModelFile> kMangaOcrModelManifest = <MangaOcrModelFile>[
  MangaOcrModelFile(
    fileName: 'detector-v4-s_int8.onnx',
    url: 'https://huggingface.co/ogkalu/comic-text-and-bubble-detector/'
        'resolve/main/detector-v4-s_int8.onnx',
    expectedBytes: 11120765,
    role: MangaOcrModelRole.detector,
  ),
  MangaOcrModelFile(
    fileName: 'encoder_model.onnx',
    url: 'https://huggingface.co/mayocream/manga-ocr-onnx/'
        'resolve/main/encoder_model.onnx',
    expectedBytes: 343454249,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'decoder_model.onnx',
    url: 'https://huggingface.co/mayocream/manga-ocr-onnx/'
        'resolve/main/decoder_model.onnx',
    expectedBytes: 117480262,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'vocab.txt',
    url: 'https://huggingface.co/mayocream/manga-ocr-onnx/'
        'resolve/main/vocab.txt',
    expectedBytes: 30216,
    role: MangaOcrModelRole.recognizer,
  ),
];

/// 最终文件是否就绪：存在且非空。
///
/// 刻意**不**在这里强校验长度==expected：下载器在 rename 前已做长度校验，能
/// 走到最终文件名的都通过了校验；而清单 expected 若因上游更新过期，强校验会把
/// 用户已可用的旧模型误判为缺失、陷入重复重下。
bool isMangaOcrModelFileReady(File file) {
  if (!file.existsSync()) {
    return false;
  }
  return file.lengthSync() > 0;
}

/// 主源 host：清单里所有 URL 的出处。
const String kMangaOcrModelPrimaryHost = 'huggingface.co';

/// 镜像 host（与 huggingface.co **路径完全同构**，只换域名即可命中同一个 blob）。
///
/// 存在的唯一理由是主源在部分网络下握手就断——470MB 的模型对这类用户等于下不动。
/// 镜像只在主源失败后按序尝试（见 `manga_ocr_model_downloader.dart`），不改变
/// 默认信任关系；字节一致性仍由下载器 rename 前的长度校验兜底。
const List<String> kMangaOcrModelMirrorHosts = <String>[
  'hf-mirror.com',
];

/// 一个模型文件的**下载候选 URL 序列**：主源在前，镜像依次在后。
///
/// 刻意做成从 [MangaOcrModelFile.url] 派生而不是让清单逐条列出多个 URL：
/// 清单里每多一个手写 URL 就多一处能写错的地方，而镜像与主源本就只差 host。
/// 非 huggingface.co 的 URL（测试注入的 localhost、将来换源）原样返回单元素
/// 列表——没有「测试专用分支」，只有「不认识的 host 不派生镜像」这一条规则。
List<String> mangaOcrModelUrlCandidates(MangaOcrModelFile file) {
  final Uri primary = Uri.parse(file.url);
  if (primary.host != kMangaOcrModelPrimaryHost) {
    return <String>[file.url];
  }
  return <String>[
    file.url,
    for (final String host in kMangaOcrModelMirrorHosts)
      primary.replace(host: host).toString(),
  ];
}

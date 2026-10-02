/// Selectable local recognizers. The existing manga-ocr model stays the default.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_fingerprint.dart' as model_fp;

enum MangaOcrLocalModel {
  mangaOcr('manga_ocr'),
  baberu('baberu'),
  mangaCtc('manga_ctc');

  const MangaOcrLocalModel(this.key);
  final String key;

  /// 已删除的 `manga_ocr_cuda`（Windows 本地 Python + torch CUDA 档）等未知值一律
  /// 落回默认 manga-ocr：旧偏好 / 备份 / 互联对端可能还带着这个 key。
  static MangaOcrLocalModel fromKey(String key) => switch (key) {
    'baberu' => baberu,
    'manga_ctc' => mangaCtc,
    _ => mangaOcr,
  };

  /// A preference restored from Windows must not select unsupported models on
  /// another device. Settings, imports and inference share this resolution.
  static MangaOcrLocalModel forPlatform(
    String key, {
    String? operatingSystem,
  }) {
    final MangaOcrLocalModel model = fromKey(key);
    return (operatingSystem ?? Platform.operatingSystem) == 'windows' ||
            model.availableOnAllPlatforms
        ? model
        : mangaOcr;
  }

  /// 纯 ONNX Runtime CPU 推理、出包五端都能跑的模型；Baberu（Windows DirectML
  /// 视觉图）只给 Windows。
  bool get availableOnAllPlatforms => switch (this) {
    mangaOcr || mangaCtc => true,
    baberu => false,
  };

  /// 可选提速组件：只有经典 manga-ocr 有（KV cache decoder，结果逐 token 相同）。
  List<MangaOcrModelFile> get accelerator => switch (this) {
    mangaOcr => kMangaOcrKvAcceleratorManifest,
    baberu || mangaCtc => const <MangaOcrModelFile>[],
  };

  List<MangaOcrModelFile> get manifest => switch (this) {
    baberu => kBaberuOcrModelManifest,
    mangaOcr => kMangaOcrModelManifest,
    mangaCtc => kMangaCtcOcrModelManifest,
  };

  String get cacheSignature => switch (this) {
    baberu => 'local-onnx-baberu-v1-bicubic-$kMangaOcrPipelineRevision',
    mangaOcr => kLocalMangaOcrEngineSignature,
    // 不能以 kLocalMangaOcrEngineSignature 开头：那样 manga-ocr 的 v4 旧缓存会被当成
    // 可补几何的来源，把 manga-ocr 的文字冒充成 CTC 的结果（BUG-2813 的升级路径）。
    mangaCtc => 'local-onnx-ctc-kellenok-v0.2-$kMangaOcrPipelineRevision',
  };

  /// Sibling directories keep deleting either model from affecting the other.
  Future<Directory> modelsDirectory() async {
    final Directory legacy = await model_fp.defaultMangaOcrModelsDir();
    final String? sibling = switch (this) {
      mangaOcr => null,
      baberu => 'manga-baberu',
      mangaCtc => 'manga-ctc',
    };
    return sibling == null
        ? legacy
        : Directory(p.join(legacy.parent.path, sibling));
  }
}

/// 已删除模型留在 `<support>/ocr_models/` 下的兄弟目录名。
///
/// `manga-cuda`：2026-10 删除的 Windows 本地 Python + torch cu128 档，一套
/// 4~10 GB；枚举值没了之后，设置页与「设置 › 存储」都不再有能删它的入口。
const List<String> kRemovedMangaOcrModelDirNames = <String>['manga-cuda'];

/// 尽力删掉已删除模型的遗留目录，返回实际删掉的目录数。
///
/// 宿主启动时调一次即可（幂等：目录不在就什么都不做）。删除失败（文件被占用 /
/// 权限）只记日志不抛：不能因为清理旧档挡住启动，下次启动会再试。
/// [ocrModelsRoot] 默认是 `<support>/ocr_models`，测试注入临时目录。
Future<int> deleteRemovedMangaOcrModelDirs({Directory? ocrModelsRoot}) async {
  final Directory root;
  try {
    root = ocrModelsRoot ?? (await model_fp.defaultMangaOcrModelsDir()).parent;
  } catch (error, stack) {
    // 启动时 fire-and-forget 调用：数据根解析失败不能变成未处理异常。
    engineLog.log('deleteRemovedMangaOcrModelDirs', error, stack);
    return 0;
  }
  int deleted = 0;
  for (final String name in kRemovedMangaOcrModelDirNames) {
    final Directory dir = Directory(p.join(root.path, name));
    try {
      if (!await dir.exists()) continue;
      await dir.delete(recursive: true);
      deleted++;
    } on FileSystemException catch (error, stack) {
      engineLog.log('deleteRemovedMangaOcrModelDirs[$name]', error, stack);
    }
  }
  return deleted;
}

const String kBaberuOcrRevision = 'd9cc13153e9a1cd8fdfa3b7b1cc329da2020aeae';

const String _baberuBase =
    'https://huggingface.co/genshiai-daichi/baberu-ocr/resolve/$kBaberuOcrRevision';

/// Apache-2.0 precision tier: FP16 vision weights with float32 IO, int8 decoder
/// prefill/step graphs with a KV cache. Exact sizes checked against HF blobs.
const List<MangaOcrModelFile> kBaberuOcrModelManifest = <MangaOcrModelFile>[
  MangaOcrModelFile(
    fileName: 'detector-v4-s_int8.onnx',
    url:
        'https://huggingface.co/ogkalu/comic-text-and-bubble-detector/'
        'resolve/main/detector-v4-s_int8.onnx',
    expectedBytes: 11120765,
    role: MangaOcrModelRole.detector,
  ),
  MangaOcrModelFile(
    fileName: 'vision_fp16.onnx',
    url: '$_baberuBase/onnx/vision_fp16.onnx',
    expectedBytes: 172917304,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'decoder_prefill_int8.onnx',
    url: '$_baberuBase/onnx/decoder_prefill_int8.onnx',
    expectedBytes: 35133596,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'decoder_step_int8.onnx',
    url: '$_baberuBase/onnx/decoder_step_int8.onnx',
    expectedBytes: 33929034,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'vocab.json',
    url: '$_baberuBase/tokenizer/vocab.json',
    expectedBytes: 130761,
    role: MangaOcrModelRole.recognizer,
  ),
  ...kPpOcrLineModelManifest,
];

/// 漫画逐列 CTC 的列识别权重：Kellenok/PP-OCRv6_manga 的 rec v0.2（Apache-2.0，在
/// PP-OCRv6 small rec 上用 Manga109-s 与 AnimeText 微调）。与 PP-OCRv6 small rec 同
/// 输入契约、同一份 18710 项词表，字典沿用 [kPpOcrRecDictFileName]。钉 revision 的
/// 理由同 PP-OCRv6（`main` 可变）；该 revision 下 LFS sha256 为
/// de12c84c63e62c80339e882e675983d886670dcb6f0147e1ed041afd6fa81888。
const String kMangaCtcRecRevision = 'ba1d479e8a61a20e8318c9758c73fbbbd290b98d';
const String kMangaCtcRecFileName = 'kellenok_manga_rec_v0.2.onnx';

/// 逐列 CTC：检测器 + PP-OCRv6 small det（列 / 行检测）+ 字典 + 漫画 rec（竖列与横行
/// 都用它读）。约 42 MB，是 manga-ocr 那套的十分之一不到。
const List<MangaOcrModelFile> kMangaCtcOcrModelManifest = <MangaOcrModelFile>[
  MangaOcrModelFile(
    fileName: 'detector-v4-s_int8.onnx',
    url:
        'https://huggingface.co/ogkalu/comic-text-and-bubble-detector/'
        'resolve/main/detector-v4-s_int8.onnx',
    expectedBytes: 11120765,
    role: MangaOcrModelRole.detector,
  ),
  MangaOcrModelFile(
    fileName: kPpOcrDetFileName,
    url:
        'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_det_onnx/'
        'resolve/$kPpOcrDetRevision/inference.onnx',
    expectedBytes: 9880512,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: kPpOcrRecDictFileName,
    url:
        'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx/'
        'resolve/$kPpOcrRecRevision/inference.yml',
    expectedBytes: 150579,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: kMangaCtcRecFileName,
    url:
        'https://huggingface.co/Kellenok/PP-OCRv6_manga/'
        'resolve/$kMangaCtcRecRevision/rec/manga_rec_v0.2.onnx',
    expectedBytes: 21167540,
    role: MangaOcrModelRole.recognizer,
  ),
];

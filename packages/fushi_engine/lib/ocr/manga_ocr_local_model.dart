/// Selectable local recognizers: per-column CTC (default, every platform) and
/// Baberu (Windows only). The kha-white manga-ocr model was removed in 2026-10.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_fingerprint.dart' as model_fp;

/// 默认本地模型：逐列 CTC（五端都能跑、约 42 MB）。
const MangaOcrLocalModel kDefaultMangaOcrLocalModel =
    MangaOcrLocalModel.mangaCtc;

enum MangaOcrLocalModel {
  baberu('baberu'),
  mangaCtc('manga_ctc');

  const MangaOcrLocalModel(this.key);
  final String key;

  /// 已删除模型的 key（`manga_ocr`：2026-10 删除的 kha-white manga-ocr；
  /// `manga_ocr_cuda`：Windows 本地 Python + torch CUDA 档）与未知值一律落回
  /// [kDefaultMangaOcrLocalModel]：旧偏好 / 备份 / 互联对端可能还带着这些 key。
  static MangaOcrLocalModel fromKey(String key) => switch (key) {
    'baberu' => baberu,
    _ => kDefaultMangaOcrLocalModel,
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
        : kDefaultMangaOcrLocalModel;
  }

  /// 纯 ONNX Runtime CPU 推理、出包五端都能跑的模型；Baberu（Windows DirectML
  /// 视觉图）只给 Windows。
  bool get availableOnAllPlatforms => switch (this) {
    mangaCtc => true,
    baberu => false,
  };

  List<MangaOcrModelFile> get manifest => switch (this) {
    baberu => kBaberuOcrModelManifest,
    mangaCtc => kMangaCtcOcrModelManifest,
  };

  String get cacheSignature => switch (this) {
    baberu => 'local-onnx-baberu-v1-bicubic-$kMangaOcrPipelineRevision',
    // 不能以 kLocalMangaOcrEngineSignature 开头：那样已删除的 manga-ocr 留下的 v4
    // 旧缓存会被当成可补几何的来源，把 manga-ocr 的文字冒充成 CTC 的结果
    // （BUG-2813 的升级路径）。
    mangaCtc => 'local-onnx-ctc-kellenok-v0.2-$kMangaOcrPipelineRevision',
  };

  /// 每个模型一个兄弟目录（`<support>/ocr_models/<name>`），删一个不波及另一个。
  /// 父目录由 [model_fp.defaultMangaOcrModelsDir]（旧 manga-ocr 目录）的 parent
  /// 求得。
  Future<Directory> modelsDirectory() async {
    final Directory legacy = await model_fp.defaultMangaOcrModelsDir();
    final String sibling = switch (this) {
      baberu => 'manga-baberu',
      mangaCtc => 'manga-ctc',
    };
    return Directory(p.join(legacy.parent.path, sibling));
  }
}

/// 按 [model] 的模型目录 / 清单 / 缓存签名解析本机已安装模型的逐页缓存签名
/// （只读缓存的消费方：向导探测 / 重开恢复；BUG-1173）。
///
/// 数据根解析在没有 platform channel 的纯 Dart 测试环境会抛，这里退回该模型的
/// 基线签名 [MangaOcrLocalModel.cacheSignature]——含义明确：「拿不到已安装模型
/// 身份」，此时只会命中修复前的旧缓存目录，绝不会把新旧模型的结果混起来。
Future<String> resolveInstalledLocalMangaOcrEngineSignature({
  MangaOcrLocalModel model = kDefaultMangaOcrLocalModel,
}) async {
  try {
    return await model_fp.resolveLocalMangaOcrEngineSignature(
      await model.modelsDirectory(),
      manifest: model.manifest,
      baseSignature: model.cacheSignature,
    );
  } catch (_) {
    return model.cacheSignature;
  }
}

/// 已删除模型留在 `<support>/ocr_models/` 下的兄弟目录名。
///
/// `manga-cuda`：2026-10 删除的 Windows 本地 Python + torch cu128 档，一套
/// 4~10 GB；枚举值没了之后，设置页与「设置 › 存储」都不再有能删它的入口。
const List<String> kRemovedMangaOcrModelDirNames = <String>['manga-cuda'];

/// 已删除的 kha-white manga-ocr 本地模型留在旧目录 `<support>/ocr_models/manga/`
/// 里的专属文件（各自的 `.part` 断点残留一并删）。
///
/// 同目录里的 PP-OCRv6 三件套（`ppocrv6_small_det.onnx` /
/// `ppocrv6_small_rec.onnx` / `ppocrv6_small_rec.yml`）**刻意不在此列**：
/// galgame 查词校准 OCR（`gal_lookup_calibration_ocr.dart`）会复用这个目录里
/// 已有的那三份，删了等于让它再下一份 31 MB。
const List<String> kRemovedMangaOcrLegacyFileNames = <String>[
  'encoder_model.onnx',
  'decoder_model.onnx',
  'vocab.txt',
  'cross_kv.onnx',
  'decoder_kv.onnx',
  'detector-v4-s_int8.onnx',
  model_fp.kMangaOcrModelFingerprintFileName,
];

/// 旧 manga-ocr 目录名（[model_fp.defaultMangaOcrModelsDir] 的 basename）。
const String kLegacyMangaOcrModelDirName = 'manga';

/// 尽力删掉已删除模型的遗留数据，返回实际删掉的**条目数**：每删掉一个
/// [kRemovedMangaOcrModelDirNames] 目录、[kRemovedMangaOcrLegacyFileNames] 里的
/// 一个文件（或它的 `.part`）、以及删空后的旧 `manga/` 目录本身，各计 1。
///
/// 宿主启动时调一次即可（幂等：不在就什么都不做）。删除失败（文件被占用 /
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
  deleted += await _deleteRemovedMangaOcrLegacyFiles(
    Directory(p.join(root.path, kLegacyMangaOcrModelDirName)),
  );
  return deleted;
}

/// 从旧 `manga/` 目录删 [kRemovedMangaOcrLegacyFileNames]（含 `.part`）；目录删空
/// 了连目录一起删。返回删掉的条目数。
Future<int> _deleteRemovedMangaOcrLegacyFiles(Directory legacy) async {
  try {
    if (!await legacy.exists()) return 0;
  } on FileSystemException catch (error, stack) {
    engineLog.log('deleteRemovedMangaOcrModelDirs[manga]', error, stack);
    return 0;
  }
  int deleted = 0;
  for (final String name in kRemovedMangaOcrLegacyFileNames) {
    for (final String fileName in <String>[name, '$name.part']) {
      final File file = File(p.join(legacy.path, fileName));
      try {
        if (!await file.exists()) continue;
        await file.delete();
        deleted++;
      } on FileSystemException catch (error, stack) {
        engineLog.log(
          'deleteRemovedMangaOcrModelDirs[manga/$fileName]',
          error,
          stack,
        );
      }
    }
  }
  try {
    if (await legacy.list().isEmpty) {
      await legacy.delete();
      deleted++;
    }
  } on FileSystemException catch (error, stack) {
    engineLog.log('deleteRemovedMangaOcrModelDirs[manga]', error, stack);
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
/// 都用它读）。约 42 MB。
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

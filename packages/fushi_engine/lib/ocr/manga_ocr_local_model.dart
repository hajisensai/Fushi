/// Selectable local recognizers. Only per-column CTC (every platform) remains:
/// the kha-white manga-ocr model and Baberu were both removed in 2026-10. The
/// enum and its key / platform resolution stay so a future model can plug in.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_fingerprint.dart' as model_fp;
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart'
    show PpOcrCharacterDictFormat;

/// 默认本地模型：逐列 CTC（五端都能跑、约 42 MB）。
const MangaOcrLocalModel kDefaultMangaOcrLocalModel =
    MangaOcrLocalModel.mangaCtc;

enum MangaOcrLocalModel {
  mangaCtc('manga_ctc');

  const MangaOcrLocalModel(this.key);
  final String key;

  /// 已删除模型的 key（`manga_ocr`：2026-10 删除的 kha-white manga-ocr；
  /// `manga_ocr_cuda`：Windows 本地 Python + torch CUDA 档；`baberu`：2026-10
  /// 删除的 genshiai-daichi/baberu-ocr）与未知值一律落回
  /// [kDefaultMangaOcrLocalModel]：旧偏好 / 备份 / 互联对端可能还带着这些 key。
  static MangaOcrLocalModel fromKey(String key) {
    for (final MangaOcrLocalModel model in values) {
      if (model.key == key) return model;
    }
    return kDefaultMangaOcrLocalModel;
  }

  /// A preference restored from Windows must not select unsupported models on
  /// another device. Settings, imports and inference share this resolution.
  static MangaOcrLocalModel forPlatform(String key, {String? operatingSystem}) {
    final MangaOcrLocalModel model = fromKey(key);
    return (operatingSystem ?? Platform.operatingSystem) == 'windows' ||
            model.availableOnAllPlatforms
        ? model
        : kDefaultMangaOcrLocalModel;
  }

  /// 纯 ONNX Runtime CPU 推理、出包五端都能跑的模型；只给 Windows 的模型在
  /// 这里返回 false（目前没有：2026-10 删掉的 Baberu 曾是唯一一个）。
  bool get availableOnAllPlatforms => switch (this) {
    mangaCtc => true,
  };

  /// 当前这一代：下载、导入、设置页展示都按它。
  MangaOcrModelGeneration get generation => switch (this) {
    mangaCtc => kMangaCtcGeneration,
  };

  /// 上一代：当前这一代还没下齐、而它在磁盘上齐全时，识别照常用它跑
  /// （[installedMangaOcrGeneration]）。没有上一代的模型返回 null。
  MangaOcrModelGeneration? get supersededGeneration => switch (this) {
    mangaCtc => kMangaCtcSupersededGeneration,
  };

  List<MangaOcrModelFile> get manifest => generation.manifest;

  String get cacheSignature => generation.cacheSignature;

  /// 每个模型一个兄弟目录（`<support>/ocr_models/<name>`），删一个不波及另一个。
  /// 父目录由 [model_fp.defaultMangaOcrModelsDir]（旧 manga-ocr 目录）的 parent
  /// 求得。
  Future<Directory> modelsDirectory() async {
    final Directory legacy = await model_fp.defaultMangaOcrModelsDir();
    final String sibling = switch (this) {
      mangaCtc => kMangaCtcModelDirName,
    };
    return Directory(p.join(legacy.parent.path, sibling));
  }
}

/// 一代模型：清单、缓存签名基线，以及块识别 rec 与它的字典。
///
/// 换 rec 版本 = 换一代。新一代的文件落盘名带版本，与上一代并存于同一个目录，
/// 所以「磁盘上装的是哪一代」只看各自清单齐不齐（[installedMangaOcrGeneration]）。
class MangaOcrModelGeneration {
  const MangaOcrModelGeneration({
    required this.manifest,
    required this.cacheSignature,
    required this.recFileName,
    required this.recDictFileName,
    required this.recDictFormat,
  });

  final List<MangaOcrModelFile> manifest;

  /// 逐页缓存签名的基线（后面再接已安装文件的内容指纹）。每代不同：上一代的
  /// 逐页缓存不会被当成这一代的结果，反之亦然。
  final String cacheSignature;

  final String recFileName;
  final String recDictFileName;
  final PpOcrCharacterDictFormat recDictFormat;

  /// [dir] 里这一代的清单文件是否齐全（只 stat 清单里那几个文件）。
  bool isCompleteIn(Directory dir) => manifest.every(
    (MangaOcrModelFile file) =>
        isMangaOcrModelFileReady(File(p.join(dir.path, file.fileName))),
  );
}

/// [dir] 里实际能用来识别的那一代：[current] 齐全就用它；否则 [superseded] 齐全
/// 就用上一代；都不齐返回 null（本地 OCR 跑不起来）。
///
/// 为什么留上一代：换 rec 版本后老用户磁盘上只有上一代的文件。没有这一步，更新
/// app 之后本地 OCR 会一直报「模型未下载」，直到用户去设置页再下一次——而上一代
/// 明明还能读。下齐新一代后上一代的文件才删（[deleteSupersededMangaCtcFiles]）。
MangaOcrModelGeneration? installedMangaOcrGeneration(
  Directory dir, {
  required MangaOcrModelGeneration current,
  MangaOcrModelGeneration? superseded,
}) {
  if (current.isCompleteIn(dir)) return current;
  if (superseded != null && superseded.isCompleteIn(dir)) return superseded;
  return null;
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
    final Directory dir = await model.modelsDirectory();
    // 当前一代没下齐而上一代还在时，实际在读（也在写缓存）的是上一代。
    final MangaOcrModelGeneration generation =
        installedMangaOcrGeneration(
          dir,
          current: model.generation,
          superseded: model.supersededGeneration,
        ) ??
        model.generation;
    return await model_fp.resolveLocalMangaOcrEngineSignature(
      dir,
      manifest: generation.manifest,
      baseSignature: generation.cacheSignature,
    );
  } catch (_) {
    return model.cacheSignature;
  }
}

/// 已删除模型留在 `<support>/ocr_models/` 下的兄弟目录名。
///
/// `manga-cuda`：2026-10 删除的 Windows 本地 Python + torch cu128 档，一套
/// 4~10 GB；`manga-baberu`：2026-10 删除的 Baberu（约 270 MB，目录里那份
/// `detector-v4-s_int8.onnx` 是它自己的副本，`manga-ctc` 另有一份，整目录删不波及
/// CTC）。枚举值没了之后，设置页与「设置 › 存储」都不再有能删它们的入口。
const List<String> kRemovedMangaOcrModelDirNames = <String>[
  'manga-cuda',
  'manga-baberu',
];

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

/// 逐列 CTC 目录名（[MangaOcrLocalModel.modelsDirectory] 的 basename）。
const String kMangaCtcModelDirName = 'manga-ctc';

/// 逐列 CTC 上一代（Kellenok rec v0.2，2026-11 换成 v0.3）独有、当前一代不再用的
/// 文件（各自的 `.part` 一并删）：v0.2 rec（21 MB）与它用的 PP-OCRv6
/// `inference.yml` 字典（v0.3 自带纯文本字典）。
///
/// **只在当前一代下齐之后才删**（[deleteSupersededMangaCtcFiles]）：没下齐之前
/// 上一代还在替它读。只删 `manga-ctc/` 里的：galgame 查词校准 OCR 用的同名字典住
/// 在 `manga/` 或 `gal_calibration/`，不受影响。
const List<String> kRemovedMangaCtcFileNames = <String>[
  kMangaCtcSupersededRecFileName,
  kPpOcrRecDictFileName,
];

/// 尽力删掉已删除模型的遗留数据，返回实际删掉的**条目数**：每删掉一个
/// [kRemovedMangaOcrModelDirNames] 目录、[kRemovedMangaOcrLegacyFileNames] 里的
/// 一个文件（或它的 `.part`）、`manga-ctc/` 里 [kRemovedMangaCtcFileNames] 的一个
/// 文件（或它的 `.part`，仅当当前一代已下齐）、以及删空后的旧 `manga/` 目录本身，
/// 各计 1。
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
  deleted += await _deleteRemovedMangaOcrFiles(
    Directory(p.join(root.path, kLegacyMangaOcrModelDirName)),
    kRemovedMangaOcrLegacyFileNames,
  );
  deleted += await deleteSupersededMangaCtcFiles(
    Directory(p.join(root.path, kMangaCtcModelDirName)),
  );
  return deleted;
}

/// 逐列 CTC 当前一代在 [ctcDir] 里下齐之后，删掉上一代独有的文件
/// （[kRemovedMangaCtcFileNames]），返回删掉的条目数；没下齐时什么都不删——那时
/// 上一代还在替它读。启动时与模型下载完成后各调一次；幂等，失败只记日志。
Future<int> deleteSupersededMangaCtcFiles(Directory ctcDir) async {
  try {
    if (!await ctcDir.exists()) return 0;
    if (!kMangaCtcGeneration.isCompleteIn(ctcDir)) return 0;
  } on FileSystemException catch (error, stack) {
    engineLog.log('deleteSupersededMangaCtcFiles', error, stack);
    return 0;
  }
  return _deleteRemovedMangaOcrFiles(ctcDir, kRemovedMangaCtcFileNames);
}

/// 从 [legacy] 目录删 [fileNames]（含 `.part`）；目录删空了连目录一起删。返回删掉
/// 的条目数。
Future<int> _deleteRemovedMangaOcrFiles(
  Directory legacy,
  List<String> fileNames,
) async {
  final String label = p.basename(legacy.path);
  try {
    if (!await legacy.exists()) return 0;
  } on FileSystemException catch (error, stack) {
    engineLog.log('deleteRemovedMangaOcrModelDirs[$label]', error, stack);
    return 0;
  }
  int deleted = 0;
  for (final String name in fileNames) {
    for (final String fileName in <String>[name, '$name.part']) {
      final File file = File(p.join(legacy.path, fileName));
      try {
        if (!await file.exists()) continue;
        await file.delete();
        deleted++;
      } on FileSystemException catch (error, stack) {
        engineLog.log(
          'deleteRemovedMangaOcrModelDirs[$label/$fileName]',
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
    engineLog.log('deleteRemovedMangaOcrModelDirs[$label]', error, stack);
  }
  return deleted;
}

/// 漫画逐列 CTC 的列识别权重：Kellenok/PP-OCRv6_manga 的 rec v0.3（Apache-2.0，在
/// PP-OCRv6 small rec 上用 Manga109-s 与 AnimeText 微调）。与 PP-OCRv6 small rec 同
/// 输入契约，但**字典不同**：v0.3 自带纯文本字典 `ppocrv6_dict.txt`（19053 项，在
/// PP-OCRv6 的 18708 项后追加了 345 个 JIS 汉字），输出 19055 类（blank + 字典 +
/// 空格）。拿 PP-OCRv6 的 `inference.yml` 配它会在识别时因词表长度不符抛错。
/// 钉 revision 的理由同 PP-OCRv6（`main` 可变，且上游改写过历史：最早钉的 v0.2
/// revision ba1d479e 整个 404，BUG-4492）；钉的是 `main` 上 2026-11-06 的提交，
/// 该 revision 下 rec 的 LFS sha256 为
/// 5288bd221a9a047c6b7d1ff56bb98de8c875fb613df98ebe8754946448bda540。
///
/// 落盘名带版本：v0.2 的文件（`kellenok_manga_rec_v0.2.onnx`）绝不会被当成 v0.3。
/// 远端 basename 是 `manga_rec.onnx` / `ppocrv6_dict.txt`，离线导入按字节数认。
const String kMangaCtcRecRevision = 'd65838996a00ef6b1c73ca3a700d7a8c5fbbef8a';
const String kMangaCtcRecFileName = 'kellenok_manga_rec_v0.3.onnx';
const String kMangaCtcRecDictFileName = 'kellenok_manga_rec_v0.3_dict.txt';

/// 逐列 CTC：检测器 + PP-OCRv6 small det（列 / 行检测）+ 漫画 rec（竖列与横行都用它
/// 读）+ 漫画 rec 的字典。约 42 MB。
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
    fileName: kMangaCtcRecFileName,
    url:
        'https://huggingface.co/Kellenok/PP-OCRv6_manga/'
        'resolve/$kMangaCtcRecRevision/rec/manga_rec.onnx',
    expectedBytes: 21334702,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: kMangaCtcRecDictFileName,
    url:
        'https://huggingface.co/Kellenok/PP-OCRv6_manga/'
        'resolve/$kMangaCtcRecRevision/ppocrv6_dict.txt',
    expectedBytes: 76327,
    role: MangaOcrModelRole.recognizer,
  ),
];

/// 逐列 CTC 的当前一代（Kellenok rec v0.3）。
///
/// 缓存签名不能以 kLocalMangaOcrEngineSignature 开头：那样已删除的 manga-ocr 留下
/// 的 v4 旧缓存会被当成可补几何的来源，把 manga-ocr 的文字冒充成 CTC 的结果
/// （BUG-2813 的升级路径）。
const MangaOcrModelGeneration kMangaCtcGeneration = MangaOcrModelGeneration(
  manifest: kMangaCtcOcrModelManifest,
  cacheSignature: 'local-onnx-ctc-kellenok-v0.3-$kMangaOcrPipelineRevision',
  recFileName: kMangaCtcRecFileName,
  recDictFileName: kMangaCtcRecDictFileName,
  recDictFormat: PpOcrCharacterDictFormat.plainText,
);

/// 上一代 rec（Kellenok v0.2，`main` 历史里的 Release v0.2 提交 d090c421）的落盘名。
const String kMangaCtcSupersededRecFileName = 'kellenok_manga_rec_v0.2.onnx';

/// 逐列 CTC 的上一代（Kellenok rec v0.2 + PP-OCRv6 `inference.yml` 字典）。**不再
/// 下载**，只用来认磁盘上已有的文件：清单的文件、顺序与缓存签名都与换代前逐字
/// 相同，所以回落到它时命中的就是用户原来那批逐页缓存目录。
///
/// 清理条件：新装机不会有这一代的文件，老用户下齐 v0.3 后文件即被删
/// （[deleteSupersededMangaCtcFiles]）；下一次换代时把这里换成那时的「上一代」。
const MangaOcrModelGeneration kMangaCtcSupersededGeneration =
    MangaOcrModelGeneration(
      manifest: <MangaOcrModelFile>[
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
          fileName: kMangaCtcSupersededRecFileName,
          url:
              'https://huggingface.co/Kellenok/PP-OCRv6_manga/'
              'resolve/d090c421598eadd2e179ad62c29ff0767492072c/'
              'rec/manga_rec_v0.2.onnx',
          expectedBytes: 21167540,
          role: MangaOcrModelRole.recognizer,
        ),
      ],
      cacheSignature: 'local-onnx-ctc-kellenok-v0.2-$kMangaOcrPipelineRevision',
      recFileName: kMangaCtcSupersededRecFileName,
      recDictFileName: kPpOcrRecDictFileName,
      recDictFormat: PpOcrCharacterDictFormat.paddleYaml,
    );

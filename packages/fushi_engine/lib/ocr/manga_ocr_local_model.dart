/// Selectable local recognizers, of three kinds ([MangaOcrRecognizerSpec]):
///
/// - PaddleOCR-format CTC line recognizers read through the per-column
///   pipeline, differing only in their weights and dictionary: the manga-tuned
///   default, a larger general Chinese one and a Korean one.
/// - muscgab manga-ocr-charspot (small / nano): one model call per text block
///   returns every character with its box and reading order
///   (`charspot_ocr_recognizer.dart`). Japanese only; weights are CC BY-NC-SA
///   4.0 and are downloaded by the user from Hugging Face, never bundled.
/// - muscgab manga-ocr-nar-small: one model call per text block returns the
///   whole text, without character boxes (`nar_ocr_recognizer.dart`). Japanese
///   only; same licence and download terms as charspot.
/// - One user-imported slot ([MangaOcrLocalModel.custom]): a PaddleOCR CTC
///   recogniser the user downloads and imports (`manga_ocr_custom_model.dart`).
///
/// The kha-white manga-ocr model and Baberu were both removed in 2026-10.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/ocr/charspot_ocr_recognizer.dart'
    show kCharspotNanoCellBudget, kCharspotSmallCellBudget;
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_custom_model.dart'
    show resolveCustomMangaOcrEngineSignature;
import 'package:fushi_engine/ocr/manga_ocr_model_fingerprint.dart' as model_fp;
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart'
    show PpOcrCharacterDictFormat;

/// 默认本地模型：逐列 CTC（五端都能跑、约 42 MB）。
const MangaOcrLocalModel kDefaultMangaOcrLocalModel =
    MangaOcrLocalModel.mangaCtc;

enum MangaOcrLocalModel {
  mangaCtc('manga_ctc'),

  /// PP-OCRv6 medium rec：通用中文（简 / 繁）识别更准，体积与耗时约为默认模型的
  /// 四倍。实测见 [kPpOcrV6MediumGeneration]。
  ppOcrV6Medium('ppocrv6_medium'),

  /// PP-OCRv5 韩文 rec：默认模型与 PP-OCRv6 都不认谚文，这是唯一能读韩文的档。
  ppOcrV5Korean('ppocrv5_korean'),

  /// muscgab manga-ocr-charspot-small：整块一次推理出逐字框与阅读序，日文漫画上
  /// 比默认模型准得多（实测见 [kCharspotSmallGeneration]）。只认日文。
  charspotSmall('charspot_small'),

  /// muscgab manga-ocr-charspot-nano：同上的 1.7M 参数版，约为 small 的四分之一
  /// 耗时，准确率略低。
  charspotNano('charspot_nano'),

  /// muscgab manga-ocr-nar-small：整块一次前向出整段文本（非自回归，54M 参数），
  /// 不给字框。准确率与 charspot-small 相当，体积约五倍、耗时约三倍（实测见
  /// [kNarSmallGeneration]）。只认日文。
  narSmall('nar_small'),

  /// User-imported slot: one PaddleOCR-format CTC recogniser (`.onnx` + its
  /// dictionary) the user downloaded and imported (`manga_ocr_custom_model.dart`).
  /// Its files are not known at compile time: [generation] is only the slot's
  /// static shape (the shared detector files it downloads); the generation that
  /// actually runs is built from the metadata written at import
  /// ([customMangaOcrGeneration]). App only: hosts and the server never list it
  /// ([isUserImported]).
  custom('custom');

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
    mangaCtc ||
    ppOcrV6Medium ||
    ppOcrV5Korean ||
    charspotSmall ||
    charspotNano ||
    narSmall ||
    custom => true,
  };

  /// The user-imported slot. Its weights live only on this device, so paired
  /// hosts and the server do not offer it to peers ([builtInValues]).
  bool get isUserImported => this == custom;

  /// Every model that ships with a download manifest (all but [custom]).
  static List<MangaOcrLocalModel> get builtInValues => <MangaOcrLocalModel>[
    for (final MangaOcrLocalModel model in values)
      if (!model.isUserImported) model,
  ];

  /// 当前这一代：下载、导入、设置页展示都按它。
  MangaOcrModelGeneration get generation => switch (this) {
    mangaCtc => kMangaCtcGeneration,
    ppOcrV6Medium => kPpOcrV6MediumGeneration,
    ppOcrV5Korean => kPpOcrV5KoreanGeneration,
    charspotSmall => kCharspotSmallGeneration,
    charspotNano => kCharspotNanoGeneration,
    narSmall => kNarSmallGeneration,
    custom => kCustomMangaOcrSlotGeneration,
  };

  /// 上一代：当前这一代还没下齐、而它在磁盘上齐全时，识别照常用它跑
  /// （[installedMangaOcrGeneration]）。没有上一代的模型返回 null。
  MangaOcrModelGeneration? get supersededGeneration => switch (this) {
    mangaCtc => kMangaCtcSupersededGeneration,
    ppOcrV6Medium ||
    ppOcrV5Korean ||
    charspotSmall ||
    charspotNano ||
    narSmall ||
    custom => null,
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
      ppOcrV6Medium => kPpOcrV6MediumModelDirName,
      ppOcrV5Korean => kPpOcrV5KoreanModelDirName,
      charspotSmall => kCharspotSmallModelDirName,
      charspotNano => kCharspotNanoModelDirName,
      narSmall => kNarSmallModelDirName,
      custom => kCustomMangaOcrModelDirName,
    };
    return Directory(p.join(legacy.parent.path, sibling));
  }
}

/// 块识别器的种类与它专属的参数。装配层（`manga_ocr_service_impl.dart`）按种类
/// 组装 isolate 里的识别器，不从 PaddleOCR 的字段里猜。
sealed class MangaOcrRecognizerSpec {
  const MangaOcrRecognizerSpec();

  /// 「OCR 忽略振假名」对这种识别器是否还有额外作用（见各子类）。为 false 时
  /// 服务把开关当关处理：识别结果与缓存目录都不随开关变。
  bool get honoursIgnoreFurigana;
}

/// PaddleOCR 格式的 CTC 行识别器，经逐列管线读（`ctc_column_ocr_recognizer.dart`）。
/// 「忽略振假名」在逐列识别前再裁掉贴着正文的注音带（`trimOcrRubyBands`）。
final class MangaOcrCtcColumnSpec extends MangaOcrRecognizerSpec {
  const MangaOcrCtcColumnSpec({required this.dictFormat});

  /// rec 字典的格式（官方 rec 是 `inference.yml`，漫画 rec 是纯文本）。
  final PpOcrCharacterDictFormat dictFormat;

  @override
  bool get honoursIgnoreFurigana => true;
}

/// muscgab manga-ocr-charspot：整块一次推理（`charspot_ocr_recognizer.dart`）。
/// 振假名在 ONNX 图里就去掉了（上游 `RUBY_THR`），开关不开也不会读进正文，所以
/// 「忽略振假名」对它没有额外作用。
final class MangaOcrCharspotSpec extends MangaOcrRecognizerSpec {
  const MangaOcrCharspotSpec({required this.cellBudget});

  /// 16 px 格子的预算（small 256、nano 196）。
  final int cellBudget;

  @override
  bool get honoursIgnoreFurigana => false;
}

/// muscgab manga-ocr-nar-small：整块一次前向出整段文本（`nar_ocr_recognizer.dart`）。
/// 模型是按「文字块 → 正文」端到端训练的，训练标注不含振假名，裁掉注音带这一步
/// 没有对应的输入可裁（它不逐列读），所以「忽略振假名」对它没有额外作用。
final class MangaOcrNarSpec extends MangaOcrRecognizerSpec {
  const MangaOcrNarSpec();

  @override
  bool get honoursIgnoreFurigana => false;
}

/// 一代模型：清单、缓存签名基线，以及块识别器的权重、字表与种类。
///
/// 换 rec 版本 = 换一代。新一代的文件落盘名带版本，与上一代并存于同一个目录，
/// 所以「磁盘上装的是哪一代」只看各自清单齐不齐（[installedMangaOcrGeneration]）。
class MangaOcrModelGeneration {
  const MangaOcrModelGeneration({
    required this.manifest,
    required this.cacheSignature,
    required this.recFileName,
    required this.recDictFileName,
    required this.recognizer,
  });

  final List<MangaOcrModelFile> manifest;

  /// 逐页缓存签名的基线（后面再接已安装文件的内容指纹）。每代不同：上一代的
  /// 逐页缓存不会被当成这一代的结果，反之亦然。
  final String cacheSignature;

  /// 块识别器的权重文件名（每个模型、每一代都不同，[mangaOcrGenerationForRecFile]
  /// 按它反查）。
  final String recFileName;

  /// 块识别器的字表文件名（PaddleOCR 字典 / charspot `vocab.json`）。
  final String recDictFileName;

  final MangaOcrRecognizerSpec recognizer;

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

/// rec 落盘名为 [recFileName] 的那一代（任一模型的当前一代或上一代）；没有任何
/// 一代用这个名字时返回 null。
///
/// 整卷任务的 isolate 只拿得到模型文件路径，缓存签名却必须跟着「实际在读的那份
/// rec」走——每一代的 rec 落盘名互不相同（带模型名 / 版本），按它反查不会认错。
///
/// The custom slot is never returned: its generation (and cache signature) comes
/// from the metadata written at import, which this synchronous lookup cannot
/// read. Callers that only have paths must be handed the signature instead
/// (`MangaOcrServiceImpl` always does).
MangaOcrModelGeneration? mangaOcrGenerationForRecFile(String recFileName) {
  for (final MangaOcrLocalModel model in MangaOcrLocalModel.builtInValues) {
    for (final MangaOcrModelGeneration? generation
        in <MangaOcrModelGeneration?>[
          model.generation,
          model.supersededGeneration,
        ]) {
      if (generation != null && generation.recFileName == recFileName) {
        return generation;
      }
    }
  }
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
    if (model.isUserImported) {
      return await resolveCustomMangaOcrEngineSignature(dir);
    }
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

/// The custom slot's folder ([MangaOcrLocalModel.modelsDirectory] basename).
const String kCustomMangaOcrModelDirName = 'custom';

/// On-disk name of the imported recogniser (the user's file is copied to it).
const String kCustomMangaOcrRecFileName = 'custom_rec.onnx';

/// Static shape of the custom slot: only the two shared detector files, which
/// are the part Fushi downloads itself (`downloadModels`). The recogniser, its
/// dictionary and the cache signature come from the import metadata
/// ([customMangaOcrGeneration]); nothing may resolve model paths from this
/// constant, and its signature is never written to because OCR cannot run
/// while the slot is empty.
const MangaOcrModelGeneration kCustomMangaOcrSlotGeneration =
    MangaOcrModelGeneration(
      manifest: <MangaOcrModelFile>[
        _kComicTextDetectorFile,
        _kPpOcrSmallDetFile,
      ],
      cacheSignature: 'local-onnx-ctc-custom-empty-$kMangaOcrPipelineRevision',
      recFileName: kCustomMangaOcrRecFileName,
      recDictFileName: '',
      recognizer: MangaOcrCtcColumnSpec(
        dictFormat: PpOcrCharacterDictFormat.plainText,
      ),
    );

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
  recognizer: MangaOcrCtcColumnSpec(
    dictFormat: PpOcrCharacterDictFormat.plainText,
  ),
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
      recognizer: MangaOcrCtcColumnSpec(
        dictFormat: PpOcrCharacterDictFormat.paddleYaml,
      ),
    );

/// 各模型共用的两份检测权重（每个模型目录各存一份，删一个模型不波及另一个）：
/// 文字块检测器与 PP-OCRv6 small det（块内列 / 行检测）。与
/// [kMangaCtcOcrModelManifest] 里的两项逐字相同。
const MangaOcrModelFile _kComicTextDetectorFile = MangaOcrModelFile(
  fileName: 'detector-v4-s_int8.onnx',
  url:
      'https://huggingface.co/ogkalu/comic-text-and-bubble-detector/'
      'resolve/main/detector-v4-s_int8.onnx',
  expectedBytes: 11120765,
  role: MangaOcrModelRole.detector,
);
const MangaOcrModelFile _kPpOcrSmallDetFile = MangaOcrModelFile(
  fileName: kPpOcrDetFileName,
  url:
      'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_det_onnx/'
      'resolve/$kPpOcrDetRevision/inference.onnx',
  expectedBytes: 9880512,
  role: MangaOcrModelRole.recognizer,
);

/// PP-OCRv6 medium rec（PaddlePaddle/PP-OCRv6_medium_rec_onnx，Apache-2.0）。与
/// PP-OCRv6 small rec 同输入契约、同 18708 项字典（各自仓库的 `inference.yml`），
/// 输出 18710 类。钉 revision 的理由同 [kPpOcrDetRevision]（`main` 可变）；该
/// revision 下 rec 的 sha256 为
/// 9c09abf0957f7968c7586464b7397b84ad2387a0497a351af40e9acc71b673ba。
///
/// 2026-11-14 实测（500 个合成中文对话块，同一套逐列管线、CPU 4 线程）：字错误率
/// 10.31%（默认模型 12.51%）、整块全对 60.0%（47.0%），每块 181 ms（48 ms）。日文
/// 漫画上不如默认模型（9.03% 对 5.87%），所以它是「中文更准」的可选档，不是默认。
const String kPpOcrV6MediumRecRevision =
    '50c7eacafc52fa7bcf4194e8cd08e46f8558504b';
const String kPpOcrV6MediumModelDirName = 'ppocrv6-medium';
const String kPpOcrV6MediumRecFileName = 'ppocrv6_medium_rec.onnx';
const String kPpOcrV6MediumRecDictFileName = 'ppocrv6_medium_rec.yml';

const MangaOcrModelGeneration kPpOcrV6MediumGeneration =
    MangaOcrModelGeneration(
      manifest: <MangaOcrModelFile>[
        _kComicTextDetectorFile,
        _kPpOcrSmallDetFile,
        MangaOcrModelFile(
          fileName: kPpOcrV6MediumRecFileName,
          url:
              'https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_rec_onnx/'
              'resolve/$kPpOcrV6MediumRecRevision/inference.onnx',
          expectedBytes: 76554979,
          role: MangaOcrModelRole.recognizer,
        ),
        MangaOcrModelFile(
          fileName: kPpOcrV6MediumRecDictFileName,
          url:
              'https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_rec_onnx/'
              'resolve/$kPpOcrV6MediumRecRevision/inference.yml',
          expectedBytes: 150580,
          role: MangaOcrModelRole.recognizer,
        ),
      ],
      cacheSignature:
          'local-onnx-ctc-ppocrv6-medium-$kMangaOcrPipelineRevision',
      recFileName: kPpOcrV6MediumRecFileName,
      recDictFileName: kPpOcrV6MediumRecDictFileName,
      recognizer: MangaOcrCtcColumnSpec(
        dictFormat: PpOcrCharacterDictFormat.paddleYaml,
      ),
    );

/// PP-OCRv5 韩文 rec（PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx，Apache-2.0）。
/// 输入契约同 PP-OCRv6 rec（[1,3,48,W]、BGR），字典是它自己的 `inference.yml`
/// （11945 项），输出 11947 类。该 revision 下 rec 的 sha256 为
/// 92f0b7785e64fc9090106a241cf4c1eb97472824558272751b88a2a4476d3a08。
///
/// 2026-11-14 实测（500 个合成韩文对话块，全部横排）：字错误率 18.07%、整块全对
/// 37.0%，每块 39 ms；默认模型与 PP-OCRv6 medium 在同一批上是 97%（不认谚文）。
/// 它不是漫画微调的，装饰字体与竖排没有测过。
const String kPpOcrV5KoreanRecRevision =
    '5c6f574b8e2230adf4287b33e736d71b9fabd28e';
const String kPpOcrV5KoreanModelDirName = 'ppocrv5-korean';
const String kPpOcrV5KoreanRecFileName = 'ppocrv5_korean_rec.onnx';
const String kPpOcrV5KoreanRecDictFileName = 'ppocrv5_korean_rec.yml';

const MangaOcrModelGeneration
kPpOcrV5KoreanGeneration = MangaOcrModelGeneration(
  manifest: <MangaOcrModelFile>[
    _kComicTextDetectorFile,
    _kPpOcrSmallDetFile,
    MangaOcrModelFile(
      fileName: kPpOcrV5KoreanRecFileName,
      url:
          'https://huggingface.co/PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx/'
          'resolve/$kPpOcrV5KoreanRecRevision/inference.onnx',
      expectedBytes: 13418787,
      role: MangaOcrModelRole.recognizer,
    ),
    MangaOcrModelFile(
      fileName: kPpOcrV5KoreanRecDictFileName,
      url:
          'https://huggingface.co/PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx/'
          'resolve/$kPpOcrV5KoreanRecRevision/inference.yml',
      expectedBytes: 96039,
      role: MangaOcrModelRole.recognizer,
    ),
  ],
  cacheSignature: 'local-onnx-ctc-ppocrv5-korean-$kMangaOcrPipelineRevision',
  recFileName: kPpOcrV5KoreanRecFileName,
  recDictFileName: kPpOcrV5KoreanRecDictFileName,
  recognizer: MangaOcrCtcColumnSpec(
    dictFormat: PpOcrCharacterDictFormat.paddleYaml,
  ),
);

/// muscgab manga-ocr-charspot 的两个模型都从作者的 HF 仓库直接下载：权重是
/// CC BY-NC-SA 4.0（非商用、署名、相同方式共享），代码 Apache-2.0。本仓不打包、
/// 不转发权重，设置页的模型说明写明「非商用许可」并署名 muscgab；README 的模型
/// 致谢表同样列出。
///
/// 清单：文字块检测器 + PP-OCRv6 small det（块大到 charspot 读不清时切列 / 行，
/// 例如整张截图、整页字幕位图，`charspot_ocr_recognizer.dart`）+ charspot 权重 +
/// 字表。不带 PaddleOCR rec：横排块也交 charspot 整块读，不经路由识别器。
///
/// 两个文件都钉了 revision 与 sha256（`main` 可变；sha256 是 HF 的 LFS 指纹 /
/// 本机下载后实算，2026-11-14）。
const String kCharspotSmallRevision =
    '72ca29202673880ca9c67b1c02c107535be4472b';
const String kCharspotSmallModelDirName = 'charspot-small';
const String kCharspotSmallRecFileName = 'charspot_small.onnx';
const String kCharspotSmallVocabFileName = 'charspot_small_vocab.json';

/// manga-ocr-charspot-small（11M 参数）。
///
/// 2026-11-14 实测（JMangaBench 1000 个真实漫画文字块，CPU，整图当一块文字图）：
/// 本管线（服务端 FFI ORT，Windows 2 线程）字错误率 1.14%、整块全对 93.6%、每块
/// 中位 45~50 ms；Python 参考实现（上游包）1.06% / 93.7%，4 线程 31 ms、2 线程 40 ms。
/// 默认模型（Kellenok v0.3 逐列）在本管线同一批是 5.13% / 87.2% / 36 ms。横排块
/// 弱于竖排（全对 76.9% 对 94.7%），超过 32 字的块也偏弱。
const MangaOcrModelGeneration
kCharspotSmallGeneration = MangaOcrModelGeneration(
  manifest: <MangaOcrModelFile>[
    _kComicTextDetectorFile,
    _kPpOcrSmallDetFile,
    MangaOcrModelFile(
      fileName: kCharspotSmallRecFileName,
      url:
          'https://huggingface.co/muscgab/manga-ocr-charspot-small/'
          'resolve/$kCharspotSmallRevision/model.onnx',
      expectedBytes: 43992111,
      role: MangaOcrModelRole.recognizer,
      sha256:
          '05fb79760f8e3dbc989b61f23a34c46b511818a2166573ce7e41d994f4403843',
    ),
    MangaOcrModelFile(
      fileName: kCharspotSmallVocabFileName,
      url:
          'https://huggingface.co/muscgab/manga-ocr-charspot-small/'
          'resolve/$kCharspotSmallRevision/vocab.json',
      expectedBytes: 62244,
      role: MangaOcrModelRole.recognizer,
      sha256:
          '9f72fc7852b1432bcb61b3b94b2e4cd8abef52b01e9051550a6a3070e2b314d5',
    ),
  ],
  cacheSignature: 'local-onnx-charspot-small-v1.0.0-$kMangaOcrPipelineRevision',
  recFileName: kCharspotSmallRecFileName,
  recDictFileName: kCharspotSmallVocabFileName,
  recognizer: MangaOcrCharspotSpec(cellBudget: kCharspotSmallCellBudget),
);

const String kCharspotNanoRevision = '978dc91bde3bcb36eed3cf2de679d607d1d0f30b';
const String kCharspotNanoModelDirName = 'charspot-nano';
const String kCharspotNanoRecFileName = 'charspot_nano.onnx';
const String kCharspotNanoVocabFileName = 'charspot_nano_vocab.json';

/// manga-ocr-charspot-nano（1.7M 参数，格子预算 196）。
///
/// 2026-11-14 实测（同一批 1000 块）：本管线字错误率 1.40%、整块全对 91.1%、每块
/// 中位 13 ms；Python 参考实现 1.47% / 90.6%，2 线程 8 ms。横排块全对 65.4%。
const MangaOcrModelGeneration kCharspotNanoGeneration = MangaOcrModelGeneration(
  manifest: <MangaOcrModelFile>[
    _kComicTextDetectorFile,
    _kPpOcrSmallDetFile,
    MangaOcrModelFile(
      fileName: kCharspotNanoRecFileName,
      url:
          'https://huggingface.co/muscgab/manga-ocr-charspot-nano/'
          'resolve/$kCharspotNanoRevision/model.onnx',
      expectedBytes: 6926056,
      role: MangaOcrModelRole.recognizer,
      sha256:
          'f4fc3f4d59f982f050dd4f57bde0e8d7335041a224c3813a5dfbc20c34b0e28c',
    ),
    MangaOcrModelFile(
      fileName: kCharspotNanoVocabFileName,
      url:
          'https://huggingface.co/muscgab/manga-ocr-charspot-nano/'
          'resolve/$kCharspotNanoRevision/vocab.json',
      expectedBytes: 48538,
      role: MangaOcrModelRole.recognizer,
      sha256:
          '9f1059427b54216c869dbf1244157f86bef74b1a0061c46a6001402c6f0c1dbf',
    ),
  ],
  cacheSignature: 'local-onnx-charspot-nano-v1.1.1-$kMangaOcrPipelineRevision',
  recFileName: kCharspotNanoRecFileName,
  recDictFileName: kCharspotNanoVocabFileName,
  recognizer: MangaOcrCharspotSpec(cellBudget: kCharspotNanoCellBudget),
);

/// muscgab manga-ocr-nar-small（HF `muscgab/manga-ocr-nar-small`，包版本 1.1.0）。
/// 许可与下载方式同 charspot：权重 CC BY-NC-SA 4.0（非商用、署名、相同方式共享），
/// 代码 Apache-2.0；本仓不打包、不转发权重，由用户从作者的 HF 仓库下载。
///
/// 清单：文字块检测器 + PP-OCRv6 small det（给整块文本配行几何，块太大或文本超过
/// 65 字时切列 / 行）+ 权重 + 字表。权重钉了 revision 与 sha256（HF 的 LFS 指纹，
/// 与本机下载后实算一致，2026-11-18）；字表与 charspot-nano 的 `vocab.json` 是同一
/// 份内容（sha256 相同）。
///
/// 2026-11-17 实测（JMangaBench_Read 固定抽样 1,500 框，Python 参考实现，ORT CPU
/// 4 线程，整框当一块文字图）：整块全对 92.00%、字错误率 1.09%、每块 88 ms、
/// 213 MB；同一批上 charspot-small 是 93.07% / 1.06% / 27 ms / 44 MB，默认模型
/// （Kellenok v0.3 逐列）87.43% / 3.27%。它不比 charspot-small 准，而且慢三倍、
/// 大五倍、没有逐字框；列出来是给想用非自回归整块模型的用户一个选项，不是推荐档。
const String kNarSmallRevision = '81ff4f3313263d1da349946a9dd20d14e0fb0e66';
const String kNarSmallModelDirName = 'nar-small';
const String kNarSmallRecFileName = 'nar_small.onnx';
const String kNarSmallVocabFileName = 'nar_small_vocab.json';

const MangaOcrModelGeneration kNarSmallGeneration = MangaOcrModelGeneration(
  manifest: <MangaOcrModelFile>[
    _kComicTextDetectorFile,
    _kPpOcrSmallDetFile,
    MangaOcrModelFile(
      fileName: kNarSmallRecFileName,
      url:
          'https://huggingface.co/muscgab/manga-ocr-nar-small/'
          'resolve/$kNarSmallRevision/onnx/mangaocr_nar_small_fp32.onnx',
      expectedBytes: 213095336,
      role: MangaOcrModelRole.recognizer,
      sha256:
          '5ee628dfd40c59c522022d87c31f8f903104198877b9ba4cf795603dc540dcf5',
    ),
    MangaOcrModelFile(
      fileName: kNarSmallVocabFileName,
      url:
          'https://huggingface.co/muscgab/manga-ocr-nar-small/'
          'resolve/$kNarSmallRevision/nar_vocabulary_6817.json',
      expectedBytes: 48538,
      role: MangaOcrModelRole.recognizer,
      sha256:
          '9f1059427b54216c869dbf1244157f86bef74b1a0061c46a6001402c6f0c1dbf',
    ),
  ],
  cacheSignature: 'local-onnx-nar-small-v1.1.0-$kMangaOcrPipelineRevision',
  recFileName: kNarSmallRecFileName,
  recDictFileName: kNarSmallVocabFileName,
  recognizer: MangaOcrNarSpec(),
);

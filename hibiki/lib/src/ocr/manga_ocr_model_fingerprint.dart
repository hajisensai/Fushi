/// 已安装漫画 OCR 模型的**内容身份**，以及由它派生的逐页缓存签名。
///
/// 为什么需要：`kLocalMangaOcrEngineSignature`（`local-onnx-v2-oriented`）是手
/// 维护常量，只描述坐标口径版本；而 `manga_ocr_model_manifest.dart` 的下载直链
/// 指向 HuggingFace 的 **`main` 可变 ref** 且清单里没有 sha256。上游一旦重新导出
/// 模型，新装用户下到的是另一份权重，缓存目录名却纹丝不动 —— 断点续跑会把新旧
/// 模型的结果混进同一卷，向导的「整卷已缓存」探测还会直接跳过重跑，全程无人察觉
/// （BUG-1173）。
///
/// 做法：把清单里全部模型文件的 sha256 折成一个短指纹接在基线常量后面，让「模型
/// 变了」在**文件系统层**表现为另一个缓存目录，旧结果自然失效而不是被静默复用。
/// 全量哈希约 470MB，按 (size, mtime) 记忆化到模型目录旁的 sidecar，命中时只做
/// 四次 stat + 一次小 JSON 读。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/ocr/manga_ocr_folder_job.dart';
import 'package:fushi/src/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// 记忆化 sidecar 文件名（与模型同目录；删模型目录即一并清掉）。
///
/// 记忆化的键是 (size, mtime)，与 git / rsync / ninja 同一套判定：模型是 11MB~343MB
/// 的整文件下载，「同尺寸 + 同毫秒时间戳但内容不同」不可能发生。指纹本身恒由内容
/// 派生，mtime 只决定要不要重算，不会自己造成整卷缓存失效（同内容重下 → 重算得到
/// 同一个 sha256 → 同一个签名）。
const String kMangaOcrModelFingerprintFileName = 'model_fingerprint.json';

/// 缓存目录名里保留的指纹长度（sha256 前 12 个 hex 字符）。
const int kMangaOcrModelFingerprintLength = 12;

/// 默认模型目录：`<appSupport>/ocr_models/manga`（经 [AppPaths] 数据根单一入口）。
Future<Directory> defaultMangaOcrModelsDir() async {
  final Directory support = await AppPaths.supportRootDirectory();
  return Directory(p.join(support.path, 'ocr_models', 'manga'));
}

/// 单个文件的 sha256（流式，不把 343MB 的 encoder 读进内存）。
Future<String> _fileSha256(File file) async {
  final Digest digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// [modelsDir] 里已安装模型集合的内容指纹。
///
/// 任一清单文件缺失/不可读时返回 `null`（没有可识别的模型身份），调用方据此退回
/// 基线签名而不是编造一个指纹。
Future<String?> resolveMangaOcrModelFingerprint(
  Directory modelsDir, {
  List<MangaOcrModelFile> manifest = kMangaOcrModelManifest,
}) async {
  final File sidecar =
      File(p.join(modelsDir.path, kMangaOcrModelFingerprintFileName));
  final Map<String, Object?> memo = await _readSidecar(sidecar);
  final Map<String, Object?> nextMemo = <String, Object?>{};
  final List<String> parts = <String>[];
  bool changed = false;
  for (final MangaOcrModelFile model in manifest) {
    final File file = File(p.join(modelsDir.path, model.fileName));
    final FileStat stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
      return null;
    }
    final int modifiedMs = stat.modified.millisecondsSinceEpoch;
    final Object? cached = memo[model.fileName];
    String? hash;
    if (cached is Map &&
        cached['size'] == stat.size &&
        cached['modified_ms'] == modifiedMs &&
        cached['sha256'] is String) {
      hash = cached['sha256'] as String;
    } else {
      try {
        hash = await _fileSha256(file);
      } on FileSystemException {
        return null;
      }
      changed = true;
    }
    nextMemo[model.fileName] = <String, Object?>{
      'size': stat.size,
      'modified_ms': modifiedMs,
      'sha256': hash,
    };
    parts.add('${model.fileName}:$hash');
  }
  if (parts.isEmpty) {
    return null;
  }
  if (changed) {
    await _writeSidecar(sidecar, nextMemo);
  }
  final Digest combined = sha256.convert(utf8.encode(parts.join('\n')));
  return combined.toString().substring(0, kMangaOcrModelFingerprintLength);
}

/// 本地 ONNX 引擎的逐页缓存签名：基线坐标口径常量 + 已安装模型指纹。
///
/// 模型不完整时退回裸 [kLocalMangaOcrEngineSignature]——那时本地 OCR 根本跑不
/// 起来，只可能读到本修复之前写下的旧缓存目录。
Future<String> resolveLocalMangaOcrEngineSignature(
  Directory modelsDir, {
  List<MangaOcrModelFile> manifest = kMangaOcrModelManifest,
}) async {
  final String? fingerprint =
      await resolveMangaOcrModelFingerprint(modelsDir, manifest: manifest);
  if (fingerprint == null) {
    return kLocalMangaOcrEngineSignature;
  }
  return '$kLocalMangaOcrEngineSignature-$fingerprint';
}

/// 用默认模型目录解析签名（只读缓存的消费方：向导探测 / 重开恢复）。
///
/// 数据根解析在没有 platform channel 的纯 Dart 测试环境会抛，这里退回基线常量
/// ——含义明确：「拿不到已安装模型身份」，此时只会命中修复前的旧缓存目录，绝不会
/// 把新旧模型的结果混起来。
Future<String> resolveInstalledLocalMangaOcrEngineSignature() async {
  try {
    return await resolveLocalMangaOcrEngineSignature(
      await defaultMangaOcrModelsDir(),
    );
  } catch (_) {
    return kLocalMangaOcrEngineSignature;
  }
}

Future<Map<String, Object?>> _readSidecar(File sidecar) async {
  if (!sidecar.existsSync()) {
    return const <String, Object?>{};
  }
  try {
    final Object? decoded = jsonDecode(await sidecar.readAsString());
    if (decoded is! Map<String, dynamic>) {
      return const <String, Object?>{};
    }
    final Object? files = decoded['files'];
    if (files is! Map<String, dynamic>) {
      return const <String, Object?>{};
    }
    return files;
  } catch (_) {
    // 损坏的记忆化文件当空：重算哈希覆盖写，不影响正确性。
    return const <String, Object?>{};
  }
}

Future<void> _writeSidecar(File sidecar, Map<String, Object?> files) async {
  try {
    await sidecar.parent.create(recursive: true);
    final File temporary = File('${sidecar.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(<String, Object?>{'schema_version': 1, 'files': files}),
      flush: true,
    );
    if (sidecar.existsSync()) {
      await sidecar.delete();
    }
    await temporary.rename(sidecar.path);
  } on FileSystemException {
    // 只读模型目录：指纹本身已算出，少一次记忆化只是下次要重算。
  }
}

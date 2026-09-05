/// 有声书 ASR 模型的磁盘管理：目录解析、就绪判定、占用统计、下载、删除。
///
/// 下载本身走共享的 `ModelFileDownloader`（`.part` 续传 / 镜像回退 / 代理），
/// 本类只负责「哪些文件、放哪、算多少」。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/onnx/model_file_downloader.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/directory_bytes.dart';

/// 某个编码器变体的模型就绪 / 占用状态。
class AsrModelStatus {
  const AsrModelStatus({
    required this.ready,
    required this.diskBytes,
    required this.totalBytes,
    required this.obtainedBytes,
  });

  /// 该变体全套文件是否都已就绪。
  final bool ready;

  /// 模型目录的**真实递归占用**字节数（含 `.part` 残留与另一个变体的编码器）。
  /// 回答「删掉能腾出多少」；与 OCR 的 `MangaOcrModelStatus.diskBytes` 同一条
  /// 理由（BUG-1732）：真相源只能是磁盘本身。
  final int diskBytes;

  /// 该变体全套文件的预期总字节数（清单常量之和）。
  final int totalBytes;

  /// 朝着 [totalBytes] **已经拿到手**的字节数：已就绪文件 + 未完成下载的
  /// `.part` 里攒下的部分。回答「还差多少下完」，与 [diskBytes] 是两个数。
  final int obtainedBytes;

  bool get hasAnyFiles => diskBytes > 0;
}

/// ASR 模型目录。
class AsrModelStore {
  AsrModelStore(this.dir);

  /// 模型目录：`<appSupport>/asr_models/reazonspeech-k2-v2`——与漫画 OCR 的
  /// `<appSupport>/ocr_models/manga` 同级同构，经 [AppPaths] 数据根单一入口，
  /// 不硬编码平台路径。
  static Future<AsrModelStore> open() async {
    final Directory support = await AppPaths.supportRootDirectory();
    return AsrModelStore(
      Directory(p.join(support.path, 'asr_models', 'reazonspeech-k2-v2')),
    );
  }

  final Directory dir;

  /// 某角色文件的落盘位置（不保证存在）。
  File fileFor(AsrModelRole role) =>
      File(p.join(dir.path, asrModelFileForRole(role).fileName));

  /// 该变体全套文件是否都已就绪（只 stat 清单里那几个文件，不遍历目录）。
  bool isReady(AsrEncoderVariant variant) {
    return asrModelFilesFor(
      variant,
    ).every((AsrModelFile file) => isAsrModelFileReady(fileFor(file.role)));
  }

  /// 该变体的就绪 / 占用状态（递归量目录，别放热路径）。
  Future<AsrModelStatus> status(AsrEncoderVariant variant) async {
    int obtained = 0;
    for (final AsrModelFile model in asrModelFilesFor(variant)) {
      final File file = fileFor(model.role);
      if (isAsrModelFileReady(file)) {
        obtained += file.lengthSync();
        continue;
      }
      // 未就绪的文件若留着 `.part`，那些字节下次点下载会被 Range 续上，必须
      // 算进「已下多少」——否则用户看到的进度会在每次重进设置页时归零。
      final File part = File('${file.path}.part');
      if (part.existsSync()) {
        obtained += part.lengthSync();
      }
    }
    return AsrModelStatus(
      ready: isReady(variant),
      diskBytes: await measureDirectoryBytes(dir),
      totalBytes: asrModelTotalBytes(variant),
      obtainedBytes: obtained,
    );
  }

  /// 下载该变体缺失的文件（事件契约见 [ModelFileDownloader.downloadAll]）。
  ///
  /// [downloader] 可注入（测试）；默认用 ASR 候选序列
  /// （[asrModelUrlCandidates]：主源 → hf-mirror → 第二源 → 其 hf-mirror）。
  Stream<ModelDownloadEvent> download(
    AsrEncoderVariant variant, {
    ModelFileDownloader? downloader,
  }) {
    final ModelFileDownloader effective =
        downloader ??
        ModelFileDownloader(
          urlCandidates: (DownloadableModelFile file) =>
              // 只有本清单的 [AsrModelFile] 会经本方法进入下载器，转型结构上成立。
              asrModelUrlCandidates(file as AsrModelFile),
        );
    return effective.downloadAll(
      files: asrModelFilesFor(variant),
      targetDir: dir,
      isReady: isAsrModelFileReady,
    );
  }

  /// 删除整个模型目录（两个变体、`.part` 残留一并清掉）；返回释放的字节数。
  Future<int> deleteAll() async {
    if (!await dir.exists()) {
      return 0;
    }
    // 先量后删：删完再量只会得到 0，用户就永远拿不到「到底释放了多少」。
    final int freed = await measureDirectoryBytes(dir);
    await dir.delete(recursive: true);
    return freed;
  }
}

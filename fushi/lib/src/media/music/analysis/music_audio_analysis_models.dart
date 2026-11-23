/// 音频分析的两个可选模型（opt-in 下载，从不随包）：
///
/// - **Beat This!**（CPJKU，ISMIR 2024，final0 检查点，MIT，https://github.com/CPJKU/beat_this）——拍点 / 强拍；
/// - **htdemucs**（Meta Research Demucs v4，MIT，https://github.com/facebookresearch/demucs）——鼓 / 人声分轨。
///
/// 两个 ONNX 文件与 folia-major 早期版本下载的是同一份（folia 的模型清单按 sha256 钉死，
/// `htdemucs.onnx` = sha256 099b5be7…）。下载源是 folia 维护者的 Hugging Face 仓库，**钉到提交**（不是 main），
/// 下载器自动带上 hf-mirror.com 镜像；落盘后按 sha256 校验，不符即删、下次重下。
///
/// 移动端只用 Beat This!（htdemucs 在手机 CPU 上一首要数分钟、发热）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_asr_core/asr_core.dart'
    show DownloadableModelFile, ModelDownloadEvent, ModelFileDownloader;
import 'package:fushi_compute/fushi_compute.dart' show ffcSha256File;
import 'package:path/path.dart' as p;

/// 模型清单版本：换文件时改它（也是模型子目录名），旧目录自然不再被读。
const String kMusicAnalysisModelsVersion = 'v1';

/// 下载源仓库的钉死提交（Hugging Face `HUAI4236/folia-models`）。
const String _kHfRevision = 'f316d6150e1749ffcf54ce79768641f1dfe58b91';

/// 一个按需下载的模型文件（sha256 钉死）。
@immutable
class MusicAnalysisModelFile implements DownloadableModelFile {
  const MusicAnalysisModelFile({
    required this.fileName,
    required this.expectedBytes,
    required this.sha256,
  });

  @override
  final String fileName;

  @override
  final int expectedBytes;

  /// 小写十六进制。
  final String sha256;

  @override
  String get url =>
      'https://huggingface.co/HUAI4236/folia-models/resolve/'
      '$_kHfRevision/$fileName';
}

/// Beat This! final0（≈83 MB）。
const MusicAnalysisModelFile kMusicBeatThisModel = MusicAnalysisModelFile(
  fileName: 'beat_this.onnx',
  expectedBytes: 83077778,
  sha256: 'c5c1466e08abdb03fdeb50668a06f244b787d564c212490482231a9cfbe9ccbd',
);

/// htdemucs 四轨（≈109 MB）。
const MusicAnalysisModelFile kMusicHtdemucsModel = MusicAnalysisModelFile(
  fileName: 'htdemucs.onnx',
  expectedBytes: 108644650,
  sha256: '099b5be76c1f6922124d07f850250f39d1f33f254a0b8cc90f4ec0dfd0912329',
);

/// 本平台要的模型（移动端不要分轨模型）。
List<MusicAnalysisModelFile> musicAnalysisModelsFor({required bool desktop}) =>
    <MusicAnalysisModelFile>[
      kMusicBeatThisModel,
      if (desktop) kMusicHtdemucsModel,
    ];

/// 本平台是不是桌面（决定要不要分轨模型）。
bool get musicAnalysisIsDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 模型目录里一个文件已就绪（存在且长度对）。sha256 在下载完成时校验过一次，之后只看长度。
bool musicAnalysisModelReady(Directory dir, MusicAnalysisModelFile file) {
  final File f = File(p.join(dir.path, file.fileName));
  return f.existsSync() && f.lengthSync() == file.expectedBytes;
}

/// 下载 [files] 到 [dir] 并逐个校验字节数与 SHA-256；不符的文件删掉并抛 [StateError]（下次重下）。
/// [onProgress] 收下载器的进度事件；[urlCandidates] / [createClient] 只给测试注入本地服务器。
Future<void> downloadMusicAnalysisModels(
  Directory dir,
  List<MusicAnalysisModelFile> files, {
  void Function(ModelDownloadEvent event)? onProgress,
  List<String> Function(DownloadableModelFile file)? urlCandidates,
  HttpClient Function()? createClient,
}) async {
  if (!dir.existsSync()) await dir.create(recursive: true);
  final ModelFileDownloader downloader = ModelFileDownloader(
    urlCandidates: urlCandidates,
    createClient: createClient,
  );
  await downloader
      .downloadAll(
        files: files,
        targetDir: dir,
        isReady: (File f) => files.any(
          (MusicAnalysisModelFile m) =>
              p.basename(f.path) == m.fileName &&
              f.lengthSync() == m.expectedBytes,
        ),
      )
      .forEach((ModelDownloadEvent e) => onProgress?.call(e));
  for (final MusicAnalysisModelFile file in files) {
    final String path = p.join(dir.path, file.fileName);
    // 原生 SHA-256，1 MiB 一块异步读（UI isolate 上不长时间阻塞）。
    final String actual = await ffcSha256File(path);
    if (actual != file.sha256) {
      await File(path).delete();
      throw StateError('${file.fileName}: sha256 $actual != ${file.sha256}');
    }
  }
}

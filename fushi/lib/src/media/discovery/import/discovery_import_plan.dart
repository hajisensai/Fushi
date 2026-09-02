/// 发现页下载物 → 导入计划的**纯分类**层：不碰 IO，输入是路径/文件清单，
/// 输出 sealed [DiscoveryImportPlan]。执行（真正调用各域导入器）在
/// `discovery_import_executor.dart`；分类规则全部可单测。
///
/// 扩展名集合一律引用各域已有的单一真相（`AudiobookStorage.audioExtensions` /
/// `TextToEpub.supportedExtensions`），不自造副本。
library;

import 'package:fushi_audio/fushi_audio.dart';

import 'package:fushi/src/media/audiobook/text_to_epub.dart';
import 'package:fushi/src/media/discovery/discovery_models.dart';

/// 字幕扩展名（`book_import_dialog.dart` 的选择器同集合；有声书对齐的输入）。
const Set<String> kDiscoverySubtitleExtensions = <String>{
  '.srt',
  '.lrc',
  '.vtt',
  '.ass',
  '.ssa',
};

/// 需要先解压的压缩包扩展名。zip 走内置解码，7z/rar 依赖 7-Zip 命令行。
const Set<String> kDiscoveryArchiveExtensions = <String>{
  '.zip',
  '.7z',
  '.rar',
};

/// 漫画**图包**载体：整包交给 `MangaArchiveImporter`，不走通用解压器。
///
/// 为什么必须是独立一档、且判定要**排在** [isDiscoveryArchivePath] 之前：
/// `.rar`/`.zip` 同时落在通用压缩包集合里，先被通用解压器截胡的话，解出来的
/// 只是一堆散图，重分类只能走 `MangaImporter.importFromImageFolder`——**包内的
/// `.mokuro` OCR 层会被静默丢掉**，用户得到一部没有查词层的漫画，而且没有任何
/// 报错。`MangaArchiveImporter` 自己解包、自己找 sidecar，把整包给它才是完整路径。
///
/// 与 `kMangaCarrierFileExtensions`（手动导入对话框的选择器白名单）的差别：
/// 这里**不含** `.epub`/`.pdf`。发现页的 pdf 恒归小说域（`OpdsFileType` 亦然），
/// 在漫画域再认一次只会让同一个文件按用户当前所在页签进不同的库。
const Set<String> kDiscoveryMangaArchiveExtensions = <String>{
  '.cbz',
  '.cbr',
  '.cb7',
  '.rar',
  '.zip',
};

/// 自动导入走不下去的稳定原因（UI 层负责翻译成用户文案）。
enum DiscoveryImportBlocker {
  /// 该媒体域认不出这个文件类型。
  unknownFileType,

  /// 有声书包里没有 EPUB/文本正文。
  audiobookMissingText,

  /// 有声书包里没有字幕（对齐的必要输入——本仓有声书模型是字幕对齐驱动）。
  audiobookMissingSubtitle,

  /// 有声书包里没有音频。
  audiobookMissingAudio,

  /// 游戏包里找不到可执行文件。
  gameNoExecutable,

  /// 7z/rar 需要 7-Zip 命令行而本机没有。
  archiveToolMissing,

  /// 解压失败（损坏/带密码等）。
  archiveExtractionFailed,
}

/// 自动导入被挡下（分类不出/解压工具缺失/解压失败）。队列把它落成任务
/// failed；[blocker] 是稳定原因码，UI 层翻译。
class DiscoveryImportBlockedException implements Exception {
  const DiscoveryImportBlockedException(this.blocker, [this.detail]);

  final DiscoveryImportBlocker blocker;
  final String? detail;

  @override
  String toString() => 'DiscoveryImportBlockedException(${blocker.name}'
      '${detail == null ? '' : ': $detail'})';
}

sealed class DiscoveryImportPlan {
  const DiscoveryImportPlan();
}

/// 直接导入一个 EPUB。
final class ImportEpubPlan extends DiscoveryImportPlan {
  const ImportEpubPlan(this.filePath);
  final String filePath;
}

/// 文本先转 EPUB 再导入。
final class ConvertTextPlan extends DiscoveryImportPlan {
  const ConvertTextPlan(this.filePath);
  final String filePath;
}

/// PDF 走独立 PdfImporter。
final class ImportPdfPlan extends DiscoveryImportPlan {
  const ImportPdfPlan(this.filePath);
  final String filePath;
}

/// 压缩包：先解压，再对解出的文件树按同域重新分类。
final class ExtractArchivePlan extends DiscoveryImportPlan {
  const ExtractArchivePlan(this.archivePath);
  final String archivePath;
}

/// 漫画图包整包导入（cbz/cbr/cb7/rar/zip）。
///
/// 刻意**不**复用 [ExtractArchivePlan]：漫画包的解压必须由
/// `MangaArchiveImporter` 做，它会识别包内的 `.mokuro` OCR sidecar 并把页图
/// 铺成 mokuro 卷目录；通用解压器解出来的散图丢掉了这一层。
final class ImportMangaArchivePlan extends DiscoveryImportPlan {
  const ImportMangaArchivePlan(this.archivePath);
  final String archivePath;
}

/// 有声书对齐导入：正文（EPUB 或可转文本）+ 字幕 + 音频。
final class AlignAudiobookPlan extends DiscoveryImportPlan {
  const AlignAudiobookPlan({
    required this.contentPath,
    required this.subtitlePath,
    required this.audioPaths,
  });

  final String contentPath;
  final String subtitlePath;
  final List<String> audioPaths;
}

/// 登记游戏 exe 进库。
final class RegisterGameExesPlan extends DiscoveryImportPlan {
  const RegisterGameExesPlan(this.exePaths);
  final List<String> exePaths;
}

/// 多个子计划（小说包里若干本书）。
final class MultiPlan extends DiscoveryImportPlan {
  const MultiPlan(this.children);
  final List<DiscoveryImportPlan> children;
}

/// 自动导入走不下去。
final class UnsupportedPlan extends DiscoveryImportPlan {
  const UnsupportedPlan(this.blocker);
  final DiscoveryImportBlocker blocker;
}

String _ext(String path) {
  final int dot = path.lastIndexOf('.');
  if (dot < 0 || dot < path.lastIndexOf('/') || dot < path.lastIndexOf('\\')) {
    return '';
  }
  return path.substring(dot).toLowerCase();
}

bool _isText(String path) {
  final String ext = _ext(path);
  return ext.isNotEmpty &&
      TextToEpub.supportedExtensions.contains(ext.substring(1));
}

bool _isAudio(String path) =>
    AudiobookStorage.audioExtensions.contains(_ext(path));

bool _isSubtitle(String path) =>
    kDiscoverySubtitleExtensions.contains(_ext(path));

/// 是否需要先解压。
bool isDiscoveryArchivePath(String path) =>
    kDiscoveryArchiveExtensions.contains(_ext(path));

/// 是否是漫画图包载体。
bool isDiscoveryMangaArchivePath(String path) =>
    kDiscoveryMangaArchiveExtensions.contains(_ext(path));

/// 单个下载文件的分类入口。
DiscoveryImportPlan classifyDiscoveryFile(
  DiscoveryMediaKind kind,
  String filePath,
) {
  // 漫画载体必须**先于**通用解压判定：`.rar`/`.zip` 两边都命中，被通用
  // 解压器截胡就会丢掉包内的 `.mokuro` OCR 层（见
  // [kDiscoveryMangaArchiveExtensions] 的注释）。
  if (kind == DiscoveryMediaKind.manga &&
      isDiscoveryMangaArchivePath(filePath)) {
    return ImportMangaArchivePlan(filePath);
  }
  if (isDiscoveryArchivePath(filePath)) return ExtractArchivePlan(filePath);
  switch (kind) {
    case DiscoveryMediaKind.novel:
      final String ext = _ext(filePath);
      if (ext == '.epub') return ImportEpubPlan(filePath);
      if (ext == '.pdf') return ImportPdfPlan(filePath);
      if (_isText(filePath)) return ConvertTextPlan(filePath);
      return const UnsupportedPlan(DiscoveryImportBlocker.unknownFileType);
    case DiscoveryMediaKind.audiobook:
      // 单文件永远凑不齐「正文 + 字幕 + 音频」。
      return const UnsupportedPlan(
          DiscoveryImportBlocker.audiobookMissingAudio);
    case DiscoveryMediaKind.game:
      if (_ext(filePath) == '.exe') {
        return RegisterGameExesPlan(<String>[filePath]);
      }
      return const UnsupportedPlan(DiscoveryImportBlocker.unknownFileType);
    case DiscoveryMediaKind.manga:
      // 图包载体已在函数开头拦下；走到这里的是单张图片/未知类型。
      // 在线漫画**追更**仍走 Mihon/mokuro 链路，与这里的整卷图包导入是两回事。
      return const UnsupportedPlan(DiscoveryImportBlocker.unknownFileType);
  }
}

/// 解压后的文件树分类（[filePaths] 为递归文件清单，绝对路径）。
///
/// [fileSizes] 供游戏 exe 启发式挑主程序（字节数，缺省时全按 0）。
DiscoveryImportPlan classifyDiscoveryDirectory(
  DiscoveryMediaKind kind,
  List<String> filePaths, {
  Map<String, int> fileSizes = const <String, int>{},
}) {
  switch (kind) {
    case DiscoveryMediaKind.novel:
      final List<DiscoveryImportPlan> children = <DiscoveryImportPlan>[
        for (final String path in filePaths)
          if (_ext(path) == '.epub')
            ImportEpubPlan(path)
          else if (_ext(path) == '.pdf')
            ImportPdfPlan(path)
          else if (_isText(path))
            ConvertTextPlan(path),
      ];
      if (children.isEmpty) {
        return const UnsupportedPlan(DiscoveryImportBlocker.unknownFileType);
      }
      if (children.length == 1) return children.single;
      return MultiPlan(children);
    case DiscoveryMediaKind.audiobook:
      String? content;
      String? subtitle;
      final List<String> audio = <String>[];
      for (final String path in filePaths) {
        if (content == null && _ext(path) == '.epub') {
          content = path;
        } else if (_isSubtitle(path)) {
          subtitle ??= path;
        } else if (_isAudio(path)) {
          audio.add(path);
        }
      }
      // EPUB 优先当正文；没有 EPUB 再退纯文本。
      if (content == null) {
        for (final String path in filePaths) {
          if (_isText(path)) {
            content = path;
            break;
          }
        }
      }
      if (audio.isEmpty) {
        return const UnsupportedPlan(
          DiscoveryImportBlocker.audiobookMissingAudio,
        );
      }
      if (subtitle == null) {
        return const UnsupportedPlan(
          DiscoveryImportBlocker.audiobookMissingSubtitle,
        );
      }
      if (content == null) {
        return const UnsupportedPlan(
          DiscoveryImportBlocker.audiobookMissingText,
        );
      }
      audio.sort();
      return AlignAudiobookPlan(
        contentPath: content,
        subtitlePath: subtitle,
        audioPaths: audio,
      );
    case DiscoveryMediaKind.game:
      final String? exe = pickGalgameMainExe(filePaths, fileSizes: fileSizes);
      if (exe == null) {
        return const UnsupportedPlan(DiscoveryImportBlocker.gameNoExecutable);
      }
      return RegisterGameExesPlan(<String>[exe]);
    case DiscoveryMediaKind.manga:
      // 文件树里的每个图包各自成一卷（种子形态：一个文件夹装若干 cbz）。
      // 这里**不**处理「一堆散图直接躺在目录里」——那需要目录根路径，而本函数
      // 只拿得到文件清单；散图目录的导入走手动导入对话框的 folder 入口。
      final List<DiscoveryImportPlan> volumes = <DiscoveryImportPlan>[
        for (final String path in filePaths)
          if (isDiscoveryMangaArchivePath(path)) ImportMangaArchivePlan(path),
      ];
      if (volumes.isEmpty) {
        return const UnsupportedPlan(DiscoveryImportBlocker.unknownFileType);
      }
      if (volumes.length == 1) return volumes.single;
      return MultiPlan(volumes);
  }
}

/// 安装器/运行库一眼假的 exe 名（含即排除）。
final RegExp _kAuxExePattern = RegExp(
  r'(unins|setup|install|update|patch|vcredist|dxsetup|directx|dotnet|redist|'
  r'crashreport|unitycrash|config$|settings$)',
  caseSensitive: false,
);

/// 从解压树里挑游戏主程序：剔除辅助 exe → 目录层级浅者优先 → 同层取最大。
/// 全被剔除时退回全量再按同规则挑（配置器命名的游戏本体不至于漏掉）。
String? pickGalgameMainExe(
  List<String> filePaths, {
  Map<String, int> fileSizes = const <String, int>{},
}) {
  final List<String> exes = <String>[
    for (final String path in filePaths)
      if (_ext(path) == '.exe') path,
  ];
  if (exes.isEmpty) return null;

  List<String> candidates = <String>[
    for (final String path in exes)
      if (!_kAuxExePattern.hasMatch(_baseNameNoExt(path))) path,
  ];
  if (candidates.isEmpty) candidates = exes;

  int depthOf(String path) => '/'.allMatches(path.replaceAll('\\', '/')).length;
  final int minDepth = candidates.map(depthOf).reduce(
        (int a, int b) => a < b ? a : b,
      );
  candidates = <String>[
    for (final String path in candidates)
      if (depthOf(path) == minDepth) path,
  ];
  candidates.sort(
    (String a, String b) => (fileSizes[b] ?? 0).compareTo(fileSizes[a] ?? 0),
  );
  return candidates.first;
}

String _baseNameNoExt(String path) {
  final String normalized = path.replaceAll('\\', '/');
  final String base = normalized.substring(normalized.lastIndexOf('/') + 1);
  final int dot = base.lastIndexOf('.');
  return dot < 0 ? base : base.substring(0, dot);
}

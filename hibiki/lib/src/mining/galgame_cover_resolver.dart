import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:hibiki/src/media/media_cover_service.dart';
import 'package:hibiki/src/media/media_extensions.dart';
import 'package:hibiki/src/mining/galgame_exe_icon.dart';
import 'package:hibiki/src/storage/app_paths.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 游戏库「自动获取封面」的解析器：给一条 [GalgameEntry] 的 exe / 工作目录，
/// 按**离线级联**挑一张封面并落盘到 `<documents>/game_covers/<id>.<ext>`。
///
/// 级联顺序（先便宜且质量高的）：
///   1. 游戏目录里已有的封面图（`cover.png` / `パッケージ.jpg` / 与游戏同名的图…），
///      按文件名启发式打分 + 真实像素尺寸校验；
///   2. exe 内嵌的最大图标（[extractLargestIconPng]，纯 Dart 解析 PE 资源）。
///
/// 两级都不中就返回 null（保持默认手柄占位图，不硬塞一张随便的图当封面）。
/// 全程 **fail-safe**：单个文件读不动 / 解码失败只跳过该候选，不中断整轮解析。
///
/// 手动「设置封面」走同一套落盘入口 [saveGameCoverFromFile]，所以自动与手动封面
/// 在磁盘上同名同目录，替换封面时不会残留两份。
///
/// 目录归属：本文件是 `MediaCoverService` 游戏岛（`game_covers/`）唯一的磁盘
/// 生产者，之所以留在 `mining/` 而不迁 `media/`，是因为游戏库域整体
/// （`galgame_*`：仓储/刮削/exe 图标解析）都住这里（见仓库地图「galgame 制卡」），
/// 且它与同目录的 [extractLargestIconPng]（galgame_exe_icon.dart）、
/// `galgame_cover_download.dart` 成对耦合——单独迁走会把游戏封面链路劈成两半。
/// 落盘统一走 [MediaCoverService.applyCoverFile] / [MediaCoverService.applyCoverBytes] 收口。

/// 一个待验证的封面候选：路径 + 文件名启发式得分（越大越像封面）。
class GameCoverCandidate {
  const GameCoverCandidate({required this.path, required this.score});

  final String path;
  final int score;

  @override
  String toString() => 'GameCoverCandidate($path, score: $score)';
}

/// 允许作为封面来源的图片扩展名（小写，含点）＝图片扩展名基集显式增删：
/// − `.gif`（动图不作封面，落盘归一化也不认它，维持既有行为）；
/// ＋ `.ico`（galgame 目录常见现成图标文件，可作候选并原样落盘）。
final Set<String> kGameCoverImageExtensions = Set<String>.unmodifiable(
  <String>{...kImageExtensionsBase, '.ico'}..remove('.gif'),
);

/// 封面像素下限：小于它的图当封面会糊成一团（多数是 UI 素材 / 小图标）。
const int kGameCoverMinPixels = 180;

/// 目录扫描上限：galgame 安装目录常有上万个素材文件，只看前这么多项，避免
/// 一次自动获取把线程钉在目录枚举上。
const int kGameCoverScanLimit = 4000;

/// 文件名启发式：命中即加分（key 已是小写；日文按原文匹配）。
const Map<String, int> _kNamePositiveScores = <String, int>{
  'cover': 100,
  'パッケージ': 100,
  'package': 90,
  'jacket': 90,
  'keyvisual': 80,
  'key_visual': 80,
  'mainvisual': 80,
  'main_visual': 80,
  'poster': 70,
  'title': 45,
  'top': 35,
  'logo': 40,
  'banner': 35,
  'folder': 35,
  'thumbnail': 30,
  'thumb': 25,
  'icon': 20,
  'game': 15,
};

/// 文件名启发式：命中即扣分（galgame 目录里最常见的「不是封面」的图）。
const Map<String, int> _kNameNegativeScores = <String, int>{
  'background': -70,
  'bgimage': -70,
  'wallpaper': -60,
  'sprite': -60,
  'chara': -60,
  'char_': -60,
  'face': -50,
  'button': -50,
  'cursor': -50,
  'save': -40,
  'load': -40,
  'config': -40,
  'menu': -30,
  'bg': -30,
};

/// 纯函数：按文件名启发式给 [filePaths] 打分，降序返回**得分为正**的候选。
///
/// 只看名字，不碰磁盘——像素尺寸校验留给 [autoResolveGameCover] 的 IO 阶段，
/// 这样打分规则本身完全可单测。同分时按路径升序稳定排序（避免目录枚举顺序抖动
/// 导致同一游戏每次自动获取选到不同的图）。
List<GameCoverCandidate> rankGameCoverCandidates({
  required List<String> filePaths,
  required String gameName,
}) {
  final String normalizedGame = _normalizeName(gameName);
  final List<GameCoverCandidate> scored = <GameCoverCandidate>[];
  for (final String path in filePaths) {
    final String extension = p.extension(path).toLowerCase();
    if (!kGameCoverImageExtensions.contains(extension)) continue;
    final String base = p.basenameWithoutExtension(path);
    final String lower = base.toLowerCase();
    int score = 0;
    for (final MapEntry<String, int> e in _kNamePositiveScores.entries) {
      if (lower.contains(e.key)) score += e.value;
    }
    for (final MapEntry<String, int> e in _kNameNegativeScores.entries) {
      if (lower.contains(e.key)) score += e.value;
    }
    // 与游戏同名的图几乎总是封面（`ATRI.png` / `sakura_moyu.jpg`）。
    final String normalizedBase = _normalizeName(base);
    if (normalizedGame.isNotEmpty && normalizedBase == normalizedGame) {
      score += 90;
    } else if (normalizedGame.isNotEmpty &&
        normalizedBase.isNotEmpty &&
        (normalizedBase.contains(normalizedGame) ||
            normalizedGame.contains(normalizedBase))) {
      score += 45;
    }
    // `.ico` 能用但通常只有 32/48px，压到正分尾部。
    if (extension == '.ico') score -= 25;
    if (score > 0) {
      scored.add(GameCoverCandidate(path: path, score: score));
    }
  }
  scored.sort((GameCoverCandidate a, GameCoverCandidate b) {
    final int byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.path.compareTo(b.path);
  });
  return scored;
}

/// 归一化名字用于比对：小写 + 去掉分隔符/空白/常见修饰。
String _normalizeName(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[\s_\-\.\(\)\[\]（）【】]'), '').trim();

/// 读 [path] 的图像宽高（只读文件头部，避免把 20MB 的图整个读进内存）。
/// 解不出返回 null。
Future<(int width, int height)?> probeImageSize(String path) async {
  RandomAccessFile? handle;
  try {
    final File file = File(path);
    if (!await file.exists()) return null;
    handle = await file.open();
    final int length = await handle.length();
    // 128KB 足够覆盖 PNG/BMP/ICO 的头，以及绝大多数 JPEG 的 SOF 段。
    final int readLength = length < 131072 ? length : 131072;
    final Uint8List head = await handle.read(readLength);
    final img.Decoder? decoder = img.findDecoderForData(head);
    if (decoder == null) return null;
    final img.DecodeInfo? info = decoder.startDecode(head);
    if (info == null || info.width <= 0 || info.height <= 0) return null;
    return (info.width, info.height);
  } catch (_) {
    return null;
  } finally {
    await handle?.close();
  }
}

/// 判定一张图的像素尺寸是否够格当封面：两边都不小于 [kGameCoverMinPixels]，
/// 且宽高比不极端（横幅 / 细长条不是封面）。纯函数。
bool isUsableCoverSize(int width, int height) {
  if (width < kGameCoverMinPixels || height < kGameCoverMinPixels) return false;
  final double ratio = width / height;
  return ratio >= 0.35 && ratio <= 2.6;
}

/// 列出 [directory] 下**直接子文件**里的图片路径（不递归：galgame 目录动辄上万素材，
/// 递归既慢又容易挖出一堆立绘）。目录不存在 / 读不动返回空列表。
Future<List<String>> listCoverCandidateFiles(String directory) async {
  try {
    final Directory dir = Directory(directory);
    if (!await dir.exists()) return const <String>[];
    final List<String> out = <String>[];
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final String extension = p.extension(entity.path).toLowerCase();
      if (!kGameCoverImageExtensions.contains(extension)) continue;
      out.add(entity.path);
      if (out.length >= kGameCoverScanLimit) break;
    }
    return out;
  } catch (_) {
    return const <String>[];
  }
}

/// exe 解析上限：超过这个体积就不为了找图标把整个文件读进内存（PE 资源段在文件
/// 尾部，无法只读头部）。绝大多数 galgame 主程序 < 32MB。
const int kGameExeIconMaxBytes = 128 * 1024 * 1024;

/// 从 [exePath] 里抽最大的内嵌图标并编码成 PNG 字节；不可用返回 null。
///
/// 整段（读盘 + PE 解析 + ICO→PNG 重编码）扔进 [Isolate.run]：exe 可能有几十 MB，
/// 图标解码也是纯 CPU，跑在 UI isolate 上会直接掉帧。
Future<Uint8List?> extractExeIconPng(String exePath) async {
  try {
    return await Isolate.run(() => _readExeIconSync(exePath));
  } catch (_) {
    return null;
  }
}

/// [extractExeIconPng] 的同步内核（在后台 isolate 里跑）。
Uint8List? _readExeIconSync(String exePath) {
  try {
    final File file = File(exePath);
    if (!file.existsSync()) return null;
    if (file.lengthSync() > kGameExeIconMaxBytes) return null;
    return extractLargestIconPng(file.readAsBytesSync(), minSize: 48);
  } catch (_) {
    return null;
  }
}

/// 自动解析结果：来源用于给用户一个准确的反馈文案。
enum GameCoverSource {
  /// 游戏目录里已有的封面图。
  directoryImage,

  /// exe 内嵌图标。
  exeIcon,
}

/// 自动解析出的封面（已落盘）。
class ResolvedGameCover {
  const ResolvedGameCover({required this.path, required this.source});

  final String path;
  final GameCoverSource source;
}

/// 为一个游戏自动解析封面并落盘，返回结果；两级来源都不中返回 null。
///
/// [gameId] 决定落盘文件名（同一游戏重复获取会覆盖，不堆垃圾）；[gameName] 参与
/// 文件名启发式；[workdir] 为空时用 exe 所在目录。
Future<ResolvedGameCover?> autoResolveGameCover({
  required String gameId,
  required String gameName,
  required String exePath,
  String? workdir,
  Directory? coverDirectory,
}) async {
  final String directory =
      (workdir != null && workdir.isNotEmpty) ? workdir : p.dirname(exePath);
  final List<String> files = await listCoverCandidateFiles(directory);
  final List<GameCoverCandidate> ranked =
      rankGameCoverCandidates(filePaths: files, gameName: gameName);
  for (final GameCoverCandidate candidate in ranked) {
    final (int, int)? size = await probeImageSize(candidate.path);
    if (size == null) continue;
    if (!isUsableCoverSize(size.$1, size.$2)) continue;
    final String? saved = await saveGameCoverFromFile(
      gameId: gameId,
      sourcePath: candidate.path,
      coverDirectory: coverDirectory,
    );
    if (saved != null) {
      return ResolvedGameCover(
        path: saved,
        source: GameCoverSource.directoryImage,
      );
    }
  }
  final Uint8List? icon = await extractExeIconPng(exePath);
  if (icon != null) {
    final String? saved = await saveGameCoverBytes(
      gameId: gameId,
      bytes: icon,
      extension: '.png',
      coverDirectory: coverDirectory,
    );
    if (saved != null) {
      return ResolvedGameCover(path: saved, source: GameCoverSource.exeIcon);
    }
  }
  return null;
}

/// 把 [sourcePath] 的图片拷成本游戏的封面，返回落盘路径；失败返回 null。
/// 手动「设置封面」与自动获取共用此入口。
///
/// 写盘走统一收口 [MediaCoverService.applyCoverFile]（原子 `.tmp`+rename +
/// 双键驱逐旧解码缓存——换封面常落同一 `<id>.<ext>` 路径，不驱逐则 UI 重建
/// 仍显示旧图）。[coverDirectory] 是测试接缝：默认落
/// [AppPaths.gameCoversDirectory]，测试传临时目录即可断言真实落盘行为，
/// 不必去 mock `path_provider` 平台通道。
Future<String?> saveGameCoverFromFile({
  required String gameId,
  required String sourcePath,
  Directory? coverDirectory,
}) async {
  try {
    final String extension = _normalizedCoverExtension(sourcePath);
    final Directory dir =
        coverDirectory ?? await AppPaths.gameCoversDirectory();
    await dir.create(recursive: true);
    await _deleteExistingCovers(dir, gameId);
    final String dest = p.join(dir.path, '$gameId$extension');
    await MediaCoverService.applyCoverFile(
      source: File(sourcePath),
      destPath: dest,
    );
    return dest;
  } catch (_) {
    return null;
  }
}

/// 把内存里的图片字节写成本游戏的封面（exe 图标 / 刮削下载路径用），返回落盘
/// 路径。写盘同样走统一收口 [MediaCoverService.applyCoverBytes]（原子落地 +
/// 双键驱逐）。
Future<String?> saveGameCoverBytes({
  required String gameId,
  required Uint8List bytes,
  required String extension,
  Directory? coverDirectory,
}) async {
  try {
    final Directory dir =
        coverDirectory ?? await AppPaths.gameCoversDirectory();
    await dir.create(recursive: true);
    await _deleteExistingCovers(dir, gameId);
    final String dest = p.join(dir.path, '$gameId$extension');
    await MediaCoverService.applyCoverBytes(bytes: bytes, destPath: dest);
    return dest;
  } catch (_) {
    return null;
  }
}

/// 删除该游戏此前的封面文件（任意扩展名）。换封面时扩展名可能从 `.png` 变成
/// `.jpg`，不清理就会在目录里堆一堆孤儿文件。
Future<void> _deleteExistingCovers(Directory dir, String gameId) async {
  try {
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      if (p.basenameWithoutExtension(entity.path) != gameId) continue;
      try {
        await entity.delete();
      } catch (_) {
        // 文件被占用：让后面的写覆盖同名文件即可，不因清理失败中断换封面。
      }
    }
  } catch (_) {
    // 目录还不存在等：交给调用方后续的 create/write。
  }
}

/// 归一化落盘扩展名：`.jpeg` 统一成 `.jpg`，未知/非图片回退 `.png`
/// （字节内容不变，只是文件名后缀；解码按内容嗅探，不看后缀）。
String _normalizedCoverExtension(String sourcePath) {
  final String raw = p.extension(sourcePath).toLowerCase();
  if (raw == '.jpeg') return '.jpg';
  return kGameCoverImageExtensions.contains(raw) ? raw : '.png';
}

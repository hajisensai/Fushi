import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/media_extensions.dart';

/// 支持「从 app 外用 Hibiki 打开」的视频扩展名（小写，不含点）。
///
/// 派生自共享真相源 [kVideoExtensions]（media_extensions.dart，导入 / 目录扫描 /
/// 刮削同表）± 显式增删——此前这里手写第三份整表并已静默漂移（`.rmvb` 能导入却
/// 不能从 app 外打开）。libmpv（media_kit 底层）能解全部这些格式；不在表内的
/// 扩展名一律拒绝，避免把任意文件（如词典 zip、EPUB）误当视频打开。
final Set<String> _supportedVideoExtensions = <String>{
  for (final String ext in kVideoExtensions) ext.substring(1),
  // 显式增：`.3gp`（手机拍摄容器）历史上只在外开白名单里。导入表暂不收录——
  // 扩大导入/扫描面不属本轮收敛；外开保留既有能力（Never break userspace）。
  '3gp',
};

/// 纯函数：判断 [path] 是否是受支持的视频文件（仅看扩展名，不碰文件系统）。
///
/// 大小写不敏感；无扩展名或扩展名不在白名单内返回 false。
bool isSupportedVideoFile(String path) {
  final String ext = p.extension(path).replaceFirst('.', '').toLowerCase();
  if (ext.isEmpty) return false;
  return _supportedVideoExtensions.contains(ext);
}

/// 纯函数：取来源命名空间路径的 basename（`/` 与 `\` 都当分隔符）；http(s)
/// URL（WebDAV href / 直链）的段是百分号编码的，先解码再返回。
///
/// 文件名解析（系列归组）、标题展示、身份派生（bookUid）都吃这一个口径——
/// 派生点唯一，编码字节才不会渗进系列名/集标题/uid（网络来源 URL 路径与
/// 本地路径在这些消费点上是同一种正常情况，不是特例分支）。解码失败（非法
/// 百分号序列）原样返回，不抛。
/// 取路径末段，**不做任何解码**。用于「来源库条目路径」。
///
/// 为什么要和 [decodedSourceBasename] 分成两个名字（而不是加个参数让调用点自己
/// 声明）：路径串本身看不出它处于哪种编码状态，靠调用点记得传对参数，等于把
/// 「有没有写对」推给每一个调用点。分成两个名字后，状态由函数名承载，选错就是
/// 语义明显不通，而不是一个静默解错的布尔。
///
/// 两种状态的真相源：
/// - **来源库条目路径已解码**：WebDAV 的 PROPFIND href 在 `webdav_ops.dart` 进入
///   [SourceFileEntry.path] 之前就 `Uri.decodeFull` 过了；SFTP/FTP 路径本就不是
///   百分号编码。所以来源库路径一律用本函数，再解一次会：① 真名里含 `%` 时
///   （`50% off.jpg`）直接抛 `ArgumentError: Invalid URL encoding`；② 真名是
///   `A%20B.jpg` 时被解成 `A B.jpg`，与查找表键对不上。
/// - **用户粘贴的 URL 仍是编码的**：那类走 [decodedSourceBasename]。
String sourceEntryBasename(String path) {
  final int sep = path.lastIndexOf(RegExp(r'[\\/]'));
  return sep >= 0 ? path.substring(sep + 1) : path;
}

/// 取路径末段，http(s) URL 会做一次百分号解码。
///
/// **只用于尚未解码的 URL**（例如用户粘贴的地址、m3u8 清单里的原始行）。
/// 来源库条目路径已经解码过了，**不得**传进来——用 [sourceEntryBasename]。
String decodedSourceBasename(String path) {
  final int sep = path.lastIndexOf(RegExp(r'[\\/]'));
  final String raw = sep >= 0 ? path.substring(sep + 1) : path;
  if (path.startsWith('http://') || path.startsWith('https://')) {
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }
  return raw;
}

/// 纯函数：归一化视频路径用于「同一物理文件」比对/派生唯一标识。
///
/// 统一分隔符（反斜杠转 `/`）、去掉冗余 `.`、`..` 段，保证 `D:/a/b.mkv` 与
/// `D:\a\b.mkv`、`D:/a/./c/../b.mkv` 归一到同一字符串。**不做大小写折叠**——
/// 与历史行为保持一致（Windows 盘符/路径大小写不一致仍视为不同，避免改动既有
/// uid 派生语义）。[externalVideoBookUid] 与 [VideoBookRepository.findByVideoPath]
/// 共用此单一真相，确保两侧归一语义完全一致（TODO-903）。
String normalizeVideoPath(String videoPath) =>
    p.normalize(videoPath).replaceAll('\\', '/');

/// 纯函数：从外部视频「绝对路径」派生稳定 bookUid：`video/ext/<sha1前12>`。
///
/// 用全路径的 sha1 前 12 位做唯一标识，保证同一文件每次打开命中同一条 VideoBook
/// （幂等复用，不会重复入库）。与导入对话框单视频的 `video/<basename>` 命名区分开
/// （前缀 `video/ext/`），避免外部打开与手动导入互相覆盖。
///
/// 路径先规范化（统一分隔符 / 去掉冗余 `.`、`..`），保证 `D:/a/b.mkv` 与
/// `D:\a\b.mkv` 派生同一 uid。
String externalVideoBookUid(String videoPath) {
  final String normalized = normalizeVideoPath(videoPath);
  final String digest =
      sha1.convert(utf8.encode(normalized)).toString().substring(0, 12);
  return 'video/ext/$digest';
}

/// 纯函数：从 Dart entrypoint 的命令行参数列表里挑出第一个受支持的视频路径。
///
/// Windows runner 经 `set_dart_entrypoint_arguments` 把 argv（去掉 binary 名）
/// 传进 `main(List<String> args)`。这里跳过以 `-` / `--` 开头的 flag（如调试器
/// 注入的参数），返回第一个看起来是视频文件的参数；没有则返回 null。
///
/// 注意：只做字符串判定，不验证文件是否真实存在（存在性检查留给调用方做 IO）。
String? firstExternalVideoArg(List<String> args) {
  for (final String arg in args) {
    if (arg.isEmpty) continue;
    if (arg.startsWith('-')) continue;
    if (isSupportedVideoFile(arg)) return arg;
  }
  return null;
}

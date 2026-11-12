// TyranoScript DOM 源的语音事件：观察脚本在引擎声明的语音缓冲区上看到一次 SE 播放
// （见 tyrano_dom_observer_script.dart 的 playbgm 挂钩）就推一条事件，这里把它解析
// 成「游戏目录里的哪个原件」，并按偏移 / 大小精确取出原始字节。
//
// 是否语音完全由引擎状态判定（`TYRANO.kag.stat.map_vo.vobuf[buf]`，与 Tyrano 自己在
// playbgm.play 里算 `is_voice` 的判据一致），这里不再看文件名 / 目录名猜。
//
// 原件位置：脚本发来的是引擎 `$.parseStorage(storage, "sound")` 的结果（通常
// `./data/sound/<storage>`），按页面 URL 解析成游戏目录里的文件路径：
//   * Electron：页面在 `.../resources/app.asar/index.html`，路径落进 app.asar →
//     读 asar 成员（`unpacked` 成员读 `app.asar.unpacked/`）；
//   * Electron 未打包（`resources/app/`）与 NW.js 散文件布局：就是普通文件；
//   * NW.js `package.nw`：目录形态同散文件；zip 形态运行时由 NW.js 解到临时目录、页面
//     URL 指向解出的目录，同样按普通文件读。zip 拼在 exe 末尾的形态本来就不识别为
//     Tyrano（见 tyrano_dom_game_detect.dart）。
// 不处理：http(s) / data / base64 存储（不是本地原件）、落在页面目录之外的路径。

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/mining/tyrano_dom/tyrano_asar.dart';
import 'package:path/path.dart' as p;
import 'package:fushi_engine/utils/misc/safe_file_name.dart';

/// 单条语音原件的大小上限（逐句语音一般几十到几百 KB）。
const int kTyranoVoiceMaxBytes = 32 * 1024 * 1024;

/// 观察脚本推来的一条语音事件。
class TyranoDomVoiceEvent {
  /// 创建语音事件。
  const TyranoDomVoiceEvent({
    required this.documentId,
    required this.lineSeq,
    required this.buffer,
    required this.storagePath,
    this.base64 = false,
    this.pageUrl = '',
  });

  /// 观察脚本实例的文档 id（页面重载 / 重注入后变化，句序号随之重来）。
  final String documentId;

  /// 句序号：这条语音属于哪一句（与 [TyranoDomFrame.lineSeq] 同一计数）。
  final int lineSeq;

  /// SE 缓冲区号（`pm.buf`）。
  final String buffer;

  /// 引擎 `$.parseStorage(storage, "sound")` 的结果。
  final String storagePath;

  /// 存储是 base64 文本（`[playse base64=...]`），不是可直接取的音频原件。
  final bool base64;

  /// 会话连接时 CDP 目标的页面 URL（Dart 侧填，不信任页面自报）。
  final String pageUrl;

  /// 换上页面 URL 的副本。
  TyranoDomVoiceEvent withPageUrl(String url) => TyranoDomVoiceEvent(
    documentId: documentId,
    lineSeq: lineSeq,
    buffer: buffer,
    storagePath: storagePath,
    base64: base64,
    pageUrl: url,
  );
}

/// 解析脚本推来的语音载荷（已 JSON 解码的 map，`k == "voice"`）；格式不对返回 null。
TyranoDomVoiceEvent? parseTyranoDomVoicePayload(Map<String, Object?> decoded) {
  if (decoded['k'] != 'voice') return null;
  final Object? doc = decoded['doc'];
  final Object? ln = decoded['ln'];
  final Object? buf = decoded['buf'];
  final Object? path = decoded['path'];
  if (doc is! String || ln is! int || ln < 0 || path is! String) return null;
  if (path.isEmpty) return null;
  return TyranoDomVoiceEvent(
    documentId: doc,
    lineSeq: ln,
    buffer: buf is String ? buf : '$buf',
    storagePath: path,
    base64: decoded['b64'] == true,
  );
}

/// 语音原件取不到的原因（诊断用）。
enum TyranoDomVoiceSkip {
  /// http(s) / data 等非本地存储。
  remote,

  /// base64 文本存储。
  base64,

  /// 页面 URL 不是 file:，或解析出的路径不在页面目录下。
  outsideGame,

  /// 归档 / 文件里没有这个成员。
  notFound,

  /// 读取失败、读不全或超过大小上限。
  unreadable,

  /// 不是 OGG（`OggS`）/ M4A（`ftyp`）原件。
  badSignature,
}

/// 原件容器格式（按文件头签名判定，不看扩展名）。
enum TyranoVoiceContainer {
  /// Ogg（Vorbis / Opus），魔数 `OggS`。
  ogg,

  /// ISO BMFF（M4A / AAC），偏移 4 处 `ftyp`。
  m4a,
}

/// 按签名判定容器；都不是返回 null。
TyranoVoiceContainer? sniffTyranoVoiceContainer(Uint8List bytes) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x4f &&
      bytes[1] == 0x67 &&
      bytes[2] == 0x67 &&
      bytes[3] == 0x53) {
    return TyranoVoiceContainer.ogg;
  }
  if (bytes.length >= 12 &&
      bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70) {
    return TyranoVoiceContainer.m4a;
  }
  return null;
}

/// 容器对应的落盘扩展名。
String tyranoVoiceExtension(TyranoVoiceContainer container) =>
    switch (container) {
      TyranoVoiceContainer.ogg => '.ogg',
      TyranoVoiceContainer.m4a => '.m4a',
    };

/// 解析出的原件位置：游戏目录里的 Windows 绝对路径（可能穿过 `.asar` 文件）。
class TyranoDomVoiceLocation {
  /// 创建位置。
  const TyranoDomVoiceLocation({required this.filePath, required this.pageDir});

  /// 原件的绝对路径（若在 asar 里，路径中间有一段是 `.asar` 文件）。
  final String filePath;

  /// 页面所在目录（原件必须在它之下）。
  final String pageDir;
}

final RegExp _schemePattern = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:');
final RegExp _drivePattern = RegExp(r'^[A-Za-z]:[\\/]');

/// 把引擎存储路径按页面 URL 解析成游戏目录里的路径（纯函数，不碰文件系统）。
/// 返回 `(location, skip)`，两者恰有一个非 null。
({TyranoDomVoiceLocation? location, TyranoDomVoiceSkip? skip})
resolveTyranoDomVoiceLocation({
  required String pageUrl,
  required String storagePath,
  bool base64 = false,
}) {
  if (base64) return (location: null, skip: TyranoDomVoiceSkip.base64);
  final Uri? page = Uri.tryParse(pageUrl);
  if (page == null || page.scheme != 'file') {
    return (location: null, skip: TyranoDomVoiceSkip.outsideGame);
  }
  final String trimmed = storagePath.trim();
  final Uri? target;
  if (_drivePattern.hasMatch(trimmed)) {
    target = Uri.file(trimmed, windows: true);
  } else if (_schemePattern.hasMatch(trimmed)) {
    final Uri? parsed = Uri.tryParse(trimmed);
    if (parsed == null || parsed.scheme != 'file') {
      return (location: null, skip: TyranoDomVoiceSkip.remote);
    }
    target = parsed;
  } else {
    // 浏览器按文档 URL 解析相对路径（含 %XX 解码、丢掉 ?query / #fragment），这里同样。
    target = Uri.tryParse(trimmed) == null ? null : page.resolve(trimmed);
  }
  if (target == null) {
    return (location: null, skip: TyranoDomVoiceSkip.outsideGame);
  }
  final String pageFile;
  final String filePath;
  try {
    pageFile = page.toFilePath(windows: true);
    final Uri bare = Uri.parse(
      target.removeFragment().toString().split('?').first,
    );
    filePath = p.windows.normalize(bare.toFilePath(windows: true));
  } on Object {
    return (location: null, skip: TyranoDomVoiceSkip.outsideGame);
  }
  final String pageDir = p.windows.dirname(pageFile);
  if (!p.windows.isWithin(
    p.windows.canonicalize(pageDir),
    p.windows.canonicalize(filePath),
  )) {
    return (location: null, skip: TyranoDomVoiceSkip.outsideGame);
  }
  return (
    location: TyranoDomVoiceLocation(filePath: filePath, pageDir: pageDir),
    skip: null,
  );
}

/// 取到的语音原件。
class TyranoDomVoiceBytes {
  /// 创建结果。
  const TyranoDomVoiceBytes({
    required this.bytes,
    required this.container,
    required this.sourcePath,
    this.asarPath,
    this.asarMember,
  });

  /// 原始字节（未转码）。
  final Uint8List bytes;

  /// 签名判定的容器。
  final TyranoVoiceContainer container;

  /// 原件路径（asar 时是穿过 asar 的虚拟路径）。
  final String sourcePath;

  /// 所在 asar 归档（不在 asar 里为 null）。
  final String? asarPath;

  /// asar 内成员相对路径（`/` 分隔）。
  final String? asarMember;
}

/// 按位置读原件并校验签名。归档头按（路径, 长度, 修改时间）缓存，一场游戏只解析一次。
class TyranoDomVoiceReader {
  final Map<String, ({int length, DateTime modified, AsarArchive archive})>
  _archives =
      <String, ({int length, DateTime modified, AsarArchive archive})>{};

  /// 读 [location] 的原件。返回 `(voice, skip)`，两者恰有一个非 null。
  Future<({TyranoDomVoiceBytes? voice, TyranoDomVoiceSkip? skip})> read(
    TyranoDomVoiceLocation location,
  ) async {
    final ({String asar, String member})? split = _splitAsar(location);
    final Uint8List? bytes;
    if (split != null) {
      final AsarArchive? archive = await _archive(split.asar);
      final AsarMember? member = archive?.member(split.member);
      if (archive == null || member == null) {
        return (voice: null, skip: TyranoDomVoiceSkip.notFound);
      }
      bytes = await archive.read(member, maxBytes: kTyranoVoiceMaxBytes);
    } else {
      final File file = File(location.filePath);
      try {
        if (!await file.exists()) {
          return (voice: null, skip: TyranoDomVoiceSkip.notFound);
        }
        bytes = await file.length() > kTyranoVoiceMaxBytes
            ? null
            : await file.readAsBytes();
      } on FileSystemException {
        return (voice: null, skip: TyranoDomVoiceSkip.unreadable);
      }
    }
    if (bytes == null) {
      return (voice: null, skip: TyranoDomVoiceSkip.unreadable);
    }
    final TyranoVoiceContainer? container = sniffTyranoVoiceContainer(bytes);
    if (container == null) {
      return (voice: null, skip: TyranoDomVoiceSkip.badSignature);
    }
    return (
      voice: TyranoDomVoiceBytes(
        bytes: bytes,
        container: container,
        sourcePath: location.filePath,
        asarPath: split?.asar,
        asarMember: split?.member,
      ),
      skip: null,
    );
  }

  /// 沿路径从根往下找第一段是 `.asar` **文件**的前缀（Electron 的 `resources/app.asar`
  /// 就是页面目录本身）。名字以 `.asar` 结尾的普通目录不算。没有返回 null（普通文件）。
  ({String asar, String member})? _splitAsar(TyranoDomVoiceLocation location) {
    final List<String> parts = p.windows.split(location.filePath);
    for (int i = 1; i < parts.length; i++) {
      if (!parts[i - 1].toLowerCase().endsWith('.asar')) continue;
      final String container = p.windows.joinAll(parts.sublist(0, i));
      if (!FileSystemEntity.isFileSync(container)) continue;
      return (asar: container, member: parts.sublist(i).join('/'));
    }
    return null;
  }

  Future<AsarArchive?> _archive(String asarPath) async {
    final FileStat stat = await File(asarPath).stat();
    final ({int length, DateTime modified, AsarArchive archive})? cached =
        _archives[asarPath];
    if (cached != null &&
        cached.length == stat.size &&
        cached.modified == stat.modified) {
      return cached.archive;
    }
    final AsarArchive? archive = await AsarArchive.open(asarPath);
    if (archive == null) return null;
    _archives[asarPath] = (
      length: stat.size,
      modified: stat.modified,
      archive: archive,
    );
    return archive;
  }
}

/// 把存储路径变成 dump 文件名里的安全片段：取 `data/sound/` 之后（没有就取最后两段），
/// `/` 换 `-`，去掉 Windows 文件名非法字符，限长，扩展名换成按签名判定的那个。
String tyranoVoiceDumpBasename(
  String sourcePath,
  TyranoVoiceContainer container,
) {
  final String normalized = sourcePath.replaceAll('\\', '/');
  final int sound = normalized.toLowerCase().lastIndexOf('/data/sound/');
  final List<String> segments =
      (sound >= 0
              ? normalized.substring(sound + '/data/sound/'.length)
              : normalized)
          .split('/')
          .where((String s) => s.isNotEmpty)
          .toList();
  final List<String> tail = sound >= 0
      ? segments
      : segments.sublist(segments.length > 2 ? segments.length - 2 : 0);
  String stem = tail.join('-');
  final int dot = stem.lastIndexOf('.');
  if (dot > 0) stem = stem.substring(0, dot);
  stem = safeWindowsFileName(stem);
  if (stem.isEmpty) stem = 'voice';
  if (stem.length > 80) stem = stem.substring(stem.length - 80);
  return '$stem${tyranoVoiceExtension(container)}';
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/disc/disc_share_manifest.dart';
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteDownloadCancelled;
import 'package:path/path.dart' as p;

/// 远端原盘（第二期）client 侧：host 签发的一次盘目录共享会话
/// （`GET /api/library/videos/<id>/disc`，见 `disc_share_routes.dart`）。
///
/// 同一份共享既给整盘下载用（[downloadRemoteDisc]），也给流式原盘菜单用
/// （[nativeDevice] 交给 libmpv 的 `bluray-device` / `dvd-device`）。
class RemoteDiscShare {
  const RemoteDiscShare({
    required this.baseUrl,
    required this.manifest,
    this.titles = const <RemoteDiscShareTitle>[],
  });

  /// 会话根，以 `/` 结尾（`https://host:port/api/library/disc/<token>/`）。
  final Uri baseUrl;
  final DiscShareManifest manifest;

  /// host 库里落在这张盘上的视频行。
  final List<RemoteDiscShareTitle> titles;

  /// 单文件 URL：路径逐段 URL 编码（盘名、文件名可能带空格 / 非 ASCII）。
  Uri fileUrl(String relativePath) => baseUrl.replace(
    path:
        '${baseUrl.path}files/'
        '${relativePath.split('/').map(Uri.encodeComponent).join('/')}',
  );

  /// 交给 libmpv 的设备串：目录盘是会话根（补丁里的 libbluray 自定义文件访问读
  /// `manifest.json` 再按清单取文件）；镜像盘是镜像文件本身的 URL（libdvdnav /
  /// libbluray 按块读）。https 原样给出，由调用方经 `nativePlaybackUri` 降给中继。
  String get nativeDevice => manifest.layout == DiscShareLayout.image
      ? fileUrl(manifest.files.single.path).toString()
      : baseUrl.toString();

  /// 严格解析签发响应；任一部分不合法返回 null。
  static RemoteDiscShare? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? rawBase = json['baseUrl'];
    final DiscShareManifest? manifest = DiscShareManifest.fromJson(
      json['manifest'],
    );
    if (rawBase is! String || manifest == null) return null;
    final Uri? base = Uri.tryParse(rawBase);
    if (base == null ||
        !(base.isScheme('http') || base.isScheme('https')) ||
        base.host.isEmpty ||
        !base.path.endsWith('/')) {
      return null;
    }
    final List<RemoteDiscShareTitle> titles = <RemoteDiscShareTitle>[];
    final Object? rawTitles = json['titles'];
    if (rawTitles is List) {
      for (final Object? raw in rawTitles) {
        if (raw is! Map) continue;
        final Object? id = raw['id'];
        final Object? path = raw['path'];
        if (id is String &&
            id.isNotEmpty &&
            path is String &&
            isSafeDiscSharePath(path)) {
          titles.add(RemoteDiscShareTitle(id: id, path: path));
        }
      }
    }
    return RemoteDiscShare(baseUrl: base, manifest: manifest, titles: titles);
  }
}

/// host 库里的一条原盘标题：[id] 是 host 的 bookUid，[path] 是成员路径相对盘根的
/// 部分（`BDMV/PLAYLIST/00800.mpls` / `VIDEO_TS/TITLE_01.dvdtitle`）。
class RemoteDiscShareTitle {
  const RemoteDiscShareTitle({required this.id, required this.path});

  final String id;
  final String path;

  /// 落地到本机盘根 [localRoot] 后这条标题的成员路径（DVD 镜像形态的盘根是 `.iso`
  /// 文件本身，title 路径照样拼在它下面，与本地导入同一形状）。
  String localMemberPath(String localRoot) =>
      p.joinAll(<String>[localRoot, ...path.split('/')]);
}

/// 对端不支持原盘共享（老 host 404 / 能力位缺失）。
class RemoteDiscShareUnsupported implements Exception {
  const RemoteDiscShareUnsupported();

  @override
  String toString() => 'RemoteDiscShareUnsupported';
}

/// 「能共享原盘」的远端视频源（互联 host）。按能力分级，同 `RemoteVideoClient`。
abstract interface class RemoteDiscShareSource {
  /// host 是否声明 `liveLibrary.discShareV1`。探不到（网络）抛错。
  Future<bool> hostSupportsDiscShare();

  /// 为盘上任一条标题 [videoId] 签发共享会话。老 host 抛
  /// [RemoteDiscShareUnsupported]；标题不是原盘 / 盘已不在抛普通错误。
  Future<RemoteDiscShare> openRemoteDiscShare(String videoId);

  /// 读共享里一个小文件的全部字节（`index.bdmv`、`AACS/Unit_Key_RO.inf`），超过
  /// [maxBytes]、不在清单里或 host 回非 200 时返回 null。
  Future<Uint8List?> readRemoteDiscFile(
    RemoteDiscShare share,
    String relativePath,
    int maxBytes,
  );

  /// 下载共享里的一个文件到 [dest]：同目录 `.part` + 验证器续传（host 文件换了就
  /// 从头下）。[cancelSignal] 完成即中止并抛 [RemoteDownloadCancelled]。
  Future<void> downloadRemoteDiscFile(
    RemoteDiscShare share,
    DiscShareFile file,
    File dest, {
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  });
}

/// 下载一个文件的原语（[RemoteDiscShareSource.downloadRemoteDiscFile] 的形状，
/// 测试可注入）。
typedef RemoteDiscFileFetch =
    Future<void> Function(
      DiscShareFile file,
      File dest, {
      void Function(int received, int? total)? onBytes,
      Future<void>? cancelSignal,
    });

/// 整盘下载落地后的本机盘根：[downloadRoot]`/<discKey 前 12 位>/<盘名>`。
///
/// 盘名保持原样（详情页的选盘、合集名都显示它）；按盘身份分一层目录，两台 host 上
/// 同名的 `Disc 1` 不会落到一起。
String remoteDiscLocalRoot(String downloadRoot, DiscShareManifest manifest) =>
    p.join(downloadRoot, manifest.discKey.substring(0, 12), manifest.name);

/// 按清单把整张盘下载到 [localRoot]（目录盘：盘根目录；镜像盘：镜像文件路径）。
///
/// 续传粒度两层：已经完整落地（大小与清单一致）的文件直接跳过；没下完的文件由
/// [fetch] 按 `.part` 字节续传。所以暂停 / 中断 / 进程被杀后再开，都从断点接着下。
/// [onBytes] 报整盘口径的 `(已收, 总量)`。取消抛 [RemoteDownloadCancelled]，已下的
/// 文件与 `.part` 都留着。
Future<void> downloadRemoteDisc({
  required DiscShareManifest manifest,
  required String localRoot,
  required RemoteDiscFileFetch fetch,
  void Function(int received, int total)? onBytes,
  Future<void>? cancelSignal,
}) async {
  bool cancelled = false;
  unawaited(
    cancelSignal?.then(
      (_) => cancelled = true,
      onError: (Object _) {
        cancelled = true;
      },
    ),
  );
  final int total = manifest.totalBytes;
  int done = 0;
  onBytes?.call(0, total);
  for (final DiscShareFile file in manifest.files) {
    if (cancelled) throw const RemoteDownloadCancelled();
    final File dest = manifest.layout == DiscShareLayout.image
        ? File(localRoot)
        : File(p.joinAll(<String>[localRoot, ...file.path.split('/')]));
    if (_isComplete(dest, file.size)) {
      done += file.size;
      onBytes?.call(done, total);
      continue;
    }
    await dest.parent.create(recursive: true);
    final int before = done;
    await fetch(
      file,
      dest,
      onBytes: (int received, int? _) =>
          onBytes?.call(before + received.clamp(0, file.size), total),
      cancelSignal: cancelSignal,
    );
    if (!_isComplete(dest, file.size)) {
      throw StateError(
        'disc file ${file.path} landed with a size other than the manifest '
        '(${file.size} bytes)',
      );
    }
    done += file.size;
    onBytes?.call(done, total);
  }
}

bool _isComplete(File file, int size) {
  try {
    return file.existsSync() && file.lengthSync() == size;
  } on FileSystemException {
    return false;
  }
}

/// 放弃一个整盘下载：删掉 [localRoot]（目录或镜像文件）及其续传残片，再删掉空了的
/// 盘身份目录。返回是否删了东西。
Future<bool> discardRemoteDiscDownload(String localRoot) async {
  bool deleted = false;
  final FileSystemEntityType type = FileSystemEntity.typeSync(localRoot);
  try {
    if (type == FileSystemEntityType.directory) {
      await Directory(localRoot).delete(recursive: true);
      deleted = true;
    } else {
      for (final String path in <String>[
        localRoot,
        '$localRoot.part',
        '$localRoot.part.etag',
      ]) {
        final File file = File(path);
        if (await file.exists()) {
          await file.delete();
          deleted = true;
        }
      }
    }
    final Directory keyDir = Directory(p.dirname(localRoot));
    if (await keyDir.exists() && await keyDir.list().isEmpty) {
      await keyDir.delete();
    }
  } on FileSystemException {
    return deleted;
  }
  return deleted;
}

/// [fileName]（host 下发的成员文件名）是不是一条原盘标题：蓝光 `.mpls` 或 DVD 的
/// 虚拟 title（`.dvdtitle`）。远端行只有文件名、没有路径，所以只能按扩展名认。
bool isRemoteDiscMemberFileName(String? fileName) {
  if (fileName == null) return false;
  final String lower = fileName.toLowerCase();
  return lower.endsWith('.mpls') || lower.endsWith('.dvdtitle');
}

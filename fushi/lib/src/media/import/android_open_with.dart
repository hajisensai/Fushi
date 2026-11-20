import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
import 'package:path/path.dart' as p;

// Android「用其他应用打开」/「分享到 Fushi」收进来的书 / 漫画（拍板台 oeJzVRQ9p1）。
//
// 原生侧 `OpenWithChannel.java` 在收到 intent 的当下把对方给的 `content://` 复制进
// `cacheDir/open_with/<uuid>/incoming`，连同原文件名、MIME 排进队列；这里取走、按
// [androidOpenWithFileName] 改成导入层认得的文件名，再交给宿主走桌面 open-with 同一条
// `LibraryCtlImporter` 入库 → 打开阅读器的路径。导入完宿主调 [AndroidOpenWithInbox.release]
// 删掉这份副本（书已复制进书库）；进程被杀留下的副本由原生侧下次启动时清掉。

/// manifest `MainActivity` 文档过滤器里登记的 MIME → 落盘扩展名。
///
/// 与 `AndroidManifest.xml` 的 VIEW / SEND 过滤器逐一对应（守卫
/// `test/media/import/android_open_with_test.dart`），扩展名都在桌面 open-with 白名单
/// `kExternalBookOpenExtensions` 里。刻意不收：
///
/// - `application/zip` / `application/octet-stream`：会把 Fushi 挂进所有压缩包、未知
///   文件的打开列表；
/// - `.mokuro`：它只是一卷漫画的入口 json，图片在旁边的目录里，`content://` 只给得了
///   这一个文件，复制过来也打不开；
/// - `.cbr` / `.cb7`（`application/vnd.comicbook-rar` / `x-cbr` / `x-cb7`）：导入要靠外部
///   7-Zip（`MangaSevenZipExtractor`），APK 里没有，登记进打开列表只会换来必然失败的入口。
///   Android 接上 RAR / 7z 解包之后再加回来。
const Map<String, String> kAndroidOpenWithBookMimeTypes = <String, String>{
  'application/epub+zip': '.epub',
  'application/pdf': '.pdf',
  'text/plain': '.txt',
  'application/vnd.comicbook+zip': '.cbz',
  'application/x-cbz': '.cbz',
};

/// 收得进来的扩展名（小写、带点）。
final Set<String> kAndroidOpenWithExtensions = kAndroidOpenWithBookMimeTypes
    .values
    .toSet();

/// 文件名主干的 UTF-8 字节上限：ext4 / f2fs 的 NAME_MAX 是 255 字节，留够余量给扩展名、
/// 书库目录名与 `X (2)` 后缀。按字节不按 UTF-16 码元算——120 个汉字就有 360 字节。
const int _kMaxStemBytes = 120;

/// provider 常见的临时 / 无意义后缀：带着它们的名字按 MIME 补扩展名（并去掉这个后缀）。
const Set<String> _kTempExtensions = <String>{
  '.tmp',
  '.temp',
  '.download',
  '.crdownload',
  '.part',
  '.bin',
  '.dat',
};

/// 看起来像真扩展名：ASCII 字母数字、1~5 位、至少一个字母。`.5巻`、`. 3`、`.1` 这类
/// 文件名里本来就有的点不算扩展名。
final RegExp _realExtension = RegExp(r'^\.(?=[0-9]*[a-z])[a-z0-9]{1,5}$');

/// 纯函数：给收进来的文件起一个导入层认得的名字；认不出是书 / 漫画时返回 null。
///
/// - 原文件名（[displayName]）带可收的扩展名：原样用（只去掉路径分隔符与控制字符）——
///   txt / cbz 的书名来自文件名，不能丢；
/// - 原名没有扩展名或只带临时后缀（QQ 等 provider 常这样给）：按 [mimeType] 补扩展名，
///   原名为空就叫 `document`；
/// - 原名带着别的真扩展名（`notes.json`、`a.srt`、`x.md`，很多 provider 把它们标成
///   `text/plain`）：拒收，与桌面白名单只收 `.txt` 一致，不把它们改名当书导入；
/// - 两样都认不出：返回 null，宿主提示打不开。
String? androidOpenWithFileName({String? displayName, String? mimeType}) {
  String? name = _sanitizeDisplayName(displayName);
  if (name != null) {
    final String ext = p.extension(name);
    final String lower = ext.toLowerCase();
    if (kAndroidOpenWithExtensions.contains(lower)) {
      return '${_clip(p.basenameWithoutExtension(name))}$ext';
    }
    if (_kTempExtensions.contains(lower)) {
      name = p.basenameWithoutExtension(name);
    } else if (_realExtension.hasMatch(lower)) {
      return null;
    }
  }
  final String? mime = mimeType?.split(';').first.trim().toLowerCase();
  final String? ext = mime == null ? null : kAndroidOpenWithBookMimeTypes[mime];
  if (ext == null) return null;
  return '${_clip(name ?? 'document')}$ext';
}

String? _sanitizeDisplayName(String? raw) {
  if (raw == null) return null;
  // provider 可能给出带目录的「名字」：只取最后一段，且不允许它把文件写出副本目录。
  final String last = raw.split(RegExp(r'[/\\]')).last;
  // 字符集走唯一真相源（BUG-1125：手抄字符集漏过反斜杠）；DEL 不在 Windows 黑名单里，另删。
  final String cleaned = last
      .replaceAll(windowsUnsafeFileNameChars, '')
      .replaceAll('\x7f', '')
      .trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return null;
  return cleaned;
}

/// 按 UTF-8 字节截到 [_kMaxStemBytes]，按码点切，不切断代理对。
String _clip(String stem) {
  final String s = stem.trim().isEmpty ? 'document' : stem;
  final StringBuffer out = StringBuffer();
  int bytes = 0;
  for (final int rune in s.runes) {
    final int size = rune < 0x80
        ? 1
        : rune < 0x800
        ? 2
        : rune < 0x10000
        ? 3
        : 4;
    if (bytes + size > _kMaxStemBytes) break;
    bytes += size;
    out.writeCharCode(rune);
  }
  return out.toString();
}

/// 原生排进队列的一份副本。
@immutable
class AndroidOpenWithCopy {
  const AndroidOpenWithCopy({
    required this.path,
    required this.displayName,
    required this.mimeType,
  });

  /// 原生 channel 的一条记录；缺 `path` 的丢掉。
  static AndroidOpenWithCopy? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final Object? path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    final Object? name = raw['displayName'];
    final Object? mime = raw['mimeType'];
    return AndroidOpenWithCopy(
      path: path,
      displayName: name is String ? name : null,
      mimeType: mime is String ? mime : null,
    );
  }

  final String path;
  final String? displayName;
  final String? mimeType;
}

/// 从原生队列取副本、改名、交宿主；宿主导入完调 [release] 删副本。
class AndroidOpenWithInbox {
  AndroidOpenWithInbox({MethodChannel? channel})
    : _channel = channel ?? FushiChannels.openWith;

  static const String _methodTake = 'takeIncomingDocuments';
  static const String _methodAvailable = 'incomingDocumentsAvailable';

  final MethodChannel _channel;

  /// 本收件箱交出去、还没 [release] 的书路径。
  final Set<String> _handedOut = <String>{};

  Future<void> Function(String bookPath)? _onBook;
  void Function(String? displayName)? _onRejected;
  Future<void>? _draining;
  bool _drainAgain = false;

  /// 挂上原生「有新文件」通知，并立刻取一次（冷启动时 intent 早于 Dart 就绪）。
  ///
  /// [onBook] 收到改好名的书路径；[onRejected] 收到认不出是书的原文件名。
  Future<void> start({
    required Future<void> Function(String bookPath) onBook,
    required void Function(String? displayName) onRejected,
  }) {
    _onBook = onBook;
    _onRejected = onRejected;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == _methodAvailable) await drain();
      return null;
    });
    return drain();
  }

  void stop() {
    _channel.setMethodCallHandler(null);
    _onBook = null;
    _onRejected = null;
  }

  /// 取走原生队列里的全部副本并逐个交出。并发调用合并成一轮之后再补一轮，
  /// 不会两次取到同一份（原生 take 即清空）也不会漏掉排队中途到的。
  Future<void> drain() {
    final Future<void>? running = _draining;
    if (running != null) {
      _drainAgain = true;
      return running;
    }
    final Future<void> run = _drainLoop().whenComplete(() => _draining = null);
    _draining = run;
    return run;
  }

  Future<void> _drainLoop() async {
    do {
      _drainAgain = false;
      final List<Object?> raw;
      try {
        raw =
            await _channel.invokeListMethod<Object?>(_methodTake) ??
            <Object?>[];
      } on MissingPluginException {
        return;
      } on PlatformException catch (e) {
        debugPrint('[Fushi] open-with take failed: $e');
        return;
      }
      // 这一批已从原生队列取走并清空：任何一本出错都不能让同批其余几本被静默丢掉。
      for (final Object? entry in raw) {
        final AndroidOpenWithCopy? copy = AndroidOpenWithCopy.fromMap(entry);
        if (copy == null) continue;
        try {
          await _deliver(copy);
        } catch (e, st) {
          debugPrint('[Fushi] open-with deliver failed: $e\n$st');
          await _deleteCopyDir(copy.path);
          _onRejected?.call(copy.displayName);
        }
      }
    } while (_drainAgain);
  }

  Future<void> _deliver(AndroidOpenWithCopy copy) async {
    final String? name = androidOpenWithFileName(
      displayName: copy.displayName,
      mimeType: copy.mimeType,
    );
    final File source = File(copy.path);
    if (name == null || !source.existsSync()) {
      await _deleteCopyDir(copy.path);
      _onRejected?.call(copy.displayName);
      return;
    }
    final String target = p.join(p.dirname(copy.path), name);
    final String bookPath;
    try {
      bookPath = target == copy.path
          ? copy.path
          : (await source.rename(target)).path;
    } on FileSystemException catch (e) {
      debugPrint('[Fushi] open-with rename failed: $e');
      await _deleteCopyDir(copy.path);
      _onRejected?.call(copy.displayName);
      return;
    }
    _handedOut.add(bookPath);
    final Future<void> Function(String bookPath)? onBook = _onBook;
    if (onBook == null) {
      await release(bookPath);
      return;
    }
    try {
      await onBook(bookPath);
    } catch (e, st) {
      // 导入 / 打开失败：宿主可能没走到它的 release，这里兜底删副本并提示。
      debugPrint('[Fushi] open-with import failed: $e\n$st');
      await release(bookPath);
      _onRejected?.call(copy.displayName);
    }
  }

  /// [bookPath] 是本收件箱交出的副本就删掉它所在的副本目录；别的路径（桌面 argv、
  /// 用户原文件）一律不动。
  Future<void> release(String bookPath) async {
    if (!_handedOut.remove(bookPath)) return;
    await _deleteCopyDir(bookPath);
  }

  Future<void> _deleteCopyDir(String copyPath) async {
    try {
      await Directory(p.dirname(copyPath)).delete(recursive: true);
    } on FileSystemException {
      // 已经不在了 / 被占用：原生侧下次启动整目录清理。
    }
  }
}

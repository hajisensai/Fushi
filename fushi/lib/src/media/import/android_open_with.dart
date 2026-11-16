import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
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
///   这一个文件，复制过来也打不开。
const Map<String, String> kAndroidOpenWithBookMimeTypes = <String, String>{
  'application/epub+zip': '.epub',
  'application/pdf': '.pdf',
  'text/plain': '.txt',
  'application/vnd.comicbook+zip': '.cbz',
  'application/x-cbz': '.cbz',
  'application/vnd.comicbook-rar': '.cbr',
  'application/x-cbr': '.cbr',
  'application/x-cb7': '.cb7',
};

/// 收得进来的扩展名（小写、带点）。
final Set<String> kAndroidOpenWithExtensions = kAndroidOpenWithBookMimeTypes
    .values
    .toSet();

/// 文件名主干的长度上限：留够余量给书库目录名与 `X (2)` 后缀。
const int _kMaxStemLength = 120;

/// 纯函数：给收进来的文件起一个导入层认得的名字；认不出是书 / 漫画时返回 null。
///
/// - 原文件名（[displayName]）带可收的扩展名：原样用（只去掉路径分隔符与控制字符）——
///   txt / cbz 的书名来自文件名，不能丢；
/// - 否则按 [mimeType] 补扩展名（QQ 等 provider 常给不带扩展名或带临时后缀的名字），
///   原名为空就叫 `document`；
/// - 两样都认不出：返回 null，宿主提示打不开。
String? androidOpenWithFileName({String? displayName, String? mimeType}) {
  final String? name = _sanitizeDisplayName(displayName);
  if (name != null &&
      kAndroidOpenWithExtensions.contains(p.extension(name).toLowerCase())) {
    final String ext = p.extension(name);
    return '${_clip(p.basenameWithoutExtension(name))}$ext';
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
  final String cleaned = last
      .replaceAll(RegExp(r'[\x00-\x1f\x7f:*?"<>|]'), '')
      .trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return null;
  return cleaned;
}

String _clip(String stem) {
  final String s = stem.isEmpty ? 'document' : stem;
  return s.length <= _kMaxStemLength ? s : s.substring(0, _kMaxStemLength);
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
      for (final Object? entry in raw) {
        final AndroidOpenWithCopy? copy = AndroidOpenWithCopy.fromMap(entry);
        if (copy == null) continue;
        await _deliver(copy);
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
    await onBook(bookPath);
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

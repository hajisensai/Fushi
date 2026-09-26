import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

/// 在线直读页缓存的根目录名（在 app 临时目录下）。
///
/// 刻意**不**放进章下载目录 `chapters/<digest>/`：那里的「已下载」判据
/// （`isChapterDownloaded`）只认下载服务写完的完整章，直读的零散页混进去会让判据
/// 与下载 worker 的续跑逻辑互相踩。
const String kMangaStreamCacheDirName = 'manga_stream_cache';

/// 同时在飞的取页请求上限（前台 + 预取共用）。
const int kOnlineMangaPageConcurrency = 3;

/// 每次取页时顺带预取前后各几页。
const int kOnlineMangaPrefetchRadius = 2;

/// 单页字节上限，与旧在线会话 / 下载服务的 100 MiB 口径一致。
const int kOnlineMangaMaximumPageBytes = 100 * 1024 * 1024;

/// 取第 [index] 页（0-based）的原始字节。Mihon 必须经扩展自己的客户端，所以这里
/// 只接一个闭包，由调用方绑到 `OnlineMangaRuntimeAdapter.fetchChapterPage`。
typedef OnlineMangaPageFetcher = Future<Uint8List> Function(int index);

/// 某页第一次解出真实尺寸时的回调（阅读器据此修正占位几何）。
typedef OnlineMangaPageMeasured = void Function(
  int index,
  int width,
  int height,
);

/// 在线直读的页会话（2026-09-26 用户撤回「必须先下载再读」，设计稿 §1 补记）。
///
/// - 懒取：只在阅读器要某页时才取，同页并发请求合并成一次（[_pending]）。
/// - 限流：最多 [maxConcurrentRequests] 个请求在飞；前台请求插队到预取前面。
/// - 预取：每次 [page] 顺带预取前后 [prefetchRadius] 页，失败静默（前台再取会重试）。
/// - 缓存：字节落到 [directory]（app 临时目录下的会话私有目录），[localFile] 因而能
///   给卡图 / 存页一个真实文件；[close] 删整个目录，上次崩溃留下的残目录在下一次
///   [open] 时清掉。
class OnlineMangaReaderSession implements MangaReaderSession {
  OnlineMangaReaderSession._({
    required this.directory,
    required List<String> pageIdentities,
    required OnlineMangaPageFetcher fetchPage,
    required this.maxConcurrentRequests,
    required this.prefetchRadius,
    this.onPageMeasured,
  })  : _pageIdentities = List<String>.unmodifiable(pageIdentities),
        _fetchPage = fetchPage,
        _permits = _PagePermitPool(
          maxConcurrentRequests < 1 ? 1 : maxConcurrentRequests,
        );

  /// 开一个会话：目录 = `<cacheRoot>/<sha(bookKey)>/<sha(chapterKey)>`。
  ///
  /// [pageIdentities] 每页一条稳定身份（面板检测 / OCR 缓存键），长度即页数。
  /// 打开前先清掉 [cacheRoot] 下所有不属于活会话的残目录。
  static Future<OnlineMangaReaderSession> open({
    required Directory cacheRoot,
    required String bookKey,
    required String chapterKey,
    required List<String> pageIdentities,
    required OnlineMangaPageFetcher fetchPage,
    int maxConcurrentRequests = kOnlineMangaPageConcurrency,
    int prefetchRadius = kOnlineMangaPrefetchRadius,
    OnlineMangaPageMeasured? onPageMeasured,
  }) async {
    final Directory directory = Directory(
      p.join(
        cacheRoot.path,
        _digest(bookKey),
        '${_digest(chapterKey)}-${_sessionSequence++}',
      ),
    );
    _activeDirectories.add(p.canonicalize(directory.path));
    try {
      await pruneStaleStreamCaches(cacheRoot);
      await directory.create(recursive: true);
    } on Object {
      _activeDirectories.remove(p.canonicalize(directory.path));
      rethrow;
    }
    return OnlineMangaReaderSession._(
      directory: directory,
      pageIdentities: pageIdentities,
      fetchPage: fetchPage,
      maxConcurrentRequests: maxConcurrentRequests,
      prefetchRadius: prefetchRadius,
      onPageMeasured: onPageMeasured,
    );
  }

  /// 删掉 [cacheRoot] 下所有不属于活会话的目录（上次崩溃 / 被杀的残留）。
  static Future<void> pruneStaleStreamCaches(Directory cacheRoot) async {
    if (!await cacheRoot.exists()) return;
    await for (final FileSystemEntity book in cacheRoot.list()) {
      if (book is! Directory) {
        await _deleteQuietly(book);
        continue;
      }
      bool keepBook = false;
      await for (final FileSystemEntity chapter in book.list()) {
        if (chapter is Directory &&
            _activeDirectories.contains(p.canonicalize(chapter.path))) {
          keepBook = true;
          continue;
        }
        await _deleteQuietly(chapter);
      }
      if (!keepBook) await _deleteQuietly(book);
    }
  }

  static final Set<String> _activeDirectories = <String>{};
  static int _sessionSequence = 0;

  /// 本会话的页缓存目录。
  final Directory directory;
  final int maxConcurrentRequests;
  final int prefetchRadius;
  final OnlineMangaPageMeasured? onPageMeasured;

  final List<String> _pageIdentities;
  final OnlineMangaPageFetcher _fetchPage;
  final _PagePermitPool _permits;
  final Map<int, Future<File>> _pending = <int, Future<File>>{};
  final Map<int, File> _cached = <int, File>{};
  final Map<int, ({int width, int height})> _dimensions =
      <int, ({int width, int height})>{};
  final Map<int, Future<({int width, int height})?>> _measuring =
      <int, Future<({int width, int height})?>>{};
  bool _closed = false;

  bool get isClosed => _closed;

  @override
  int get pageCount => _pageIdentities.length;

  @override
  Future<MangaPageBytes> page(int index) async {
    _validateIndex(index);
    final Future<File> fileFuture = _ensureFile(index, priority: true);
    _prefetchAround(index);
    final File file = await fileFuture;
    final Uint8List bytes = await file.readAsBytes();
    final ({int width, int height})? size = await _measure(index, bytes);
    return MangaPageBytes(
      bytes: bytes,
      contentType: mangaImageContentType(bytes),
      width: size?.width,
      height: size?.height,
    );
  }

  /// 解一次尺寸（同页并发只解一次、回调只报一次）；解不出来返回 null，下次再试。
  Future<({int width, int height})?> _measure(int index, Uint8List bytes) {
    final ({int width, int height})? known = _dimensions[index];
    if (known != null) {
      return Future<({int width, int height})?>.value(known);
    }
    return _measuring.putIfAbsent(index, () async {
      try {
        final ({int width, int height})? size =
            await mangaImageDimensions(bytes);
        if (size != null && !_closed) {
          _dimensions[index] = size;
          onPageMeasured?.call(index, size.width, size.height);
        }
        return size;
      } finally {
        _measuring.remove(index);
      }
    });
  }

  @override
  Future<File?> localFile(int index) async {
    _validateIndex(index);
    return _ensureFile(index, priority: true);
  }

  /// 已经落盘的第 [index] 页（同步；没取过 / 越界 → null）。卡图路径这类同步读者用。
  String? cachedFilePath(int index) => _cached[index]?.path;

  @override
  String cacheIdentity(int index) {
    if (index < 0 || index >= _pageIdentities.length) {
      throw RangeError.index(index, _pageIdentities, 'index');
    }
    return _pageIdentities[index];
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _permits.cancelWaiters();
    _activeDirectories.remove(p.canonicalize(directory.path));
    // 在飞的请求没法从适配器侧取消：结果回来时看到 _closed 就丢弃不写盘。删目录
    // 失败（Windows 上有句柄正在写）不要紧，下一次 open 的 prune 会收尾。
    await _deleteQuietly(directory);
  }

  Future<File> _ensureFile(int index, {required bool priority}) {
    _throwIfClosed();
    final File? cached = _cached[index];
    if (cached != null) return Future<File>.value(cached);
    final Future<File>? pending = _pending[index];
    if (pending != null) {
      if (priority) _permits.promote(index);
      return pending;
    }
    final Future<File> future = _download(index, priority: priority);
    _pending[index] = future;
    return future;
  }

  Future<File> _download(int index, {required bool priority}) async {
    try {
      await _permits.acquire(index, priority: priority);
      return await _fetchToDisk(index);
    } finally {
      // 成功失败都在 future 完成前摘掉：失败的页下一次请求会重新取。
      _pending.remove(index);
    }
  }

  Future<File> _fetchToDisk(int index) async {
    try {
      _throwIfClosed();
      final Uint8List bytes = await _fetchPage(index);
      _throwIfClosed();
      if (bytes.isEmpty) {
        throw const MihonRuntimeException(
          'PAGE_EMPTY',
          'The online manga page is empty',
        );
      }
      if (bytes.length > kOnlineMangaMaximumPageBytes) {
        throw const MihonRuntimeException(
          'PAGE_TOO_LARGE',
          'The online manga page is too large',
        );
      }
      final File target = File(
        p.join(directory.path, onlineMangaStreamPageFileName(index, bytes)),
      );
      final File staged = File('${target.path}.part');
      await staged.writeAsBytes(bytes, flush: true);
      if (_closed) {
        await _deleteQuietly(staged);
        _throwIfClosed();
      }
      await staged.rename(target.path);
      _cached[index] = target;
      return target;
    } finally {
      _permits.release();
    }
  }

  void _prefetchAround(int index) {
    for (int distance = 1; distance <= prefetchRadius; distance++) {
      for (final int candidate in <int>[index + distance, index - distance]) {
        if (candidate < 0 || candidate >= pageCount) continue;
        if (_cached.containsKey(candidate) || _pending.containsKey(candidate)) {
          continue;
        }
        unawaited(
          _ensureFile(candidate, priority: false).then<void>(
            (_) {},
            // 预取失败静默：前台真要这一页时会重新取。
            onError: (Object _) {},
          ),
        );
      }
    }
  }

  void _validateIndex(int index) {
    _throwIfClosed();
    if (index < 0 || index >= _pageIdentities.length) {
      throw RangeError.index(index, _pageIdentities, 'index');
    }
  }

  void _throwIfClosed() {
    if (_closed) {
      throw const MihonRuntimeException(
        'SESSION_CLOSED',
        'The online manga reader session is closed',
      );
    }
  }

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString().substring(0, 24);

  static Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } on FileSystemException {
      // 句柄占用等：留给下一次 prune。
    }
  }
}

/// 直读缓存里第 [index] 页的文件名：与下载服务同一个 `page-NNNNNN` 词干，扩展名按
/// 字节嗅探（嗅不出来用 `.img`，阅读器不靠扩展名判类型）。
String onlineMangaStreamPageFileName(int index, Uint8List bytes) {
  final String stem = 'page-${(index + 1).toString().padLeft(6, '0')}';
  final String extension = switch (mangaImageContentType(bytes)) {
    'image/png' => '.png',
    'image/jpeg' => '.jpg',
    'image/gif' => '.gif',
    'image/webp' => '.webp',
    _ => '.img',
  };
  return '$stem$extension';
}

/// 带插队的计数信号量：前台请求排在预取前面，已排队的预取被前台要到时可提升。
class _PagePermitPool {
  _PagePermitPool(this._capacity);

  final int _capacity;
  int _inUse = 0;
  final ListQueue<_PermitWaiter> _waiters = ListQueue<_PermitWaiter>();

  Future<void> acquire(int index, {required bool priority}) {
    if (_inUse < _capacity && _waiters.isEmpty) {
      _inUse++;
      return Future<void>.value();
    }
    final _PermitWaiter waiter = _PermitWaiter(index);
    if (priority) {
      _waiters.addFirst(waiter);
    } else {
      _waiters.addLast(waiter);
    }
    return waiter.completer.future;
  }

  /// 已在排队的第 [index] 页被前台要了：挪到队首。
  void promote(int index) {
    _PermitWaiter? found;
    for (final _PermitWaiter waiter in _waiters) {
      if (waiter.index == index) {
        found = waiter;
        break;
      }
    }
    if (found == null) return;
    _waiters.remove(found);
    _waiters.addFirst(found);
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().completer.complete();
      return;
    }
    if (_inUse > 0) _inUse--;
  }

  void cancelWaiters() {
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completer.completeError(
            const MihonRuntimeException(
              'SESSION_CLOSED',
              'The online manga reader session is closed',
            ),
          );
    }
  }
}

class _PermitWaiter {
  _PermitWaiter(this.index);

  final int index;
  final Completer<void> completer = Completer<void>();
}

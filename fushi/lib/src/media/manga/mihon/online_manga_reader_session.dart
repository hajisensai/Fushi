import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
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

/// 每次取页时顺带往阅读方向（页号增大）预取几页。
///
/// 顺序阅读几乎只往前翻，预取额度集中在前面（chimahon / Mihon 的 HttpPageLoader
/// 也只往后预取）；很多源的扩展自带限流，往回多取的页会占掉限流额度。
const int kOnlineMangaPrefetchAhead = 4;

/// 每次取页时顺带往回预取几页（回翻一页不白屏即可）。
const int kOnlineMangaPrefetchBehind = 1;

/// 单页字节上限，与旧在线会话 / 下载服务的 100 MiB 口径一致。
const int kOnlineMangaMaximumPageBytes = 100 * 1024 * 1024;

/// 取第 [index] 页（0-based）的原始字节。Mihon 必须经扩展自己的客户端，所以这里
/// 只接一个闭包，由调用方绑到 `OnlineMangaRuntimeAdapter.fetchChapterPage`。
typedef OnlineMangaPageFetcher = Future<Uint8List> Function(int index);

/// 取消这些页（0-based）在运行时侧仍在飞的请求。只是尽力而为：取消不了的请求
/// 回来时会话按已关闭 / 已丢弃处理，不写盘。
typedef OnlineMangaPageCanceller = Future<void> Function(Iterable<int> indices);

/// 某页第一次解出真实尺寸时的回调（阅读器据此修正占位几何）。
typedef OnlineMangaPageMeasured =
    void Function(int index, int width, int height);

/// 在线直读的页会话（2026-09-26 用户撤回「必须先下载再读」，设计稿 §1 补记）。
///
/// - 懒取：只在阅读器要某页时才取，同页并发请求合并成一次（[_pending]）。
/// - 限流：最多 [maxConcurrentRequests] 个请求在飞；前台请求插队到预取前面。
/// - 预取：每次 [page] 顺带往前预取 [prefetchAhead] 页、往回 [prefetchBehind] 页，失败
///   静默（前台再取会重试）。读者跳走后，还在排队、落在新页预取窗口外的旧预取直接丢弃：很多源的扩展自带限流
///   拦截器，过期预取会占掉限流额度与取图通道，让真正要看的页排在它们后面。
/// - 取消：[close] 时把还在飞的请求经 [cancelPages] 交给运行时取消（Android 原生
///   取图线程有限，快速换章时旧章请求不该继续占着）。
/// - 缓存：字节落到 [directory]（app 临时目录下的会话私有目录），[localFile] 因而能
///   给卡图 / 存页一个真实文件；[close] 删整个目录，上次崩溃留下的残目录在下一次
///   [open] 时清掉。
class OnlineMangaReaderSession implements MangaReaderSession {
  OnlineMangaReaderSession._({
    required this.directory,
    required List<String> pageIdentities,
    required OnlineMangaPageFetcher fetchPage,
    required this.maxConcurrentRequests,
    required this.prefetchAhead,
    required this.prefetchBehind,
    this.onPageMeasured,
    this.cancelPages,
  }) : _pageIdentities = List<String>.unmodifiable(pageIdentities),
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
    int prefetchAhead = kOnlineMangaPrefetchAhead,
    int prefetchBehind = kOnlineMangaPrefetchBehind,
    OnlineMangaPageMeasured? onPageMeasured,
    OnlineMangaPageCanceller? cancelPages,
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
      prefetchAhead: prefetchAhead,
      prefetchBehind: prefetchBehind,
      onPageMeasured: onPageMeasured,
      cancelPages: cancelPages,
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
  final int prefetchAhead;
  final int prefetchBehind;
  final OnlineMangaPageMeasured? onPageMeasured;
  final OnlineMangaPageCanceller? cancelPages;

  final List<String> _pageIdentities;
  final OnlineMangaPageFetcher _fetchPage;
  final _PagePermitPool _permits;
  final Map<int, Future<File>> _pending = <int, Future<File>>{};
  final Map<int, File> _cached = <int, File>{};
  final Set<int> _fetching = <int>{};
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
    _dropStalePrefetches(index);
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
        final ({int width, int height})? size = await mangaImageDimensions(
          bytes,
        );
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

  /// 等到当前所有排队 / 在飞的取页（含 [page] 顺带发起的 fire-and-forget 预取）
  /// 都落定——成功落盘或失败摘掉。预取没有别的完成信号，测试据此断言，而不是
  /// 睡一段墙钟时间赌它跑完（BUG-2802：CI 高负载下 80ms 不够，预取只起了一半）。
  @visibleForTesting
  Future<void> debugWaitForIdle() async {
    while (_pending.isNotEmpty) {
      await Future.wait<void>(<Future<void>>[
        for (final Future<File> pending in _pending.values.toList())
          pending.then<void>((_) {}, onError: (Object _) {}),
      ]);
    }
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
    // 在飞的请求交给运行时取消；取消不掉的结果回来时看到 _closed 就丢弃不写盘。
    final List<int> fetching = _fetching.toList(growable: false);
    final OnlineMangaPageCanceller? cancel = cancelPages;
    if (cancel != null && fetching.isNotEmpty) {
      try {
        await cancel(fetching);
      } on Object {
        // 取消只是释放资源；失败不影响关闭。
      }
    }
    // 删目录失败（Windows 上有句柄正在写）不要紧，下一次 open 的 prune 会收尾。
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
    _fetching.add(index);
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
      _fetching.remove(index);
      _permits.release();
    }
  }

  /// 丢掉还在排队、落在 [index] 预取窗口外的预取（前台请求不动）。
  void _dropStalePrefetches(int index) {
    _permits.dropQueuedPrefetches(
      (int queued) =>
          queued > index + prefetchAhead || queued < index - prefetchBehind,
    );
  }

  void _prefetchAround(int index) {
    // 近的先排：+1、-1、+2、+3……
    final int reach = prefetchAhead > prefetchBehind
        ? prefetchAhead
        : prefetchBehind;
    for (int distance = 1; distance <= reach; distance++) {
      for (final int candidate in <int>[
        if (distance <= prefetchAhead) index + distance,
        if (distance <= prefetchBehind) index - distance,
      ]) {
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
    final _PermitWaiter waiter = _PermitWaiter(index, priority: priority);
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
    found.priority = true;
    _waiters.addFirst(found);
  }

  /// 摘掉 [isStale] 为真的排队预取，以 `PREFETCH_STALE` 失败结束它们。
  void dropQueuedPrefetches(bool Function(int index) isStale) {
    final List<_PermitWaiter> stale = <_PermitWaiter>[
      for (final _PermitWaiter waiter in _waiters)
        if (!waiter.priority && isStale(waiter.index)) waiter,
    ];
    for (final _PermitWaiter waiter in stale) {
      _waiters.remove(waiter);
      waiter.completer.completeError(
        const MihonRuntimeException(
          'PREFETCH_STALE',
          'The prefetched page is no longer near the reading position',
        ),
      );
    }
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
  _PermitWaiter(this.index, {required this.priority});

  final int index;
  bool priority;
  final Completer<void> completer = Completer<void>();
}

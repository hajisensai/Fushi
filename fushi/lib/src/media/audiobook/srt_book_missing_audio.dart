import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/media/import/srt_book_attach_epub.dart'
    show srtBookCanAttachEpub;
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

/// 反馈 IHgBrvHizT：书架上「音频文件丢失」的字幕书卡怎么收场。
///
/// 以前断链只有一条出路「重新定位文件」，错误态副行恒显示、关不掉。现在多两条，
/// 都**可撤销**、都保留原音频路径：
///
/// - **不再提示**（[dismiss] / [undismiss]）：只隐藏警告，音频路径一字不动。
///   记住的是「对哪一组路径」关的提示——偏好值就是那组路径的 JSON。路径一变
///   （重新定位、重新导入）旧的关闭自然失效，新的断链会重新提示，不需要任何
///   清理时机。
/// - **转成纯字幕书**（[convertToSubtitleOnly] / [restoreAudio]）：清空行上的
///   `audio_paths_json`，书按普通字幕书出卡、打开不再起有声书会话；原路径先存进
///   本机偏好，菜单里「恢复音频」原样写回。
///
/// 两个偏好键都只属于这台设备（值是本机文件路径 / 「dismissed」词元），
/// `PortableSettingsPolicy` 按词元 `paths` / `dismissed` 判为不可移植，不会跟设置同步走。
///
/// 只对 files 模式（`audioPaths`）生效，与断链判定同一口径；目录模式不在范围内。
class SrtBookMissingAudio {
  SrtBookMissingAudio({
    required PrefStore prefs,
    required SrtBookRepository repository,
    bool Function(String path)? exists,
  }) : _prefs = prefs,
       _repository = repository,
       _exists = exists;

  final PrefStore _prefs;
  final SrtBookRepository _repository;
  final bool Function(String path)? _exists;

  /// 「对这组路径不再提示」的偏好键；值 = 关闭时那组路径的 JSON。
  static String dismissedPrefKey(String uid) =>
      'srt_book_audio_missing_dismissed_$uid';

  /// 转成纯字幕书时暂存的原音频路径；值 = 路径 JSON，空串 = 没有暂存。
  static String detachedPathsPrefKey(String uid) =>
      'srt_book_detached_audio_paths_$uid';

  /// 行上登记的文件列表里是否有任一断链（不看是否关过提示）。
  bool hasMissingAudio(SrtBook book) {
    final List<String>? paths = book.audioPaths;
    if (paths == null || paths.isEmpty) return false;
    return AudiobookStorage.hasMissingPaths(paths, exists: _exists);
  }

  /// 用户是否对**当前这组**路径关过提示。
  bool isDismissed(SrtBook book) {
    final List<String>? paths = book.audioPaths;
    if (paths == null || paths.isEmpty) return false;
    final Object? stored = _prefs.getPref(dismissedPrefKey(book.uid));
    return stored is String && stored.isNotEmpty && stored == jsonEncode(paths);
  }

  /// 书架卡要不要画「音频文件丢失」错误态。
  ///
  /// [hasMissing] 是调用方已经算好的断链结论（书架卡传
  /// [probeMissingUids] 的缓存结果，不在 build 里同步探盘）；不传时现探。
  bool showsWarning(SrtBook book, {bool? hasMissing}) =>
      (hasMissing ?? hasMissingAudio(book)) && !isDismissed(book);

  /// 一批字幕书里音频断链的 uid 集合（gap-novelmisc-2）。
  ///
  /// 书架以前在每张卡的 build 里对整组路径同步 `existsSync`，一次刷新里同一批路径
  /// 被探好几轮、而且全在 UI isolate 上。这里随 `srtBooksProvider` 出新列表时
  /// 异步探一次（`File.exists` 走 IO 线程），结果按 uid 缓存给卡片读；每本书遇到
  /// 第一个断链文件就停。只看 files 模式（`audioPaths`），与 [hasMissingAudio] 同口径。
  static Future<Set<String>> probeMissingUids(
    Iterable<SrtBook> books, {
    Future<bool> Function(String path)? exists,
  }) async {
    final Future<bool> Function(String) probe =
        exists ?? (String path) => File(path).exists();
    Future<String?> missingUid(SrtBook book) async {
      final List<String>? paths = book.audioPaths;
      if (paths == null || paths.isEmpty) return null;
      for (final String path in paths) {
        if (!await probe(path)) return book.uid;
      }
      return null;
    }

    final List<String?> uids = await Future.wait(books.map(missingUid));
    return <String>{...uids.whereType<String>()};
  }

  /// 「转成纯字幕书」能不能给：音频断链，且不是 EPUB 有声书的配对行。
  ///
  /// 配对行（uid = `srtbook_epub_<bookKey>`）的同一批音频路径还登记在 `audiobooks`
  /// 行上，会话启动器优先读那一行；只清 srt 行等于半转换，所以配对行只给「不再提示」。
  bool canConvertToSubtitleOnly(SrtBook book) =>
      hasMissingAudio(book) && srtBookCanAttachEpub(book);

  /// 转成纯字幕书时暂存的原路径；没有暂存、或行上又有了音频（重新导入 / 重新定位）
  /// 时返回 null——此时「恢复音频」没有意义，不给。
  List<String>? detachedAudioPaths(SrtBook book) {
    final List<String>? current = book.audioPaths;
    if (current != null && current.isNotEmpty) return null;
    final String? root = book.audioRoot;
    if (root != null && root.isNotEmpty) return null;
    final Object? stored = _prefs.getPref(detachedPathsPrefKey(book.uid));
    if (stored is! String || stored.isEmpty) return null;
    final Object? decoded = jsonDecode(stored);
    if (decoded is! List) return null;
    final List<String> paths = decoded.whereType<String>().toList();
    return paths.isEmpty ? null : paths;
  }

  /// 不再提示当前这组断链路径。
  Future<void> dismiss(SrtBook book) async {
    final List<String>? paths = book.audioPaths;
    if (paths == null || paths.isEmpty) return;
    await _prefs.setPref(dismissedPrefKey(book.uid), jsonEncode(paths));
  }

  /// 撤销 [dismiss]：恢复提示。
  Future<void> undismiss(SrtBook book) =>
      _prefs.setPref(dismissedPrefKey(book.uid), '');

  /// 转成纯字幕书：先暂存原路径、再清行上的音频列（反过来一旦清完写暂存失败，
  /// 原路径就再也找不回）。成功后 [book] 的内存副本同步清空，返回是否真写了行。
  Future<bool> convertToSubtitleOnly(SrtBook book) async {
    if (!canConvertToSubtitleOnly(book)) return false;
    final List<String> paths = List<String>.of(book.audioPaths!);
    await _prefs.setPref(detachedPathsPrefKey(book.uid), jsonEncode(paths));
    final bool written = await _repository.clearAudioPaths(book.uid);
    if (written) book.audioPaths = null;
    return written;
  }

  /// 撤销 [convertToSubtitleOnly]：把暂存的原路径写回行上，再清暂存。
  Future<bool> restoreAudio(SrtBook book) async {
    final List<String>? paths = detachedAudioPaths(book);
    if (paths == null) return false;
    final bool written = await _repository.patchByUid(
      book.uid,
      audioPaths: paths,
    );
    if (!written) return false;
    book.audioPaths = paths;
    await _prefs.setPref(detachedPathsPrefKey(book.uid), '');
    return true;
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:crypto/crypto.dart' show sha1;
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:path/path.dart' as p;

/// 插图表的盘上缓存（BUG-3433）。
///
/// [EpubBook.images] 要把每一章 XHTML 整章解析一遍，长篇一次几百毫秒到秒级；歌词模式
/// 插图、阅读器插图册与书架插图库每次打开都要它。一本书导入后插图集合不变，所以算一次
/// 落盘，之后按章节文件指纹（大小 + 修改时间）判有效、直接读回。章节文件被换掉（在线小说
/// 占位页 → 正文）指纹随之变，自动重算。
///
/// 缓存放在 support 根下的独立目录，不放进书的解压目录：解压目录会被原样重打包成 .epub
/// 发给互联 / 云同步的对端、整树进备份，派生缓存不该混进书里。书挪了位置（换数据根）或
/// 缓存被清掉只是下次重算一次。删书时由 `EpubStorage.deleteBookDir` 经
/// [deleteEpubImageIndexCache] 一并删掉。
///
/// [EpubBook.images] 的扫描语义（字数口径、位置换算、`sharesLineWithText` 判据等）一旦
/// 改动，必须把 [kEpubImageIndexCacheVersion] 加一，否则旧缓存会继续顶替新结果。
const int kEpubImageIndexCacheVersion = 1;

/// support 根下的缓存目录名。
const String kEpubImageIndexCacheDirName = 'epub_image_index';

/// [cacheDir] 里属于解压目录 [extractDir] 的插图表缓存文件（按规范化路径的 sha1 命名）。
File epubImageIndexCacheFile(Directory cacheDir, String extractDir) {
  final String key = sha1
      .convert(utf8.encode(p.canonicalize(extractDir)))
      .toString();
  return File(p.join(cacheDir.path, '$key.json'));
}

/// 生产路径：`<support>/epub_image_index/<sha1>.json`。读全局 [enginePaths]，只能在
/// 根 isolate 调用（后台 isolate 里装配点不在）。
///
/// 宿主没装配 [enginePaths]（纯 Dart 测试、只碰解压目录的调用方）时返回 null = 不缓存；
/// 装配了但取 support 根失败时经 [engineLog] 记下原因再返回 null（退回现算，不丢插图）。
Future<File?> epubImageIndexCacheFileFor(String extractDir) async {
  if (extractDir.isEmpty || enginePaths is UninstalledEnginePaths) return null;
  try {
    final Directory root = await enginePaths.supportRootDirectory();
    return epubImageIndexCacheFile(
      Directory(p.join(root.path, kEpubImageIndexCacheDirName)),
      extractDir,
    );
  } on Object catch (error, stack) {
    engineLog.log('epubImageIndexCacheFileFor', error, stack);
    return null;
  }
}

/// 删掉解压目录 [extractDir] 对应的插图表缓存（删书时调用，见
/// `EpubStorage.deleteBookDir`）。缓存按解压目录路径命名，不删的话这份文件成孤儿，
/// 之后同一路径再导入别的书时只剩指纹一道防线。根 isolate 调用；失败经 [engineLog]
/// 记录、不向上抛——它是派生物，删书本身不能因它失败。
Future<void> deleteEpubImageIndexCache(String extractDir) async {
  final File? file = await epubImageIndexCacheFileFor(extractDir);
  if (file == null) return;
  try {
    if (file.existsSync()) file.deleteSync();
  } on Object catch (error, stack) {
    engineLog.log('deleteEpubImageIndexCache', error, stack);
  }
}

/// [book] 的章节文件指纹。任一章没有盘上文件（eager 章节：DB 回退、测试构造）时
/// 返回 null——无从判断是否过期，不缓存。
String? epubImageIndexFingerprint(EpubBook book) {
  final StringBuffer out = StringBuffer()
    ..write('v$kEpubImageIndexCacheVersion|')
    ..write(book.coverHref ?? '');
  for (final EpubChapter chapter in book.chapters) {
    final String? path = chapter.filePath;
    if (path == null) return null;
    final FileStat stat = FileStat.statSync(path);
    out
      ..write('|')
      ..write(chapter.href)
      ..write(':')
      ..write(stat.size)
      ..write(':')
      ..write(stat.modified.millisecondsSinceEpoch);
  }
  return out.toString();
}

/// 一次缓存读写里出的错。后台 isolate 没有装配 [engineLog]（那边写的是 stderr，等于
/// 丢掉），所以只把文字带回来，由根 isolate 经 [reportEpubImageIndexCacheFailures]
/// 记日志。只含字符串，跨 isolate 传递无顾虑。
class EpubImageIndexCacheFailure {
  const EpubImageIndexCacheFailure({
    required this.stage,
    required this.error,
    required this.stack,
  });

  /// `read` / `write` / `write.cleanup`。
  final String stage;
  final String error;
  final String stack;
}

/// [loadEpubImagesWithCache] 的结果：插图表 + 缓存读写失败（读失败已退回现算，写失败
/// 只是下次再算，都不影响 [images]，但必须让根 isolate 记下来）。
class EpubImageIndexLoad {
  const EpubImageIndexLoad({
    required this.images,
    this.failures = const <EpubImageIndexCacheFailure>[],
  });

  final List<EpubImageRef> images;
  final List<EpubImageIndexCacheFailure> failures;
}

/// 根 isolate 上把后台带回的缓存失败交给 [engineLog]。
void reportEpubImageIndexCacheFailures(
  String source,
  List<EpubImageIndexCacheFailure> failures,
) {
  for (final EpubImageIndexCacheFailure failure in failures) {
    engineLog.log(
      '$source.${failure.stage}',
      failure.error,
      failure.stack.isEmpty ? null : StackTrace.fromString(failure.stack),
    );
  }
}

/// 取 [book] 的插图表，优先读 [cacheFile]（指纹一致才用），否则扫描整本书并把结果写回
/// [cacheFile]。读到的结果经 [EpubBook.adoptImages] 回填，同一实例之后再读不重算。
///
/// 读写失败（权限、磁盘满、内容损坏）都退回现算，绝不因缓存出错丢插图；失败原因放进
/// [EpubImageIndexLoad.failures] 带回调用方记日志。同步执行，供后台 isolate 调用。
EpubImageIndexLoad loadEpubImagesWithCache(EpubBook book, File cacheFile) {
  if (book.hasImages) return EpubImageIndexLoad(images: book.images);
  final List<EpubImageIndexCacheFailure> failures =
      <EpubImageIndexCacheFailure>[];
  final String? fingerprint = epubImageIndexFingerprint(book);
  if (fingerprint != null) {
    final List<EpubImageRef>? cached = _readCache(
      cacheFile,
      fingerprint,
      failures,
    );
    if (cached != null) {
      book.adoptImages(cached);
      return EpubImageIndexLoad(images: book.images, failures: failures);
    }
  }
  final List<EpubImageRef> images = book.images;
  if (fingerprint != null) {
    _writeCache(cacheFile, fingerprint, images, failures);
  }
  return EpubImageIndexLoad(images: images, failures: failures);
}

List<EpubImageRef>? _readCache(
  File file,
  String fingerprint,
  List<EpubImageIndexCacheFailure> failures,
) {
  try {
    // 不存在 / 指纹不符是正常的未命中，不算失败。
    if (!file.existsSync()) return null;
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('cache root is not a JSON object');
    }
    if (decoded['fingerprint'] != fingerprint) return null;
    final Object? list = decoded['images'];
    if (list is! List<dynamic>) {
      throw const FormatException('cache "images" is not a JSON list');
    }
    return <EpubImageRef>[
      for (final dynamic entry in list)
        EpubImageRef.fromJson(entry as Map<String, dynamic>),
    ];
  } on Object catch (error, stack) {
    failures.add(
      EpubImageIndexCacheFailure(
        stage: 'read',
        error: '${file.path}: $error',
        stack: stack.toString(),
      ),
    );
    return null;
  }
}

final Random _tmpNameRandom = Random();

/// 写缓存用的临时文件名。同一本书可能被几个后台 isolate 同时算（阅读器插图册、歌词
/// 模式、书架插图库、看兄弟卷），共用一个 `.tmp` 会互相截断、rename 撞车；每次写用独立
/// 文件名（进程号 + 微秒 + 随机数），最后一次 rename 胜出——各家内容相同，谁赢都对。
File _uniqueTmpFor(File file) => File(
  '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.'
  '${_tmpNameRandom.nextInt(1 << 32)}.tmp',
);

void _writeCache(
  File file,
  String fingerprint,
  List<EpubImageRef> images,
  List<EpubImageIndexCacheFailure> failures,
) {
  final File tmp = _uniqueTmpFor(file);
  try {
    file.parent.createSync(recursive: true);
    tmp.writeAsStringSync(
      jsonEncode(<String, Object>{
        'fingerprint': fingerprint,
        'images': <Map<String, Object>>[
          for (final EpubImageRef ref in images) ref.toJson(),
        ],
      }),
      flush: true,
    );
    tmp.renameSync(file.path);
  } on Object catch (error, stack) {
    failures.add(
      EpubImageIndexCacheFailure(
        stage: 'write',
        error: '${file.path}: $error',
        stack: stack.toString(),
      ),
    );
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } on Object catch (cleanupError, cleanupStack) {
      failures.add(
        EpubImageIndexCacheFailure(
          stage: 'write.cleanup',
          error: '${tmp.path}: $cleanupError',
          stack: cleanupStack.toString(),
        ),
      );
    }
  }
}

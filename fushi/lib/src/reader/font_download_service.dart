import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:fushi/src/pages/implementations/font_preview/font_file_metadata.dart'
    show readFontFamilyNameSync;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_compute/fushi_compute.dart' show FfcArchiveFormat;
import 'package:fushi_engine/utils/archive/archive_unpacker.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_user_agent.dart';
import 'package:path/path.dart' as p;

/// 字体库认得的字体文件扩展名（小写、带点）。
const Set<String> kFontFileExtensions = <String>{
  '.ttf',
  '.otf',
  '.ttc',
  '.woff',
  '.woff2',
};

/// 一个已落进字体目录的字体文件：[name] 是目录里的显示名，[path] 是绝对路径。
class ImportedFontFile {
  const ImportedFontFile({required this.name, required this.path});

  final String name;
  final String path;
}

/// 一次字体下载的结果：落地了哪些文件、是否被取消、失败原因。
///
/// 执行体不弹任何 toast / 对话框，就是为了让批量下载能把 N 条结果聚合成一句话，
/// 也让没有 UI 的调用方（浏览器扩展的字体端点）能直接消费。
class FontDownloadResult {
  const FontDownloadResult({
    this.files = const <ImportedFontFile>[],
    this.error,
    this.cancelled = false,
    this.unreachable = false,
  });

  final List<ImportedFontFile> files;
  final String? error;
  final bool cancelled;

  /// 所有下载源都在传输层失败（连不上 / 超时 / TLS），没有一个源真正答复过。
  /// 这是「网络到不了下载源」，UI 据此提示配置网络代理或手动导入字体文件，而不是
  /// 只报一个失败计数（反馈 f4ybrMM0mP「要自己配置，也没提醒」）。
  final bool unreachable;

  int get importedCount => files.length;

  bool get succeeded => error == null && !cancelled && files.isNotEmpty;
}

/// 这次失败是不是「请求根本没送到 / 没拿到答复」的传输层失败（连接超时、连接
/// 错误、收发超时、证书失败，或底层是 socket / TLS 异常）。服务端已经答复的
/// 4xx/5xx 不算——那不是网络到不了，换代理也没用。
@visibleForTesting
bool isFontDownloadTransportFailure(DioError e) {
  switch (e.type) {
    case DioErrorType.connectionTimeout:
    case DioErrorType.sendTimeout:
    case DioErrorType.receiveTimeout:
    case DioErrorType.connectionError:
    case DioErrorType.badCertificate:
      return true;
    case DioErrorType.unknown:
      final Object? cause = e.error;
      return cause is SocketException ||
          cause is TlsException ||
          cause is HttpException;
    case DioErrorType.badResponse:
    case DioErrorType.cancel:
      return false;
  }
}

/// 字体文件的下载 / 导入执行体：从 `CustomFontsPage` 里搬出来的纯文件层——
/// **不碰目录偏好、不碰 UI**，只负责「多源回退下载 → 校验 → 复制/解包进 [fontsDir]」。
/// 页面与浏览器扩展端点共用同一份，落地文件的命名规则只有这一处。
class FontDownloadService {
  FontDownloadService({
    required this.fontsDir,
    Dio Function()? dioFactory,
    ArchiveUnpacker? archiveUnpacker,
  }) : _dioFactory = dioFactory ?? _createDefaultDio,
       _archiveUnpacker = archiveUnpacker ?? ArchiveUnpacker();

  /// 字体落地目录（`<appDirectory>/custom_fonts`）。不存在时按需创建。
  final Directory fontsDir;
  final Dio Function() _dioFactory;

  /// 字体包（zip / 7z / rar，含加密包）的解包点：导入链路唯一的 [ArchiveUnpacker]，
  /// 口令对话框 / 记住的口令也走它。
  final ArchiveUnpacker _archiveUnpacker;

  /// 一个字体包解出字体的总字节上限（按实际写出量强制，防解压炸弹；整套 Noto CJK
  /// 超级 OTC 也远小于它）。
  static const int _kMaxFontArchiveBytes = 2 * 1024 * 1024 * 1024;

  // BUG-1498：字体全在 cdn.jsdelivr.net / raw.githubusercontent.com /
  // fonts.google.com 上，原先是裸 `Dio(...)`（`findProxy` 为 null，连 HTTPS_PROXY
  // 都不读）。改经统一装配点，三级 URL 回退逻辑不变。
  static Dio _createDefaultDio() => createAppDio(
    options: BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 10),
      followRedirects: true,
      maxRedirects: 10,
      headers: <String, String>{
        'User-Agent': fushiUserAgent('custom-fonts'),
        'Accept': '*/*',
      },
    ),
  );

  /// 按扩展名判断是不是字体文件名（zip 内条目名 / 用户选的文件名都走这个）。
  static bool isFontFileName(String path) =>
      kFontFileExtensions.contains(p.extension(path).toLowerCase());

  /// 按文件头魔数嗅探字体格式，返回带点小写扩展名；不是已知字体格式时返回 null。
  static Future<String?> detectFontExtension(File file) async {
    try {
      final RandomAccessFile raf = await file.open();
      try {
        final List<int> header = await raf.read(8);
        if (header.length < 4) return null;
        // wOFF（WOFF 1.0；第 5..8 字节是 flavor：0x00010000 TrueType / 'OTTO' CFF，
        // 两种都是 WOFF1）。旧实现把非 0x00010000 flavor 当 woff2、又不认真正的
        // 'wOF2' 魔数，导致 WOFF2 直链下载一律被判「不是字体」而回退到下一源。
        if (header[0] == 0x77 && header[1] == 0x4F && header[2] == 0x46) {
          if (header[3] == 0x46) return '.woff';
          // wOF2
          if (header[3] == 0x32) return '.woff2';
        }
        // TrueType / OpenType
        if (header[0] == 0x00 &&
            header[1] == 0x01 &&
            header[2] == 0x00 &&
            header[3] == 0x00) {
          return '.ttf';
        }
        if (header[0] == 0x4F &&
            header[1] == 0x54 &&
            header[2] == 0x54 &&
            header[3] == 0x4F) {
          return '.otf';
        }
        // TTC
        if (header[0] == 0x74 &&
            header[1] == 0x74 &&
            header[2] == 0x63 &&
            header[3] == 0x66) {
          return '.ttc';
        }
        return null;
      } finally {
        await raf.close();
      }
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'FontDownloadService.detectFontExt',
        e,
        stack,
      );
      return null;
    }
  }

  static Future<bool> isValidFontFile(File file) async =>
      await detectFontExtension(file) != null;

  /// zip 魔数（`PK\x03\x04`）。
  static Future<bool> isZipFile(File file) async {
    try {
      final RandomAccessFile raf = await file.open();
      try {
        final List<int> header = await raf.read(4);
        return header.length >= 4 &&
            header[0] == 0x50 &&
            header[1] == 0x4B &&
            header[2] == 0x03 &&
            header[3] == 0x04;
      } finally {
        await raf.close();
      }
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'FontDownloadService.isZipArchive',
        e,
        stack,
      );
      return false;
    }
  }

  /// 从下载 URL 推导落地文件名：Google Fonts 打包接口按 `?family=` 取名，
  /// 其它取最后一个路径段。
  static String fileNameFromUrl(String url) {
    final Uri uri = Uri.parse(url);
    if (uri.queryParameters.containsKey('family')) {
      final String family = uri.queryParameters['family']!.replaceAll(' ', '_');
      return '$family.zip';
    }
    if (uri.pathSegments.isNotEmpty) {
      return Uri.decodeComponent(uri.pathSegments.last);
    }
    return 'font_${DateTime.now().millisecondsSinceEpoch}';
  }

  Directory _ensureFontsDir() {
    if (!fontsDir.existsSync()) fontsDir.createSync(recursive: true);
    return fontsDir;
  }

  /// 把 [src] 导入字体目录。
  ///
  /// - 压缩包（zip / 7z 按魔数判，rar 交 7-Zip；含加密包）→ 经 [ArchiveUnpacker]
  ///   解出其中所有字体条目；给了 [overrideName] 时只挑一个（优先 `regular` /
  ///   `[wght]` 那一份）并以 [overrideName] 命名。解不开抛 [ArchiveUnpackException]。
  /// - 字体文件（按 [fileName] 扩展名或魔数判）→ 复制为
  ///   `<name>_<epochMs><ext>`，name 取 [overrideName]，否则取字体 `name` 表里的
  ///   家族名（[importedFontDisplayName]），读不出才退回去扩展名的 [fileName]。
  /// - 都不是 → 抛 [FormatException]，由调用方决定怎么提示。
  ///
  /// 只动文件，不写目录偏好。
  Future<List<ImportedFontFile>> importFile(
    File src, {
    required String fileName,
    String? overrideName,
  }) async {
    final String ext = p.extension(fileName).toLowerCase();
    final String? detected = await detectFontExtension(src);
    if (detected == null && await _isArchive(src, ext)) {
      return _extractFontsFromArchive(src, overrideName: overrideName);
    }
    if (kFontFileExtensions.contains(ext)) {
      return <ImportedFontFile>[
        await _copySingleFont(src, fileName, ext, overrideName: overrideName),
      ];
    }
    if (detected == null) {
      throw FormatException('Not a font file or archive', fileName);
    }
    return <ImportedFontFile>[
      await _copySingleFont(
        src,
        fileName,
        detected,
        overrideName: overrideName,
      ),
    ];
  }

  Future<ImportedFontFile> _copySingleFont(
    File src,
    String fileName,
    String ext, {
    String? overrideName,
  }) async {
    final String name =
        overrideName ??
        importedFontDisplayName(
          src.path,
          fallback: p.basenameWithoutExtension(fileName),
        );
    final String destPath = p.join(
      _ensureFontsDir().path,
      '${safeWindowsFileName(name)}_${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    await src.copy(destPath);
    return ImportedFontFile(name: name, path: destPath);
  }

  /// 导入字体文件的目录名：文件 `name` 表里的家族名（Typographic Family 优先），
  /// 读不出（WOFF2、坏文件）才用 [fallback]（去扩展名的文件名，旧行为）。
  ///
  /// 用真实家族名的意义：同一家族的多个字重文件（`KleeOne-Regular.ttf` +
  /// `KleeOne-SemiBold.ttf`）落成**同名**条目，CSS 生成器把同名条目合成一个家族、
  /// 每个文件按真实字重各出一条 `@font-face`，粗体请求就会选中粗体文件，而不是把
  /// 常规字面合成加粗。按文件名命名时两份永远是两个互不相干的家族。
  @visibleForTesting
  static String importedFontDisplayName(
    String path, {
    required String fallback,
  }) {
    final String? family = readFontFamilyNameSync(path);
    return family == null || family.isEmpty ? fallback : family;
  }

  /// [src] 是不是解包点认得的压缩包（zip / 7z 按魔数，rar 按魔数或扩展名）。条目表
  /// 坏的包也算——交给解包点报它自己的错，不当成「不是字体」。
  Future<bool> _isArchive(File src, String ext) async {
    if (kRarArchiveExtensions.contains(ext)) return true;
    try {
      return (await _archiveUnpacker.probe(src.path)).format !=
          FfcArchiveFormat.unknown;
    } on ArchiveUnpackException {
      return true;
    }
  }

  Future<List<ImportedFontFile>> _extractFontsFromArchive(
    File archiveFile, {
    String? overrideName,
  }) async {
    final Directory work = await Directory.systemTemp.createTemp(
      'fushi-font-archive-',
    );
    try {
      final Directory unpacked = Directory(p.join(work.path, 'fonts'));
      await _archiveUnpacker.extract(
        archiveFile.path,
        intoDir: unpacked.path,
        includeExtensions: kFontFileExtensions,
        maxTotalBytes: _kMaxFontArchiveBytes,
      );
      // 按包内相对路径排序：落地顺序（批量结果、同名家族的先后）不随文件系统枚举顺序变。
      final List<File> fontFiles = <File>[
        if (await unpacked.exists())
          await for (final FileSystemEntity entity in unpacked.list(
            recursive: true,
            followLinks: false,
          ))
            if (entity is File && isFontFileName(entity.path)) entity,
      ];
      fontFiles.sort(
        (File a, File b) => p
            .relative(a.path, from: unpacked.path)
            .compareTo(p.relative(b.path, from: unpacked.path)),
      );
      final Directory dir = _ensureFontsDir();
      if (overrideName != null && fontFiles.isNotEmpty) {
        final File font = fontFiles.firstWhere((File f) {
          final String base = p.basenameWithoutExtension(f.path).toLowerCase();
          return base.contains('regular') || base.contains('[wght]');
        }, orElse: () => fontFiles.first);
        final String destPath = p.join(
          dir.path,
          '${safeWindowsFileName(overrideName)}_${DateTime.now().millisecondsSinceEpoch}${p.extension(font.path)}',
        );
        await font.copy(destPath);
        return <ImportedFontFile>[
          ImportedFontFile(name: overrideName, path: destPath),
        ];
      }

      final List<ImportedFontFile> imported = <ImportedFontFile>[];
      final int ts = DateTime.now().millisecondsSinceEpoch;
      for (final File font in fontFiles) {
        final String baseName = p.basenameWithoutExtension(font.path);
        final String destPath = p.join(
          dir.path,
          '${baseName}_$ts${p.extension(font.path)}',
        );
        await font.copy(destPath);
        // 家族包（Google Fonts 的 zip 里 Regular + SemiBold …）按真实家族名落成同名
        // 条目，自动合成一个多字重家族。
        imported.add(
          ImportedFontFile(
            name: importedFontDisplayName(destPath, fallback: baseName),
            path: destPath,
          ),
        );
      }
      return imported;
    } finally {
      try {
        await work.delete(recursive: true);
      } on FileSystemException catch (e, stack) {
        // 系统临时目录里的残留不影响导入结果，记一笔即可。
        ErrorLogService.instance.log(
          'FontDownloadService.archiveCleanup',
          e,
          stack,
        );
      }
    }
  }

  /// 下载执行体：按 [urls] 顺序多源回退（前一源失败或回的不是字体/zip 就试下一源），
  /// 成功后经 [importFile] 落进字体目录。
  ///
  /// [onProgress] 收 0..1 的进度，源切换或总长未知时给 null。取消由调用方持有
  /// [cancelToken]：批量时一次取消应当停掉整批。
  Future<FontDownloadResult> download(
    List<String> urls, {
    String? overrideName,
    CancelToken? cancelToken,
    void Function(double? progress)? onProgress,
  }) async {
    final int ts = DateTime.now().millisecondsSinceEpoch;
    final String tempPath = p.join(_ensureFontsDir().path, '_tmp_$ts');
    final File tempFile = File(tempPath);
    Future<void> discardTemp() async {
      if (await tempFile.exists()) await tempFile.delete();
    }

    try {
      final Dio dio = _dioFactory();

      String? downloadedUrl;
      Object? lastError;
      // 每个源的失败原因（全部失败时整段写进错误日志——以前只走 debugPrint，
      // 用户附带的日志里看不到任何字体下载记录，无从诊断）。
      final List<String> attempts = <String>[];
      // 是否每个源都败在传输层（没有任何一个源真正答复过）。
      bool allUnreachable = true;
      for (int i = 0; i < urls.length; i++) {
        final String currentUrl = urls[i];
        debugPrint(
          '[fushi-fonts] trying source ${i + 1}/${urls.length}: $currentUrl',
        );
        onProgress?.call(null);
        try {
          await dio.download(
            currentUrl,
            tempPath,
            cancelToken: cancelToken,
            onReceiveProgress: (int received, int total) {
              if (total > 0) onProgress?.call(received / total);
            },
          );
          if (await tempFile.exists() &&
              !await isZipFile(tempFile) &&
              !await isValidFontFile(tempFile)) {
            debugPrint(
              '[fushi-fonts] source ${i + 1} returned non-font data, skipping',
            );
            lastError = Exception(
              'Downloaded file is not a valid font or archive',
            );
            allUnreachable = false;
            attempts.add('$currentUrl -> not a font or archive');
            await tempFile.delete();
            continue;
          }
          downloadedUrl = currentUrl;
          break;
        } on DioError catch (e) {
          if (e.type == DioErrorType.cancel) rethrow;
          lastError = e;
          if (!isFontDownloadTransportFailure(e)) allUnreachable = false;
          final int? status = e.response?.statusCode;
          attempts.add(
            '$currentUrl -> ${e.type.name}'
            '${status == null ? '' : ' $status'}'
            '${e.error == null ? '' : ' (${e.error})'}',
          );
          debugPrint('[fushi-fonts] source ${i + 1} failed: ${e.type.name}');
          await discardTemp();
        }
      }

      if (downloadedUrl == null) {
        ErrorLogService.instance.log(
          'FontDownloadService.download',
          Exception(
            'all ${urls.length} font sources failed:\n${attempts.join('\n')}',
          ),
        );
        await discardTemp();
        final Object? err = lastError;
        return FontDownloadResult(
          error: err is DioError ? err.type.name : '${err ?? 'no source'}',
          unreachable: allUnreachable && urls.isNotEmpty,
        );
      }

      final List<ImportedFontFile> files = await importFile(
        tempFile,
        fileName: fileNameFromUrl(downloadedUrl),
        overrideName: overrideName,
      );
      await discardTemp();
      return FontDownloadResult(files: files);
    } on DioError catch (e, stack) {
      await discardTemp();
      if (e.type == DioErrorType.cancel) {
        return const FontDownloadResult(cancelled: true);
      }
      debugPrint(
        '[fushi-fonts] DioError: type=${e.type} '
        'status=${e.response?.statusCode} msg=${e.message}',
      );
      debugPrint('[fushi-fonts] stack: $stack');
      return FontDownloadResult(error: e.type.name);
    } catch (e, stack) {
      await discardTemp();
      debugPrint('[fushi-fonts] download failed: $e');
      debugPrint('[fushi-fonts] stack: $stack');
      return FontDownloadResult(error: '$e');
    }
  }
}

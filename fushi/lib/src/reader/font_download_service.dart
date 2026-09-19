import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi/src/utils/misc/error_log_service.dart';
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
  });

  final List<ImportedFontFile> files;
  final String? error;
  final bool cancelled;

  int get importedCount => files.length;

  bool get succeeded => error == null && !cancelled && files.isNotEmpty;
}

/// 字体文件的下载 / 导入执行体：从 `CustomFontsPage` 里搬出来的纯文件层——
/// **不碰目录偏好、不碰 UI**，只负责「多源回退下载 → 校验 → 复制/解包进 [fontsDir]」。
/// 页面与浏览器扩展端点共用同一份，落地文件的命名规则只有这一处。
class FontDownloadService {
  FontDownloadService({required this.fontsDir, Dio Function()? dioFactory})
      : _dioFactory = dioFactory ?? _createDefaultDio;

  /// 字体落地目录（`<appDirectory>/custom_fonts`）。不存在时按需创建。
  final Directory fontsDir;
  final Dio Function() _dioFactory;

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
      ErrorLogService.instance
          .log('FontDownloadService.detectFontExt', e, stack);
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
      ErrorLogService.instance
          .log('FontDownloadService.isZipArchive', e, stack);
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
  /// - zip（按魔数判）→ 解出其中所有字体条目；给了 [overrideName] 时只挑一个
  ///   （优先 `regular` / `[wght]` 那一份）并以 [overrideName] 命名。
  /// - 字体文件（按 [fileName] 扩展名或魔数判）→ 复制为
  ///   `<name>_<epochMs><ext>`，name 取 [overrideName] 或去扩展名的 [fileName]。
  /// - 都不是（如 7z/rar 或坏 zip）→ 抛 [FormatException]，由调用方决定怎么提示。
  ///
  /// 只动文件，不写目录偏好。
  Future<List<ImportedFontFile>> importFile(
    File src, {
    required String fileName,
    String? overrideName,
  }) async {
    if (await isZipFile(src)) {
      return _extractFontsFromArchive(src, overrideName: overrideName);
    }
    final String ext = p.extension(fileName).toLowerCase();
    if (kFontFileExtensions.contains(ext)) {
      return <ImportedFontFile>[
        await _copySingleFont(src, fileName, ext, overrideName: overrideName),
      ];
    }
    final String? detected = await detectFontExtension(src);
    if (detected == null) {
      throw FormatException('Not a font file or zip archive', fileName);
    }
    return <ImportedFontFile>[
      await _copySingleFont(src, fileName, detected,
          overrideName: overrideName),
    ];
  }

  Future<ImportedFontFile> _copySingleFont(
    File src,
    String fileName,
    String ext, {
    String? overrideName,
  }) async {
    final String name = overrideName ?? p.basenameWithoutExtension(fileName);
    final String destPath = p.join(
      _ensureFontsDir().path,
      '${name}_${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    await src.copy(destPath);
    return ImportedFontFile(name: name, path: destPath);
  }

  Future<List<ImportedFontFile>> _extractFontsFromArchive(
    File archiveFile, {
    String? overrideName,
  }) async {
    final List<int> bytes = await archiveFile.readAsBytes();
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final List<ArchiveFile> fontEntries = archive.files
        .where(
            (ArchiveFile entry) => entry.isFile && isFontFileName(entry.name))
        .toList();
    final Directory dir = _ensureFontsDir();
    if (overrideName != null && fontEntries.isNotEmpty) {
      final ArchiveFile entry = fontEntries.firstWhere((ArchiveFile entry) {
        final String base =
            p.basenameWithoutExtension(entry.name).toLowerCase();
        return base.contains('regular') || base.contains('[wght]');
      }, orElse: () => fontEntries.first);
      final String ext = p.extension(entry.name);
      final String destPath = p.join(
        dir.path,
        '${safeWindowsFileName(overrideName)}_${DateTime.now().millisecondsSinceEpoch}$ext',
      );
      File(destPath).writeAsBytesSync(entry.content as List<int>);
      return <ImportedFontFile>[
        ImportedFontFile(name: overrideName, path: destPath),
      ];
    }

    final List<ImportedFontFile> imported = <ImportedFontFile>[];
    final int ts = DateTime.now().millisecondsSinceEpoch;
    for (final ArchiveFile entry in fontEntries) {
      final String baseName = p.basenameWithoutExtension(entry.name);
      final String ext = p.extension(entry.name);
      final String destPath = p.join(dir.path, '${baseName}_$ts$ext');
      File(destPath).writeAsBytesSync(entry.content as List<int>);
      imported.add(ImportedFontFile(name: baseName, path: destPath));
    }
    return imported;
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
            await tempFile.delete();
            continue;
          }
          downloadedUrl = currentUrl;
          break;
        } on DioError catch (e) {
          if (e.type == DioErrorType.cancel) rethrow;
          lastError = e;
          debugPrint('[fushi-fonts] source ${i + 1} failed: ${e.type.name}');
          await discardTemp();
        }
      }

      if (downloadedUrl == null) {
        final Object err = lastError ?? Exception('All sources failed');
        if (err is Exception) throw err;
        if (err is Error) throw err;
        throw Exception(err.toString());
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

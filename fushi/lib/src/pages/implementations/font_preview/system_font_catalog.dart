import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/reader/font_download_service.dart'
    show kFontFileExtensions;
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// 本机一款系统字体族。
///
/// [family] 是引擎（Flutter `TextStyle.fontFamily` / WebView CSS `font-family`）
/// **按名能解析到**的族名——字体库里系统字体条目只存这个名字，名字不对等于没加。
@immutable
class SystemFontFamily {
  const SystemFontFamily({required this.family, this.supportsJapanese});

  final String family;

  /// 字体自身是否带日文字形（假名 + 常用汉字）。null = 该平台判不出来
  /// （Android 的字形检测会把系统回退也算进去，判了也是恒 true）。
  final bool? supportsJapanese;

  @override
  bool operator ==(Object other) =>
      other is SystemFontFamily &&
      other.family == family &&
      other.supportsJapanese == supportsJapanese;

  @override
  int get hashCode => Object.hash(family, supportsJapanese);

  @override
  String toString() =>
      'SystemFontFamily($family, supportsJapanese: $supportsJapanese)';
}

/// 系统字体清单与它的来源可信度。
@immutable
class SystemFontList {
  const SystemFontList({required this.families, required this.namesReliable});

  static const SystemFontList empty = SystemFontList(
    families: <SystemFontFamily>[],
    namesReliable: true,
  );

  final List<SystemFontFamily> families;

  /// false = 名字是从字体**文件名**推出来的兜底结果（平台枚举不可用时），
  /// 与引擎认的族名可能对不上（`msgothic.ttc` 推不出 `MS Gothic`），UI 要提示。
  final bool namesReliable;
}

/// 解析 `listSystemFonts` 通道的返回值。
///
/// 契约：`List<Map>`，每项 `{family: String, supportsJapanese?: bool}`。旧 Android
/// 宿主返回裸 `List<String>`，同样接受（`supportsJapanese` 记 null）。按族名大小写
/// 不敏感去重，排序后返回；空名、`@` 开头的竖排别名族一律丢弃。
@visibleForTesting
List<SystemFontFamily> parseSystemFontChannelResult(Object? raw) {
  if (raw is! List) return const <SystemFontFamily>[];
  final Map<String, SystemFontFamily> byKey = <String, SystemFontFamily>{};
  for (final Object? item in raw) {
    String? family;
    bool? supportsJapanese;
    if (item is String) {
      family = item;
    } else if (item is Map) {
      final Object? rawFamily = item['family'];
      if (rawFamily is String) family = rawFamily;
      final Object? rawJa = item['supportsJapanese'];
      if (rawJa is bool) supportsJapanese = rawJa;
    }
    final String trimmed = family?.trim() ?? '';
    if (trimmed.isEmpty || trimmed.startsWith('@')) continue;
    byKey.putIfAbsent(
      trimmed.toLowerCase(),
      () =>
          SystemFontFamily(family: trimmed, supportsJapanese: supportsJapanese),
    );
  }
  return _sorted(byKey.values);
}

/// 解析 `fc-list : family` 的输出。一行可能是 `名A,名B`（同族多语言别名），
/// 只取第一个——fontconfig 按任一别名都能匹配，首项是它自己的规范名。
@visibleForTesting
List<String> parseFcListFamilies(String output) {
  final Set<String> seen = <String>{};
  final List<String> families = <String>[];
  for (final String line in const LineSplitter().convert(output)) {
    final String first = line.split(',').first.trim();
    if (first.isEmpty) continue;
    if (seen.add(first.toLowerCase())) families.add(first);
  }
  return families;
}

/// 从字体**文件名**推族名：只作平台枚举不可用时的兜底，名字不保证与引擎一致。
@visibleForTesting
String guessFontFamilyFromFileName(String filePath) => p
    .basenameWithoutExtension(filePath)
    .replaceAll(RegExp(r'[-_]'), ' ')
    .replaceAll(
      RegExp(
        r'\s+(Regular|Bold|Italic|Light|Medium|Thin|'
        r'Black|ExtraBold|SemiBold|ExtraLight|Condensed|Expanded)$',
        caseSensitive: false,
      ),
      '',
    )
    .trim();

List<SystemFontFamily> _sorted(Iterable<SystemFontFamily> families) =>
    families.toList()..sort(
      (SystemFontFamily a, SystemFontFamily b) =>
          a.family.toLowerCase().compareTo(b.family.toLowerCase()),
    );

/// 系统字体清单的唯一入口（字体库「添加系统字体」浏览页用）。
///
/// 顺序：平台通道（各端原生 API 给真实族名）→ Linux `fc-list` → 扫字体目录按
/// 文件名推名（标记 [SystemFontList.namesReliable] = false）。成功结果进程内缓存。
class SystemFontCatalog {
  SystemFontCatalog._();

  static SystemFontList? _cache;

  /// 测试注入：替换真实平台枚举。
  @visibleForTesting
  static Future<SystemFontList> Function()? debugLoaderOverride;

  @visibleForTesting
  static void debugReset() {
    _cache = null;
    debugLoaderOverride = null;
  }

  static Future<SystemFontList> load() async {
    final SystemFontList? cached = _cache;
    if (cached != null) return cached;
    final Future<SystemFontList> Function()? override = debugLoaderOverride;
    final SystemFontList result = override != null
        ? await override()
        : await _loadFromPlatform();
    if (result.families.isNotEmpty) _cache = result;
    return result;
  }

  static Future<SystemFontList> _loadFromPlatform() async {
    final List<SystemFontFamily> fromChannel = await _loadFromChannel();
    if (fromChannel.isNotEmpty) {
      return SystemFontList(families: fromChannel, namesReliable: true);
    }
    if (Platform.isLinux) {
      final List<SystemFontFamily> fromFc = await _loadFromFcList();
      if (fromFc.isNotEmpty) {
        return SystemFontList(families: fromFc, namesReliable: true);
      }
    }
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return SystemFontList(
        families: await _scanFontDirectories(),
        namesReliable: false,
      );
    }
    return SystemFontList.empty;
  }

  static Future<List<SystemFontFamily>> _loadFromChannel() async {
    try {
      final Object? raw = await FushiChannels.fonts.invokeMethod<Object?>(
        'listSystemFonts',
      );
      return parseSystemFontChannelResult(raw);
    } on MissingPluginException {
      // 该平台宿主没实现（例如 Linux runner），走下一级兜底。
      return const <SystemFontFamily>[];
    } catch (e, stack) {
      ErrorLogService.instance.log('SystemFontCatalog.channel', e, stack);
      return const <SystemFontFamily>[];
    }
  }

  static Future<List<SystemFontFamily>> _loadFromFcList() async {
    try {
      final ProcessResult all = await Process.run('fc-list', <String>[
        ':',
        'family',
      ]);
      if (all.exitCode != 0) return const <SystemFontFamily>[];
      final ProcessResult ja = await Process.run('fc-list', <String>[
        ':lang=ja',
        'family',
      ]);
      final Set<String> japanese = ja.exitCode == 0
          ? parseFcListFamilies(
              ja.stdout as String,
            ).map((String f) => f.toLowerCase()).toSet()
          : <String>{};
      return _sorted(<SystemFontFamily>[
        for (final String family in parseFcListFamilies(all.stdout as String))
          SystemFontFamily(
            family: family,
            supportsJapanese: japanese.contains(family.toLowerCase()),
          ),
      ]);
    } catch (e, stack) {
      ErrorLogService.instance.log('SystemFontCatalog.fcList', e, stack);
      return const <SystemFontFamily>[];
    }
  }

  static Future<List<SystemFontFamily>> _scanFontDirectories() async {
    final List<String> fontDirs = <String>[];
    if (Platform.isWindows) {
      fontDirs.add(r'C:\Windows\Fonts');
      final String? localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null) {
        fontDirs.add(p.join(localAppData, r'Microsoft\Windows\Fonts'));
      }
    } else if (Platform.isMacOS) {
      fontDirs.addAll(<String>['/System/Library/Fonts', '/Library/Fonts']);
      final String? home = Platform.environment['HOME'];
      if (home != null) fontDirs.add('$home/Library/Fonts');
    } else if (Platform.isLinux) {
      fontDirs.addAll(<String>['/usr/share/fonts', '/usr/local/share/fonts']);
      final String? home = Platform.environment['HOME'];
      if (home != null) fontDirs.add('$home/.local/share/fonts');
    }

    final Map<String, SystemFontFamily> byKey = <String, SystemFontFamily>{};
    for (final String dirPath in fontDirs) {
      final Directory dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      try {
        await for (final FileSystemEntity entity in dir.list(recursive: true)) {
          if (entity is! File) continue;
          final String ext = p.extension(entity.path).toLowerCase();
          if (!kFontFileExtensions.contains(ext)) continue;
          final String name = guessFontFamilyFromFileName(entity.path);
          if (name.isEmpty) continue;
          byKey.putIfAbsent(
            name.toLowerCase(),
            () => SystemFontFamily(family: name),
          );
        }
      } catch (e) {
        debugPrint('[fushi-fonts] error scanning $dirPath: $e');
      }
    }
    return _sorted(byKey.values);
  }
}

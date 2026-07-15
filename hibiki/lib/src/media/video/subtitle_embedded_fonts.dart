import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// 视频容器（MKV 等）里的一条字体附件（attachment stream）的最小描述。
///
/// [attachmentOrdinal] 是**附件流之间的相对序号**（0 基），对应 ffmpeg
/// `-dump_attachment:t:<ordinal>` 的 `t:` 索引；不是 ffprobe 的绝对 `index`。
class EmbeddedFontAttachment {
  const EmbeddedFontAttachment({
    required this.attachmentOrdinal,
    required this.fileName,
  });

  final int attachmentOrdinal;

  /// 附件的原始文件名（`tags.filename`，可能缺失 → 兜底 `attachment_<n>`）。
  /// 仅用于给抽出的临时文件挑扩展名，字体真实 family 名一律从 sfnt name 表解析。
  final String fileName;
}

/// 从 ffprobe（`-select_streams t -show_streams -print_format json`）的 JSON 输出里
/// 解析出**字体**附件流列表（纯函数，可单测）。判据：`codec_type == attachment` 且
/// （`codec_name` 是 ttf/otf/…，或 `tags.mimetype` 是字体 MIME，或 `tags.filename`
/// 扩展名是字体扩展名）。非字体附件（字幕引用的封面图等）跳过。解析失败返回空列表
/// （诚实降级，不抛）。
List<EmbeddedFontAttachment> parseFfprobeFontAttachments(String jsonText) {
  if (jsonText.trim().isEmpty) return const <EmbeddedFontAttachment>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } catch (_) {
    return const <EmbeddedFontAttachment>[];
  }
  if (decoded is! Map) return const <EmbeddedFontAttachment>[];
  final Object? streams = decoded['streams'];
  if (streams is! List) return const <EmbeddedFontAttachment>[];

  final List<EmbeddedFontAttachment> result = <EmbeddedFontAttachment>[];
  int ordinal = 0; // 附件流相对序号（只在 attachment 流上递增）。
  for (final Object? s in streams) {
    if (s is! Map) continue;
    if (s['codec_type'] != 'attachment') continue;
    final int thisOrdinal = ordinal;
    ordinal++;

    final String codecName = (s['codec_name'] as String? ?? '').toLowerCase();
    final Object? tagsObj = s['tags'];
    final Map<Object?, Object?> tags =
        tagsObj is Map ? tagsObj : const <Object?, Object?>{};
    final String fileName =
        (tags['filename'] as String? ?? tags['FILENAME'] as String? ?? '')
            .trim();
    final String mime =
        (tags['mimetype'] as String? ?? tags['MIMETYPE'] as String? ?? '')
            .toLowerCase();

    if (_isFontAttachment(
      codecName: codecName,
      mimetype: mime,
      fileName: fileName,
    )) {
      result.add(EmbeddedFontAttachment(
        attachmentOrdinal: thisOrdinal,
        fileName: fileName.isEmpty ? 'attachment_$thisOrdinal' : fileName,
      ));
    }
  }
  return result;
}

/// 字体附件判据：codec 名 / MIME / 文件名扩展名任一命中字体即可。
bool _isFontAttachment({
  required String codecName,
  required String mimetype,
  required String fileName,
}) {
  const Set<String> fontCodecs = <String>{'ttf', 'otf', 'sfnt'};
  if (fontCodecs.contains(codecName)) return true;
  // 常见字体 MIME（各 muxer 写法不一）。
  if (mimetype.contains('font') ||
      mimetype == 'application/x-truetype-font' ||
      mimetype == 'application/vnd.ms-opentype' ||
      mimetype == 'application/x-font-ttf' ||
      mimetype == 'application/x-font-otf') {
    return true;
  }
  final String ext = p.extension(fileName).toLowerCase();
  return ext == '.ttf' || ext == '.otf' || ext == '.ttc';
}

/// 匹配 ffmpeg `-i` 日志里一条附件流行 `Stream #0:N: Attachment: <codec>`
/// （codec 可为空 / `none`；跳过可选的 `[0x..]` 流 id 与 `(lang)` 段）。
final RegExp _ffmpegAttachmentStreamPattern = RegExp(
  r'Stream #\d+:\d+(?:\[0x[0-9a-fA-F]+\])?(?:\([^)]*\))?: Attachment:\s*([A-Za-z0-9_]*)',
);

/// 匹配 ffmpeg 任意 `Stream #N:M ...` 行——附件 metadata 块扫到下一条 Stream 即止。
final RegExp _ffmpegAnyStreamPattern = RegExp(r'Stream #\d+:\d+');

/// 匹配附件 metadata 块里的 `filename : <值>` / `mimetype : <值>` 行（大小写不敏感）。
final RegExp _ffmpegAttachmentFilenamePattern =
    RegExp(r'^\s*filename\s*:\s*(.+?)\s*$', caseSensitive: false);
final RegExp _ffmpegAttachmentMimetypePattern =
    RegExp(r'^\s*mimetype\s*:\s*(.+?)\s*$', caseSensitive: false);

/// 从 `ffmpeg -i <video>` 的 stderr 日志解析出**字体**附件流列表（纯函数，可单测）。
///
/// 与 [parseFfprobeFontAttachments] 判据一致（codec/MIME/文件名扩展名任一命中字体），
/// 但**不依赖 ffprobe**：桌面 ffprobe 常未随产物捆绑、也不在 PATH，而 ffmpeg 已被内嵌
/// 字幕枚举（`parseSubtitleStreamsFromFfmpegLog`）与附件抽取（`-dump_attachment`）复用，
/// 是「哪台机器能列内嵌字幕，就能列内嵌字体」的单一可用工具（BUG-829：改用 ffmpeg 后
/// 内封字体真正生效，而非仅静默降级）。ffmpeg 日志格式：
/// ```
///   Stream #0:3: Attachment: ttf
///       Metadata:
///         filename        : matisse.ttf
///         mimetype        : application/x-truetype-font
/// ```
/// [attachmentOrdinal] 按**附件流**出现序递增（每条 Attachment 流 +1，字体与非字体都计），
/// 对应 `-dump_attachment:t:<ordinal>` 的 `t:` 相对索引。解析失败/无附件返回空列表。
List<EmbeddedFontAttachment> parseFfmpegFontAttachments(String ffmpegLog) {
  final List<String> lines = const LineSplitter().convert(ffmpegLog);
  final List<EmbeddedFontAttachment> result = <EmbeddedFontAttachment>[];
  int ordinal = 0; // 附件流相对序号（只在 Attachment 流上递增）。
  for (int i = 0; i < lines.length; i++) {
    final RegExpMatch? m = _ffmpegAttachmentStreamPattern.firstMatch(lines[i]);
    if (m == null) continue;
    final int thisOrdinal = ordinal;
    ordinal++;

    final String codecName = (m.group(1) ?? '').toLowerCase();
    String fileName = '';
    String mime = '';
    // 向后扫该附件流的 metadata 块（更深缩进的独立行），到下一条 Stream 行为止。
    for (int j = i + 1; j < lines.length; j++) {
      if (_ffmpegAnyStreamPattern.hasMatch(lines[j])) break;
      final RegExpMatch? fn =
          _ffmpegAttachmentFilenamePattern.firstMatch(lines[j]);
      if (fn != null && fileName.isEmpty) fileName = fn.group(1)!.trim();
      final RegExpMatch? mt =
          _ffmpegAttachmentMimetypePattern.firstMatch(lines[j]);
      if (mt != null && mime.isEmpty) mime = mt.group(1)!.trim().toLowerCase();
    }

    if (_isFontAttachment(
      codecName: codecName,
      mimetype: mime,
      fileName: fileName,
    )) {
      result.add(EmbeddedFontAttachment(
        attachmentOrdinal: thisOrdinal,
        fileName: fileName.isEmpty ? 'attachment_$thisOrdinal' : fileName,
      ));
    }
  }
  return result;
}

/// 从 sfnt 字体字节（ttf/otf/ttc）解析所有声明的 **family 名**（纯函数，可单测）。
///
/// 读 `name` 表的 nameID 1（Family）与 16（Typographic/Preferred Family）——ASS `Fontname`
/// 对应的正是字体内部声明的 family 名，附件的**文件名往往与之不同**（如
/// `matisse.otf` vs `FOT-Matisse ProN B`），必须以 name 表为准才能把附件注册成 ASS 能
/// 命中的 family。TTC（`ttcf`）遍历其中每个子字体。任何越界 / 格式异常静默跳过、返回已
/// 解析到的名字（诚实降级，绝不抛）。
Set<String> parseSfntFamilyNames(Uint8List bytes) {
  final Set<String> out = <String>{};
  try {
    if (bytes.length < 12) return out;
    final ByteData data = ByteData.sublistView(bytes);
    final int tag = data.getUint32(0);
    const int ttcfTag = 0x74746366; // 'ttcf'
    if (tag == ttcfTag) {
      // TTC 头：'ttcf'(4) major(2) minor(2) numFonts(uint32@8) offsets[numFonts]。
      if (bytes.length < 12) return out;
      final int numFonts = data.getUint32(8);
      for (int i = 0; i < numFonts; i++) {
        final int offPos = 12 + i * 4;
        if (offPos + 4 > bytes.length) break;
        final int fontOffset = data.getUint32(offPos);
        _parseSfntNameTableAt(data, bytes.length, fontOffset, out);
      }
    } else {
      _parseSfntNameTableAt(data, bytes.length, 0, out);
    }
  } catch (_) {
    // 越界 / 非法字体：返回已解析到的（可能为空），不抛。
  }
  return out;
}

/// 解析从 [base] 偏移开始的单个 sfnt 表目录里的 `name` 表，family 名并入 [out]。
void _parseSfntNameTableAt(
  ByteData data,
  int length,
  int base,
  Set<String> out,
) {
  if (base + 12 > length) return;
  final int numTables = data.getUint16(base + 4);
  int nameOffset = -1;
  for (int i = 0; i < numTables; i++) {
    final int rec = base + 12 + i * 16;
    if (rec + 16 > length) return;
    final int recTag = data.getUint32(rec);
    const int nameTag = 0x6E616D65; // 'name'
    if (recTag == nameTag) {
      nameOffset = data.getUint32(rec + 8);
      break;
    }
  }
  if (nameOffset < 0 || nameOffset + 6 > length) return;

  final int count = data.getUint16(nameOffset + 2);
  final int stringStorage = nameOffset + data.getUint16(nameOffset + 4);
  for (int i = 0; i < count; i++) {
    final int rec = nameOffset + 6 + i * 12;
    if (rec + 12 > length) return;
    final int platformId = data.getUint16(rec);
    final int nameId = data.getUint16(rec + 6);
    // 只要 Family(1) 与 Typographic Family(16)。
    if (nameId != 1 && nameId != 16) continue;
    final int strLen = data.getUint16(rec + 8);
    final int strOff = stringStorage + data.getUint16(rec + 10);
    if (strLen <= 0 || strOff + strLen > length) continue;
    final Uint8List raw =
        data.buffer.asUint8List(data.offsetInBytes + strOff, strLen);
    final String? name = _decodeNameRecord(platformId, raw);
    if (name != null && name.trim().isNotEmpty) out.add(name.trim());
  }
}

/// 按 platformID 解码 name 记录字节：Windows(3)/Unicode(0) 是 UTF-16BE；Mac(1) 近似
/// Latin1（ASCII 安全，日文 Mac 记录罕见，解不出就交给 UTF-16 记录兜底）。
String? _decodeNameRecord(int platformId, Uint8List raw) {
  try {
    if (platformId == 3 || platformId == 0) {
      // UTF-16BE。
      if (raw.length.isOdd) return null;
      final StringBuffer sb = StringBuffer();
      for (int i = 0; i + 1 < raw.length; i += 2) {
        sb.writeCharCode((raw[i] << 8) | raw[i + 1]);
      }
      return sb.toString();
    }
    // Mac / 其它：Latin1 兜底。
    return latin1.decode(raw, allowInvalid: true);
  } catch (_) {
    return null;
  }
}

/// 从视频容器抽取内嵌字体附件、注册进 Flutter 引擎，供自绘字幕 overlay 按 ASS
/// `Fontname` 命中真实字体（对齐 mpv/libass 的 attachment 字体加载）。
///
/// 背景：Hibiki 自绘渲染字幕（为逐字查词，不走 libass），故不像 mpv 那样自动加载 MKV
/// 内嵌字体 → 商用日文字体缺失时 fallback 替换、观感与 mpv 差。本加载器补上这条链路：
/// ffmpeg `-i` 枚举附件 → ffmpeg `-dump_attachment` 抽到临时目录 → 解析每个字体的 sfnt
/// name 表拿 family 名 → [FontLoader] 注册。注册后 overlay 的 `_styleForGrapheme` 用
/// `cue.fontName` 作 `fontFamily` 即可命中（无需改 overlay）。全程只用 ffmpeg（与内嵌
/// 字幕枚举同一可用工具），不依赖桌面常缺的 ffprobe（BUG-829）。
///
/// 降级链（任一失败都不崩、回退系统字体）：非本地文件 / 无 ffmpeg / 无附件 / 解析失败
/// → 返回空集，overlay 继续走既有 CJK fallback。
class SubtitleEmbeddedFontLoader {
  SubtitleEmbeddedFontLoader({FfmpegBackend? backend})
      : _backend = backend ?? resolveFfmpegBackend();

  final FfmpegBackend _backend;

  /// 已注册的 family 名（[FontLoader] 不能卸载，重复注册无意义）。进程级去重。
  static final Set<String> _registeredFamilies = <String>{};

  /// 按视频路径缓存本次解析出的 family 名集，避免同一视频反复抽取。
  final Map<String, Set<String>> _byVideoPath = <String, Set<String>>{};

  static const Duration _probeTimeout = Duration(seconds: 20);
  static const Duration _dumpTimeout = Duration(seconds: 40);

  /// 为 [videoPath] 加载内嵌字体，返回**成功注册**的 family 名集合（可空）。幂等：
  /// 同一路径二次调用直接回缓存。非本地存在文件直接返回空集（网络流 / HLS 无附件可抽）。
  Future<Set<String>> loadForVideo(String videoPath) async {
    if (videoPath.isEmpty) return const <String>{};
    final Set<String>? cached = _byVideoPath[videoPath];
    if (cached != null) return cached;

    final Set<String> families = <String>{};
    try {
      if (!File(videoPath).existsSync()) {
        _byVideoPath[videoPath] = families;
        return families;
      }
      final List<EmbeddedFontAttachment> fonts =
          await _enumerateFontAttachments(videoPath);
      if (fonts.isEmpty) {
        _byVideoPath[videoPath] = families;
        return families;
      }
      final Directory tempDir =
          await Directory.systemTemp.createTemp('hibiki_subfonts_');
      try {
        final List<File> extracted =
            await _dumpAttachments(videoPath, fonts, tempDir);
        for (final File file in extracted) {
          await _registerFontFile(file, families);
        }
      } finally {
        // 注册后字节已进引擎，临时文件可删（best-effort）。
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    } catch (e, stack) {
      ErrorLogService.instance
          .log('SubtitleEmbeddedFontLoader.loadForVideo', e, stack);
    }
    _byVideoPath[videoPath] = families;
    return families;
  }

  /// 用 ffmpeg `-i` 枚举字体附件流（解析其 stderr 日志）。失败返回空列表。
  ///
  /// **只用 ffmpeg**（与内嵌字幕枚举同一工具、同一 backend），不用 ffprobe：桌面 ffprobe
  /// 常未随产物捆绑、也不在 PATH，旧的 `runProbe` 路径会因 `Process.start` 抛
  /// [ProcessException]，内封字体在缺 ffprobe 的机器上**根本枚举不到**（BUG-829）。改走
  /// ffmpeg 后，「能列内嵌字幕的机器就能列内嵌字体」，内封字体真正生效。
  ///
  /// `-i` 无输出文件恒非 0 退出，但流信息已写 stderr（= [FfmpegRunResult.output]），故
  /// **只看 output 不看退出码**（与 `parseSubtitleStreamsFromFfmpegLog` 调用点一致）。
  /// 连 ffmpeg 都缺（[ProcessException]）时就地兜住返回空集：这是预期降级、非应用错误，
  /// 不放它穿到 [loadForVideo] 兜底 catch 被当「报错」刷进 [ErrorLogService]。
  Future<List<EmbeddedFontAttachment>> _enumerateFontAttachments(
    String videoPath,
  ) async {
    final FfmpegRunResult probe;
    try {
      probe = await _backend.run(
        <String>['-hide_banner', '-i', videoPath],
        _probeTimeout,
      );
    } on ProcessException {
      // 连 ffmpeg 也无可执行：预期降级，非错误，不记日志。
      return const <EmbeddedFontAttachment>[];
    }
    return parseFfmpegFontAttachments(probe.output);
  }

  /// 一次 ffmpeg 调用把所有字体附件抽到 [tempDir]（`-dump_attachment:t:<ordinal>`）。
  /// ffmpeg 无输出文件会以非 0 退出但**附件已在输入解析阶段写盘**，故不看退出码，只收集
  /// 真正写出的文件。
  Future<List<File>> _dumpAttachments(
    String videoPath,
    List<EmbeddedFontAttachment> fonts,
    Directory tempDir,
  ) async {
    final List<String> args = <String>['-y'];
    final List<File> targets = <File>[];
    for (final EmbeddedFontAttachment font in fonts) {
      final String ext = _fontExtension(font.fileName);
      final File out = File(p.join(
        tempDir.path,
        'font_${font.attachmentOrdinal}$ext',
      ));
      args
        ..add('-dump_attachment:t:${font.attachmentOrdinal}')
        ..add(out.path);
      targets.add(out);
    }
    args
      ..add('-i')
      ..add(videoPath);
    // 退出码忽略（无输出文件恒非 0）；只认写出的文件。
    await _backend.run(args, _dumpTimeout);
    return <File>[
      for (final File f in targets)
        if (f.existsSync() && f.lengthSync() > 0) f,
    ];
  }

  /// 读字体文件 → 解析 family 名 → 按每个 family 名注册（同字节可挂多名）。
  Future<void> _registerFontFile(File file, Set<String> families) async {
    final Uint8List bytes = await file.readAsBytes();
    final Set<String> names = parseSfntFamilyNames(bytes);
    if (names.isEmpty) return;
    for (final String family in names) {
      families.add(family);
      if (_registeredFamilies.contains(family)) continue;
      try {
        final FontLoader loader = FontLoader(family)
          ..addFont(Future<ByteData>.value(
            bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes),
          ));
        await loader.load();
        _registeredFamilies.add(family);
      } catch (e, stack) {
        ErrorLogService.instance
            .log('SubtitleEmbeddedFontLoader.register($family)', e, stack);
      }
    }
  }

  /// 附件文件名的字体扩展名，缺失/异常回退 `.ttf`（仅决定临时文件名，不影响解析）。
  String _fontExtension(String fileName) {
    final String ext = p.extension(fileName).toLowerCase();
    if (ext == '.ttf' || ext == '.otf' || ext == '.ttc') return ext;
    return '.ttf';
  }
}

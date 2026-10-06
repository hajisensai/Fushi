/// 字幕压缩包（整季包）解包：所有字幕来源共用的唯一实现。
///
/// 最早只长在 SubDL 里（`extractSubdlSubtitles`）——SubDL 的下载体本来就是 zip。
/// Jimaku 上大量老番只有整季 zip / rar / 7z（BUG-3000 跟进），于是抽到这里，
/// SubDL 与 Jimaku 共用同一套「解 zip → 只留文本字幕 → 按集号挑」的判据。
///
/// 只能解 zip：仓库没有 RAR / 7z 解码依赖（`archive` 3.x 不支持这两种）。遇到它们
/// 明确抛 [ExternalProviderFailureKind.unsupported]，绝不把压缩流当文本落盘。
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart'
    show parseSubtitleEpisode;

/// 可被播放页解析的文本字幕扩展名（与 Jimaku / AJATT 的 `isTextSubtitle` 同一集合）。
const Set<String> kTextSubtitleExtensions = <String>{
  'srt',
  'ass',
  'ssa',
  'vtt'
};

/// 字幕压缩包格式。只有 [zip] 能解。
enum SubtitleArchiveFormat {
  zip,
  rar,
  sevenZip;

  /// 本仓能否解开这种包。
  bool get isSupported => this == SubtitleArchiveFormat.zip;

  /// 给用户看的格式名。
  String get label => switch (this) {
        SubtitleArchiveFormat.zip => 'ZIP',
        SubtitleArchiveFormat.rar => 'RAR',
        SubtitleArchiveFormat.sevenZip => '7z',
      };
}

/// 按文件名扩展名判断是不是字幕压缩包；不是返回 null。纯函数。
SubtitleArchiveFormat? subtitleArchiveFormatForName(String fileName) =>
    switch (_extensionOf(fileName)) {
      'zip' => SubtitleArchiveFormat.zip,
      'rar' => SubtitleArchiveFormat.rar,
      '7z' => SubtitleArchiveFormat.sevenZip,
      _ => null,
    };

/// 压缩包里挑出来的一个文本字幕文件。
class ArchivedSubtitle {
  const ArchivedSubtitle({required this.fileName, required this.bytes});

  final String fileName;
  final Uint8List bytes;
}

/// 按字节魔数认格式（扩展名会骗人：SubDL 有 RAR 伪装成 `.zip` 的老上传）。
SubtitleArchiveFormat? sniffSubtitleArchiveFormat(Uint8List bytes) {
  bool startsWith(List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (int i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(const <int>[0x50, 0x4B, 0x03, 0x04])) {
    return SubtitleArchiveFormat.zip;
  }
  if (startsWith(const <int>[0x52, 0x61, 0x72, 0x21])) {
    return SubtitleArchiveFormat.rar;
  }
  if (startsWith(const <int>[0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) {
    return SubtitleArchiveFormat.sevenZip;
  }
  return null;
}

/// 压缩包相关失败的 `operation`：UI 据此把 unsupported / notFound 说成「解不开这种
/// 包」/「包里没有这一集」，而不是笼统的下载失败。
const String kSubtitleArchiveOperation = 'archive';

/// 解不开的压缩包格式统一抛这个失败（UI 据 `kind == unsupported` 给「暂不支持解包」）。
ExternalProviderFailure unsupportedSubtitleArchiveFailure(
  String providerId,
  SubtitleArchiveFormat format,
) =>
    ExternalProviderFailure(
      providerId: providerId,
      operation: kSubtitleArchiveOperation,
      kind: ExternalProviderFailureKind.unsupported,
      message: '$providerId returned a ${format.label} archive, '
          'which is not supported',
    );

/// 把下载体（zip / 裸字幕）解成文本字幕文件列表。纯函数，便于单测。
///
/// - zip：跳过目录、`__MACOSX/` 与 `._` AppleDouble 残渣，只留
///   [kTextSubtitleExtensions]；
/// - RAR / 7z：没有解码依赖，抛 [unsupportedSubtitleArchiveFailure]；
/// - 其余按裸字幕文件处理（站点偶尔直接回单文件），文件名用 [fallbackFileName]。
List<ArchivedSubtitle> extractArchivedSubtitles(
  Uint8List bytes, {
  required String fallbackFileName,
  required String providerId,
}) {
  final SubtitleArchiveFormat? format = sniffSubtitleArchiveFormat(bytes);
  if (format == null) {
    return <ArchivedSubtitle>[
      ArchivedSubtitle(fileName: fallbackFileName, bytes: bytes),
    ];
  }
  if (!format.isSupported) {
    throw unsupportedSubtitleArchiveFailure(providerId, format);
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: true);
  } on Object {
    throw ExternalProviderFailure(
      providerId: providerId,
      operation: 'download',
      kind: ExternalProviderFailureKind.invalidResponse,
      message: '$providerId archive could not be decoded',
    );
  }
  final List<ArchivedSubtitle> out = <ArchivedSubtitle>[];
  for (final ArchiveFile file in archive.files) {
    if (!file.isFile) continue;
    final String path = file.name.replaceAll('\\', '/');
    if (path.startsWith('__MACOSX/') || path.contains('/__MACOSX/')) continue;
    final String baseName = path.substring(path.lastIndexOf('/') + 1);
    if (baseName.isEmpty || baseName.startsWith('._')) continue;
    if (!kTextSubtitleExtensions.contains(_extensionOf(baseName))) continue;
    final Object? content = file.content;
    if (content is! List<int>) continue;
    out.add(
      ArchivedSubtitle(
        fileName: baseName,
        bytes: content is Uint8List ? content : Uint8List.fromList(content),
      ),
    );
  }
  return out;
}

/// 多文件包里挑出要用的那一个。纯函数，便于单测。
///
/// 只有一个直接用；没给集号用第一个（zip 内顺序通常就是集序）；给了集号按文件名
/// 解析集号（[parseSubtitleEpisode]）取命中的第一个。命中不了时：
/// [fallbackToFirst] 为 true 退回第一个（SubDL 的既有语义：它的包由服务端按集号
/// 区间圈过）；为 false 返回 null——整季包里挑不出这一集时，给第一集的字幕等于
/// 静默装错（Jimaku 用这一档）。
ArchivedSubtitle? pickArchivedSubtitle(
  List<ArchivedSubtitle> files, {
  int? episode,
  bool fallbackToFirst = true,
}) {
  if (files.isEmpty) return null;
  if (files.length == 1 || episode == null) return files.first;
  for (final ArchivedSubtitle file in files) {
    if (parseSubtitleEpisode(file.fileName) == episode) return file;
  }
  return fallbackToFirst ? files.first : null;
}

String _extensionOf(String fileName) {
  final int dot = fileName.lastIndexOf('.');
  return dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
}

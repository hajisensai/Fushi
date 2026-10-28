import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// The disc's own library artwork: `BDMV/META/DL/bdmt_<lang>.xml` ("disclib"
/// metadata) names thumbnails that sit beside it, e.g.
/// `<di:thumbnail href="./L.jpg" size="640x360"/>`. Authored by the publisher,
/// so it tells discs of one work apart where the scraped poster cannot.
class BlurayDiscThumbnail {
  const BlurayDiscThumbnail({
    required this.href,
    required this.width,
    required this.height,
  });

  /// Relative to `BDMV/META/DL`, already checked to stay inside it.
  final String href;
  final int width;
  final int height;
}

/// Languages tried first, in order; any other language follows by file name.
const List<String> kBlurayDiscThumbnailLanguages = <String>['jpn', 'eng'];

/// Every usable thumbnail one disclib document declares. Unknown `size`
/// counts as 0x0 so it still beats nothing but loses to any sized entry.
List<BlurayDiscThumbnail> parseBlurayDiscThumbnails(String xmlSource) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(xmlSource);
  } on XmlException {
    return const <BlurayDiscThumbnail>[];
  }
  final List<BlurayDiscThumbnail> thumbnails = <BlurayDiscThumbnail>[];
  for (final XmlElement element
      in document.descendants.whereType<XmlElement>()) {
    if (element.name.local != 'thumbnail') continue;
    final String? href = _containedHref(element.getAttribute('href'));
    if (href == null) continue;
    final RegExpMatch? size = RegExp(
      r'^\s*(\d{1,5})\s*x\s*(\d{1,5})\s*$',
    ).firstMatch(element.getAttribute('size') ?? '');
    thumbnails.add(
      BlurayDiscThumbnail(
        href: href,
        width: size == null ? 0 : int.parse(size.group(1)!),
        height: size == null ? 0 : int.parse(size.group(2)!),
      ),
    );
  }
  return thumbnails;
}

/// Disc metadata is untrusted: only plain names inside `META/DL` qualify.
String? _containedHref(String? raw) {
  if (raw == null) return null;
  final String trimmed = raw.trim().replaceAll('\\', '/');
  if (trimmed.isEmpty || trimmed.contains(':')) return null;
  final String normalized = p.posix.normalize(trimmed);
  if (p.posix.isAbsolute(normalized) ||
      normalized == '.' ||
      normalized.split('/').contains('..')) {
    return null;
  }
  return normalized;
}

/// Orders `bdmt_<lang>.xml` names by [preferredLanguages], then by name.
List<String> orderBlurayDiscMetadataFiles(
  Iterable<String> fileNames, {
  List<String> preferredLanguages = kBlurayDiscThumbnailLanguages,
}) {
  int rank(String name) {
    final String lang = name.substring(5, name.length - 4).toLowerCase();
    final int index = preferredLanguages.indexOf(lang);
    return index < 0 ? preferredLanguages.length : index;
  }

  final List<String> names = <String>[
    for (final String name in fileNames)
      if (RegExp(r'^bdmt_[A-Za-z]{3}\.xml$').hasMatch(name)) name,
  ];
  names.sort((String a, String b) {
    final int byRank = rank(a).compareTo(rank(b));
    return byRank != 0 ? byRank : a.compareTo(b);
  });
  return names;
}

/// Absolute path of the disc's artwork under [discRootPath], or null when the
/// disc declares none that exists. The first language (see
/// [orderBlurayDiscMetadataFiles]) with an existing thumbnail wins; within it,
/// the largest.
Future<String?> findBlurayDiscThumbnail(
  String discRootPath, {
  List<String> preferredLanguages = kBlurayDiscThumbnailLanguages,
}) async {
  final Directory dl = Directory(p.join(discRootPath, 'BDMV', 'META', 'DL'));
  final List<String> names;
  try {
    names = <String>[
      await for (final FileSystemEntity e in dl.list(followLinks: false))
        if (e is File) p.basename(e.path),
    ];
  } on FileSystemException {
    return null;
  }
  for (final String name in orderBlurayDiscMetadataFiles(
    names,
    preferredLanguages: preferredLanguages,
  )) {
    final File xml = File(p.join(dl.path, name));
    try {
      // Bound allocation for malformed/untrusted disc metadata.
      if (await xml.length() > 256 * 1024) continue;
      final List<BlurayDiscThumbnail> declared =
          parseBlurayDiscThumbnails(await xml.readAsString())..sort(
            (BlurayDiscThumbnail a, BlurayDiscThumbnail b) =>
                (b.width * b.height).compareTo(a.width * a.height),
          );
      for (final BlurayDiscThumbnail t in declared) {
        final String path = p.joinAll(<String>[dl.path, ...t.href.split('/')]);
        if (await File(path).exists()) return path;
      }
    } on FileSystemException {
      continue;
    } on FormatException {
      continue;
    }
  }
  return null;
}

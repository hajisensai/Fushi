import 'dart:convert';

import 'package:fushi_engine/media/manga/mokuro_payload.dart';

class MokuroSidecarMergeResult {
  const MokuroSidecarMergeResult({
    required this.payload,
    required this.matchedPages,
  });
  final MokuroPayload payload;
  final int matchedPages;
  bool get accepted => matchedPages > 0;
}

MokuroSidecarMergeResult mergeMokuroSidecar({
  required MokuroPayload downloaded,
  required String sidecarJson,
  List<String>? sourceUrls,
}) {
  final MokuroPayload sidecar;
  try {
    sidecar = parseMokuro(sidecarJson);
  } on Object {
    return MokuroSidecarMergeResult(payload: downloaded, matchedPages: 0);
  }
  if (sidecar.images.isEmpty || downloaded.images.isEmpty) {
    return MokuroSidecarMergeResult(payload: downloaded, matchedPages: 0);
  }
  final List<MokuroImage> merged = <MokuroImage>[...downloaded.images];
  final Set<int> used = <int>{};
  int matched = 0;
  for (final MokuroImage overlay in sidecar.images) {
    final List<int> candidates = <int>[];
    for (int index = 0; index < downloaded.images.length; index++) {
      if (used.contains(index)) continue;
      final String source = sourceUrls != null && index < sourceUrls.length
          ? sourceUrls[index]
          : '';
      if (_samePage(overlay.url, downloaded.images[index].url) ||
          (source.isNotEmpty && _samePage(overlay.url, source))) {
        candidates.add(index);
      }
    }
    if (candidates.length != 1) continue;
    final int index = candidates.single;
    final MokuroImage original = downloaded.images[index];
    if (!_validDimensions(overlay.size, original.size)) continue;
    final List<MokuroBlock> blocks = <MokuroBlock>[];
    final Set<String> seen = <String>{};
    for (final MokuroBlock block in overlay.blocks) {
      if (!_validBlock(block, overlay.size)) continue;
      final String key = jsonEncode(<Object?>[
        block.rectangle.left,
        block.rectangle.top,
        block.rectangle.right,
        block.rectangle.bottom,
        block.lines,
      ]);
      if (seen.add(key)) blocks.add(block);
    }
    used.add(index);
    merged[index] = MokuroImage(
      url: original.url,
      size: original.size,
      blocks: List<MokuroBlock>.unmodifiable(blocks),
    );
    matched++;
  }
  if (matched == 0) {
    return MokuroSidecarMergeResult(payload: downloaded, matchedPages: 0);
  }
  return MokuroSidecarMergeResult(
    payload: MokuroPayload(
      images: List<MokuroImage>.unmodifiable(merged),
      ocr: const MangaOcrMetadata(
        engine: 'mokuro-sidecar',
        engineSignature: 'mokuro.moe',
        schemaVersion: 1,
      ),
    ),
    matchedPages: matched,
  );
}

bool _samePage(String a, String b) {
  final String left = _pageKey(a);
  final String right = _pageKey(b);
  if (left.isEmpty || right.isEmpty) return false;
  return left == right || left.endsWith('/$right') || right.endsWith('/$left');
}

String _pageKey(String value) {
  final String normalized = normalizeMangaUrl(value.trim()).toLowerCase();
  if (normalized.isEmpty) return '';
  final String leaf = normalized.split('/').last;
  final RegExpMatch? numbered = RegExp(
    r'(?:page[-_] )?(\d+)(\.[a-z0-9]+)$'.replaceAll(' ', ''),
  ).firstMatch(leaf);
  if (numbered != null) {
    return '#${int.parse(numbered.group(1)!)}${numbered.group(2)}';
  }
  return normalized;
}

bool _validDimensions(MokuroSize sidecar, MokuroSize actual) =>
    sidecar.width > 0 &&
    sidecar.height > 0 &&
    (sidecar.width - actual.width).abs() < 0.5 &&
    (sidecar.height - actual.height).abs() < 0.5;

bool _validBlock(MokuroBlock block, MokuroSize size) {
  final MokuroRect r = block.rectangle;
  return r.left.isFinite &&
      r.top.isFinite &&
      r.right.isFinite &&
      r.bottom.isFinite &&
      r.left >= 0 &&
      r.top >= 0 &&
      r.right <= size.width &&
      r.bottom <= size.height &&
      r.right > r.left &&
      r.bottom > r.top;
}

bool looksLikeMokuroSidecar(String body) {
  try {
    final Object? value = jsonDecode(body);
    return value is Map &&
        value['pages'] is List &&
        (value['pages'] as List).isNotEmpty;
  } on Object {
    return false;
  }
}

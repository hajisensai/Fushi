import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const Set<String> _sourceExtensions = <String>{
  '.dart',
  '.c',
  '.cc',
  '.cpp',
  '.cxx',
  '.h',
  '.hpp',
  '.inc',
};

const List<String> _lookupSourceRoots = <String>[
  'lib/src/lookup',
  'lib/src/platform',
  'lib/src/pages/implementations',
  'windows/runner',
  '../native/galgame_hook/hook',
  '../native/galgame_hook/include',
];

const List<String> _lookupSemanticMarkers = <String>[
  'galattached',
  'galingame',
  'gallookup',
  'gal_lookup',
  'attachedtextsurface',
  'attachedlookup',
  'lookuphit',
  'lookup_hit',
  'lookupgeometry',
  'lookup_geometry',
  'lookupshield',
  'lookup_shield',
  'geometryproviderregistry',
  'geometry_provider_registry',
  'lowlevelmousehook',
  'low_level_mouse_hook',
];

const Map<String, String> _forbiddenOcrApiNeedles = <String, String>{
  'package:fushi/src/ocr/': 'Fushi OCR package import',
  'package:fushi/src/media/manga/ocr/': 'manga OCR package import',
  'windows.media.ocr': 'Windows.Media.Ocr API',
  'windows::media::ocr': 'Windows::Media::Ocr API',
  'ocrengine': 'system OCR engine API',
  'paddleocr': 'PaddleOCR API',
  'tesseract': 'Tesseract API',
  'textrecognizer': 'text recognizer API',
  'recognizeasync(': 'asynchronous text recognition API',
  'mokuro': 'mokuro OCR integration',
};

String _normalizedPath(String path) => path.replaceAll('\\', '/').toLowerCase();

String _extensionOf(String path) {
  final String normalized = _normalizedPath(path);
  final int slash = normalized.lastIndexOf('/');
  final int dot = normalized.lastIndexOf('.');
  return dot > slash ? normalized.substring(dot) : '';
}

Iterable<File> _candidateSourceFiles() sync* {
  for (final String rootPath in _lookupSourceRoots) {
    final Directory root = Directory(rootPath);
    expect(
      root.existsSync(),
      isTrue,
      reason: 'missing lookup source root $rootPath',
    );
    for (final FileSystemEntity entity in root.listSync(recursive: true)) {
      if (entity is! File ||
          !_sourceExtensions.contains(_extensionOf(entity.path))) {
        continue;
      }
      final String path = _normalizedPath(entity.path);
      if (path.contains('/test/') || path.contains('/tests/')) continue;
      yield entity;
    }
  }
}

bool _isProductionLookupSource(File file, String source) {
  final String path = _normalizedPath(file.path);
  final String name = path.substring(path.lastIndexOf('/') + 1);
  final String lower = source.toLowerCase();

  // Dart lookup files are selected by their Galgame-specific name or symbols;
  // unrelated reader/video/global lookup implementations remain outside this
  // Windows-only guard and may keep their own platform capabilities.
  if (path.contains('/lib/src/lookup/')) {
    return name.startsWith('gal_') ||
        _lookupSemanticMarkers.any(lower.contains);
  }
  if (path.contains('/lib/src/platform/') ||
      path.contains('/lib/src/pages/implementations/')) {
    return (name.startsWith('gal_') && lower.contains('lookup')) ||
        _lookupSemanticMarkers.any(lower.contains);
  }

  // Native routing files do not all have "lookup" in their filename
  // (flutter_window.cpp and exact engine adapters are examples). Selecting by
  // production contract symbols automatically follows future split files and
  // providers without extending a hand-maintained filename allow-list.
  return name.contains('lookup') || _lookupSemanticMarkers.any(lower.contains);
}

void main() {
  test('all discovered Galgame lookup production sources stay OCR-free', () {
    final Map<String, String> productionSources = <String, String>{};
    for (final File file in _candidateSourceFiles()) {
      final String source = file.readAsStringSync();
      if (_isProductionLookupSource(file, source)) {
        productionSources[_normalizedPath(file.path)] = source;
      }
    }

    expect(
      productionSources.length,
      greaterThanOrEqualTo(20),
      reason: 'lookup source discovery unexpectedly collapsed',
    );
    for (final String root in <String>[
      'lib/src/lookup/',
      'lib/src/platform/',
      'lib/src/pages/implementations/',
      'windows/runner/',
      'native/galgame_hook/hook/',
      'native/galgame_hook/include/',
    ]) {
      expect(
        productionSources.keys.any((String path) => path.contains(root)),
        isTrue,
        reason: 'lookup source discovery missed $root',
      );
    }

    final List<String> violations = <String>[];
    for (final MapEntry<String, String> entry in productionSources.entries) {
      final String lower = entry.value.toLowerCase();
      for (final MapEntry<String, String> forbidden
          in _forbiddenOcrApiNeedles.entries) {
        if (lower.contains(forbidden.key)) {
          violations.add('${entry.key}: ${forbidden.value}');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          'Galgame lookup production sources must never invoke OCR. '
          'The guard intentionally scans executable API/import tokens rather '
          'than the bare acronym, so no-OCR UI text and comments remain legal.\n'
          '${violations.join('\n')}',
    );
  });

  test(
    'attached child owns neither a session listener nor a channel listener',
    () {
      final String child = File(
        'lib/src/lookup/gal_attached_text_controller.dart',
      ).readAsStringSync();
      final String central = File(
        'lib/src/lookup/gal_hook_text_overlay_controller.dart',
      ).readAsStringSync();

      expect(child, isNot(contains('.addListener(')));
      expect(child, isNot(contains('setMethodCallHandler(')));
      expect(
        RegExp(r'_session\.addListener\(').allMatches(central),
        hasLength(1),
        reason: 'gal session 只能由 central overlay controller 监听一次',
      );
    },
  );
}

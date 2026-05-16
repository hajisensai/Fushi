import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

class RecommendedDictionary {
  const RecommendedDictionary({
    required this.name,
    required this.url,
    required this.description,
    required this.matchPrefix,
  });

  final String name;
  final String url;
  final String description;

  /// Stable prefix to detect if this dictionary is already installed.
  /// Matched with `startsWith` against installed dictionary names.
  final String matchPrefix;
}

class DictionaryDownloader {
  DictionaryDownloader._();

  static const List<RecommendedDictionary> recommended = [
    RecommendedDictionary(
      name: 'JMdict (English)',
      url:
          'https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/JMdict_english.zip',
      description: 'Japanese-English dictionary (~22 MB)',
      matchPrefix: 'JMdict',
    ),
    RecommendedDictionary(
      name: 'JPDB Frequency',
      url:
          'https://github.com/MarvNC/jpdb-freq-list/releases/latest/download/JPDB.Frequency.List.zip',
      description: 'Word frequency data (~1 MB)',
      matchPrefix: 'JPDB',
    ),
  ];

  static Future<File> download({
    required String url,
    required Directory tempDir,
    required ValueNotifier<double> progressNotifier,
    CancelToken? cancelToken,
  }) async {
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }

    final String fileName = Uri.parse(url).pathSegments.last;
    final String destPath = path.join(tempDir.path, fileName);
    final Dio dio = Dio();

    try {
      await dio.download(
        url,
        destPath,
        cancelToken: cancelToken,
        options: Options(
          followRedirects: true,
          maxRedirects: 5,
        ),
        onReceiveProgress: (int received, int total) {
          if (total > 0) {
            progressNotifier.value = received / total;
          }
        },
      );
      return File(destPath);
    } finally {
      dio.close();
    }
  }
}

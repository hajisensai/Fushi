import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

/// Fetches term audio from local Yomitan audio DB, online sources, or TTS.
class LocalAudioEnhancement extends AudioEnhancement {
  LocalAudioEnhancement({required super.field})
      : super(
          uniqueKey: key,
          label: 'Local Audio',
          description:
              'Fetch audio from the local database, online sources, or TTS.',
          icon: Icons.audio_file,
        );

  static const String key = 'local_audio';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_enhancement_local_audio;

  @override
  Future<void> enhanceCreatorParams({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required EnhancementTriggerCause cause,
  }) async {
    final audioField = field as AudioExportField;

    String term = creatorModel.getFieldController(TermField.instance).text.trim();
    String reading =
        creatorModel.getFieldController(ReadingField.instance).text.trim();

    if (term.isEmpty) return;

    await audioField.setAudio(
      cause: cause,
      appModel: appModel,
      creatorModel: creatorModel,
      newAutoCannotOverride: true,
      searchTerm: term,
      generateAudio: () => _generateAudio(appModel, term, reading),
    );
  }

  Future<File?> _generateAudio(
      AppModel appModel, String term, String reading) async {
    // 1. Local audio database: query metadata, then extract blob
    if (appModel.localAudioEnabled) {
      try {
        final info = await TtsChannel.instance
            .queryLocalAudio(term, reading)
            .timeout(const Duration(milliseconds: 500));
        if (info != null) {
          final path = await TtsChannel.instance
              .extractLocalAudio(info['file']!, info['source']!);
          if (path != null && path.isNotEmpty) {
            final file = File(path);
            if (file.existsSync()) return file;
          }
        }
      } on TimeoutException {
        // Fall through
      }
    }

    // 2. TTS to file
    final dir = await getApplicationSupportDirectory();
    final outPath = '${dir.path}/tts_term_audio.wav';
    final word = reading.isNotEmpty ? reading : term;
    final result = await TtsChannel.instance.ttsToFile(word, outPath);
    if (result != null) {
      final file = File(result);
      if (file.existsSync()) return file;
    }

    return null;
  }

  @override
  Future<File?> fetchAudio({
    required AppModel appModel,
    required BuildContext context,
    required String term,
    required String reading,
  }) async {
    return _generateAudio(appModel, term, reading);
  }
}

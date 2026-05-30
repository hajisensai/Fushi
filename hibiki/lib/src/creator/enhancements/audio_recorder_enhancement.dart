import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// An enhancement that can be used to record audio.
class AudioRecorderEnhancement extends AudioEnhancement {
  /// Initialise this enhancement with the hardset parameters.
  AudioRecorderEnhancement({required super.field})
      : super(
          uniqueKey: key,
          label: 'Audio Recorder',
          description:
              'Record and use audio captured from the device microphone.',
          icon: Icons.mic_outlined,
        );

  /// Used to identify this enhancement and to allow a constant value for the
  /// default mappings value of [AnkiMapping].
  static const String key = 'audio_recorder';

  /// Whether audio recording is available on the current platform.
  ///
  /// record supports Android/iOS/macOS/Windows/Linux. On Linux the encoder
  /// needs system tools (parecord/pactl/ffmpeg) present; without them start()
  /// throws at runtime and the recorder dialog falls back gracefully.
  static bool get isAvailable => true;

  @override
  String getLocalisedLabel(AppModel appModel) =>
      t.creator_enhancement_audio_recorder;

  @override
  Future<void> enhanceCreatorParams({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required EnhancementTriggerCause cause,
  }) async {
    AudioExportField audioField = field as AudioExportField;

    Directory appDirDoc = await getApplicationSupportDirectory();
    String tempAudioPath =
        '${appDirDoc.path}/${field.uniqueKey}/audioRecorderTemp';
    Directory tempAudioDirectory = Directory(tempAudioPath);

    String tempTimestamp = DateFormat('yyyyMMddTkkmmss').format(DateTime.now());

    Directory tempTimestampDirectory =
        Directory('$tempAudioPath/$tempTimestamp');
    tempTimestampDirectory.createSync(recursive: true);
    String tempFilePath = '${tempTimestampDirectory.path}/audio.m4a';
    if (context.mounted) {
      await showAppDialog<File?>(
        context: context,
        builder: (_) => AudioRecorderDialogPage(
          filePath: tempFilePath,
          onSave: (tempFile) {
            String audioRecorderPath =
                '${appDirDoc.path}/${field.uniqueKey}/audioRecorder';
            Directory audioRecorderDirectory = Directory(audioRecorderPath);
            if (audioRecorderDirectory.existsSync()) {
              audioRecorderDirectory.deleteSync(recursive: true);
            }
            audioRecorderDirectory.createSync(recursive: true);

            String finalTimestamp =
                DateFormat('yyyyMMddTkkmmss').format(DateTime.now());
            Directory finalTimestampDirectory =
                Directory('$audioRecorderPath/$finalTimestamp');
            String finalFilePath = '${finalTimestampDirectory.path}/audio.m4a';

            finalTimestampDirectory.createSync(recursive: true);
            tempFile.copySync(finalFilePath);

            tempAudioDirectory.deleteSync(recursive: true);

            audioField.setAudio(
              cause: cause,
              appModel: appModel,
              creatorModel: creatorModel,
              newAutoCannotOverride: false,
              generateAudio: () async {
                return File(finalFilePath);
              },
            );
          },
        ),
      );
    }
  }

  @override
  Future<File?> fetchAudio({
    required AppModel appModel,
    required BuildContext context,
    required String term,
    required String reading,
  }) async {
    return null;
  }
}

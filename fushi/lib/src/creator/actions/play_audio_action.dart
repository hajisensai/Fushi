import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:fushi/src/creator/enhancements/local_audio_enhancement.dart';
import 'package:fushi/src/creator/fields/audio_field.dart';
import 'package:fushi/src/creator/quick_action.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/creator/creator_model.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// An enhancement used effectively as a shortcut for previewing audio.
class PlayAudioAction extends QuickAction {
  /// Initialise this enhancement with the hardset parameters.
  PlayAudioAction()
    : super(
        uniqueKey: key,
        label: 'Play Audio',
        description:
            'Attempts to play audio based on the Audio enhancements. The auto'
            ' is the top priority.',
        icon: Icons.play_circle_outline,
      );

  final AudioPlayer _audioPlayer = AudioPlayer();
  StreamSubscription<void>? _noisySub;

  /// Used to identify this enhancement and to allow a constant value for the
  /// default mappings value of [AnkiMapping].
  static const String key = 'play_audio';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_action_play_audio;

  @override
  Future<void> executeAction({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required String? dictionaryName,
  }) async {
    _audioPlayer.stop();

    // HBK-AUDIT-083: removed dead branches. The previous code built a literal
    // single-element `List<Enhancement>`, then checked `isEmpty` (never true)
    // and iterated `Enhancement?` null-checking each element (a non-nullable
    // list cannot contain null). Collapsed to the single audio enhancement
    // this action actually previews.
    final LocalAudioEnhancement enhancement = LocalAudioEnhancement(
      field: AudioField.instance,
    );

    // 带上词条出自的词典：系统语音兜底按它声明的词头语言念（BUG-3669）。
    final File? file = await enhancement.fetchEntryAudio(
      appModel: appModel,
      term: entry.word,
      reading: entry.reading,
      dictionaryName: dictionaryName ?? entry.dictionaryName,
    );

    if (file != null) {
      await _audioPlayer.setFilePath(file.path);

      AudioSession? session;
      if (supportsNativeAudio) {
        session = await AudioSession.instance;
        await session.configure(
          const AudioSessionConfiguration(
            avAudioSessionCategory: AVAudioSessionCategory.playback,
            avAudioSessionCategoryOptions:
                AVAudioSessionCategoryOptions.duckOthers,
            avAudioSessionMode: AVAudioSessionMode.defaultMode,
            avAudioSessionRouteSharingPolicy:
                AVAudioSessionRouteSharingPolicy.defaultPolicy,
            avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
            androidAudioAttributes: AndroidAudioAttributes(
              contentType: AndroidAudioContentType.music,
              usage: AndroidAudioUsage.media,
            ),
            androidAudioFocusGainType:
                AndroidAudioFocusGainType.gainTransientMayDuck,
            androidWillPauseWhenDucked: true,
          ),
        );

        _noisySub?.cancel();
        _noisySub = session.becomingNoisyEventStream.listen((event) async {
          await _audioPlayer.stop();
          session?.setActive(false);
        });
      }

      session?.setActive(true);
      await _audioPlayer.play();
      session?.setActive(false);
      return;
    }

    FushiToast.show(
      msg: t.audio_unavailable,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
      severity: ToastSeverity.error,
    );
  }
}

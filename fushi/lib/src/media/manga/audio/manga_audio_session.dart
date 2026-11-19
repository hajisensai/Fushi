/// 漫画有声成品起 `AudiobookSession` 的材料：按清单时间表排好的播放列表（句子音频 +
/// 静音条目）、对应的内存 cue、换算过口径的进度读写，以及随会话同生共死的
/// [MangaAudioPlaybackDriver]。
///
/// 阅读器（`manga_fushi/read_aloud.part.dart`）与后台入口（`AudiobookSessionLauncher`
/// 遇到 [kMangaAlignmentFormat] 的书时）都走 [resolveMangaAudioSessionRequest]，所以
/// 无论从哪里起播，播放列表、进度口径与纯听跳过规则都是同一份。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';

import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/audiobook_session_start_request.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_playback_driver.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_playback_plan.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_silence.dart';

/// 生产播放器适配：全书毫秒 = 播放列表毫秒。
class _ControllerPort implements MangaAudioPlayerPort {
  _ControllerPort(this._c);

  final AudiobookPlayerController _c;

  @override
  void addListener(VoidCallback listener) => _c.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _c.removeListener(listener);

  @override
  int get positionMs => _c.globalPosition.inMilliseconds;

  @override
  bool get isPlaying => _c.isPlaying;

  @override
  double get speed => _c.speed;

  @override
  Future<void> play() => _c.play();

  @override
  Future<void> pause() => _c.pause();

  @override
  Future<void> seekMs(int ms) => _c.seekGlobalMs(ms);

  @override
  Future<void> setSpeed(double speed) => _c.setSpeed(speed);
}

/// 进度读写的口径换算：库里存「只数句子音频」的毫秒（与库里 cue 同源，补回一句时
/// 仓库层按 cue 换算的就是它），会话里用播放列表毫秒。
SessionPersistCallbacks mangaAudioPersistCallbacks(
  AudiobookRepository repo,
  String bookKey,
  MangaAudioPlaybackPlan plan,
) => SessionPersistCallbacks(
  onPositionWrite: (String key, int posMs) => repo.updatePositionMs(
    bookKey: key,
    positionMs: plan.toLinePositionMs(posMs),
  ),
  onDelayPersist: (int ms) => repo.updateDelayMs(bookKey: bookKey, ms: ms),
  onSpeedPersist: (double speed) =>
      repo.updateSpeed(bookKey: bookKey, speed: speed),
  onVolumePersist: (double volume) =>
      repo.updateVolume(bookKey: bookKey, volume: volume),
  onImagePausePersist: (int sec) =>
      repo.updateImagePauseSec(bookKey: bookKey, sec: sec),
  onFollowAudioPersist: (bool value) =>
      repo.updateFollowAudio(bookKey: bookKey, value: value),
);

/// 起会话的材料。静音文件在这里写好（按时长去重，放成品目录下）。
Future<AudiobookSessionStartRequest> resolveMangaAudioSessionRequest(
  FushiDatabase db, {
  required MangaAudioRegistration registration,
  required String title,
  String? author,
  String? coverPath,
  double pacing = 1.0,
}) async {
  final String bookKey = registration.bookKey;
  final MangaAudioPlaybackPlan plan = MangaAudioPlaybackPlan.build(
    registration.manifest,
    pacing: pacing,
  );
  await ensureMangaSilenceFiles(
    registration.manifestDir,
    plan.silenceDurations,
  );
  final List<String> paths = plan.filePaths(
    linePath: registration.linePath,
    silencePath: (int ms) => mangaSilencePath(registration.manifestDir, ms),
  );
  final AudiobookRepository repo = AudiobookRepository(db);
  final List<Object> prefs = await Future.wait<Object>(<Future<Object>>[
    repo.readDelayMs(bookKey),
    repo.readSpeed(bookKey),
    repo.readPositionMs(bookKey),
    repo.readVolume(bookKey),
  ]);
  // 会话的 Audiobook 用播放列表（与内存 cue 的文件下标同源）：制卡取片段、换源等按
  // cue.audioFileIndex 找文件的地方才不会错位到库里那份只含句子的列表上。
  final Audiobook audiobook = Audiobook()
    ..bookKey = bookKey
    ..audioPaths = paths
    ..alignmentFormat = kMangaAlignmentFormat
    ..alignmentPath = registration.manifestFile.path;
  return AudiobookSessionStartRequest(
    info: SessionBookInfo(
      bookKey: bookKey,
      audiobook: audiobook,
      title: title,
      mediaIdentifier: 'fushi://book/$bookKey',
      author: author,
      coverPath: coverPath,
      statsMediaKey: bookKey,
      format: BookFormat.manga,
      cueLayoutId: plan.layoutId,
    ),
    audioFiles: <File>[for (final String path in paths) File(path)],
    prefs: SessionPrefs(
      // 漫画的跟随翻页由驱动管（[MangaAudioPlaybackDriver.followPage]），控制器的
      // 跟随（EPUB 跨章）对漫画无意义。
      followAudio: false,
      delayMs: prefs[0] as int,
      speed: prefs[1] as double,
      positionMs: plan.fromLinePositionMs(prefs[2] as int),
      imagePauseSec: 0,
      volume: prefs[3] as double,
    ),
    persist: mangaAudioPersistCallbacks(repo, bookKey, plan),
    cues: plan.cues(bookKey),
    companion: (AudiobookPlayerController controller) =>
        MangaAudioPlaybackDriver(
          bookKey: bookKey,
          plan: plan,
          player: _ControllerPort(controller),
        ),
  );
}

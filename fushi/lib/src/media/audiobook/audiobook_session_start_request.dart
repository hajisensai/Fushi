/// 一本书的有声书会话启动材料（`AudiobookSessionLauncher` 与漫画有声
/// `manga_audio_session.dart` 共同产出、阅读器 / 后台入口消费）。单独成叶子文件，
/// 让漫画有声不必反向 import 启动器。
library;

import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';

import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/remote/audiobook_remote_playback.dart';

class AudiobookSessionStartRequest {
  const AudiobookSessionStartRequest({
    required this.info,
    required this.audioFiles,
    required this.prefs,
    required this.persist,
    this.cues = const <AudioCue>[],
    this.remote,
    this.companion,
  });

  final SessionBookInfo info;
  final List<File> audioFiles;
  final SessionPrefs prefs;
  final SessionPersistCallbacks persist;

  /// 非空 = 远端（流式）书：[audioFiles] 是占位文件，播放与制卡取音频走它。起会话时
  /// 原样传给 `AudiobookSession.start(remote:)`。
  final AudiobookRemotePlayback? remote;

  /// 随会话同生共死的伴随对象工厂（漫画有声的句序驱动）。起会话时原样传给
  /// `AudiobookSession.start(companion:)`。
  final AudiobookSessionCompanionFactory? companion;

  bool get isSrtBookSource => info.isSrtBookSource;

  /// 全书对齐 cue（扁平，无章节上下文）。供后台听书 [AudiobookSession.start] 在无
  /// reader 时灌进控制器，让 currentCue 在 load 后即可解析（悬浮窗有字）。reader 在场
  /// 时 reader 仍会按章节重新 setChapterCues，覆盖此扁平列表，行为不变。
  final List<AudioCue> cues;
}

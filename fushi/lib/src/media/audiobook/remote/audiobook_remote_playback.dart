/// 远端（流式）有声书的播放接缝。
///
/// 播放器、会话、制卡只认这个抽象：本机音频文件走原来的路径，远端音频由具体实现
/// （目前只有 Audiobookshelf）提供流式音源和「给 ffmpeg 的输入」。控制器里没有任何
/// 协议细节。
library;

import 'dart:io';

import 'package:just_audio/just_audio.dart';

/// 一条音轨交给外部进程（ffmpeg）读取时用的输入：本机路径，或带鉴权头的 URL。
class AudiobookTrackInput {
  const AudiobookTrackInput({
    required this.input,
    this.headers = const <String, String>{},
  });

  /// 本机文件路径，或 `http(s)://…` 地址。
  final String input;

  /// 读取 [input] 要带的请求头（鉴权）；本机文件为空。
  final Map<String, String> headers;

  bool get isRemote => headers.isNotEmpty || input.contains('://');
}

abstract class AudiobookRemotePlayback {
  /// 音轨数；与会话里的 `audioFiles` 一一对应。
  int get trackCount;

  /// 占位文件，一轨一个，**不存在于磁盘**。会话 / 控制器的接口按「音频文件列表」
  /// 编排（数量、下标），远端书没有本机文件，用这些占位撑住下标；任何真要读文件内容
  /// 的地方必须改走 [trackInput]。
  List<File> get placeholderFiles;

  /// 给主播放器的流式音源，一轨一个。
  List<AudioSource> buildSources();

  /// 单独一轨的全新流式音源——句子回放用的临时播放器不能和主播放器共用同一个实例。
  AudioSource buildTrackSource(int index);

  /// 第 [index] 轨交给 ffmpeg 的输入：地址 + **现取**的鉴权头（令牌临近过期会先刷新）。
  Future<AudiobookTrackInput> trackInput(int index);

  /// 会话结束时释放本接缝占用的资源（不关共享的协议层实例，它归注册表管）。
  Future<void> release();
}

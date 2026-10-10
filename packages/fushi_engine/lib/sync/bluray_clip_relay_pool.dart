// 互联 host 下发蓝光标题分段（`/api/library/videos/<id>/bdclip.m2ts`）时的解密会话池。
//
// 加密盘的 m2ts 不能原样发给 client：host 用 [AacsMediaSession] 为每段开一个解密
// 回环（独立 isolate 读盘 + AES，见 `aacs_stream_relay.dart`），分段端点把请求转给
// 它。开一个回环要起 isolate、读密钥，播放器一次播放会对同一段发几十上百个 Range
// 请求，所以会话按**一次播放**（流 token）复用，而不是每个请求开关一次。
//
// 回收按「在途请求数归零后空闲多久」算：mpv 常常用一条长 GET 连续读很久，期间没有新
// 请求，只按「最后一次请求」计时会把正在播的流从中间掐断。

import 'dart:async';

import 'package:fushi_engine/media/video/bluray/aacs_media_session.dart';
import 'package:meta/meta.dart';

/// 一次分段请求持有的源：[source] 等于请求的码流路径时是未加密的本地文件，否则是
/// 解密回环 URL。请求结束（含播放器中途断开）必须 [release]。
class BlurayClipLease {
  BlurayClipLease._(this.source, this._release);

  final String source;
  final void Function() _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class _PlaybackSession {
  _PlaybackSession(this.media);

  final AacsMediaSession media;
  int inFlight = 0;
  Timer? idle;
}

class BlurayClipRelayPool {
  BlurayClipRelayPool({
    this.idleTimeout = const Duration(minutes: 5),
    @visibleForTesting AacsMediaSession Function()? openSession,
  }) : _openSession = openSession ?? AacsMediaSession.new;

  /// 一次播放的解密会话在没有在途请求后保留多久（暂停、拖进度条的间隙不重开回环）。
  final Duration idleTimeout;

  final AacsMediaSession Function() _openSession;

  final Map<String, _PlaybackSession> _sessions = <String, _PlaybackSession>{};
  bool _closed = false;

  @visibleForTesting
  int get sessionCount => _sessions.length;

  /// 为播放 [playback]（流 token）解析码流 [streamPath]。未加密时原样返回路径；
  /// 加密时返回本次播放共用的解密回环 URL。
  Future<BlurayClipLease> acquire(String playback, String streamPath) async {
    if (_closed) throw StateError('Blu-ray clip relay pool is closed');
    final _PlaybackSession session = _sessions.putIfAbsent(
      playback,
      () => _PlaybackSession(_openSession()),
    );
    session.idle?.cancel();
    session.idle = null;
    session.inFlight++;
    try {
      final String source = await session.media.resolve(streamPath);
      return BlurayClipLease._(source, () => _release(playback, session));
    } catch (_) {
      _release(playback, session);
      rethrow;
    }
  }

  void _release(String playback, _PlaybackSession session) {
    session.inFlight--;
    if (session.inFlight > 0 || _sessions[playback] != session) return;
    session.idle = Timer(idleTimeout, () {
      if (session.inFlight > 0 || _sessions[playback] != session) return;
      _sessions.remove(playback);
      unawaited(session.media.close());
    });
  }

  /// host 停机：关掉全部解密回环（释放光驱 / 盘文件句柄）。
  Future<void> closeAll() async {
    _closed = true;
    final List<_PlaybackSession> sessions = _sessions.values.toList();
    _sessions.clear();
    for (final _PlaybackSession session in sessions) {
      session.idle?.cancel();
      await session.media.close();
    }
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/video/video_remote_binding_support.dart';
import 'package:fushi/src/mining/advanced_mining/video_advanced_mining.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_subtitle_panel.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart'
    show RemoteMineResult;
import 'package:fushi_engine/sync/immersion_mine_payload.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';

/// 往 [tab] 页里派发一条扩展 `runtime.onMessage` 消息并等回应（见
/// `WebBrowserExtensionHostFeature.request`）；页面没装整栈 / 超时 → null。
typedef WebBrowserVideoRemoteRequest =
    Future<Object?> Function(
      WebBrowserTab tab,
      Map<String, Object?> message,
      Duration timeout,
    );

/// 页面回报的遥控播放态（`fushiRemoteState.remote`，扩展 subtitle-panel.js「手机视频遥控」）。
@immutable
class WebBrowserVideoRemotePlayback {
  const WebBrowserVideoRemotePlayback({
    required this.positionMs,
    required this.durationMs,
    required this.playing,
    required this.rate,
    required this.volume,
    required this.controlRevision,
    required this.site,
    required this.title,
  });

  final int positionMs;
  final int durationMs;
  final bool playing;
  final double rate;

  /// 0..100（静音报 0）。
  final int volume;

  /// 页面里**不是遥控下发**的显式播放控制次数（电脑前的人按播放 / 暂停 / 拖动）。
  final int controlRevision;

  /// `youtube` / `netflix` / `bilibili` / `other`（subtitle-providers.js `fushiSite`）。
  final String site;
  final String title;
}

/// 一次 `fushiRemoteState` 回报：侧栏同形的字幕状态 + 播放态。
@immutable
class WebBrowserVideoRemoteState {
  const WebBrowserVideoRemoteState({
    required this.subtitles,
    required this.playback,
  });

  final WebBrowserSubtitlePanelState subtitles;
  final WebBrowserVideoRemotePlayback playback;

  /// 这一页此刻有没有可遥控的正片：有 `<video>` 且时长已知。
  bool get hasVideo => subtitles.hasVideo && playback.durationMs > 0;
}

int _int(Object? v) => v is num ? v.round() : 0;

/// 解析页面回报；形状不对 → null。
WebBrowserVideoRemoteState? parseWebBrowserVideoRemoteState(Object? raw) {
  final WebBrowserSubtitlePanelState? subtitles =
      parseWebBrowserSubtitlePanelState(raw);
  if (subtitles == null || raw is! Map) return null;
  final Object? r = raw['remote'];
  if (r is! Map) return null;
  final Object? rate = r['rate'];
  return WebBrowserVideoRemoteState(
    subtitles: subtitles,
    playback: WebBrowserVideoRemotePlayback(
      positionMs: _int(r['positionMs']),
      durationMs: _int(r['durationMs']),
      playing: r['playing'] == true,
      rate: rate is num && rate > 0 ? rate.toDouble() : 1,
      volume: _int(r['volume']).clamp(0, 100),
      controlRevision: _int(r['controlRevision']),
      site: r['site'] is String ? r['site'] as String : 'other',
      title: r['title'] is String ? r['title'] as String : '',
    ),
  );
}

/// 一次状态轮询的结果：[answered] = 页面回了话；[state] = 认得出的状态（null = 回了但
/// 认不出 / 没有遥控块）。
typedef _RemoteStateReply = ({
  bool answered,
  WebBrowserVideoRemoteState? state,
});

/// 遥控绑定要的 app 能力（浏览页装配，测试注入假的）。
class WebBrowserVideoRemotePorts {
  const WebBrowserVideoRemotePorts({
    required this.request,
    required this.runtime,
    required this.register,
    required this.unregister,
    required this.mineImmersion,
    required this.miningPads,
    this.closeTab,
  });

  /// app → 页面（扩展 `runtime.onMessage` 契约）。
  final WebBrowserVideoRemoteRequest request;

  /// 扩展后台消息（`subtitleSearch` / `subtitleFetch`，与字幕侧栏同一份路由）。
  final Future<Object?> Function(
    WebBrowserTab tab,
    Map<String, Object?> message,
  )
  runtime;

  /// 遥控宿主（`AppModel.videoRemoteHost`）的登记 / 注销。
  final void Function(VideoRemotePlaybackBinding binding) register;
  final void Function(VideoRemotePlaybackBinding binding) unregister;

  /// 沉浸制卡（`AppModel.createRemoteMiningService().mineImmersion`）。
  final Future<RemoteMineResult> Function(ImmersionMinePayload payload)
  mineImmersion;

  /// 制卡音频首尾留白（`AppModel.miningAudioHeadPadMs` / `miningAudioTailPadMs`）。
  final ({int headPadMs, int tailPadMs}) Function() miningPads;

  /// 关掉标签页（与标签栏关闭同一入口；最后一个标签页关掉时浏览页随之退出）。
  /// null = 手机的「关闭视频」不可用。
  final void Function(WebBrowserTab tab)? closeTab;
}

/// app 内浏览器「前台标签页的正片」作为手机视频遥控的播放器。
///
/// 只有前台标签页、且页面里真有正片（有 `<video>`、时长已知）时登记；切标签 / 关标签 /
/// 页面换到别的视频（videoKey 变）/ 浏览页销毁时注销或换新会话。状态来源是页面里的扩展
/// 整栈（subtitle-panel.js 的 `fushiRemote*` 消息），与字幕侧栏开没开无关：登记期间每
/// [activePollInterval] 轮询一次，没登记时每 [idlePollInterval] 看一眼前台页有没有视频。
///
/// 宿主按「页面叠放」排登记顺序：后登记的在上面、接管手机。所以浏览页被整页路由盖住
/// （[setCovered]，例如「在 Fushi 里播放」推出的原生播放器页）期间只更新 / 结束已有会话、
/// **不新登记**——否则下面这页换视频后重登记会跳到上层播放器头上抢走手机。露出来后下一次
/// 轮询再登记。页面一次没回话（超时）不算「没视频」，会话照旧，不让手机闪断。
class WebBrowserVideoRemote extends ChangeNotifier {
  WebBrowserVideoRemote({
    required this.ports,
    this.activePollInterval = const Duration(milliseconds: 500),
    this.idlePollInterval = const Duration(milliseconds: 1500),
    this.requestTimeout = const Duration(milliseconds: 1500),
    this.autoPoll = true,
  });

  final WebBrowserVideoRemotePorts ports;
  final Duration activePollInterval;
  final Duration idlePollInterval;
  final Duration requestTimeout;

  /// false = 不自己排轮询（测试手动调 [poll]）。
  final bool autoPoll;

  WebBrowserTab? _activeTab;
  _WebVideoRemoteSession? _session;

  /// 浏览页被整页路由盖住（见 [setCovered]）。
  bool _covered = false;
  Timer? _timer;
  bool _polling = false;
  bool _pollAgain = false;
  bool _disposed = false;

  /// 测试用：当前登记的绑定（null = 没登记）。
  @visibleForTesting
  VideoRemotePlaybackBinding? get binding => _session?.binding;

  // ── 浏览页生命周期 ───────────────────────────────────────────────────

  /// 前台标签页变了（null = 没有前台页）。
  void setActiveTab(WebBrowserTab? tab) {
    if (identical(tab, _activeTab)) return;
    _activeTab = tab;
    final _WebVideoRemoteSession? session = _session;
    if (session != null && !identical(session.tab, tab)) _endSession();
    _pollSoon();
  }

  /// 浏览页被整页路由盖住 / 重新露出（`RouteAware.didPushNext` / `didPopNext`）。
  /// 盖住期间不新登记（已有会话照常更新、该结束照常结束），露出后马上看一眼。
  void setCovered(bool covered) {
    if (covered == _covered) return;
    _covered = covered;
    if (!covered) _pollSoon();
  }

  /// [tab] 不再是前台页（随后通常紧跟新前台页的 [setActiveTab]）。
  void tabDeactivated(WebBrowserTab tab) {
    if (identical(tab, _activeTab)) setActiveTab(null);
  }

  /// 标签页关了。
  void tabClosed(WebBrowserTab tab) {
    if (identical(_session?.tab, tab)) _endSession();
    if (identical(_activeTab, tab)) _activeTab = null;
  }

  /// 标签页导航了（加载完 / 单页应用换地址）：马上看一眼，不等下一拍。
  void tabNavigated(WebBrowserTab tab) {
    if (identical(tab, _activeTab)) _pollSoon();
  }

  void _pollSoon() {
    if (!autoPoll || _disposed) return;
    _timer?.cancel();
    _timer = Timer(Duration.zero, () => unawaited(poll()));
  }

  void _schedule() {
    if (!autoPoll || _disposed) return;
    _timer?.cancel();
    _timer = Timer(
      _session == null ? idlePollInterval : activePollInterval,
      () => unawaited(poll()),
    );
  }

  void _endSession() {
    final _WebVideoRemoteSession? session = _session;
    if (session == null) return;
    _session = null;
    session.searchHandles.clear();
    ports.unregister(session.binding);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _endSession();
    super.dispose();
  }

  // ── 轮询 ───────────────────────────────────────────────────────────

  /// 读一次前台标签页的状态，按它登记 / 换会话 / 注销，并通知宿主。
  @visibleForTesting
  Future<void> poll() async {
    if (_disposed) return;
    if (_polling) {
      _pollAgain = true;
      return;
    }
    _polling = true;
    try {
      await _pollOnce();
    } finally {
      _polling = false;
    }
    if (_pollAgain && !_disposed) {
      _pollAgain = false;
      await poll();
      return;
    }
    _schedule();
  }

  Future<void> _pollOnce() async {
    final WebBrowserTab? tab = _activeTab;
    if (tab == null) {
      _endSession();
      return;
    }
    final _RemoteStateReply reply = await _fetch(tab);
    if (_disposed || !identical(tab, _activeTab)) return;
    // 页面这一拍没回话（繁忙 / 超时）：什么都不改，下一拍再看。
    if (!reply.answered) return;
    final WebBrowserVideoRemoteState? state = reply.state;
    if (state == null || !state.hasVideo) {
      _endSession();
      return;
    }
    _apply(tab, state, fresh: false);
  }

  /// 取状态：cue 身份没变时只取状态，变了再带 cue 取一次（与字幕侧栏同一节奏）。
  /// `answered == false` = 页面没回话（请求超时，`ports.request` 回 null），与「页面明确
  /// 回报没视频 / 回报认不出」分开。
  Future<_RemoteStateReply> _fetch(WebBrowserTab tab) async {
    final Object? firstRaw = await ports.request(tab, <String, Object?>{
      'type': 'fushiRemoteState',
      'includeCues': false,
    }, requestTimeout);
    if (firstRaw == null) return (answered: false, state: null);
    final WebBrowserVideoRemoteState? first = parseWebBrowserVideoRemoteState(
      firstRaw,
    );
    if (first == null) return (answered: true, state: null);
    final _WebVideoRemoteSession? session = _session;
    if (session != null &&
        identical(session.tab, tab) &&
        session.cueIdentity == first.subtitles.cueIdentity) {
      return (answered: true, state: first);
    }
    final Object? fullRaw = await ports.request(tab, <String, Object?>{
      'type': 'fushiRemoteState',
      'includeCues': true,
    }, requestTimeout);
    if (fullRaw == null) return (answered: false, state: null);
    return (answered: true, state: parseWebBrowserVideoRemoteState(fullRaw));
  }

  /// 落一份页面回报。[fresh] = 命令的回执（遥控自己刚下发过，不再判断登记）。
  void _apply(
    WebBrowserTab tab,
    WebBrowserVideoRemoteState state, {
    required bool fresh,
  }) {
    _WebVideoRemoteSession? session = _session;
    if (session != null &&
        (!identical(session.tab, tab) ||
            session.videoKey != state.subtitles.videoKey)) {
      if (fresh) return; // 回执来自已经换掉的会话
      _endSession();
      session = null;
    }
    if (session == null) {
      // 被别的整页路由盖着：不新登记（登记 = 放到最上层接管手机），露出后再登记。
      if (_covered) return;
      session = _WebVideoRemoteSession(tab, state.subtitles.videoKey);
      session.binding = _bind(session);
      session.update(state);
      _session = session;
      ports.register(session.binding);
      return;
    }
    session.update(state);
    notifyListeners();
  }

  // ── 绑定 ───────────────────────────────────────────────────────────

  _WebVideoRemoteSession _live(_WebVideoRemoteSession session) {
    if (_disposed || !identical(_session, session)) {
      throw const VideoRemoteException(409, 'no_video');
    }
    return session;
  }

  /// 往页面发一条遥控命令，回执里的新状态立刻落进会话。
  Future<void> _control(
    _WebVideoRemoteSession session,
    Map<String, Object?> message,
  ) async {
    _live(session);
    final Object? reply = await ports.request(session.tab, <String, Object?>{
      'type': 'fushiRemoteControl',
      ...message,
    }, requestTimeout);
    final WebBrowserVideoRemoteState? state = parseWebBrowserVideoRemoteState(
      reply,
    );
    if (state == null) {
      throw const VideoRemoteException(409, 'no_video');
    }
    if (identical(_session, session)) _apply(session.tab, state, fresh: true);
  }

  /// 遥控下发的一次显式播放控制：本地修订号 +1（同步，先于页面往返；见
  /// [_WebVideoRemoteSession.controlRevision]）。
  Future<void> _intent(
    _WebVideoRemoteSession session,
    Map<String, Object?> message,
  ) {
    _live(session).localRevision++;
    return _control(session, message);
  }

  VideoRemotePlaybackBinding _bind(_WebVideoRemoteSession session) =>
      VideoRemotePlaybackBinding(
        // 标签页 + 页面视频身份：换标签 / 页面里换了视频就是新会话。
        identity: () => 'web|${session.tab.id}|${session.videoKey}',
        title: () => session.title,
        // 收藏句的出处：网页视频没有库条目，用页面视频身份（与网页学习计时的 `web:` 同前缀）。
        bookUid: () => 'web:${session.videoKey}',
        sectionIndex: () => 0,
        cues: () => session.rows(),
        state: () => <String, Object?>{
          'positionMs': session.playback.positionMs,
          'durationMs': session.playback.durationMs,
          'playing': session.playback.playing,
          'speed': session.playback.rate,
          'controlRevision': session.controlRevision,
          'primaryTrack': session.activeLang,
          'secondaryTrack': null,
          // 页面回报的 cue 已套过用户设的时轴偏移（播放器轴），行上不再带偏移。
          'primaryDelayMs': 0,
          'secondaryDelayMs': 0,
          'volume': session.playback.volume,
          'episodeIndex': 0,
          'episodeCount': 0,
        },
        command: (String action, Map<String, dynamic> body) async {
          switch (action) {
            case 'play':
            case 'pause':
              await _intent(session, <String, Object?>{'action': action});
            case 'seek':
            case 'seekCue':
              final int position = (body['positionMs'] as num).toInt();
              final int duration = session.playback.durationMs;
              final int target = duration > 0
                  ? position.clamp(0, duration)
                  : position;
              await _intent(session, <String, Object?>{
                'action': 'seek',
                'ms': target,
              });
              if (action == 'seekCue') {
                await _intent(session, <String, Object?>{'action': 'play'});
              }
            default:
              throw const VideoRemoteException(400, 'invalid_action');
          }
        },
        mine:
            (
              VideoRemoteCue cue,
              Map<String, dynamic> request,
              VideoRemoteMineSelection selection,
            ) => _mine(session, cue, request, selection),
        // 试听放的是会写进卡片的那段（与 [_mine] 同一个 [_miningWindow]）。
        previewAudio: (VideoRemoteCue anchor, int startMs, int endMs) async {
          final ({int clipStartMs, int clipEndMs}) window = _miningWindow(
            session,
            anchor,
            startMs,
            endMs,
          );
          if (window.clipEndMs <= window.clipStartMs) return false;
          await _intent(session, <String, Object?>{
            'action': 'playRange',
            'startMs': window.clipStartMs,
            'endMs': window.clipEndMs,
          });
          return true;
        },
        stopAudio: () =>
            _intent(session, <String, Object?>{'action': 'stopRange'}),
        openFavorite: (FavoriteSentence favorite) =>
            _openFavorite(session, favorite),
        addListener: addListener,
        removeListener: removeListener,
        // 音量不是播放意图，不动修订号。
        setVolume: (int volume) => _control(session, <String, Object?>{
          'action': 'volume',
          'volume': volume,
        }),
        subtitleTracks: () async => _subtitleOptions(_live(session)),
        selectSubtitleTrack: (String? id) => _selectSubtitle(session, id),
        searchSubtitles: (String? query, int? episode) =>
            _searchSubtitles(session, query, episode),
        downloadSubtitle: (String id) => _downloadSubtitle(session, id),
        // 手机「关闭视频」= 关掉这个标签页（与标签栏关闭同一入口）。
        close: ports.closeTab == null
            ? null
            : () async => ports.closeTab!(_live(session).tab),
      );

  // ── 字幕轨 ─────────────────────────────────────────────────────────

  String _trackId(_WebVideoRemoteSession session, String lang) =>
      videoRemoteSubtitleOptionId('${session.videoKey}|$lang');

  List<VideoRemoteSubtitleOption> _subtitleOptions(
    _WebVideoRemoteSession session,
  ) => <VideoRemoteSubtitleOption>[
    for (final WebBrowserSubtitleTrack track in session.tracks)
      VideoRemoteSubtitleOption(
        id: _trackId(session, track.lang),
        label: track.label,
        kind: track.lang.startsWith(_kExternalLangPrefix)
            ? 'external'
            : session.playback.site == 'youtube'
            ? 'youtube'
            : 'embedded',
        selected: track.lang == session.activeLang,
        selectable: true,
      ),
  ];

  /// 选主字幕：与字幕侧栏选轨同一语义（只换活动轨）。页面总会自动挑一条可用轨当活动轨，
  /// 「关闭字幕」在网页里没有对应状态，回 409 `subtitle_track_unavailable`。
  Future<void> _selectSubtitle(
    _WebVideoRemoteSession session,
    String? id,
  ) async {
    _live(session);
    if (id == null) {
      throw const VideoRemoteException(409, 'subtitle_track_unavailable');
    }
    final WebBrowserSubtitleTrack? track = session.tracks
        .where((WebBrowserSubtitleTrack t) => _trackId(session, t.lang) == id)
        .firstOrNull;
    if (track == null) {
      throw const VideoRemoteException(404, 'subtitle_track_missing');
    }
    if (track.lang == session.activeLang) return;
    await _control(session, <String, Object?>{
      'action': 'selectTrack',
      'lang': track.lang,
    });
    // 活动轨换了：带 cue 重取一次，让宿主在回执后就看到新句子列表。
    final WebBrowserVideoRemoteState? state = (await _fetch(session.tab)).state;
    if (state != null && identical(_session, session)) {
      _apply(session.tab, state, fresh: true);
    }
  }

  /// 在线搜字幕：与字幕侧栏「在线搜索」同一条后台路由（`subtitleSearch`）。没给关键词时
  /// 用页面标题（侧栏同一预填）；算不出关键词回空结果，手机自己填词再搜。
  Future<VideoRemoteOnlineSubtitleSearch> _searchSubtitles(
    _WebVideoRemoteSession session,
    String? query,
    int? episode,
  ) async {
    _live(session);
    final String effective = (query ?? session.title).trim();
    if (effective.isEmpty) {
      return VideoRemoteOnlineSubtitleSearch(
        query: '',
        episode: episode,
        candidates: const <VideoRemoteOnlineSubtitle>[],
      );
    }
    final Object? response = await ports.runtime(session.tab, <String, Object?>{
      'type': 'subtitleSearch',
      'query': effective,
      if (episode != null && episode > 0) 'episode': episode,
    });
    _live(session);
    final Object? data = response is Map ? response['data'] : null;
    if (data is! Map || data['ok'] != true) {
      final Object? error = data is Map ? data['error'] : null;
      if (error == 'missing-query') {
        return VideoRemoteOnlineSubtitleSearch(
          query: effective,
          episode: episode,
          candidates: const <VideoRemoteOnlineSubtitle>[],
        );
      }
      throw VideoRemoteException(
        error == 'no-provider' ? 409 : 502,
        error == 'no-provider'
            ? 'subtitle_source_missing'
            : 'subtitle_search_failed',
      );
    }
    session.searchHandles.clear();
    final List<VideoRemoteOnlineSubtitle> candidates =
        <VideoRemoteOnlineSubtitle>[];
    final Object? raw = data['candidates'];
    if (raw is List) {
      for (final Object? c in raw) {
        if (c is! Map || c['handle'] is! String) continue;
        final String handle = c['handle'] as String;
        // 句柄可能带来源地址：只把它的摘要交给手机。
        final String id = videoRemoteSubtitleOptionId(handle);
        session.searchHandles[id] = (
          handle: handle,
          fileName: '${c['fileName'] ?? ''}',
        );
        final Object? language = c['language'];
        final Object? candidateEpisode = c['episode'];
        candidates.add(
          VideoRemoteOnlineSubtitle(
            id: id,
            fileName: '${c['fileName'] ?? ''}',
            provider: '${c['provider'] ?? ''}',
            language: language is String && language.isNotEmpty
                ? language
                : null,
            episode: candidateEpisode is num ? candidateEpisode.toInt() : null,
            aiTranslated: c['aiTranslated'] == true,
            hearingImpaired: c['hearingImpaired'] == true,
          ),
        );
      }
    }
    return VideoRemoteOnlineSubtitleSearch(
      query: effective,
      episode: episode,
      candidates: candidates,
    );
  }

  /// 下载一条在线字幕（`subtitleFetch`，可能很慢、在宿主命令队列外跑），返回「装进页面」
  /// 一步：与侧栏下载完成同一条 `fushiSubtitleSidePanelInstallTrack`。装之前核对会话还是
  /// 发起时那个（同一标签页、同一视频），否则 409 `session_changed`。
  Future<VideoRemoteSubtitleApply> _downloadSubtitle(
    _WebVideoRemoteSession session,
    String id,
  ) async {
    _live(session);
    final ({String handle, String fileName})? hit = session.searchHandles[id];
    if (hit == null) {
      throw const VideoRemoteException(404, 'subtitle_candidate_missing');
    }
    final Object? response = await ports.runtime(session.tab, <String, Object?>{
      'type': 'subtitleFetch',
      'handle': hit.handle,
    });
    final Object? data = response is Map ? response['data'] : null;
    final Object? cues = data is Map ? data['cues'] : null;
    if (data is! Map || data['ok'] != true || cues is! List || cues.isEmpty) {
      final Object? error = data is Map ? data['error'] : null;
      throw error == 'unknown-handle'
          ? const VideoRemoteException(404, 'subtitle_candidate_missing')
          : const VideoRemoteException(502, 'subtitle_download_failed');
    }
    final String fileName = data['filename'] is String
        ? data['filename'] as String
        : hit.fileName;
    return () async {
      if (_disposed || !identical(_session, session)) {
        throw const VideoRemoteException(409, 'session_changed');
      }
      final Object? reply = await ports.request(session.tab, <String, Object?>{
        'type': 'fushiSubtitleSidePanelInstallTrack',
        'filename': fileName,
        'cues': cues,
      }, requestTimeout);
      if (reply is! Map || reply['ok'] != true) {
        throw const VideoRemoteException(409, 'no_video');
      }
      final WebBrowserVideoRemoteState? state = (await _fetch(
        session.tab,
      )).state;
      if (state != null && identical(_session, session)) {
        _apply(session.tab, state, fresh: true);
      }
    };
  }

  // ── 收藏句 ─────────────────────────────────────────────────────────

  /// 手机点收藏句：本视频的句子在页面里跳过去播放；别的视频 / 书的收藏网页里打不开，回
  /// 404 `favorite_source_unavailable`（与原生页「来源打不开」同一个码）。
  Future<void> _openFavorite(
    _WebVideoRemoteSession session,
    FavoriteSentence favorite,
  ) async {
    _live(session);
    if (favorite.bookKey != 'web:${session.videoKey}' ||
        (favorite.sectionIndex ?? 0) != 0) {
      throw const VideoRemoteException(404, 'favorite_source_unavailable');
    }
    final VideoRemoteCue cue = matchVideoRemoteFavoriteCue(
      session.rows(),
      favorite,
    );
    await _intent(session, <String, Object?>{
      'action': 'seek',
      'ms': (cue.startMs + cue.delayMs).clamp(0, 1 << 30),
    });
    await _intent(session, <String, Object?>{'action': 'play'});
  }

  // ── 制卡 ───────────────────────────────────────────────────────────

  /// 遥控制卡 / 试听共用的时间窗：字幕时基区间按制卡音频首尾留白加宽，再按行的调轴换到
  /// 播放器轴（网页 cue 已套过偏移，调轴恒 0）。试听与写卡只算这一处。
  ({int clipStartMs, int clipEndMs}) _miningWindow(
    _WebVideoRemoteSession session,
    VideoRemoteCue anchor,
    int startMs,
    int endMs,
  ) {
    final ({int headPadMs, int tailPadMs}) pads = ports.miningPads();
    final ({int startMs, int endMs}) padded = videoRemotePaddedMiningRange(
      startMs: startMs,
      endMs: endMs,
      cues: session.audioCues,
      headPadMs: pads.headPadMs,
      tailPadMs: pads.tailPadMs,
    );
    return (
      clipStartMs: (padded.startMs + anchor.delayMs).clamp(0, 1 << 30),
      clipEndMs: (padded.endMs + anchor.delayMs).clamp(0, 1 << 30),
    );
  }

  /// 遥控制卡：与浏览器扩展的网页制卡同一套服务端能力（[FushiRemoteMiningService.mineImmersion]）。
  /// - YouTube：按视频 id + 时间窗从真实视频流裁画面与音频；
  /// - bilibili（稿件 / 番剧）：页面当前解码帧当封面，音轨按时间窗从原始流裁（playurl 由页面
  ///   带用户会话取回，取不到时稿件让服务端自己解析、番剧不带可裁源，规则同扩展 background.js）；
  /// - Netflix：DRM，只能录屏回放，这里没有录制能力 → 409 `video_extraction_unavailable`；
  /// - 其它站点：页面当前解码帧 + 句子（没有可裁的原始流，卡上没有句子音频，与扩展「立即出卡」
  ///   同）；连帧都取不到（跨域 / DRM 画面）→ 409 `video_extraction_unavailable`。
  Future<Map<String, Object?>> _mine(
    _WebVideoRemoteSession session,
    VideoRemoteCue cue,
    Map<String, dynamic> request,
    VideoRemoteMineSelection selection,
  ) async {
    _live(session);
    final VideoRemoteMineRequest parsed = parseVideoRemoteMineRequest(request);
    final ({int clipStartMs, int clipEndMs}) window = _miningWindow(
      session,
      cue,
      selection.startMs,
      selection.endMs,
    );
    final VideoMiningRange range = applyVideoMiningOverrides((
      clipStartMs: window.clipStartMs,
      clipEndMs: window.clipEndMs,
      stillFrameAtMs: (selection.startMs + cue.delayMs).clamp(0, 1 << 30),
      sentence: '',
      cueSentence: null,
    ), parsed.overrides);
    final String sentence = videoRemoteMineSentence(selection, parsed.sentence);
    // 手机送来的词典媒体已在 [parseVideoRemoteMineRequest] 里清洗过（只留落在词典资源根
    // 内的条目，mineImmersion 据此写缓存）。
    final Map<String, String> fields = parsed.fields;
    final Object? reply = await ports.request(session.tab, <String, Object?>{
      'type': 'fushiRemoteMineContext',
    }, const Duration(seconds: 12));
    _live(session);
    if (reply is! Map || reply['ok'] != true) {
      throw const VideoRemoteException(409, 'no_video');
    }
    final ImmersionMinePayload payload = webBrowserRemoteMinePayload(
      context: reply,
      fields: fields,
      sentence: sentence,
      cueSentence: selection.cueSentence,
      documentTitle: session.title,
      clipStartMs: range.clipStartMs,
      clipEndMs: range.clipEndMs,
      cueStartMs: range.stillFrameAtMs,
    );
    final RemoteMineResult result = await ports.mineImmersion(payload);
    final bool success = result.result == 'success';
    final bool duplicate = result.result == 'duplicate';
    return <String, Object?>{
      'ankiConnect': success,
      'noteId': null,
      if (duplicate) 'duplicate': true,
      'success': success,
      if (!success && !duplicate) 'error': 'mining_failed',
    };
  }
}

/// 外挂字幕轨的语言前缀（subtitle-panel.js `EXT_PREFIX`）。
const String _kExternalLangPrefix = '外挂:';

/// 页面制卡素材（`fushiRemoteMineContext` 的回应）→ 沉浸制卡请求。按站点分流见
/// [WebBrowserVideoRemote] 的 `_mine`；不支持的站点抛 409 `video_extraction_unavailable`。
ImmersionMinePayload webBrowserRemoteMinePayload({
  required Map<dynamic, dynamic> context,
  required Map<String, String> fields,
  required String sentence,
  required String cueSentence,
  required String documentTitle,
  required int clipStartMs,
  required int clipEndMs,
  required int cueStartMs,
}) {
  final Object? clip = context['clip'];
  final String? kind = clip is Map && clip['kind'] is String
      ? clip['kind'] as String
      : null;
  final String? id = clip is Map && clip['id'] is String
      ? clip['id'] as String
      : null;
  final int? part = clip is Map && clip['part'] is num
      ? (clip['part'] as num).toInt()
      : null;
  final String? playurl =
      context['playurlBody'] is String &&
          (context['playurlBody'] as String).isNotEmpty
      ? context['playurlBody'] as String
      : null;
  Uint8List? screenshot;
  final Object? raw = context['screenshotBase64'];
  if (raw is String && raw.isNotEmpty) {
    try {
      screenshot = base64Decode(raw);
    } on FormatException {
      screenshot = null;
    }
  }
  final String title = documentTitle.isNotEmpty
      ? documentTitle
      : '${context['title'] ?? ''}';
  if (kind == 'netflix') {
    throw const VideoRemoteException(409, 'video_extraction_unavailable');
  }
  if (kind == 'youtube' && id != null) {
    return ImmersionMinePayload(
      fields: fields,
      sentence: sentence,
      cueSentence: cueSentence,
      documentTitle: title,
      youtubeVideoId: id,
      clipStartMs: clipStartMs,
      clipEndMs: clipEndMs,
      cueStartMs: cueStartMs,
    );
  }
  // 番剧的音轨只能由页面带会话取：没取到就连 kind 一起不发（同 background.js）。
  final bool clipSource =
      id != null &&
      (kind == 'bilibili' || (kind == 'bilibili-pgc' && playurl != null));
  if (!clipSource && screenshot == null) {
    throw const VideoRemoteException(409, 'video_extraction_unavailable');
  }
  return ImmersionMinePayload(
    fields: fields,
    sentence: sentence,
    cueSentence: cueSentence,
    documentTitle: title,
    screenshotBytes: screenshot,
    cueStartMs: cueStartMs,
    clipStartMs: clipSource ? clipStartMs : null,
    clipEndMs: clipSource ? clipEndMs : null,
    clipSourceKind: clipSource ? kind : null,
    clipSourceId: clipSource ? id : null,
    clipSourcePart: clipSource ? part : null,
    clipSourcePlayurlBody: clipSource ? playurl : null,
  );
}

/// 一个被遥控的网页视频（某个标签页里的某个 videoKey）。
class _WebVideoRemoteSession {
  _WebVideoRemoteSession(this.tab, this.videoKey);

  final WebBrowserTab tab;
  final String videoKey;
  late final VideoRemotePlaybackBinding binding;

  WebBrowserVideoRemotePlayback playback = const WebBrowserVideoRemotePlayback(
    positionMs: 0,
    durationMs: 0,
    playing: false,
    rate: 1,
    volume: 0,
    controlRevision: 0,
    site: 'other',
    title: '',
  );
  String? activeLang;
  List<WebBrowserSubtitleTrack> tracks = const <WebBrowserSubtitleTrack>[];
  String cueIdentity = '';

  /// 活动轨的 cue（只在 cue 身份变了时重建，身份不变时保持同一个列表实例——
  /// [VideoRemoteCueCache] 与宿主都按 identical 判断句子列表变没变）。
  List<AudioCue> audioCues = const <AudioCue>[];
  final VideoRemoteCueCache _cueCache = VideoRemoteCueCache();

  /// 遥控下发的显式播放控制次数（下发时同步 +1，先于页面往返）。宿主的查词暂停判据
  /// 要求「遥控自己的一次暂停让修订号恰好 +1」，所以这部分必须在 Dart 侧同步计。
  int localRevision = 0;

  /// 在线字幕搜索结果：手机拿到的不透明 id → 后台句柄（下一次搜索即作废）。
  final Map<String, ({String handle, String fileName})> searchHandles =
      <String, ({String handle, String fileName})>{};

  String get title => playback.title.isNotEmpty ? playback.title : tab.title;

  /// 修订号 = 遥控自己下发的 + 页面里别人操作的（页面只计后者）。
  int get controlRevision => localRevision + playback.controlRevision;

  List<VideoRemoteCue> rows() => _cueCache.read(
    primary: audioCues,
    key: '${activeLang ?? ''}|$cueIdentity',
  );

  void update(WebBrowserVideoRemoteState state) {
    playback = state.playback;
    activeLang = state.subtitles.activeLang;
    tracks = state.subtitles.tracks;
    final List<WebBrowserSubtitleCue>? cues = state.subtitles.cues;
    final String identity = state.subtitles.cueIdentity;
    if (cues != null && identity != cueIdentity) {
      cueIdentity = identity;
      audioCues = List<AudioCue>.unmodifiable(<AudioCue>[
        for (final WebBrowserSubtitleCue c in cues)
          AudioCue()
            ..bookKey = ''
            ..chapterHref = ''
            ..sentenceIndex = 0
            ..textFragmentId = ''
            ..text = c.text
            ..startMs = c.startMs
            ..endMs = c.endMs
            ..audioFileIndex = 0,
      ]);
    }
  }
}

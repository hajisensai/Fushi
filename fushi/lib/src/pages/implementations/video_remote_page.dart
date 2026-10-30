import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/lookup_overlay_navigator.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart'
    show SentenceContextSlot;
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/video/video_remote_control_layout.dart';
import 'package:fushi/src/models/preferences_repository.dart'
    show PreferencesRepository;
import 'package:fushi/src/pages/implementations/video_remote/video_remote_cover_image.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_episode_sheet.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_library_sheet.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_subtitle_search_sheet.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_touchpad.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart'
    show fushiMotionDuration;
import 'package:fushi/src/pages/implementations/video_remote/video_remote_control_editor.dart'
    show showVideoRemoteControlEditor;
import 'package:fushi/src/pages/implementations/video_remote/video_remote_models.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_scaffold.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_volume_sheet.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart'
    show shouldShowLookupDismissBarrier;
import 'package:fushi/src/pages/implementations/dictionary_popup_resource_source.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show DictionaryPopupWebViewState, MinePopupResult, QueuedOverwriteReply;
import 'package:fushi/src/sync/sync_backend.dart' show SyncAuthError;
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/sync/video_remote_client.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/app_ui_scale.dart'
    show FushiAppUiScaleNeutralizer;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/lookup_audio_playback.dart'
    show playResolvedLookupAudio;
import 'package:fushi/src/utils/misc/lookup_dismiss_barrier.dart';
import 'package:fushi/src/utils/overlay_entry_lifecycle.dart';
import 'package:fushi_anki/fushi_anki.dart' show AnkiOpenWordOutcome;
import 'package:fushi_core/fushi_core.dart'
    show kStatSourceVideo, mimeTypeForFilePath;
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/utils/components/fushi_haptics.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/sync/video_remote_service.dart'
    show
        videoRemoteCapabilityCloseVideo,
        videoRemoteActionUnsupported,
        videoRemoteCapabilityCaret,
        videoRemoteCapabilityEpisodes,
        videoRemoteCaretMaxCount,
        videoRemoteCaretMoves,
        videoRemoteCapabilityOpenVideo,
        videoRemoteCapabilitySubtitleSearch,
        videoRemoteCapabilitySubtitleTracks,
        videoRemoteCapabilityVolume;
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show lookupHighlightGraphemeCount;
import 'package:http/http.dart' as http;

/// 手机字幕遥控器：字幕列表 + 收藏 + 在手机上查电脑的词典 / 制卡。
///
/// 查词与视频侧栏是**同一个**弹框（[DictionaryPageMixin] → `DictionaryPopupLayer`
/// → popup.js），嵌套查词 / 原地跳转 / 热槽都由 mixin 承担；本页只换三样东西：
/// 数据源（钉住的那台电脑，[searchPopupDictionary]）、词典资源（那台电脑的样式 /
/// 媒体 / 发音，[popupResourceSource]）、制卡（经遥控协议交给那台电脑的 Anki，
/// [onMineEntry]）。会打到手机本机 Anki / 数据库的入口一律禁用。
class VideoRemotePage extends ConsumerStatefulWidget {
  const VideoRemotePage({
    required this.repository,
    required this.peer,
    this.httpClient,
    super.key,
  });
  final SyncRepository repository;
  final FushiClientUrl peer;
  final http.Client? httpClient;
  @override
  ConsumerState<VideoRemotePage> createState() => VideoRemotePageState();
}

/// 本页的状态与行为：协议、会话与查词在这里；画面是 `video_remote/` 下的
/// [VideoRemoteScaffold]（纯展示），build 把快照投影成它的不可变数据、把它的
/// 回调接回下面这些命令。跟随当前句 / 页签 / 收藏搜索与多选归脚手架自己管。
///
/// * 字幕：[rows]（主副轨按时间交错）/ [currentRowIndex] / [isPrimaryRow] /
///   [previousRowIndex] / [nextRowIndex]。
/// * 播放：[available] / [playing] / [title] / [playbackState] / [positionMs] /
///   [play] / [pause] / [togglePlay] / [seekTo] / [seekToRow] / [previousRow] /
///   [nextRow]。
/// * 收藏：[favorites] / [isRowFavorited] / [toggleRowFavorite] /
///   [favoritesAllVideos] / [setFavoritesAllVideos] / [removeFavorites] /
///   [openFavorite]。
/// * 查词：[openLookup]（行 + 被点字的 grapheme 下标 + 可选锚点）/ [closeLookup] /
///   [lookupOpen]。
/// * 连接：[errorText] / [reconnect]。
class VideoRemotePageState extends ConsumerState<VideoRemotePage>
    with WidgetsBindingObserver, DictionaryPageMixin {
  late final VideoRemoteClient _client = VideoRemoteClient(
    repository: widget.repository,
    peer: widget.peer,
    httpClient: widget.httpClient,
  );
  late http.Client _dictionaryHttp = widget.httpClient ?? http.Client();
  late FushiRemoteLookupClient _lookup = _createLookup();
  Map<String, dynamic> _state = <String, dynamic>{};
  List<Map<String, dynamic>> _cues = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _favorites = <Map<String, dynamic>>[];
  final Set<String> _starred = <String>{};
  bool _foreground = true, _polling = false, _all = false;
  bool _favoritesLoading = false;
  int _active = -1, _revision = 0, _generation = 0;
  VideoRemoteTab _tab = VideoRemoteTab.transcript;

  /// 触控板模式（整屏手势遥控）是否打开。
  bool _touchpad = false;

  /// 脚手架行号 → [_cues] 里的主轨行（每次 build 由 [_projectTranscript] 重算）。
  List<Map<String, dynamic>> _lineRows = <Map<String, dynamic>>[];

  /// 当前弹框栈顶层查词（[openLookup]）查的那个词在行内的位置；对外只经
  /// [lookupHighlight] 派生读（栈全关即 null），嵌套查词不改它。
  VideoRemoteLookupHighlight? _lookupHighlight;

  /// 控制卡进度条的读口（本地按速度推算播放头，见 [_position]）。
  late final _RemoteClock _playbackClock = _RemoteClock(this);
  int _favoriteGeneration = 0;
  String _error = '';
  Timer? _clock;
  Timer? _retry;
  int _retryAttempt = 0;
  Future<void> _disconnecting = Future<void>.value();
  Map<String, dynamic>? _favoriteTarget;
  Completer<Map<String, dynamic>>? _favoriteCueWaiter;
  String? _cueSessionId;
  int? _cueSubtitleVersion;
  String? _cueLoadKey;
  Future<List<Map<String, dynamic>>>? _cueLoad;
  DateTime _anchor = DateTime.now();

  // ── 查词会话 ───────────────────────────────────────────────────────────
  /// 弹框栈。手机端查词弹框与视频侧栏同一套（见类注释）。
  final DictionaryPopupController _popup = DictionaryPopupController(
    lowMemory: false,
    onLookupStackDepthChanged: recordLookupStackDepth,
  );

  /// 电脑端这次查词的上下文（`lookupBegin` 回的 contextId）：整个弹框栈（含嵌套
  /// 查词）共用一个；栈全部关掉才 `lookupEnd`（电脑只恢复自己造成的暂停）。
  String? _lookupContextId;

  /// 上下文绑定的行与字幕会话：点了别的行或字幕会话变了就不能再复用它。
  String? _lookupCueId, _lookupSessionId;
  int? _lookupSubtitleVersion;

  /// 每次 [openLookup] / 关栈自增：在途的 `lookupBegin` 回来时据此判断自己是否已过期。
  int _lookupSerial = 0;

  /// 弹框来自电脑：样式 / 媒体 / 发音都问那台电脑（见 [popupResourceSource]）。
  late final RemoteDictionaryPopupResources _resources =
      RemoteDictionaryPopupResources(
        fetchStyles: () => _lookup.dictionaryStyles(),
        fetchMedia: (String dictionary, String path) async {
          final RemoteDictionaryMedia? media = await _lookup.dictionaryMedia(
            dictionary: dictionary,
            path: path,
          );
          return media == null
              ? null
              : DictionaryPopupMedia(
                  bytes: media.bytes,
                  contentType: media.contentType,
                );
        },
        fetchWordAudio: (String expression, String reading) =>
            _lookup.lookupAudioUrl(expression: expression, reading: reading),
      );

  /// 弹框挂在根 Overlay（盖过 AppBar / 底栏，与视频页、首页词典同范式）。
  OverlayEntry? _popupOverlayEntry;
  bool _overlayInert = false;

  /// 只在第一次查词时读：没查过词的页面不该为了字幕列表去初始化 AppModel 依赖。
  late final AppModel _appModel = ref.read(appProvider);

  @override
  AppModel get mixinAppModel => _appModel;

  @override
  ThemeData get mixinTheme => Theme.of(context);

  @override
  String get dictionarySourceType => kStatSourceVideo;

  @override
  DictionaryPopupResourceSource? get popupResourceSource => _resources;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clock = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _highlight(),
    );
    unawaited(_start());
  }

  /// The dictionary hop is bound to the same host, credential and pin.
  FushiRemoteLookupClient _createLookup() => FushiRemoteLookupClient(
    repo: widget.repository,
    onlyCandidate: widget.peer,
    httpClient: _client.guardPlaintext(_dictionaryHttp),
    pinnedClientFactory: _client.pinnedClientFactory,
  );

  /// Only `paused` / `detached` release the remote: `inactive` (iOS control
  /// centre, incoming-call banner, app switcher peek) and `hidden` are
  /// transitional and must not drop the lease or resume the computer. One
  /// background period sends exactly one disconnect; `resumed` reconnects.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_foreground) return;
        _foreground = true;
        _generation++;
        _dictionaryHttp = widget.httpClient ?? http.Client();
        _lookup = _createLookup();
        _clock?.cancel();
        _clock = Timer.periodic(
          const Duration(milliseconds: 250),
          (_) => _highlight(),
        );
        unawaited(_start());
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (!_foreground) return;
        _foreground = false;
        _generation++;
        _clock?.cancel();
        _retry?.cancel();
        _cancelFavoriteWait();
        final String? lookupContext = _dropLookupSession();
        _dictionaryHttp.close();
        _client.cancelPending();
        _disconnecting = _disconnecting.then(
          (_) => _disconnect(lookupContextId: lookupContext),
        );
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  @override
  void dispose() {
    _foreground = false;
    _overlayInert = true;
    _cancelFavoriteWait();
    // 先摘根 Overlay 浮层：entry 一旦移除就不会再用失效的 State 重建。
    final OverlayEntry? entry = _popupOverlayEntry;
    if (entry != null) {
      removeAndDisposeOwnedOverlayEntry(entry);
      _popupOverlayEntry = null;
    }
    final String? lookupContext = _lookupContextId;
    _lookupContextId = null;
    _lookupSerial++;
    _popup.dispose();
    _dictionaryHttp.close();
    _client.cancelPending();
    _generation++;
    _clock?.cancel();
    _retry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_disconnect(lookupContextId: lookupContext));
    super.dispose();
  }

  @override
  void deactivate() {
    _overlayInert = true;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _overlayInert = false;
  }

  /// [lookupContextId] 非空时先结束这次查词（电脑恢复本次查词造成的暂停），再释放
  /// 控制权。用一次性 client：页面自己的 client 此刻已 [VideoRemoteClient.cancelPending]。
  Future<void> _disconnect({String? lookupContextId}) async {
    final VideoRemoteClient cleanup = VideoRemoteClient(
      repository: widget.repository,
      peer: widget.peer,
      httpClient: widget.httpClient,
    );
    try {
      if (lookupContextId != null) {
        try {
          await cleanup.call('lookupEnd', <String, dynamic>{
            'contextId': lookupContextId,
            'requestId': cleanup.requestId(),
          });
        } catch (e, stack) {
          // 释放控制权仍要继续：断开后电脑按租约清掉这次查词上下文。
          ErrorLogService.instance.log('VideoRemote.lookupEnd', e, stack);
        }
      }
      await cleanup.disconnect();
    } catch (_) {
      // A disconnected device releases its lookup ownership through the host lease.
    } finally {
      cleanup.cancelPending();
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    final int generation = _generation;
    try {
      if (mounted) setState(() => _error = '');
      await action();
    } catch (e) {
      if (mounted && _foreground && generation == _generation) {
        final String text = videoRemoteErrorText(e);
        if (text.isNotEmpty) setState(() => _error = text);
      }
    }
  }

  Future<void> _start() async {
    if (_polling || !_foreground || !mounted) return;
    _polling = true;
    final int generation = _generation;
    Object? failure;
    try {
      // A background disconnect must finish before reacquiring this peer's lease.
      await _disconnecting;
      if (!mounted || !_foreground || generation != _generation) return;
      _revision = 0;
      final Map<String, dynamic> initial = await _client.snapshot();
      if (!mounted || !_foreground || generation != _generation) return;
      await _apply(initial);
      _retryAttempt = 0;
      while (mounted && _foreground && generation == _generation) {
        final Map<String, dynamic> response = await _client.events(_revision);
        if (!mounted || !_foreground || generation != _generation) break;
        if (response['reset'] == true) {
          final Map<String, dynamic> reset = await _client.snapshot();
          if (!mounted || !_foreground || generation != _generation) break;
          await _apply(reset);
        } else {
          for (final dynamic event
              in response['events'] as List? ?? <dynamic>[]) {
            if (event['type'] == 'state') {
              if ((event['revision'] as num).toInt() >= _revision) {
                await _apply(<String, dynamic>{
                  ...Map<String, dynamic>.from(event['payload'] as Map),
                  'revision': event['revision'],
                });
              }
            }
          }
        }
        _revision = (response['revision'] as num?)?.toInt() ?? _revision;
      }
    } catch (e, stackTrace) {
      failure = e;
      if (mounted && _foreground && generation == _generation) {
        await _guard(() async => Error.throwWithStackTrace(e, stackTrace));
      }
    } finally {
      _polling = false;
      if (mounted && _foreground && generation != _generation) {
        unawaited(_start());
      }
    }
    if (mounted && _foreground && generation != _generation) {
      return;
    } else if (mounted &&
        _foreground &&
        failure is VideoRemoteError &&
        (failure.statusCode == null ||
            <String>{
              'session_changed',
              'subtitles_changed',
              'controller_lease_lost',
            }.contains(failure.message))) {
      _retry?.cancel();
      _retry = Timer(
        Duration(seconds: 2 << (_retryAttempt++).clamp(0, 2)),
        () => unawaited(_start()),
      );
    }
  }

  Map<String, dynamic> get _session => <String, dynamic>{
    'sessionId': _state['sessionId'],
    'subtitleVersion': _state['subtitleVersion'],
  };
  Future<void> _apply(Map<String, dynamic> value) async {
    final int generation = _generation;
    final int revision = (value['revision'] as num?)?.toInt() ?? _revision;
    if (!mounted || !_foreground || revision < _revision) return;
    final bool changed =
        value['sessionId'] != _cueSessionId ||
        value['subtitleVersion'] != _cueSubtitleVersion;
    final bool favoritesChanged =
        value['favoriteVersion'] != _state['favoriteVersion'];
    setState(() {
      _state = value;
      if (value['error'] != null) {
        _error = videoRemoteErrorText(
          VideoRemoteError(value['error'].toString()),
        );
      }
      _anchor = DateTime.now();
      _revision = (value['revision'] as num?)?.toInt() ?? _revision;
      if (changed) {
        _cues = <Map<String, dynamic>>[];
        _starred.clear();
        _active = -1;
      }
    });
    _syncNowPlayingCover();
    if (changed) {
      final Map<String, dynamic> session = Map<String, dynamic>.from(_session);
      final String key =
          '$generation|${session['sessionId']}|${session['subtitleVersion']}';
      if (_cueLoadKey != key) {
        _cueLoadKey = key;
        _cueLoad = _loadCues(session, value, generation);
      }
      late final List<Map<String, dynamic>> cues;
      try {
        cues = await _cueLoad!;
      } finally {
        if (_cueLoadKey == key) {
          _cueLoadKey = null;
          _cueLoad = null;
        }
      }
      if (mounted &&
          _foreground &&
          generation == _generation &&
          _state['sessionId'] == session['sessionId'] &&
          _state['subtitleVersion'] == session['subtitleVersion']) {
        setState(() {
          _cues = cues;
          _cueSessionId = session['sessionId'] as String?;
          _cueSubtitleVersion = (session['subtitleVersion'] as num?)?.toInt();
          _starred
            ..clear()
            ..addAll(
              cues
                  .where((Map<String, dynamic> c) => c['favorited'] == true)
                  .map((Map<String, dynamic> c) => c['id'].toString()),
            );
          _active = -1;
        });
      }
    }
    if (favoritesChanged || changed) await _loadFavorites();
    _highlight();
    _checkFavoriteReady();
  }

  /// 「正在播放」封面对应的电脑视频（快照 `identity` = bookUid）；换视频才重拉。
  String? _coverIdentity;

  /// 「正在播放」封面（背景取色 + 控制卡缩略图）；没有 / 还没拉到为 null。
  ImageProvider? _nowPlayingCover;

  /// 每部视频只拉一次封面：失败（没有封面 / 旧版电脑）也记住，不在每次快照
  /// 刷新时重试。
  void _syncNowPlayingCover() {
    final String identity = _state['identity']?.toString() ?? '';
    if (identity == _coverIdentity) return;
    _coverIdentity = identity;
    if (_nowPlayingCover != null) setState(() => _nowPlayingCover = null);
    if (identity.isEmpty) return;
    unawaited(
      _client
          .fetchRemoteCover(videoRemoteCoverPath(identity))
          .then(
            (Uint8List bytes) {
              if (!mounted || _coverIdentity != identity || bytes.isEmpty) {
                return;
              }
              setState(() => _nowPlayingCover = MemoryImage(bytes));
            },
            onError: (Object _) {
              // 没有封面：保留应用主题与图标占位，不是错误。
            },
          ),
    );
  }

  Future<List<Map<String, dynamic>>> _loadCues(
    Map<String, dynamic> session,
    Map<String, dynamic> value,
    int generation,
  ) async {
    if (value['available'] != true) return <Map<String, dynamic>>[];
    // Chunks are cached per (sessionId, subtitleVersion) inside the client, so
    // a reconnect or an interrupted load only fetches what is still missing.
    final List<Map<String, dynamic>>? cues = await _client.subtitles(
      sessionId: session['sessionId'].toString(),
      subtitleVersion: (session['subtitleVersion'] as num?)?.toInt() ?? 0,
      expectedTotal: (value['cueCount'] as num?)?.toInt() ?? 0,
      active: () => mounted && _foreground && generation == _generation,
    );
    return cues ?? <Map<String, dynamic>>[];
  }

  void _cancelFavoriteWait() {
    final Completer<Map<String, dynamic>>? waiter = _favoriteCueWaiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(const VideoRemoteError('lookup_cancelled'));
    }
  }

  /// Dual-subtitle lists interleave both tracks by time; the current line and
  /// previous/next navigation follow the primary track only, so a secondary
  /// line at the same instant never steals the highlight or a skip.
  static bool _isPrimary(Map<String, dynamic> cue) =>
      cue['track'] != 'secondary';

  static int _cueStart(Map<String, dynamic> cue) =>
      (cue['startMs'] as num).toInt() +
      ((cue['delayMs'] as num?)?.toInt() ?? 0);

  static int _cueEnd(Map<String, dynamic> cue) =>
      (cue['endMs'] as num).toInt() + ((cue['delayMs'] as num?)?.toInt() ?? 0);

  double get _position {
    final num base = _state['positionMs'] as num? ?? 0;
    final double speed = (_state['speed'] as num?)?.toDouble() ?? 1;
    return base.toDouble() +
        (_state['playing'] == true
            ? DateTime.now().difference(_anchor).inMilliseconds * speed
            : 0);
  }

  void _highlight() {
    if (!mounted || !_foreground || _cues.isEmpty) return;
    final double position = _position;
    final int index = _cues.indexWhere(
      (Map<String, dynamic> c) =>
          _isPrimary(c) && position >= _cueStart(c) && position < _cueEnd(c),
    );
    if (index == _active) return;
    setState(() => _active = index);
  }

  /// The neighbouring primary line in [direction] (-1 / 1) from the current
  /// line, or from the playhead when it sits between lines; -1 when none.
  int _primaryNeighbor(int direction) {
    if (_active >= 0) {
      for (
        int i = _active + direction;
        i >= 0 && i < _cues.length;
        i += direction
      ) {
        if (_isPrimary(_cues[i])) return i;
      }
      return -1;
    }
    final double position = _position;
    int found = -1;
    for (int i = 0; i < _cues.length; i++) {
      final Map<String, dynamic> cue = _cues[i];
      if (!_isPrimary(cue)) continue;
      if (direction > 0 && _cueStart(cue) > position) return i;
      if (direction < 0 && _cueEnd(cue) <= position) found = i;
    }
    return found;
  }

  Future<void> _command(
    String action, {
    String? cueId,
    int? positionMs,
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) => _guard(() async {
    await _client.call('command', <String, dynamic>{
      ..._session,
      'requestId': _client.requestId(),
      'action': action,
      if (cueId != null) 'cueId': cueId,
      if (positionMs != null) 'positionMs': positionMs,
      ...extra,
    });
    await _apply(await _client.snapshot());
  });
  Future<void> _loadFavorites() async {
    final int lifecycle = _generation;
    final int generation = ++_favoriteGeneration;
    if (mounted) setState(() => _favoritesLoading = true);
    try {
      await _fetchFavorites(lifecycle, generation);
    } finally {
      if (mounted && generation == _favoriteGeneration) {
        setState(() => _favoritesLoading = false);
      }
    }
  }

  Future<void> _fetchFavorites(int lifecycle, int generation) async {
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    int total = 0;
    do {
      final Map<String, dynamic> result = await _client.call(
        'favorites',
        <String, dynamic>{
          // 搜索在收藏组件里本地做（与媒体搜索同一归一化口径）。
          'query': '',
          'currentOnly': !_all,
          'sessionId': _state['sessionId'],
          'offset': items.length,
          'limit': 200,
        },
      );
      if (generation != _favoriteGeneration ||
          !mounted ||
          !_foreground ||
          lifecycle != _generation) {
        return;
      }
      final List<dynamic> page = result['items'] as List? ?? <dynamic>[];
      items.addAll(
        page.map((dynamic e) => Map<String, dynamic>.from(e as Map)),
      );
      total = (result['total'] as num?)?.toInt() ?? items.length;
      if (page.isEmpty) break;
    } while (items.length < total);
    final List<Map<String, dynamic>> current = <Map<String, dynamic>>[];
    if (_all) {
      int count = 0;
      do {
        final Map<String, dynamic> page = await _client
            .call('favorites', <String, dynamic>{
              'query': '',
              'currentOnly': true,
              'sessionId': _state['sessionId'],
              'offset': current.length,
              'limit': 200,
            });
        if (generation != _favoriteGeneration ||
            !mounted ||
            !_foreground ||
            lifecycle != _generation) {
          return;
        }
        final List<dynamic> entries = page['items'] as List? ?? <dynamic>[];
        current.addAll(
          entries.map((dynamic e) => Map<String, dynamic>.from(e as Map)),
        );
        count = (page['total'] as num?)?.toInt() ?? current.length;
        if (entries.isEmpty) break;
      } while (current.length < count);
    } else {
      current.addAll(items);
    }
    if (mounted && generation == _favoriteGeneration) {
      setState(() {
        _favorites = items;
        {
          _starred.clear();
          for (final Map<String, dynamic> cue in _cues) {
            if (current.any(
              (Map<String, dynamic> item) =>
                  item['bookUid'] == _state['identity'] &&
                  item['text'] == cue['text'] &&
                  item['startMs'] == cue['startMs'],
            )) {
              _starred.add(cue['id'].toString());
            }
          }
        }
      });
    }
  }

  Future<void> _star(Map<String, dynamic> cue) => _guard(() async {
    final String id = cue['id'].toString();
    final bool value = !_starred.contains(id);
    await _client.call('favoriteSet', <String, dynamic>{
      ..._session,
      'cueId': id,
      'favorited': value,
      'requestId': _client.requestId(),
    });
    if (mounted) {
      setState(() {
        if (value) {
          _starred.add(id);
        } else {
          _starred.remove(id);
        }
      });
    }
    await _loadFavorites();
  });
  // ── 对外接口（`video_remote/` 展示组件只经这里读状态、发命令） ─────────────

  /// 字幕行（主副轨按时间交错）。每行 `{id, text, startMs, endMs, delayMs, track}`。
  List<Map<String, dynamic>> get rows =>
      UnmodifiableListView<Map<String, dynamic>>(_cues);

  /// 当前句（只认主轨）在 [rows] 里的下标；播放头落在两句之间时为 -1。
  int get currentRowIndex => _active;

  /// 副轨行不参与当前句与上一句 / 下一句。
  bool isPrimaryRow(Map<String, dynamic> row) => _isPrimary(row);

  /// 上一句 / 下一句主轨行的下标，没有为 -1。
  int get previousRowIndex => _primaryNeighbor(-1);
  int get nextRowIndex => _primaryNeighbor(1);

  /// 电脑上报的播放快照（`available` / `playing` / `positionMs` / `title` …）。
  Map<String, dynamic> get playbackState =>
      UnmodifiableMapView<String, dynamic>(_state);
  bool get available => _state['available'] == true;
  bool get playing => _state['playing'] == true;
  String? get title => _state['title']?.toString();

  /// 本地按速度推算的当前播放位置（毫秒）。
  double get positionMs => _position;

  Future<void> play() => _command('play');
  Future<void> pause() => _command('pause');
  Future<void> togglePlay() => _command(playing ? 'pause' : 'play');

  /// 跳到 [position]（拖进度条 / ±10 秒）。
  Future<void> seekTo(Duration position) =>
      _command('seek', positionMs: position.inMilliseconds.clamp(0, 1 << 30));

  /// 电脑支持的可选遥控能力（快照 `capabilities`）；旧版电脑不上报 = 全都不支持，
  /// 对应按钮置灰，不会发出它听不懂的命令。
  Set<String> get capabilities => <String>{
    for (final Object? item in _state['capabilities'] as List? ?? <Object?>[])
      item.toString(),
  };

  /// 电脑能否点播（从它的视频库里选片让它播放）；不需要电脑上已开着视频。
  bool get canPickVideo =>
      capabilities.contains(videoRemoteCapabilityOpenVideo);

  /// 点播：列出电脑的视频库，选中后让电脑关掉正在放的（照常落进度）、打开这一部。
  /// 新视频的会话经事件流推过来，本页照常换到它的字幕。
  Future<void> pickVideo() => _guard(() async {
    if (!canPickVideo || !context.mounted) return;
    // 正在查的词属于要被关掉的视频：先收起弹框、结束电脑上的查词上下文。
    closeLookup();
    final String? picked = await showVideoRemoteLibrarySheet(
      context: context,
      load: (String query, int offset) async => VideoRemoteLibraryPage.fromJson(
        await _client.call('library', <String, dynamic>{
          'query': query,
          'offset': offset,
          'limit': 100,
        }),
      ),
      coverFor: _libraryCover,
    );
    if (picked == null || !mounted) return;
    if (available && picked == _state['identity']) return;
    await _client.call('openVideo', <String, dynamic>{
      'bookUid': picked,
      'requestId': _client.requestId(),
    });
  });

  /// 点播行的封面：只拉电脑声明有封面的条目（`coverVersion`），磁盘缓存按
  /// 版本键控（重新刮削换了封面就重拉）。
  ImageProvider? _libraryCover(VideoRemoteLibraryEntry entry) {
    final int? version = entry.coverVersion;
    if (version == null) return null;
    return ResizeImage(
      RemoteCoverImage(
        videoRemoteCoverPath(entry.bookUid),
        _client,
        cacheKey: '${entry.bookUid}@$version',
      ),
      width: 192,
      allowUpscaling: false,
    );
  }

  /// 电脑当前作品的集数（单视频 / 旧版电脑为 0）。
  int get episodeCount => (_state['episodeCount'] as num?)?.toInt() ?? 0;

  /// 电脑音量 0..100；旧版电脑不上报为 null。
  int? get volume => (_state['volume'] as num?)?.round();

  /// 选集 / 字幕轨弹框的数据（电脑上的集列表与主字幕轨）。
  Future<Map<String, dynamic>> _playbackOptions() =>
      _client.call('playbackOptions', <String, dynamic>{..._session});

  /// 选集：列出电脑上这部作品的各集（带封面、打开即在当前集），点选后电脑与剧集
  /// 列表点选同一入口换集。
  Future<void> pickEpisode() => _guard(() async {
    final Map<String, dynamic> session = _session;
    final Map<String, dynamic> options = await _playbackOptions();
    if (!context.mounted) return;
    final List<VideoRemoteEpisodeEntry> episodes = <VideoRemoteEpisodeEntry>[
      for (final Object? item in options['episodes'] as List? ?? <Object?>[])
        if (item is Map)
          VideoRemoteEpisodeEntry.fromJson(Map<String, dynamic>.from(item)),
    ];
    final int? current = episodes
        .where((VideoRemoteEpisodeEntry e) => e.current)
        .map((VideoRemoteEpisodeEntry e) => e.index)
        .firstOrNull;
    final int? picked = await showVideoRemoteEpisodeSheet(
      context: context,
      episodes: episodes,
      coverFor: (VideoRemoteEpisodeEntry entry) =>
          _episodeCover(session, entry.index),
    );
    if (picked == null || picked == current || !mounted) return;
    await _command('episode', extra: <String, dynamic>{'episodeIndex': picked});
  });

  /// 选集第 [index] 集的封面（电脑 `episodeCover`）。缓存键带电脑身份与这次会话：
  /// 换一台电脑、或同一部作品换了集（新会话、同一下标是另一份列表）都不串图。
  ImageProvider _episodeCover(Map<String, dynamic> session, int index) =>
      VideoRemoteCoverImage(
        cacheKey:
            'video-remote-episode-cover|${_client.coverCacheNamespace}|'
            '${session['sessionId']}|$index',
        load: () async {
          final Map<String, dynamic> result = await _client.call(
            'episodeCover',
            <String, dynamic>{...session, 'episodeIndex': index},
          );
          final Object? data = result['data'];
          return data is String ? base64Decode(data) : null;
        },
      );

  /// 电脑能否从手机关掉正在放的视频。
  bool get canCloseVideo =>
      available && capabilities.contains(videoRemoteCapabilityCloseVideo);

  /// 关闭电脑上正在放的视频（电脑走视频页自己的退出流程，进度照常保存）。
  Future<void> closeVideo() => _guard(() async {
    if (!canCloseVideo || !context.mounted) return;
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.video_remote_close_video,
      message: t.video_remote_close_video_confirm,
      confirmLabel: t.video_remote_close_video,
      icon: FushiIcons.stop,
    );
    if (!confirmed || !mounted) return;
    // 正在查的词属于要被关掉的视频：先收起弹框、结束电脑上的查词上下文。
    closeLookup();
    await _client.call('closeVideo', <String, dynamic>{
      'sessionId': _session['sessionId'],
      'requestId': _client.requestId(),
    });
    if (context.mounted) fushiRemoteActionHaptic(context);
    await _apply(await _client.snapshot());
  });

  /// 切换电脑上的主字幕轨（含「关闭字幕」）。
  Future<void> pickSubtitleTrack() => _guard(() async {
    final Map<String, dynamic> options = await _playbackOptions();
    if (!context.mounted) return;
    final List<Map<String, dynamic>> tracks = <Map<String, dynamic>>[
      for (final Object? item
          in options['subtitleTracks'] as List? ?? <Object?>[])
        if (item is Map) Map<String, dynamic>.from(item),
    ];
    // 「关闭字幕」用空串占位（轨 id 永不为空）；「在线搜索字幕」用一个不可能是
    // 轨 id 的值（轨 id 是十六进制摘要）。
    const String off = '';
    const String searchOnline = '\u0000search';
    String? current = options['subtitleOff'] == true ? off : null;
    for (final Map<String, dynamic> track in tracks) {
      if (track['selected'] == true) current = track['id'].toString();
    }
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: t.video_control_subtitle_track,
      icon: FushiIcons.subtitles,
      selected: current,
      options: <FushiChoiceOption<String>>[
        FushiChoiceOption<String>(value: off, label: t.video_subtitle_off),
        for (final Map<String, dynamic> track in tracks)
          FushiChoiceOption<String>(
            value: track['id'].toString(),
            label: track['label']?.toString() ?? '',
            enabled: track['selectable'] != false,
          ),
        if (canSearchSubtitles)
          FushiChoiceOption<String>(
            value: searchOnline,
            label: t.video_subtitle_search_open,
            icon: FushiIcons.search,
          ),
      ],
    );
    if (picked == searchOnline) {
      await searchSubtitlesOnline();
      return;
    }
    if (picked == null || picked == current || !mounted) return;
    await _command(
      'subtitleTrack',
      extra: <String, dynamic>{'trackId': picked == off ? null : picked},
    );
  });

  /// 电脑能否在线搜字幕（快照 `capabilities`）。
  bool get canSearchSubtitles =>
      available && capabilities.contains(videoRemoteCapabilitySubtitleSearch);

  /// 在线搜字幕：电脑按当前视频检索、手机挑一条、电脑下载并应用为主字幕。新字幕
  /// 经事件流（字幕版本变化）推回本页。
  Future<void> searchSubtitlesOnline() async {
    if (!canSearchSubtitles || !context.mounted) return;
    closeLookup();
    final Map<String, Map<String, dynamic>> downloads =
        <String, Map<String, dynamic>>{};
    final bool applied = await showVideoRemoteSubtitleSearchSheet(
      context: context,
      search: (String? query, int? episode) async =>
          VideoRemoteSubtitleSearchResult.fromJson(
            await _client.call('subtitleSearch', <String, dynamic>{
              ..._session,
              if (query != null) 'query': query,
              if (episode != null) 'episode': episode,
            }),
          ),
      // 不走 [_command]：它把错误收进页面错误条，这里要让弹层就地显示原因。
      // 同一条候选重试时原样重发第一次的请求（同 requestId、同会话）：电脑那边
      // 下载若还在跑（超过手机的请求超时）就并进去，不会再下一份、再应用一次。
      // 电脑明确回了错误（有状态码）就丢掉：那个结果会按 requestId 重放，重试
      // 要发新请求。
      download: (String candidateId) async {
        try {
          await _client.call(
            'command',
            downloads.putIfAbsent(
              candidateId,
              () => <String, dynamic>{
                ..._session,
                'requestId': _client.requestId(),
                'action': 'subtitleDownload',
                'candidateId': candidateId,
              },
            ),
          );
        } on VideoRemoteError catch (error) {
          if (error.statusCode != null) downloads.remove(candidateId);
          rethrow;
        }
        downloads.remove(candidateId);
        await _apply(await _client.snapshot());
      },
      errorText: videoRemoteErrorText,
    );
    if (applied && mounted) {
      if (context.mounted) fushiRemoteActionHaptic(context);
      FushiToast.show(
        msg: t.video_remote_subtitle_search_applied,
        severity: ToastSeverity.success,
      );
    }
  }

  /// 把电脑音量设成 [value]（0..100）。
  Future<void> setVolume(int value) => _command(
    'volume',
    extra: <String, dynamic>{'volume': value.clamp(0, 100)},
  );

  /// 音量弹层：松手即把音量发给电脑。
  Future<void> showVolume() => showVideoRemoteVolumeSheet(
    context: context,
    initial: volume ?? 100,
    onCommit: (int value) => unawaited(setVolume(value)),
  );

  /// 跳到 [row] 句首并播放。
  Future<void> seekToRow(Map<String, dynamic> row) =>
      _command('seekCue', cueId: row['id'].toString());

  Future<void> previousRow() {
    final int index = previousRowIndex;
    return index < 0 ? Future<void>.value() : seekToRow(_cues[index]);
  }

  Future<void> nextRow() {
    final int index = nextRowIndex;
    return index < 0 ? Future<void>.value() : seekToRow(_cues[index]);
  }

  /// 收藏列表（当前视频或全部视频，见 [favoritesAllVideos]），已按 [favoritesQuery] 过滤。
  List<Map<String, dynamic>> get favorites =>
      UnmodifiableListView<Map<String, dynamic>>(_favorites);
  bool isRowFavorited(Map<String, dynamic> row) =>
      _starred.contains(row['id'].toString());
  Future<void> toggleRowFavorite(Map<String, dynamic> row) => _star(row);

  bool get favoritesAllVideos => _all;
  Future<void> setFavoritesAllVideos(bool all) {
    setState(() => _all = all);
    return _guard(_loadFavorites);
  }

  /// 批量取消收藏（每批最多 200 条）。
  Future<void> removeFavorites(Set<String> ids) => _guard(() async {
    final List<String> all = ids.toList();
    for (int offset = 0; offset < all.length; offset += 200) {
      final List<String> batch = all.sublist(
        offset,
        (offset + 200).clamp(0, all.length),
      );
      await _client.call('favoritesRemove', <String, dynamic>{
        'ids': batch,
        'requestId': _client.requestId(),
      });
    }
    await _loadFavorites();
  });

  /// 在电脑上打开收藏（跨视频先确认）；[lookup] 为真时打开后直接查这句。
  Future<void> openFavorite(
    Map<String, dynamic> favorite, {
    bool lookup = false,
  }) => _openFavorite(favorite, lookup: lookup);

  /// 当前要给用户看的错误（已本地化，空串 = 无）。
  String get errorText => _error;

  /// 手动重连（重新取快照与事件流）。
  Future<void> reconnect() => _start();

  // ── 查词 ───────────────────────────────────────────────────────────────

  /// 弹框栈里是否有东西在显示（含搜索期占位）。
  bool get lookupOpen => _popup.hasVisiblePopup || _popup.isSearchingUi;

  /// 正在查的词在行内的高亮（画在字幕行 / 收藏卡上）。从存值按「弹框栈还有可见
  /// 层」派生：逐层关到空、返回键、切后台收栈……任何关闭路径都自然清空，不另存
  /// 布尔镜像（与视频页 `_activeSubtitleLookupHighlight` 同口径）。
  VideoRemoteLookupHighlight? get lookupHighlight =>
      _popup.hasVisiblePopup ? _lookupHighlight : null;

  /// 查词入口：在 [row] 的第 [charOffset] 个 grapheme 处查词（行点击传 0 = 从句首
  /// 最长匹配）。[anchor] 是被点词的全局锚点矩形（字幕组件回传的「被点字位→句末」
  /// 字形盒并集，与视频页字幕侧栏同口径），弹框贴着它的上方 / 下方、不盖住词；
  /// 缺省（键盘查词 / 控制卡「制卡」）贴字幕列表当前句高度。[favoriteId] 非空 =
  /// 从收藏卡发起，高亮画在那张卡上，否则画在字幕行上。
  ///
  /// 会话规则：弹框栈与电脑端的一次查词上下文一一对应。第一次点字 `lookupBegin`
  /// （电脑暂停）；弹框开着时再点同一行沿用上下文；点了别的行发带
  /// `replaceContextId`（旧上下文）的 `lookupBegin`，电脑把旧上下文的暂停直接转交给
  /// 新的、不经「恢复再暂停」（老电脑不认这个字段，照旧先结束旧的再开新的）；整个栈
  /// 关掉（[_popAt] 收口）才 `lookupEnd`。
  Future<void> openLookup(
    Map<String, dynamic> row,
    int charOffset, {
    Rect? anchor,
    String? favoriteId,
  }) => _guard(() async {
    if (!_foreground || !mounted) return;
    final String text = row['text'].toString();
    final ({int start, String term}) lookupSpan = subtitleTranscriptLookupSpan(
      text,
      charOffset,
    );
    final String span = lookupSpan.term;
    final String term = span.isNotEmpty ? span : text.trim();
    if (term.isEmpty) return;
    // 换词：旧词的高亮先撤掉，新词查完再按匹配长度画。
    if (_lookupHighlight != null) setState(() => _lookupHighlight = null);
    final int serial = ++_lookupSerial;
    final int generation = _generation;
    final String cueId = row['id'].toString();
    final Rect selection = anchor == null || anchor == Rect.zero
        ? _fallbackAnchor()
        : anchor;
    if (!_lookupBoundTo(cueId)) {
      final String? previous = _lookupContextId;
      _clearLookupContext();
      final Map<String, dynamic> begun;
      try {
        begun = await _client.call('lookupBegin', <String, dynamic>{
          ..._session,
          'cueId': cueId,
          'requestId': _client.requestId(),
          if (previous != null) 'replaceContextId': previous,
        });
      } catch (_) {
        // 没开成新上下文：旧的还挂在电脑上（会话 / 字幕已变、这一行没了），照旧
        // 结束它，电脑只恢复它自己造成的暂停。已被转交过的旧上下文，电脑当未知忽略。
        if (previous != null) unawaited(_guard(() => _sendLookupEnd(previous)));
        rethrow;
      }
      final String contextId = begun['contextId'].toString();
      if (serial != _lookupSerial ||
          !mounted ||
          !_foreground ||
          generation != _generation) {
        // 等电脑回话期间用户已关栈 / 换了行 / 切到后台：这次上下文作废。后台时
        // 断开流程会结束它，这里只处理前台的情形。
        if (mounted && _foreground && generation == _generation) {
          await _sendLookupEnd(contextId);
        }
        return;
      }
      _lookupContextId = contextId;
      _lookupCueId = cueId;
      _lookupSessionId = _state['sessionId']?.toString();
      _lookupSubtitleVersion = (_state['subtitleVersion'] as num?)?.toInt();
    }
    _ensureWarmPopup();
    final int matchedRunes = await pushNestedPopup(
      query: term,
      selectionRect: selection,
      controller: _popup,
      replaceStack: true,
      // 顶层查词原地复用常驻热槽 WebView（BUG-094）；低内存无热槽时清栈重建。
      reuseWarmSlot: true,
      autoRead: true,
    );
    // BUG-2091 同语义：按引擎回报的匹配长度在行内高亮被查词；查无词条（0）不高亮。
    // 查词期间又点了别的词 / 栈已关（serial 变了 / 栈空）就不再画这次的。有词条
    // 的结果要等 WebView 渲染才翻可见：这里先存，[lookupHighlight] 翻可见后才露出。
    if (mounted && serial == _lookupSerial && _popup.entries.isNotEmpty) {
      final int count = lookupHighlightGraphemeCount(term, matchedRunes);
      final VideoRemoteLookupHighlight? next =
          count > 0 && lookupSpan.start >= 0 && span.isNotEmpty
          ? VideoRemoteLookupHighlight(
              surface: favoriteId == null
                  ? VideoRemoteLookupSurface.transcript
                  : VideoRemoteLookupSurface.favorite,
              id: favoriteId ?? row['id'].toString(),
              text: text,
              graphemeStart: lookupSpan.start,
              graphemeCount: count,
            )
          : null;
      if (next != _lookupHighlight) setState(() => _lookupHighlight = next);
    }
    // 搜索期间用户可能已把栈关掉（那时上下文已结束）；这里只补「查完发现栈已空」。
    _endLookupIfClosed();
  });

  /// 关掉整个弹框栈（返回键 / 外部调用）。电脑端上下文随之结束。
  void closeLookup() {
    if (_popup.entries.isEmpty && _lookupContextId == null) return;
    _popAt(0);
  }

  /// 当前上下文是否就是 [cueId] 这一行、且字幕会话没变——是才能复用。
  bool _lookupBoundTo(String cueId) =>
      _lookupContextId != null &&
      _lookupCueId == cueId &&
      _lookupSessionId == _state['sessionId']?.toString() &&
      _lookupSubtitleVersion == (_state['subtitleVersion'] as num?)?.toInt();

  void _clearLookupContext() {
    _lookupContextId = null;
    _lookupCueId = null;
    _lookupSessionId = null;
    _lookupSubtitleVersion = null;
  }

  Future<void> _sendLookupEnd(String contextId) async {
    await _client.call('lookupEnd', <String, dynamic>{
      'contextId': contextId,
      'requestId': _client.requestId(),
    });
  }

  /// 弹框栈关闭的**唯一**收口：barrier 点外面 / 横滑、X、返回键、[closeLookup]
  /// 都走这里。关的只是嵌套的一层（栈里还有可见层）或还在搜索时不结束上下文。
  void _popAt(int index) {
    if (index >= 0) popNestedPopupAt(index, _popup);
    if (mounted &&
        _lookupHighlight != null &&
        !_popup.hasVisiblePopup &&
        !_popup.isSearchingUi) {
      setState(() => _lookupHighlight = null);
    }
    _endLookupIfClosed();
  }

  void _endLookupIfClosed() {
    if (!mounted || _popup.hasVisiblePopup || _popup.isSearchingUi) return;
    final String? contextId = _lookupContextId;
    if (contextId == null) return;
    _lookupSerial++;
    _clearLookupContext();
    unawaited(_guard(() => _sendLookupEnd(contextId)));
  }

  /// 后台：收起弹框栈并交出要结束的上下文（由断开流程用一次性 client 发
  /// `lookupEnd`，见 [_disconnect]）。
  String? _dropLookupSession() {
    final String? contextId = _lookupContextId;
    _lookupSerial++;
    _clearLookupContext();
    if (mounted && (_popup.entries.isNotEmpty || _lookupHighlight != null)) {
      setState(() {
        if (_popup.entries.isNotEmpty) _popup.dismissAt(0);
        _lookupHighlight = null;
      });
    }
    return contextId;
  }

  /// 常驻热槽（BUG-094）：第一次查词时才 seed——那时 AppModel 一定已初始化。
  void _ensureWarmPopup() {
    _popup.lowMemory = mixinAppModel.lowMemoryMode;
    _popup.seedWarmSlot();
  }

  /// 没有按下点（键盘查词）时：贴在字幕列表当前句所在的高度（横屏在右栏）。
  Rect _fallbackAnchor() {
    final Size screen = MediaQuery.sizeOf(context);
    final double x = screen.width > screen.height
        ? screen.width * 0.68
        : screen.width / 2;
    return Rect.fromCenter(
      center: Offset(x, screen.height * 0.42),
      width: 24,
      height: 24,
    );
  }

  void _reportLookupError(Object error) {
    if (!mounted || !_foreground) return;
    final String text = videoRemoteErrorText(error);
    if (text.isNotEmpty) setState(() => _error = text);
  }

  // ── DictionaryPageMixin 注入点：数据源 / 发音 / 制卡都去钉住的那台电脑 ─────

  @override
  Future<DictionarySearchResult> searchPopupDictionary({
    required String term,
    required int maximumTerms,
    List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
  }) async {
    final DictionarySearchResult? found;
    try {
      found = await _lookup.searchDictionary(
        term: term,
        wildcards: true,
        maximumTerms: maximumTerms,
        // 字幕原文自带的振假名（以 term 为坐标系）一并交给电脑，电脑按读音排同长度候选。
        rubySpans: rubySpans,
        // 不带 `language`：被查的字幕在电脑上播放，查词语言归电脑（电脑视频页按字幕
        // 语言登记查词来源语言）。遥控端本机的查词语言与这次查词无关。
      );
    } catch (e) {
      // 电脑不可达 / 配对被拒：横幅报原因，弹框按「没查到」收尾（不留半截搜索态）。
      _reportLookupError(e);
      return DictionarySearchResult(searchTerm: term);
    }
    final DictionarySearchResult result =
        found ?? DictionarySearchResult(searchTerm: term);
    try {
      // 渲染前备好那台电脑的词典样式；缺了只是难看，不挡结果。
      await _resources.prefetchStyles(result);
    } catch (e, stack) {
      ErrorLogService.instance.log('VideoRemote.dictionaryStyles', e, stack);
    }
    return result;
  }

  @override
  Future<bool> playPopupWordAudio(
    String expression,
    String reading,
    DictionaryPopupWebViewState? popupState,
  ) async {
    final String? ref;
    try {
      ref = await _resources.wordAudioRef(expression, reading);
    } catch (e, stack) {
      ErrorLogService.instance.log('VideoRemote.wordAudio', e, stack);
      return false;
    }
    return playResolvedLookupAudio(
      ref,
      label: expression,
      playInWebView: popupState?.playWordAudioUrl,
    );
  }

  // ── 「高级制卡」：草稿只在电脑端（本次查词上下文里），手机只发命令 ──────────────
  //
  // 与视频页同一个「高级制卡」对话框（mixin 的 `_openAdvancedMiningDialog`）：
  // 草稿模型、上下 N 句的取法、预览 map、合成文本 / 区间全在电脑端，手机经
  // `lookupContext` 驱动它；制卡时电脑按这份草稿出卡（见 [onMineEntry]）。试听也在
  // 电脑的播放器上放——手机没有视频音频。

  /// 电脑最近一次回的上下文预览：命令失败时给对话框兜底，不让它卡在加载态。
  Map<String, Object?>? _contextPreview;

  /// 发一条 `lookupContext` 命令，回电脑的最新预览；失败（查词已结束 / 字幕变了 /
  /// 电脑不可达）回 null，并按 [report] 用 toast 报原因（弹框此时停靠屏外，横幅
  /// 被对话框盖住）。
  Future<Map<String, Object?>?> _lookupContext(
    String action, {
    Map<String, dynamic> args = const <String, dynamic>{},
    bool report = true,
  }) async {
    final String? contextId = _lookupContextId;
    try {
      if (contextId == null) throw const VideoRemoteError('lookup_expired');
      final Map<String, dynamic> result = await _client
          .call('lookupContext', <String, dynamic>{
            ...args,
            'contextId': contextId,
            'requestId': _client.requestId(),
            'action': action,
          });
      return _contextPreview = Map<String, Object?>.of(result);
    } catch (e) {
      final String text = report ? videoRemoteErrorText(e) : '';
      if (text.isNotEmpty) {
        FushiToast.show(msg: text, severity: ToastSeverity.warning);
      }
      return null;
    }
  }

  /// 电脑答不上来时的预览：上一份电脑预览，或只有被查那一行。
  Map<String, Object?> _contextFallback() {
    final Map<String, Object?>? last = _contextPreview;
    if (last != null) return last;
    String current = '';
    for (final Map<String, dynamic> row in _cues) {
      if (row['id']?.toString() == _lookupCueId) {
        current = row['text']?.toString() ?? '';
        break;
      }
    }
    return <String, Object?>{
      'prev': const <String>[],
      'current': current,
      'next': const <String>[],
      'total': 0,
    };
  }

  @override
  Future<Map<String, Object?>> Function()?
  get onSentenceContextPreviewToDraft => () async {
    _contextPreview = null;
    return await _lookupContext('preview') ?? _contextFallback();
  };

  @override
  Future<int> Function(int prevCount, int nextCount)?
  get onSetSentenceContextToDraft => (int prevCount, int nextCount) async {
    final Map<String, Object?> preview =
        await _lookupContext(
          'set',
          args: <String, dynamic>{'prev': prevCount, 'next': nextCount},
        ) ??
        _contextFallback();
    return (preview['total'] as num?)?.toInt() ?? 0;
  };

  @override
  Future<int> Function()? get onClearSentenceDraftToDraft => () async {
    await _lookupContext('clear');
    return 0;
  };

  @override
  Future<void> Function(SentenceContextSlot slot, int index, String text)?
  get onEditSentenceContextText =>
      (SentenceContextSlot slot, int index, String text) async {
        await _lookupContext(
          'edit',
          args: <String, dynamic>{
            'slot': slot.name,
            'index': index,
            'text': text,
          },
        );
      };

  @override
  Future<void> Function(SentenceContextSlot slot, int index, bool removed)?
  get onRemoveSentenceContext =>
      (SentenceContextSlot slot, int index, bool removed) async {
        await _lookupContext(
          'remove',
          args: <String, dynamic>{
            'slot': slot.name,
            'index': index,
            'removed': removed,
          },
        );
      };

  @override
  Future<bool> Function()? get onPreviewSentenceAudioToDraft =>
      () async => (await _lookupContext('previewAudio'))?['played'] == true;

  @override
  Future<void> Function()? get onStopSentenceAudioPreviewToDraft => () async {
    await _lookupContext('stopAudio', report: false);
  };

  /// 卡组由电脑那台的 Anki 设置决定，手机本地的卡组列表对它没有意义——不给卡组分区。
  @override
  bool get advancedMiningDeckChoiceAvailable => false;

  /// 「高级制卡」（手机遥控）：只有句子分区，仍经 `lookupContext` 驱动电脑上的草稿。
  /// 句子音频与画面都在电脑上抽、按电脑的设置出卡，手机这边不提供音频 / 图片分区。
  /// 对话框关闭时停掉电脑上可能还在放的试听。
  @override
  Future<AdvancedMiningSections> buildAdvancedMiningSections({
    required String matched,
  }) async => AdvancedMiningSections(
    sentence: AdvancedMiningSentenceSection(
      fetchPreview: onSentenceContextPreviewToDraft!,
      setContext: onSetSentenceContextToDraft!,
      editSentence: onEditSentenceContextText,
      removeSentence: onRemoveSentenceContext,
    ),
    onClosed: onStopSentenceAudioPreviewToDraft,
  );

  /// 制卡交给电脑：用电脑本地的 Anki 配置，素材从电脑正在播的视频按本次查词绑定的
  /// 字幕句抽取。网络失败（没拿到任何响应）时才按 requestId 回查任务——电脑明确
  /// 拒绝（lookup_expired / mining_busy …）就是结局，不能被 task_missing 盖掉。
  @override
  Future<MinePopupResult> onMineEntry(Map<String, String> fields) async {
    final String? contextId = _lookupContextId;
    final int generation = _generation;
    if (contextId == null) {
      _showMineFailure(const VideoRemoteError('lookup_expired'));
      return const MinePopupResult();
    }
    FushiToast.showMine(
      msg: t.card_mining_pending,
      status: MineToastStatus.pending,
    );
    try {
      final Map<String, dynamic> task = await _runRemoteMine(
        contextId,
        await _portableMineFields(fields),
        generation,
      );
      return _mineResult(task);
    } catch (e) {
      _showMineFailure(e);
      return const MinePopupResult();
    }
  }

  Future<Map<String, dynamic>> _runRemoteMine(
    String contextId,
    Map<String, String> fields,
    int generation,
  ) async {
    final String requestId = _client.requestId();
    final String sentence = fields['sentence'] ?? '';
    Map<String, dynamic> task;
    try {
      task = await _client.call('mine', <String, dynamic>{
        'contextId': contextId,
        'requestId': requestId,
        'fields': <String, dynamic>{
          'rawFields': fields,
          // 空句子不发：电脑端用本次查词绑定的字幕句。
          if (sentence.isNotEmpty) 'sentence': sentence,
        },
      });
    } on VideoRemoteError catch (e) {
      if (e.statusCode != null) rethrow;
      task = await _client.call('mineStatus', <String, dynamic>{
        'requestId': requestId,
      });
    }
    while (task['status'] == 'queued' || task['status'] == 'running') {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted || !_foreground || generation != _generation) {
        throw const VideoRemoteError('lookup_cancelled');
      }
      task = await _client.call('mineStatus', <String, dynamic>{
        'taskId': task['taskId'],
      });
    }
    return task;
  }

  MinePopupResult _mineResult(Map<String, dynamic> task) {
    if (task['status'] == 'succeeded') {
      FushiToast.showMine(
        msg: t.video_remote_mined,
        status: MineToastStatus.added,
      );
      // 卡已在电脑的 Anki 里，但手机查不了那边的重（查重入口已禁用）：按「已收下」
      // 画 ✓，不让弹窗回查本机 Anki 再把按钮翻回「+」。
      return const MinePopupResult.queued();
    }
    final Object? result = task['result'];
    if (result is Map && result['duplicate'] == true) {
      FushiToast.showMine(
        msg: t.card_duplicate,
        status: MineToastStatus.duplicate,
      );
      return const MinePopupResult(duplicate: true);
    }
    _showMineFailure(
      VideoRemoteError((task['error'] ?? 'mining_failed').toString()),
    );
    return const MinePopupResult();
  }

  void _showMineFailure(Object error) {
    final String text = videoRemoteErrorText(error);
    if (text.isEmpty) return;
    FushiToast.showMine(msg: text, status: MineToastStatus.failed);
  }

  /// 弹窗给的单词音频引用若是手机本地文件（钉扎 HTTPS 下电脑发音被物化到本机缓存），
  /// 电脑打不开它：内联成 `data:` URI 带过去；超过上限或已不存在就不带音频。
  Future<Map<String, String>> _portableMineFields(
    Map<String, String> fields,
  ) async {
    final String audio = fields['audio'] ?? '';
    if (audio.isEmpty ||
        audio.startsWith('data:') ||
        audio.startsWith('http://') ||
        audio.startsWith('https://')) {
      return fields;
    }
    final String path = audio.startsWith('file://')
        ? Uri.parse(audio).toFilePath()
        : audio;
    final File file = File(path);
    if (!await file.exists() ||
        await file.length() > _kMaxInlineWordAudioBytes) {
      return <String, String>{...fields, 'audio': ''};
    }
    final String mime = mimeTypeForFilePath(path, fallback: 'audio/mpeg');
    return <String, String>{
      ...fields,
      'audio': 'data:$mime;base64,${base64Encode(await file.readAsBytes())}',
    };
  }

  static const int _kMaxInlineWordAudioBytes = 4 * 1024 * 1024;

  // 以下入口默认打到**手机本机**的 Anki / 收藏库，而卡与收藏都在电脑上：一律禁用，
  // 弹框随之退回「+ / ✓」两态。词收藏没有遥控协议（遥控只有按字幕句收藏）。

  @override
  Future<bool> checkDuplicate(String expression, String reading) async => false;

  @override
  Future<int?> findOverwriteTargetNoteId(
    String expression,
    String reading,
  ) async => null;

  @override
  Future<MinePopupResult> onUpdateEntry(
    int noteId,
    Map<String, String> fields,
  ) async => const MinePopupResult();

  @override
  Future<MinePopupResult> onMinedCardAction(Map<String, String> fields) async =>
      const MinePopupResult();

  /// BUG-3492：卡在电脑那边制，手机既查不了那边的重、也不做远程覆盖（所有者
  /// 2026-10-17 拍板）——只如实说一声。
  @override
  Future<QueuedOverwriteReply> onQueueOverwrite(
    Map<String, String> fields,
  ) async => QueuedOverwriteReply(message: t.video_remote_overwrite_pending);

  @override
  Future<AnkiOpenWordOutcome> onOpenInAnki(
    String expression,
    String reading,
  ) async => AnkiOpenWordOutcome.failed;

  @override
  Future<bool> onFavoriteEntry(Map<String, String> fields) async => false;

  @override
  Future<bool> onFavoriteCheck(String expression, String reading) async =>
      false;

  // ── 根 Overlay 浮层 ────────────────────────────────────────────────────

  void _syncPopupOverlay() {
    if (!mounted) return;
    if (_popup.entries.isEmpty) {
      final OverlayEntry? entry = _popupOverlayEntry;
      if (entry != null) {
        removeAndDisposeOwnedOverlayEntry(entry);
        _popupOverlayEntry = null;
      }
      return;
    }
    final OverlayEntry? existing = _popupOverlayEntry;
    if (existing != null) {
      if (existing.mounted) existing.markNeedsBuild();
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(builder: _buildPopupOverlay);
    _popupOverlayEntry = entry;
    overlay.insert(entry);
  }

  /// 浮层子树：dismiss barrier + 搜索期占位 + 各层弹框 + 停驻层。每个子项都接了
  /// 对话框隐藏计数（守卫 `lookup_overlay_dialog_gate_guard_test.dart`）。
  Widget _buildPopupOverlay(BuildContext overlayContext) {
    if (!mounted || _overlayInert) return const SizedBox.shrink();
    return LookupOverlayNavigator(
      child: FushiAppUiScaleNeutralizer(
        child: Theme(
          data:
              mixinAppModel.overrideDictionaryTheme ?? Theme.of(overlayContext),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              if (!mounted || _overlayInert) return const SizedBox.shrink();
              final Size screen = Size(
                constraints.maxWidth,
                constraints.maxHeight,
              );
              return Stack(
                // 隐藏热槽停在屏幕右外侧预热（BUG-135），不能裁。
                clipBehavior: Clip.none,
                children: <Widget>[
                  if (shouldShowLookupDismissBarrier(
                    hasVisiblePopup: _popup.hasVisiblePopup,
                    isSearching: _popup.isSearchingUi,
                    hiddenByDialog: lookupPopupHiddenByDialog,
                  ))
                    Positioned.fill(
                      child: LookupDismissBarrier(
                        onTapDismiss: (_) => _popAt(0),
                        onSwipeDismiss: () => _popAt(_popup.lastVisibleIndex),
                        swipeEnabled:
                            ReaderFushiSource.instance.enableSwipeToClose,
                        touchSwipeEnabled:
                            ReaderFushiSource.instance.enableTouchSwipeToClose,
                        sensitivity:
                            ReaderFushiSource.instance.dismissSwipeSensitivity,
                        onNonPrimaryButtonDown:
                            onDismissBarrierNonPrimaryButton,
                      ),
                    ),
                  if (_popup.isSearchingUi && _popup.pendingRect != null)
                    buildPopupLoadingPlaceholder(
                      rect: _popup.pendingRect!,
                      screen: screen,
                    ),
                  for (int i = 0; i < _popup.entries.length; i++)
                    _buildNestedPopupLayer(i, screen),
                  ...buildParkedRealmLayers(screen: screen, controller: _popup),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildNestedPopupLayer(int index, Size screen) =>
      buildNestedPopupLayer(
        index: index,
        screen: screen,
        controller: _popup,
        // 嵌套查词共用同一个电脑端上下文：只压子层，不再 lookupBegin。
        onPush: (String text, Rect rect, List<FushiRubySpan> rubySpans) =>
            pushNestedPopup(
              query: text,
              selectionRect: rect,
              controller: _popup,
              rubySpans: rubySpans,
            ),
        onPop: _popAt,
        autoReadOnNavigate: true,
      );

  bool _isFavoriteSession(Map<String, dynamic> favorite) =>
      _state['available'] == true &&
      favorite['bookUid'] == _state['identity'] &&
      (favorite['sectionIndex'] ?? 0) == (_state['sectionIndex'] ?? 0) &&
      _cueSessionId == _state['sessionId'] &&
      _cueSubtitleVersion == _state['subtitleVersion'];

  Map<String, dynamic>? _favoriteCue(Map<String, dynamic> favorite) {
    if (!_isFavoriteSession(favorite)) return null;
    final List<Map<String, dynamic>> matches = _cues
        .where(
          (Map<String, dynamic> cue) =>
              cue['text'] == favorite['text'] &&
              cue['startMs'] == favorite['startMs'],
        )
        .toList();
    if (matches.length > 1) {
      throw const VideoRemoteError('favorite_subtitle_ambiguous');
    }
    return matches.firstOrNull;
  }

  void _checkFavoriteReady() {
    final Completer<Map<String, dynamic>>? waiter = _favoriteCueWaiter;
    final Map<String, dynamic>? favorite = _favoriteTarget;
    if (waiter == null || waiter.isCompleted || favorite == null) return;
    try {
      if (_state['error'] != null) {
        throw VideoRemoteError(_state['error'].toString());
      }
      final Map<String, dynamic>? cue = _favoriteCue(favorite);
      if (cue != null) waiter.complete(cue);
    } catch (e, stack) {
      waiter.completeError(e, stack);
    }
  }

  Future<Map<String, dynamic>> _waitForFavoriteCue(
    Map<String, dynamic> favorite,
  ) async {
    final Completer<Map<String, dynamic>> waiter =
        Completer<Map<String, dynamic>>();
    _favoriteTarget = favorite;
    _favoriteCueWaiter = waiter;
    _checkFavoriteReady();
    try {
      return await waiter.future.timeout(
        const Duration(seconds: 35),
        onTimeout: () =>
            throw const VideoRemoteError('favorite_subtitle_unavailable'),
      );
    } finally {
      if (identical(waiter, _favoriteCueWaiter)) {
        _favoriteCueWaiter = null;
        _favoriteTarget = null;
      }
    }
  }

  /// [anchor] 是收藏卡上被点词的全局锚点矩形：收藏就在电脑当前视频里、能直接
  /// 查时贴着它弹；要先确认并切视频、等那句 cue 到位的路径上，收藏列表会随新
  /// 视频重排 / 重取，那个矩形已不可信，退回 [_fallbackAnchor]。
  Future<void> _openFavorite(
    Map<String, dynamic> favorite, {
    bool lookup = false,
    int charOffset = 0,
    Rect? anchor,
  }) => _guard(() async {
    final int generation = _generation;
    if (_favoriteCueWaiter != null) return;
    final String favoriteId = favorite['id'].toString();
    if (lookup) {
      final Map<String, dynamic>? cue = _favoriteCue(favorite);
      if (cue != null) {
        await openLookup(
          cue,
          charOffset,
          anchor: anchor,
          favoriteId: favoriteId,
        );
        return;
      }
    }
    // 根 Overlay 上的查词浮层排在对话框路由之上：对话框期间整栈让位。
    final bool confirmed = await runWithLookupPopupHidden<bool>(
      () => showFushiConfirmDialog(
        context: context,
        title: t.video_remote_open_favorite,
        message: favorite['title'].toString(),
        cancelLabel: t.cancel,
        confirmLabel: t.play,
      ),
    );
    if (!confirmed || !mounted || !_foreground || generation != _generation) {
      return;
    }
    await _client.call('openFavorite', <String, dynamic>{
      'id': favorite['id'],
      'requestId': _client.requestId(),
    });
    await _apply(await _client.snapshot());
    if (lookup) {
      if (!mounted || !_foreground || generation != _generation) return;
      final Map<String, dynamic> cue = await _waitForFavoriteCue(favorite);
      if (mounted && _foreground && generation == _generation) {
        await openLookup(cue, charOffset, favoriteId: favoriteId);
      }
    }
  });
  @override
  Widget build(BuildContext context) {
    // 弹框挂在根 Overlay：本页每次重建（mixin 改栈后都会 setState）后同步过去。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPopupOverlay());
    final _TranscriptProjection projection = _projectTranscript();
    _lineRows = projection.rows;
    return PopScope(
      // 弹框开着时返回键先关弹框（逐层），触控板开着时先退回遥控器，不退出遥控页。
      canPop: !lookupOpen && !_touchpad,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        if (_touchpad) {
          setTouchpad(false);
          return;
        }
        final int top = _popup.lastVisibleIndex;
        _popAt(top >= 0 ? top : 0);
      },
      child: Scaffold(
        body: AnimatedSwitcher(
          duration: fushiMotionDuration(
            context,
            const Duration(milliseconds: 220),
          ),
          child: _touchpad ? _touchpadView() : _scaffold(projection),
        ),
      ),
    );
  }

  /// 触控板：整屏手势遥控（不看手机也能按），见 [VideoRemoteTouchpad]。
  Widget _touchpadView() {
    final Map<String, dynamic>? current = _active >= 0 && _active < _cues.length
        ? _cues[_active]
        : null;
    return VideoRemoteTouchpad(
      key: const ValueKey<String>('video-remote-touchpad-view'),
      line: current?['text']?.toString() ?? '',
      playing: playing,
      caretActive: caretActive,
      caretAvailable: canDriveCaret,
      onAction: _onTouchpadAction,
      onExit: () => setTouchpad(false),
    );
  }

  /// 电脑上字幕选词光标在哪（快照 `caret`：`none` / `video` / `popup`）；旧版
  /// 电脑不上报 = `none`。
  String get caretSurface => _state['caret']?.toString() ?? 'none';

  /// 电脑上的选词光标开着（触控板据此切到选词手势）。
  bool get caretActive => caretSurface != 'none';

  /// 电脑支持从手机驱动选词光标（查词卡弹在电脑屏幕上）。
  bool get canDriveCaret =>
      available && capabilities.contains(videoRemoteCapabilityCaret);

  /// 还没发出的选词光标步（步名, 步数）。按顺序一条接一条发；连拖时排着的同向
  /// 挪动并成一条（`count`），慢网络下手指停了光标也不会继续往前跑很远。
  final List<(String, int)> _caretPending = <(String, int)>[];
  bool _caretSending = false;

  /// 排一步选词光标命令。
  void _sendCaret(String step) {
    final (String, int)? last = _caretPending.isEmpty
        ? null
        : _caretPending.last;
    if (last != null &&
        last.$1 == step &&
        videoRemoteCaretMoves.contains(step) &&
        last.$2 < videoRemoteCaretMaxCount) {
      _caretPending.last = (step, last.$2 + 1);
    } else {
      _caretPending.add((step, 1));
    }
    if (!_caretSending) unawaited(_drainCaret());
  }

  /// 依次发出排着的光标步。电脑回报光标落在哪，本页据此切换触控板手势；回报
  /// `none`（光标已退出，或电脑上有人用键盘退了它）时余下的步作废。
  Future<void> _drainCaret() async {
    _caretSending = true;
    try {
      while (_caretPending.isNotEmpty) {
        final (String step, int count) = _caretPending.removeAt(0);
        if (!mounted || !available) {
          _caretPending.clear();
          return;
        }
        try {
          final Map<String, dynamic> result = await _client
              .call('command', <String, dynamic>{
                ..._session,
                'requestId': _client.requestId(),
                'action': 'caret',
                'caret': step,
                if (count > 1) 'count': count,
              });
          if (!mounted) return;
          final String surface = result['caret']?.toString() ?? 'none';
          setState(
            () => _state = <String, dynamic>{..._state, 'caret': surface},
          );
          if (surface == 'none') {
            _caretPending.clear();
            if (step == 'enter') {
              FushiToast.show(
                msg: t.video_remote_touchpad_caret_unavailable,
                severity: ToastSeverity.warning,
              );
            }
          }
        } catch (error) {
          _caretPending.clear();
          if (!mounted) return;
          final String text = videoRemoteErrorText(error);
          if (text.isNotEmpty) setState(() => _error = text);
        }
      }
    } finally {
      _caretSending = false;
    }
  }

  Widget _scaffold(_TranscriptProjection projection) {
    return KeyedSubtree(
      key: const ValueKey<String>('video-remote-scaffold-view'),
      child: VideoRemoteScaffold(
        nowPlaying: _nowPlaying(),
        lines: projection.lines,
        activeIndex: projection.activeLine,
        favorites: _favoriteEntries(),
        favoritesScope: _all
            ? VideoRemoteFavoritesScope.allVideos
            : VideoRemoteFavoritesScope.currentVideo,
        favoritesLoading: _favoritesLoading,
        controlLayout: _controlLayout(),
        clock: _playbackClock,
        notice: _notice(),
        initialTab: _tab,
        onTabChanged: (VideoRemoteTab tab) {
          _tab = tab;
          if (tab == VideoRemoteTab.favorites) {
            unawaited(_guard(_loadFavorites));
          }
        },
        isControlEnabled: controlEnabled,
        transcriptReplayKey:
            '${_state['sessionId']}|${_state['subtitleVersion']}',
        lookupHighlight: lookupHighlight,
        // 弹框开着时列表区不响应横滑切页（不和弹框的横滑关闭 / 逐字点击抢手势）。
        pageSwipeEnabled: !lookupOpen,
        callbacks: VideoRemoteCallbacks(
          onBack: () => unawaited(Navigator.of(context).maybePop()),
          onControl: (VideoRemoteControlItem item) =>
              unawaited(_onControl(item)),
          // 锚点是字幕组件回传的被点词矩形（与视频页字幕侧栏同口径）：弹框
          // 贴着词的正上方 / 正下方，不盖住它。
          onLookup: (int line, int charOffset, Rect anchor) {
            if (line < 0 || line >= _lineRows.length) return;
            unawaited(openLookup(_lineRows[line], charOffset, anchor: anchor));
          },
          onLineTap: (int line) => _withLine(line, seekToRow),
          onReplayLine: (int line) => _withLine(line, seekToRow),
          onToggleFavoriteLine: (int line) =>
              _withLine(line, toggleRowFavorite),
          // 制卡要先选词：打开这一句的查词弹框，在弹框里点 ＋。
          onMineLine: (int line) =>
              _withLine(line, (Map<String, dynamic> row) => openLookup(row, 0)),
          onFavoritesScopeChanged: (VideoRemoteFavoritesScope scope) =>
              unawaited(
                setFavoritesAllVideos(
                  scope == VideoRemoteFavoritesScope.allVideos,
                ),
              ),
          onOpenFavorite: (VideoRemoteFavoriteEntry entry) {
            final Map<String, dynamic>? favorite = _favoriteById(entry.id);
            if (favorite != null) unawaited(openFavorite(favorite));
          },
          onLookupFavorite:
              (VideoRemoteFavoriteEntry entry, int offset, Rect anchor) {
                final Map<String, dynamic>? favorite = _favoriteById(entry.id);
                if (favorite == null) return;
                unawaited(
                  _openFavorite(
                    favorite,
                    lookup: true,
                    charOffset: offset,
                    anchor: anchor,
                  ),
                );
              },
          onRemoveFavorites: (Set<String> ids) =>
              unawaited(removeFavorites(ids)),
          onRefresh: () => unawaited(reconnect()),
          onPickVideo: canPickVideo ? () => unawaited(pickVideo()) : null,
          onCloseVideo: canCloseVideo ? () => unawaited(closeVideo()) : null,
          onOpenTouchpad: available ? () => setTouchpad(true) : null,
          onSeek: available ? (Duration to) => unawaited(seekTo(to)) : null,
          onCustomizeControls: _prefs == null
              ? null
              : () => unawaited(
                  runWithLookupPopupHidden<void>(
                    () => showVideoRemoteControlEditor(context, prefs: _prefs),
                  ),
                ),
        ),
      ),
    );
  }

  /// 是否在触控板模式（[setTouchpad]）。
  bool get touchpadOpen => _touchpad;

  /// 进 / 出触控板。进入时收起查词弹框（触控板盖住了它所属的字幕行）。
  void setTouchpad(bool open) {
    if (open == _touchpad) return;
    if (open) closeLookup();
    // 离开触控板时把电脑上的选词光标收掉（逐层关卡、最后退出光标并恢复它暂停
    // 的播放）：回到遥控器后再没有手段操作它。回报 `none` 后余下的后退作废。
    if (!open && canDriveCaret && caretActive) {
      for (int i = 0; i < 6; i++) {
        _sendCaret('back');
      }
    }
    setState(() => _touchpad = open);
  }

  /// 触控板操作 → 遥控命令；返回 false = 这一下做不了（不震、不闪图标）。
  bool _onTouchpadAction(VideoRemotePadAction action) {
    if (!available) return false;
    final Map<String, dynamic>? current = _active >= 0 && _active < _cues.length
        ? _cues[_active]
        : null;
    switch (action) {
      case VideoRemotePadAction.playPause:
        unawaited(togglePlay());
      case VideoRemotePadAction.replayLine:
        if (current == null) return false;
        unawaited(seekToRow(current));
      case VideoRemotePadAction.previousLine:
        if (previousRowIndex < 0) return false;
        unawaited(previousRow());
      case VideoRemotePadAction.nextLine:
        if (nextRowIndex < 0) return false;
        unawaited(nextRow());
      case VideoRemotePadAction.volumeUp:
      case VideoRemotePadAction.volumeDown:
        final int? current = volume;
        if (!capabilities.contains(videoRemoteCapabilityVolume) ||
            current == null) {
          return false;
        }
        final int step = action == VideoRemotePadAction.volumeUp ? 10 : -10;
        final int next = (current + step).clamp(0, 100);
        // 已到头：不发、不震。
        if (next == current) return false;
        // 先记下本地值：连着快滑时下一档在这一档上加，不等电脑的快照回来。
        setState(() => _state = <String, dynamic>{..._state, 'volume': next});
        unawaited(setVolume(next));
      case VideoRemotePadAction.caretEnter:
        if (!canDriveCaret) return false;
        // 先当它已进入：长按的手指还按着，接着拖就该挪字，不等这一来回；电脑
        // 回报 `none`（屏上没有可选字幕）时 [_drainCaret] 改回来。
        setState(() => _state = <String, dynamic>{..._state, 'caret': 'video'});
        _sendCaret('enter');
      case VideoRemotePadAction.caretLeft:
      case VideoRemotePadAction.caretRight:
      case VideoRemotePadAction.caretUp:
      case VideoRemotePadAction.caretDown:
      case VideoRemotePadAction.caretActivate:
      case VideoRemotePadAction.caretLongPress:
      case VideoRemotePadAction.caretBack:
        if (!canDriveCaret || !caretActive) return false;
        _sendCaret(switch (action) {
          VideoRemotePadAction.caretLeft => 'left',
          VideoRemotePadAction.caretRight => 'right',
          VideoRemotePadAction.caretUp => 'up',
          VideoRemotePadAction.caretDown => 'down',
          VideoRemotePadAction.caretActivate => 'activate',
          VideoRemotePadAction.caretLongPress => 'longPress',
          _ => 'back',
        });
    }
    return true;
  }

  // ── 展示投影：协议快照 → `video_remote/` 的不可变数据 ─────────────────────

  /// 脚手架的行（只放主轨）与 [_cues] 里对应行的映射；副轨挂成 secondaryText。
  _TranscriptProjection _projectTranscript() {
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    final List<VideoRemoteTranscriptLine> lines = <VideoRemoteTranscriptLine>[];
    final List<Map<String, dynamic>> secondary = <Map<String, dynamic>>[
      for (final Map<String, dynamic> cue in _cues)
        if (!_isPrimary(cue)) cue,
    ];
    int activeLine = -1;
    for (int i = 0; i < _cues.length; i++) {
      final Map<String, dynamic> cue = _cues[i];
      if (!_isPrimary(cue)) continue;
      if (i == _active) activeLine = rows.length;
      final int start = _cueStart(cue), end = _cueEnd(cue);
      final List<String> translations = <String>[
        for (final Map<String, dynamic> other in secondary)
          if (_cueStart(other) < end && _cueEnd(other) > start)
            other['text'].toString(),
      ];
      rows.add(cue);
      lines.add(
        VideoRemoteTranscriptLine(
          id: cue['id'].toString(),
          text: cue['text'].toString(),
          start: Duration(milliseconds: start),
          end: Duration(milliseconds: end),
          secondaryText: translations.isEmpty ? null : translations.join('\n'),
          favorited: _starred.contains(cue['id'].toString()),
        ),
      );
    }
    return _TranscriptProjection(rows, lines, activeLine);
  }

  void _withLine(
    int line,
    Future<void> Function(Map<String, dynamic> row) action,
  ) {
    if (line < 0 || line >= _lineRows.length) return;
    unawaited(action(_lineRows[line]));
  }

  VideoRemoteNowPlaying _nowPlaying() {
    final Map<String, dynamic>? current = _active >= 0 && _active < _cues.length
        ? _cues[_active]
        : null;
    return VideoRemoteNowPlaying(
      title: _state['title']?.toString() ?? '',
      hostName: widget.peer.deviceName,
      cover: _nowPlayingCover,
      isPlaying: playing,
      speed: (_state['speed'] as num?)?.toDouble() ?? 1,
      currentFavorited:
          current != null && _starred.contains(current['id'].toString()),
      volume: volume,
    );
  }

  List<VideoRemoteFavoriteEntry> _favoriteEntries() =>
      <VideoRemoteFavoriteEntry>[
        for (final Map<String, dynamic> favorite in _favorites)
          VideoRemoteFavoriteEntry(
            id: favorite['id'].toString(),
            text: favorite['text'].toString(),
            videoTitle: favorite['title']?.toString() ?? '',
            start: Duration(
              milliseconds: (favorite['startMs'] as num?)?.toInt() ?? 0,
            ),
            isCurrentVideo:
                favorite['bookUid'] == _state['identity'] &&
                (favorite['sectionIndex'] ?? 0) ==
                    (_state['sectionIndex'] ?? 0),
          ),
      ];

  Map<String, dynamic>? _favoriteById(String id) {
    for (final Map<String, dynamic> favorite in _favorites) {
      if (favorite['id'].toString() == id) return favorite;
    }
    return null;
  }

  VideoRemoteNotice? _notice() {
    if (_error.isNotEmpty) {
      return VideoRemoteNotice(
        kind: _error == t.video_remote_error_unreachable
            ? VideoRemoteNoticeKind.disconnected
            : VideoRemoteNoticeKind.error,
        message: _error,
        actionLabel: t.video_remote_retry,
        onAction: () => unawaited(reconnect()),
      );
    }
    if (!available) {
      return VideoRemoteNotice(
        kind: VideoRemoteNoticeKind.waiting,
        message: t.video_remote_waiting,
        actionLabel: canPickVideo ? t.video_remote_library_pick : null,
        onAction: canPickVideo ? () => unawaited(pickVideo()) : null,
      );
    }
    return null;
  }

  /// 按钮布局读偏好（偏好仓库未就绪时用出厂布局）。
  PreferencesRepository? get _prefs =>
      mixinAppModel.isPreferencesReady ? mixinAppModel.prefsRepo : null;

  VideoRemoteControlLayout _controlLayout() =>
      _prefs?.videoRemoteControlLayout ?? VideoRemoteControlLayout.defaults;

  /// 遥控协议没有倍速与电脑端字幕显隐命令：这两个按钮置灰而不是点了没反应。
  /// 选集 / 字幕轨 / 音量要电脑在快照里声明支持（旧版电脑置灰）；选集还要有
  /// 不止一集。
  bool controlEnabled(VideoRemoteControlItem item) => switch (item) {
    VideoRemoteControlItem.speed ||
    VideoRemoteControlItem.subtitleVisibility => false,
    VideoRemoteControlItem.episodes =>
      available &&
          episodeCount > 1 &&
          capabilities.contains(videoRemoteCapabilityEpisodes),
    VideoRemoteControlItem.subtitleTrack =>
      available && capabilities.contains(videoRemoteCapabilitySubtitleTracks),
    VideoRemoteControlItem.volume =>
      available && capabilities.contains(videoRemoteCapabilityVolume),
    VideoRemoteControlItem.previousCue => previousRowIndex >= 0,
    VideoRemoteControlItem.nextCue => nextRowIndex >= 0,
    VideoRemoteControlItem.replayCue ||
    VideoRemoteControlItem.favorite ||
    VideoRemoteControlItem.mine => _active >= 0,
    _ => available,
  };

  Future<void> _onControl(VideoRemoteControlItem item) async {
    final Map<String, dynamic>? current = _active >= 0 && _active < _cues.length
        ? _cues[_active]
        : null;
    switch (item) {
      case VideoRemoteControlItem.playPause:
        await togglePlay();
      case VideoRemoteControlItem.previousCue:
        await previousRow();
      case VideoRemoteControlItem.nextCue:
        await nextRow();
      case VideoRemoteControlItem.replayCue:
        if (current != null) await seekToRow(current);
      case VideoRemoteControlItem.favorite:
        if (current != null) await toggleRowFavorite(current);
      case VideoRemoteControlItem.mine:
        // 制卡要先选词：打开当前句的查词弹框。
        if (current != null) await openLookup(current, 0);
      case VideoRemoteControlItem.seekBack:
        await seekTo(Duration(milliseconds: positionMs.round() - 10000));
      case VideoRemoteControlItem.seekForward:
        await seekTo(Duration(milliseconds: positionMs.round() + 10000));
      case VideoRemoteControlItem.episodes:
        await pickEpisode();
      case VideoRemoteControlItem.subtitleTrack:
        await pickSubtitleTrack();
      case VideoRemoteControlItem.volume:
        await showVolume();
      case VideoRemoteControlItem.followCurrent:
      case VideoRemoteControlItem.speed:
      case VideoRemoteControlItem.subtitleVisibility:
        // followCurrent 由脚手架自己处理；另两个没有协议命令（已置灰）。
        break;
    }
  }
}

/// [VideoRemotePageState._projectTranscript] 的结果。
class _TranscriptProjection {
  const _TranscriptProjection(this.rows, this.lines, this.activeLine);

  final List<Map<String, dynamic>> rows;
  final List<VideoRemoteTranscriptLine> lines;
  final int activeLine;
}

/// 控制卡进度条的读口：位置按电脑上报的快照 + 本地速度推算。
class _RemoteClock implements FushiPlaybackClock {
  _RemoteClock(this._page);

  final VideoRemotePageState _page;

  @override
  Duration get position =>
      Duration(milliseconds: math.max(0, _page.positionMs.round()));

  @override
  Duration get duration => Duration(
    milliseconds: (_page.playbackState['durationMs'] as num?)?.toInt() ?? 0,
  );
}

/// Localized text for a video remote failure. Host error codes map to their
/// own messages; unknown codes keep the code visible so reports stay useful.
/// Raw exception text (including [SyncAuthError.toString]) is never shown.
/// Returns an empty string for silent outcomes such as a cancelled lookup.
String videoRemoteErrorText(Object error) {
  if (error is SyncAuthError) return t.video_remote_error_pairing_rejected;
  if (error is VideoRemotePinRefused) {
    return t.video_remote_error_certificate_mismatch;
  }
  // 查词走同一台电脑的词典端点：全部候选传输层失败 = 电脑不可达。
  if (error is RemoteLookupUnreachableError) {
    return t.video_remote_error_unreachable;
  }
  if (error is! VideoRemoteError) {
    return t.video_remote_error_unknown(code: error.runtimeType.toString());
  }
  final String code = error.message;
  switch (code) {
    case 'lookup_cancelled':
      return '';
    case 'controller_busy':
      return t.video_remote_error_controller_busy;
    case 'controller_lease_lost':
      return t.video_remote_error_controller_lease_lost;
    case 'session_changed':
    case 'subtitles_changed':
    case 'cue_missing':
      return t.video_remote_error_subtitles_changed;
    case 'favorite_missing':
      return t.video_remote_error_favorite_missing;
    case 'favorite_ambiguous':
    case 'favorite_subtitle_ambiguous':
      return t.video_remote_error_favorite_ambiguous;
    case 'favorite_source_unavailable':
    case 'favorite_subtitle_unavailable':
      return t.video_remote_error_favorite_source_unavailable;
    case 'favorite_subtitle_missing':
      return t.video_remote_error_favorite_subtitle_missing;
    case 'video_extraction_unavailable':
      return t.video_remote_error_video_extraction_unavailable;
    case 'lookup_expired':
      return t.video_remote_error_lookup_expired;
    case 'mining_busy':
      return t.video_remote_error_mining_busy;
    case 'mining_failed':
      return t.video_remote_error_mining_failed;
    case 'requests_busy':
      return t.video_remote_error_requests_busy;
    case 'no_video':
      return t.video_remote_error_no_video;
    case 'video_missing':
      return t.video_remote_error_video_missing;
    case 'host_busy':
      return t.video_remote_error_host_busy;
    case 'remote_closed':
      return t.video_remote_error_remote_closed;
    case 'task_missing':
      return t.video_remote_error_task_missing;
    case 'internal_error':
      return t.video_remote_error_internal_error;
    case 'paired_peer_required':
      return t.video_remote_error_pairing_rejected;
    case videoRemoteActionUnsupported:
      return t.video_remote_error_action_unsupported;
    case 'episode_missing':
      return t.video_remote_error_episode_unavailable;
    case 'subtitle_busy':
      return t.video_remote_error_subtitle_busy;
    case 'subtitle_track_missing':
    case 'subtitle_track_unavailable':
      return t.video_remote_error_subtitle_track_unavailable;
    case 'subtitle_source_missing':
      return t.video_remote_error_subtitle_source_missing;
    case 'subtitle_search_failed':
      return t.video_remote_error_subtitle_search_failed;
    case 'subtitle_candidate_missing':
      return t.video_remote_error_subtitle_candidate_missing;
    case 'subtitle_download_failed':
      return t.video_jimaku_download_failed;
    case VideoRemoteError.unreachableCode:
      return t.video_remote_error_unreachable;
    case VideoRemoteError.certificateMismatchCode:
      return t.video_remote_error_certificate_mismatch;
    case 'invalid_action':
    case 'invalid_argument':
    case 'invalid_favorite':
    case 'invalid_favorites':
    case 'invalid_fields':
    case 'invalid_json':
    case 'invalid_number':
    case 'invalid_peer':
    case 'invalid_request_id':
    case 'invalid_revision':
    case 'request_id_conflict':
    case 'unknown_operation':
      return t.video_remote_error_invalid_request(code: code);
  }
  // An old host without the endpoint answers a bare 404/405.
  if (error.statusCode == 404 || error.statusCode == 405) {
    return t.video_remote_unsupported;
  }
  return t.video_remote_error_unknown(code: code);
}

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:document_file_save_plus/document_file_save_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:local_assets_server/local_assets_server.dart';
import 'package:share_plus/share_plus.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/src/media/audiobook/audiobook_controller.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/reader_position_model.dart';
import 'package:hibiki/src/media/audiobook/reader_position_repository.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_match_codec.dart';
import 'package:hibiki/src/media/audiobook/srt_book_model.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';
import 'package:hibiki/utils.dart';

/// The media page used for the [ReaderTtuSource].
class ReaderTtuSourcePage extends BaseSourcePage {
  /// Create an instance of this page.
  const ReaderTtuSourcePage({
    super.item,
    super.key,
  });

  @override
  BaseSourcePageState createState() => _ReaderTtuSourcePageState();
}

class _ReaderTtuSourcePageState extends BaseSourcePageState<ReaderTtuSourcePage>
    with WidgetsBindingObserver {
  /// The media source pertaining to this page.
  ReaderTtuSource get mediaSource => ReaderTtuSource.instance;
  bool _controllerInitialised = false;
  late InAppWebViewController _controller;

  DateTime? lastMessageTime;
  DateTime? lastTapLookupTime;
  Orientation? lastOrientation;

  Duration get consoleMessageDebounce => const Duration(milliseconds: 50);
  Duration get tapLookupDebounce => const Duration(milliseconds: 500);

  final FocusNode _focusNode = FocusNode();
  bool _isRecursiveSearching = false;

  // ── 有声书播放器 ────────────────────────────────────────────────────────────
  AudiobookPlayerController? _audiobookController;

  /// 当前章节的 href（用于 cue 查询和 JS 注解）。
  String _currentChapterHref = '';

  /// 非 null 表示当前书来自 [SrtBook]（字幕 EPUB）；值为 [SrtBook.uid]。
  String? _srtBookUid;

  // ── PR8b: Follow audio pill + auto-off 状态 ─────────────────────────────

  /// Follow=OFF 时 cue 跨章触发：悬浮 pill "→ 第 N 章"，点击跳转后清空。
  /// null 表示无 pending；setState 驱动重绘。
  int? _pendingNavSection;

  /// 已被请求跳章（`requestSectionNav` 调用后），用来过滤掉那条由自己
  /// 触发的 sectionChanged 回报事件——否则 ON 模式下系统自己跳的章会
  /// 被当成用户意图，立刻又把 Follow auto-off 掉。
  int? _inFlightNavSection;

  /// 跨章跳章超时兜底。`requestSectionNav` 用 `evaluateJavascript`，不 await
  /// JS Promise——Dart 侧 await 几乎瞬间返回。之前立刻调
  /// `notifySectionRestoreCompleted` 会提前清 `_chapterTransition`，期间
  /// 另一条 cue tick 看到段不匹配再发一次跳章，ttu 被轮番 `__ttuGoToSection`，
  /// scrollTop 反复被清零到章首（翻页被拽回首页的视觉来源）。改为等 ttu
  /// 自己把 `sectionChanged(auto=true, idx==target)` 推回来再 notify；本
  /// Timer 兜底 ttu fork 缺失 / 跳章失败 3s 内没回报时强制降级为 pill。
  Timer? _navRestoreTimeout;

  /// reader 当前挂载的 ttu section index。-1 = 还没收到任何 sectionChanged
  /// 事件（开书前 / ttu 还没初始化）。供 controller 通过
  /// [AudiobookPlayerController.getCurrentReaderSection] 读取，作为"cue 是否
  /// 跨章"的判定参照系（对齐 Sasayaki SasayakiPlayer 的 getCurrentIndex 闭包）。
  ///
  /// 不能默认 0：cue 在第 5 章但 reader 还没汇报时，0 会被误判为"跨章"。
  /// controller 端遇到 -1 直接 return 不触发跨章逻辑。
  int _currentTtuSection = -1;

  /// 上次调 applySasayakiCues 的 section + rootTextLen。
  /// 对齐 JS 侧 `__hoshiSasayakiAppliedForSection`，防同一挂载周期里
  /// sasayakiMountedSection 连发多条消息导致重复 apply（apply 本身会包
  /// 大量 span，代价不小）。JS 侧也有 guard，这里再挡一层减少 console bridge
  /// 开销。
  int _lastSasayakiAppliedSection = -1;
  int _lastSasayakiAppliedRootLen = -1;

  // ── 位置持久化（ReaderPosition Isar 表） ────────────────────────────────
  //
  // 保存触发：JS 侧 scroll debounce 1s 调 saveReaderPos handler，Dart 侧
  // 拿到 {section, offset} 即刻写 Isar（去重：同 section+offset 跳过）。
  // ttu sectionChanged(auto=false) 翻章也主动写一次（offset=0 记段首）。
  // dispose 里做一次 flush：evaluate 当前视口位置 → 写库，兜 1s debounce
  // 窗内关书丢失。

  /// 上一次写进 Isar 的位置，用于去重，避免高频 scroll 里重复 writeTxn。
  ReaderViewportPos? _lastSavedPos;

  /// 一本书的 WebView 生命周期里只做一次恢复。**不是只在成功时置 true**：
  /// 读 Isar 返回 null（新书）/ requestSectionNav 抛异常 / 无 ttuId 都算
  /// "做过了"，防止每次 Sasayaki mount 事件都反复触发恢复。
  bool _didRestorePos = false;

  /// 恢复需要两次 mount（第一次 current section，第二次跳完 savedSection）。
  /// 第一次读 Isar 时把 saved pos 暂存这里，第二次 mount 匹配 section 时
  /// consume。同段直接恢复时也临时设一下，`_finishRestore` 会立即清掉。
  ReaderViewportPos? _pendingRestorePos;

  /// 恢复流程进行中（requestSectionNav → 等 mount → scrollToNormOffset）。
  /// 此期间 `_handleCueCrossChapter` 必须拒绝 Follow audio 的跨章跳转，
  /// 否则音频 cue 推着 reader 往播放位置跑，恢复目标章就被覆盖。
  bool _restoreInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applyVolumeKeyIntercept();
    // 异步检查是否有挂载有声书
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initAudiobookIfAvailable();
    });
  }

  @override
  void dispose() {
    VolumeKeyChannel.instance.setHandlers();
    VolumeKeyChannel.instance.setInterceptEnabled(false);
    _navRestoreTimeout?.cancel();
    // 在 WebView 销毁前同步读一次当前视口位置（fire-and-forget 写 Isar），
    // 兜住 JS 侧 1s scroll-debounce 窗内关书导致的保存丢失。
    // unawaited 是有意的：dispose 不能 async，Isar 写不依赖 UI 线程，
    // Future 在 widget 销毁后仍能跑完。
    _flushReaderPosOnDispose();
    _audiobookController?.removeListener(_onCueChanged);
    _audiobookController?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Fire-and-forget：读一次视口位置并写库。WebView 可能已开始销毁，
  /// evaluateJavascript 抛异常就吞掉。
  void _flushReaderPosOnDispose() {
    if (!_controllerInitialised) return;
    final InAppWebViewController controller = _controller;
    Future<void>.microtask(() async {
      try {
        final ReaderViewportPos? pos =
            await AudiobookBridge.getViewportNormOffset(controller);
        if (pos == null) return;
        await _persistReaderPos(
          section: pos.section,
          offset: pos.offset,
          from: 'dispose',
        );
      } catch (e) {
        debugPrint('[hibiki-reader-pos] dispose flush err: $e');
      }
    });
  }

  /// 把位置写进 Isar。同 section+offset 则跳过，避免重复 writeTxn。
  Future<void> _persistReaderPos({
    required int section,
    required int offset,
    required String from,
  }) async {
    if (section < 0 || offset < 0) return;
    final int? ttuId = _extractTtuBookId();
    if (ttuId == null || ttuId <= 0) return;
    if (_lastSavedPos?.section == section && _lastSavedPos?.offset == offset) {
      return;
    }
    _lastSavedPos = ReaderViewportPos(section: section, offset: offset);
    try {
      final ReaderPositionRepository repo =
          ReaderPositionRepository(appModel.database);
      await repo.save(
        ttuBookId: ttuId,
        sectionIndex: section,
        normCharOffset: offset,
      );
      debugPrint(
        '[hibiki-reader-pos] save($from) ttuId=$ttuId s=$section o=$offset',
      );
    } catch (e) {
      debugPrint('[hibiki-reader-pos] save err: $e');
    }
  }

  /// Wire native volume-key interception according to the current setting.
  /// Called on page mount and whenever the toggle flips via the settings
  /// dialog so the key handler stops swallowing volume presses once the
  /// user turns the feature off.
  void _applyVolumeKeyIntercept() {
    final enabled = mediaSource.volumePageTurningEnabled;
    if (enabled) {
      VolumeKeyChannel.instance.setHandlers(
        onVolumeUp: _onVolumeKeyUp,
        onVolumeDown: _onVolumeKeyDown,
      );
    } else {
      VolumeKeyChannel.instance.setHandlers();
    }
    VolumeKeyChannel.instance.setInterceptEnabled(enabled);
  }

  void _onVolumeKeyUp() {
    if (!_controllerInitialised) return;
    if (isDictionaryShown) {
      clearDictionaryResult();
      unselectWebViewTextSelection(_controller);
      mediaSource.clearCurrentSentence();
      return;
    }
    _autoOffFollowOnManualTurn();
    unselectWebViewTextSelection(_controller);
    _controller.evaluateJavascript(source: leftArrowSimulateJs);
  }

  void _onVolumeKeyDown() {
    if (!_controllerInitialised) return;
    if (isDictionaryShown) {
      clearDictionaryResult();
      unselectWebViewTextSelection(_controller);
      mediaSource.clearCurrentSentence();
      return;
    }
    _autoOffFollowOnManualTurn();
    unselectWebViewTextSelection(_controller);
    _controller.evaluateJavascript(source: rightArrowSimulateJs);
  }

  /// 所有显式手翻的 Follow auto-off 公共入口：音量键 / swipe 跨段 /
  /// ToC 点击都调这里。音量键在 ttu 连续滚动模式下 wheel 只滚不翻章，
  /// 不触发 sectionChanged，所以必须在 arrow simulate 之前主动调；
  /// swipe / ToC 则由 [_handleTtuSectionChanged] 的 auto=false 分支转发。
  /// 没这一层，按着音量键往下读，下一条 cue 会把 reader 拖回原位。
  /// 无有声书或 Follow=OFF 时直接跳过。
  void _autoOffFollowOnManualTurn() {
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;
    if (!controller.followAudio.value) return;
    controller.setFollowAudio(false);
    if (mounted) {
      Fluttertoast.showToast(msg: 'Follow audio 已暂停（用户手动翻页）');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      FocusScope.of(context).unfocus();
      _focusNode.requestFocus();
    }
  }

  @override
  void onSearch(String searchTerm, {String? sentence = ''}) async {
    _isRecursiveSearching = true;
    if (appModel.isMediaOpen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await Future.delayed(const Duration(milliseconds: 5), () {});
    }
    await appModel.openRecursiveDictionarySearch(
      searchTerm: searchTerm,
      killOnPop: false,
    );
    if (appModel.isMediaOpen) {
      await Future.delayed(const Duration(milliseconds: 5), () {});
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _isRecursiveSearching = false;

    _focusNode.requestFocus();
  }

  /// Hide the dictionary and dispose of the current result.
  @override
  void clearDictionaryResult() async {
    super.clearDictionaryResult();
    unselectWebViewTextSelection(_controller);
  }

  @override
  void onCreatorClose() {
    _focusNode.unfocus();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    Orientation orientation = MediaQuery.of(context).orientation;
    if (orientation != lastOrientation) {
      if (_controllerInitialised) {
        clearDictionaryResult();
      }
      lastOrientation = orientation;
    }

    return Focus(
      autofocus: true,
      focusNode: _focusNode,
      onFocusChange: (value) {
        if (mediaSource.volumePageTurningEnabled &&
            !(ModalRoute.of(context)?.isCurrent ?? false) &&
            !appModel.isCreatorOpen &&
            !_isRecursiveSearching) {
          _focusNode.requestFocus();
        }
      },
      canRequestFocus: true,
      // Android volume keys don't reach Flutter's key pipeline reliably
      // (AudioManager consumes them first), so page-turn goes through
      // VolumeKeyChannel / MainActivity.dispatchKeyEvent instead. This
      // Focus is kept for other future keyboard bindings (e.g. desktop).
      onKey: (data, event) => KeyEventResult.ignored,
      child: WillPopScope(
        onWillPop: onWillPop,
        child: Scaffold(
          backgroundColor: Colors.black,
          resizeToAvoidBottomInset: false,
          body: SafeArea(
            top: !mediaSource.extendPageBeyondNavigationBar,
            bottom: false,
            child: Stack(
              fit: StackFit.expand,
              alignment: Alignment.center,
              children: <Widget>[
                // WebView 全屏渲染，bar 作为 overlay 叠在底部。不能往
                // `.book-content` 注 padding-bottom —— 那会让 ttu paginated
                // 模式每页的实际绘制高度大于 --book-content-child-height
                // （ttu 算步长用 child-height，绘制区带上 padding），翻页
                // 滚动步长 < 实际可视高，视觉上就是"上半上一页、下半下一页"
                // 的撕裂。
                buildBody(),
                buildDictionary(),
                buildAudiobookBar(),
                buildAudiobookImportButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildBody() {
    AsyncValue<LocalAssetsServer> server =
        ref.watch(ttuServerProvider(appModel.targetLanguage));

    return server.when(
      data: buildReaderArea,
      loading: buildLoading,
      error: (error, stack) => buildError(
        error: error,
        stack: stack,
        refresh: () {
          ref.invalidate(ttuServerProvider(appModel.targetLanguage));
        },
      ),
    );
  }

  void setDictionaryColors() async {
    String currentTheme = (await _controller.evaluateJavascript(
            source: 'window.localStorage.getItem("theme")'))
        .toString();
    switch (currentTheme) {
      case 'light-theme':
        appModel.setOverrideDictionaryTheme(appModel.theme);
        appModel.setOverrideDictionaryColor(
          Color.fromRGBO(249, 249, 249, dictionaryEntryOpacity),
        );
        break;
      case 'ecru-theme':
        appModel.setOverrideDictionaryTheme(appModel.theme);
        appModel.setOverrideDictionaryColor(
          Color.fromRGBO(247, 246, 235, dictionaryEntryOpacity),
        );
        break;
      case 'water-theme':
        appModel.setOverrideDictionaryTheme(appModel.theme);
        appModel.setOverrideDictionaryColor(
          Color.fromRGBO(223, 236, 244, dictionaryEntryOpacity),
        );
        break;
      case 'gray-theme':
        appModel.setOverrideDictionaryTheme(appModel.darkTheme);
        appModel.setOverrideDictionaryColor(
          Color.fromRGBO(35, 39, 42, dictionaryEntryOpacity),
        );
        break;
      case 'dark-theme':
        appModel.setOverrideDictionaryTheme(appModel.darkTheme);
        appModel.setOverrideDictionaryColor(
          Color.fromRGBO(18, 18, 18, dictionaryEntryOpacity),
        );
        break;
      case 'black-theme':
        appModel.setOverrideDictionaryTheme(appModel.darkTheme);
        appModel.setOverrideDictionaryColor(
          Color.fromRGBO(16, 16, 16, dictionaryEntryOpacity),
        );
        break;
    }

    if (mounted) {
      clearDictionaryResult();
      setState(() {});
    }
  }

  String sanitizeWebViewTextSelection(String? text) {
    if (text == null) {
      return '';
    }

    text = text.replaceAll('\\n', '\n');
    text = text.trim();
    return text;
  }

  Future<String> getWebViewTextSelection(
      InAppWebViewController webViewController) async {
    String? selectedText = await webViewController.getSelectedText();
    selectedText = sanitizeWebViewTextSelection(selectedText);
    return selectedText;
  }

  CacheMode get cacheMode {
    if (mediaSource.currentTtuInternalVersion ==
        ReaderTtuSource.ttuInternalVersion) {
      return CacheMode.LOAD_CACHE_ELSE_NETWORK;
    } else {
      mediaSource.setTtuInternalVersion();
      return CacheMode.LOAD_NO_CACHE;
    }
  }

  createFileFromBase64(String base64Content) async {
    var bytes = base64Decode(base64Content.replaceAll('\n', ''));
    DocumentFileSavePlus().saveFile(
      bytes.buffer.asUint8List(),
      _suggestedFilename,
      _mimeType,
    );
    Fluttertoast.showToast(msg: t.file_downloaded(name: _suggestedFilename));
  }

  Widget buildReaderArea(LocalAssetsServer server) {
    return InAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(
          widget.item?.mediaIdentifier ??
              'http://localhost:${server.boundPort}/manage.html',
        ),
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
        // 必须 DOCUMENT_START：ttu bundle 模块顶层
        // `me()("autoBookmark", !1)` 在 import 时就 getItem 一次做 Subject
        // 初值，onLoadStop 之后再 setItem 已经晚了（除非再 reload 页面，
        // 但 reload 会毁掉 audiobook bridge）。
        UserScript(
          source: _readerDocumentStartJs,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      onPermissionRequest: (controller, origin) async {
        return PermissionResponse(
          action: PermissionResponseAction.GRANT,
        );
      },
      initialSettings: InAppWebViewSettings(
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        mediaPlaybackRequiresUserGesture: false,
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        javaScriptCanOpenWindowsAutomatically: true,
        useOnDownloadStart: true,
        verticalScrollbarThumbColor: Colors.transparent,
        verticalScrollbarTrackColor: Colors.transparent,
        horizontalScrollbarThumbColor: Colors.transparent,
        horizontalScrollbarTrackColor: Colors.transparent,
        scrollbarFadingEnabled: false,
        appCachePath: appModel.browserDirectory.path,
        cacheMode: cacheMode,
        supportMultipleWindows: true,
      ),
      contextMenu: contextMenu,
      onConsoleMessage: onConsoleMessage,
      onWebViewCreated: (controller) {
        _controller = controller;
        _controllerInitialised = true;

        controller.addJavaScriptHandler(
          handlerName: 'blobToBase64Handler',
          callback: (data) async {
            if (data.isNotEmpty) {
              final String base64Content = data[0];
              createFileFromBase64(base64Content);
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onTapLookup',
          callback: (data) async {
            if (data.isEmpty) return;
            final DateTime now = DateTime.now();
            if (lastTapLookupTime != null &&
                now.difference(lastTapLookupTime!) < tapLookupDebounce) {
              return;
            }
            lastTapLookupTime = now;
            try {
              final Map<String, dynamic> payload =
                  Map<String, dynamic>.from(data[0] as Map);
              await _processLookup(payload);
            } catch (e) {
              debugPrint('onTapLookup error: $e');
            }
          },
        );

        // JS 侧 `.book-content` scroll debounce 1s 后调这里，把当前视口
        // 的 (sectionIndex, 章内 normCharOffset) 写进 Isar ReaderPosition。
        // JS 已经 debounce 过了，Dart 侧直接写，不再加层 debounce。
        controller.addJavaScriptHandler(
          handlerName: 'saveReaderPos',
          callback: (data) async {
            if (data.isEmpty) return;
            try {
              final Map<String, dynamic> payload =
                  Map<String, dynamic>.from(data[0] as Map);
              final int? section = (payload['section'] as num?)?.toInt();
              final int? offset = (payload['offset'] as num?)?.toInt();
              if (section == null || offset == null) return;
              await _persistReaderPos(
                section: section,
                offset: offset,
                from: 'scroll',
              );
            } catch (e) {
              debugPrint('[hibiki-reader-pos] saveReaderPos error: $e');
            }
          },
        );
      },
      onCreateWindow: (controller, createWindowRequest) async {
        showDialog(
          context: context,
          builder: (context) {
            return AlertDialog(
              insetPadding: Spacing.of(context).insets.all.big,
              contentPadding: EdgeInsets.zero,
              content: SizedBox(
                width: MediaQuery.of(context).size.width,
                height: MediaQuery.of(context).size.height * (3 / 4),
                child: InAppWebView(
                  initialSettings: InAppWebViewSettings(
                    supportZoom: false,
                    disableContextMenu: true,
                    allowFileAccessFromFileURLs: true,
                    allowUniversalAccessFromFileURLs: true,
                    mediaPlaybackRequiresUserGesture: false,
                    verticalScrollBarEnabled: false,
                    horizontalScrollBarEnabled: false,
                    javaScriptCanOpenWindowsAutomatically: true,
                    userAgent: 'random',
                    useOnDownloadStart: true,
                    verticalScrollbarThumbColor: Colors.transparent,
                    verticalScrollbarTrackColor: Colors.transparent,
                    horizontalScrollbarThumbColor: Colors.transparent,
                    horizontalScrollbarTrackColor: Colors.transparent,
                    scrollbarFadingEnabled: false,
                    appCachePath: appModel.browserDirectory.path,
                    cacheMode: cacheMode,
                    supportMultipleWindows: true,
                  ),
                  windowId: createWindowRequest.windowId,
                  onDownloadStartRequest: onDownloadStartRequest,
                  onCloseWindow: (controller) {
                    if (mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
              ),
            );
          },
        );
        return true;
      },
      onReceivedServerTrustAuthRequest: (controller, challenge) async {
        return ServerTrustAuthResponse(
          action: ServerTrustAuthResponseAction.PROCEED,
        );
      },
      onLoadStop: (controller, uri) async {
        if (mediaSource.adaptTtuTheme) {
          setDictionaryColors();
        }

        await controller.evaluateJavascript(source: javascriptToExecute);
        Future.delayed(const Duration(seconds: 1), _focusNode.requestFocus);

        debugPrint(
          '[hibiki-audiobook] onLoadStop uri=$uri '
          'ctrl=${_audiobookController != null} srtUid=$_srtBookUid',
        );
        _currentChapterHref = uri?.toString() ?? _currentChapterHref;
        await _maybeInjectAudiobookBridge(controller, trigger: 'onLoadStop');
        await _syncAudiobookModeAttr();
      },
      onTitleChanged: (controller, title) async {
        await controller.evaluateJavascript(source: javascriptToExecute);

        if (mediaSource.adaptTtuTheme) {
          setDictionaryColors();
        }

        debugPrint(
          '[hibiki-audiobook] onTitleChanged title=$title '
          'ctrl=${_audiobookController != null} srtUid=$_srtBookUid',
        );
        await _maybeInjectAudiobookBridge(controller, trigger: 'onTitleChanged');
        await _syncAudiobookModeAttr();
      },
      onDownloadStartRequest: onDownloadStartRequest,
    );
  }

  String _suggestedFilename = '';
  String _mimeType = '';

  void onDownloadStartRequest(
      InAppWebViewController controller, DownloadStartRequest request) async {
    _mimeType = request.mimeType ?? _mimeType;

    _suggestedFilename = request.suggestedFilename ?? _suggestedFilename;

    await controller.evaluateJavascript(
        source: downloadFileJs.replaceAll(
            'blobUrlPlaceholder', request.url.toString()));
  }

  Future<void> selectTextOnwards({
    required int cursorX,
    required int cursorY,
    required int offsetIndex,
    required int length,
    required int whitespaceOffset,
    required bool isSpaceDelimited,
  }) async {
    await _controller.setContextMenu(emptyContextMenu);
    await _controller.evaluateJavascript(
      source:
          'selectTextForTextLength($cursorX, $cursorY, $offsetIndex, $length, $whitespaceOffset, $isSpaceDelimited);',
    );
    await _controller.setContextMenu(contextMenu);
  }

  void onConsoleMessage(
    InAppWebViewController controller,
    ConsoleMessage message,
  ) async {
    late Map<String, dynamic> messageJson;
    bool isJson = true;
    try {
      messageJson = jsonDecode(message.message);
    } catch (e) {
      isJson = false;
    }

    // diag / sasayaki 消息绕过 50ms 防抖：一次 IDB 回调里连打五六条初始化
    // 探针，只放第一条过去会让 sasayakiRefsReady / sasayakiRefsSection 等
    // 关键诊断消失，表面看像"refs 没加载"。
    final String? msgType = isJson
        ? messageJson['hibiki-message-type'] as String?
        : null;
    final bool isDiag = msgType != null &&
        (msgType.startsWith('diag') || msgType.startsWith('sasayaki'));

    if (!isDiag) {
      DateTime now = DateTime.now();
      if (lastMessageTime != null &&
          now.difference(lastMessageTime!) < consoleMessageDebounce) {
        return;
      }
      lastMessageTime = now;
    }

    if (!isJson) {
      JsonEncoder encoder = const JsonEncoder.withIndent('  ');
      debugPrint(encoder.convert(message.toJson()));
      return;
    }

    switch (msgType) {
      case 'lookup':
        await _processLookup(messageJson);
        break;
      case 'seekToSentence':
        final AudiobookClickEvent? event =
            AudiobookBridge.parseMessage(messageJson);
        if (event != null) {
          await _seekToSentence(event);
        }
        break;
      case 'sectionChanged':
        _handleTtuSectionChanged(messageJson);
        break;
      case 'sasayakiMountedSection':
        await _handleSasayakiMountedSection(messageJson);
        break;
      default:
        // Unknown types (audiobook bridge diagnostics etc.) → 打日志方便排查
        debugPrint('[hibiki-audiobook-diag] ${message.message}');
        break;
    }
  }

  Future<void> _processLookup(Map<String, dynamic> payload) async {
    FocusScope.of(context).unfocus();
    _focusNode.requestFocus();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    int index = (payload['index'] as num).toInt();
    String text = (payload['text'] as String?) ?? '';
    int x = (payload['x'] as num).toInt();
    int y = (payload['y'] as num).toInt();

    const JidoujishoPopupPosition position = JidoujishoPopupPosition.bottomHalf;

    text = text.replaceAll('\\n', '\n');

    if (text.isEmpty || index < 0 || index >= text.length) {
      clearDictionaryResult();
      mediaSource.clearCurrentSentence();
      return;
    }

    try {
      /// If we cut off at a lone surrogate, offset the index back by 1. The
      /// selection meant to select the index before
      RegExp loneSurrogate = RegExp(
        '[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:[^\uD800-\uDBFF]|^)[\uDC00-\uDFFF]',
      );
      if (index != 0 && text.substring(index).startsWith(loneSurrogate)) {
        index = index - 1;
      }

      bool isSpaceDelimited = appModel.targetLanguage.isSpaceDelimited;

      String searchTerm = appModel.targetLanguage.getSearchTermFromIndex(
        text: text,
        index: index,
      );
      int whitespaceOffset =
          searchTerm.length - searchTerm.trimLeft().length;

      int offsetIndex = appModel.targetLanguage
              .getStartingIndex(text: text, index: index) +
          whitespaceOffset;

      int length = appModel.targetLanguage.getGuessHighlightLength(
        searchTerm: searchTerm,
      );

      if (mediaSource.highlightOnTap) {
        await selectTextOnwards(
          cursorX: x,
          cursorY: y,
          offsetIndex: offsetIndex,
          length: length,
          whitespaceOffset: whitespaceOffset,
          isSpaceDelimited: isSpaceDelimited,
        );
      }

      searchDictionaryResult(
        searchTerm: searchTerm,
        position: position,
      ).then((_) async {
        length = appModel.targetLanguage.getFinalHighlightLength(
          result: currentResult,
          searchTerm: searchTerm,
        );

        if (mediaSource.highlightOnTap) {
          await selectTextOnwards(
            cursorX: x,
            cursorY: y,
            offsetIndex: offsetIndex,
            length: length,
            whitespaceOffset: whitespaceOffset,
            isSpaceDelimited: isSpaceDelimited,
          );

          if (!dictionaryPopupShown) {
            unselectWebViewTextSelection(_controller);
          }
        }

        JidoujishoTextSelection selection =
            appModel.targetLanguage.getSentenceFromParagraph(
          paragraph: text,
          index: index,
          startOffset: offsetIndex,
          endOffset: offsetIndex + length,
        );

        mediaSource.setCurrentSentence(
          selection: selection,
        );
      }).catchError((Object e) {
        debugPrint('_processLookup async error: $e');
        clearDictionaryResult();
        mediaSource.clearCurrentSentence();
      });
    } catch (e) {
      debugPrint('_processLookup error: $e');
      clearDictionaryResult();
    }
  }

  Future<void> unselectWebViewTextSelection(
      InAppWebViewController webViewController) async {
    String source = '''
if (!window.getSelection().isCollapsed) {
  window.getSelection().removeAllRanges();
}
''';
    await webViewController.evaluateJavascript(source: source);
  }

  /// Get the default context menu for sources that make use of embedded web
  /// views.
  ContextMenu get contextMenu => ContextMenu(
        settings: ContextMenuSettings(
          hideDefaultSystemContextMenuItems: true,
        ),
        menuItems: [
          searchMenuItem(),
          stashMenuItem(),
          copyMenuItem(),
          shareMenuItem(),
          creatorMenuItem(),
        ],
      );

  /// Get the default context menu for sources that make use of embedded web
  /// views.
  ContextMenu get emptyContextMenu => ContextMenu(
        settings: ContextMenuSettings(
          hideDefaultSystemContextMenuItems: true,
        ),
        menuItems: [],
      );

  ContextMenuItem searchMenuItem() {
    return ContextMenuItem(
      id: 1,
      title: t.search,
      action: searchMenuAction,
    );
  }

  ContextMenuItem stashMenuItem() {
    return ContextMenuItem(
      id: 2,
      title: t.stash,
      action: stashMenuAction,
    );
  }

  ContextMenuItem copyMenuItem() {
    return ContextMenuItem(
      id: 3,
      title: t.copy,
      action: copyMenuAction,
    );
  }

  ContextMenuItem shareMenuItem() {
    return ContextMenuItem(
      id: 4,
      title: t.share,
      action: shareMenuAction,
    );
  }

  ContextMenuItem creatorMenuItem() {
    return ContextMenuItem(
      id: 5,
      title: t.creator,
      action: creatorMenuAction,
    );
  }

  void searchMenuAction() async {
    String searchTerm = await getSelectedText();
    _isRecursiveSearching = true;

    await unselectWebViewTextSelection(_controller);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await Future.delayed(const Duration(milliseconds: 5), () {});
    await appModel.openRecursiveDictionarySearch(
      searchTerm: searchTerm,
      killOnPop: false,
    );
    await Future.delayed(const Duration(milliseconds: 5), () {});
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _isRecursiveSearching = false;
    _focusNode.requestFocus();
  }

  void stashMenuAction() async {
    String searchTerm = await getSelectedText();
    appModel.addToStash(terms: [searchTerm]);
    await unselectWebViewTextSelection(_controller);
  }

  void creatorMenuAction() async {
    String text = (await getSelectedText()).replaceAll('\\n', '\n');

    await unselectWebViewTextSelection(_controller);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await Future.delayed(const Duration(milliseconds: 5), () {});

    await appModel.openCreator(
      ref: ref,
      killOnPop: false,
      creatorFieldValues: CreatorFieldValues(
        textValues: {
          SentenceField.instance: text,
          TermField.instance: '',
          ClozeBeforeField.instance: '',
          ClozeInsideField.instance: '',
          ClozeAfterField.instance: '',
        },
      ),
    );

    await Future.delayed(const Duration(milliseconds: 5), () {});
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _focusNode.requestFocus();
  }

  void copyMenuAction() async {
    String searchTerm = await getSelectedText();
    Clipboard.setData(ClipboardData(text: searchTerm));
    await unselectWebViewTextSelection(_controller);
  }

  void shareMenuAction() async {
    String searchTerm = await getSelectedText();
    Share.share(searchTerm);
    await unselectWebViewTextSelection(_controller);
  }

  Future<String> getSelectedText() async {
    return (await _controller.getSelectedText() ?? '')
        .replaceAll('\\n', '\n')
        .trim();
  }

  String downloadFileJs = '''
var xhr = new XMLHttpRequest();
var blobUrl = "blobUrlPlaceholder";
console.log(blobUrl);
xhr.open('GET', blobUrl, true);
xhr.responseType = 'blob';
xhr.onload = function(e) {
  if (this.status == 200) {
    var blob = this.response;
    var reader = new FileReader();
    reader.readAsDataURL(blob);
    reader.onloadend = function() {
      var base64data = reader.result;
      var base64ContentArray = base64data.split(",")     ;
      var mimeType = base64ContentArray[0].match(/[^:\\s*]\\w+\\/[\\w-+\\d.]+(?=[;| ])/)[0];
      var decodedFile = base64ContentArray[1];
      console.log(mimeType);
      window.flutter_inappwebview.callHandler('blobToBase64Handler', decodedFile, mimeType);
    };
  };
};
xhr.send();
''';

  /// AT_DOCUMENT_START 注入：在 ttu bundle 的 Svelte 模块初始化前把
  /// `localStorage.autoBookmark` 拨到 "1"，让 `me()("autoBookmark",!1)`
  /// 在建 BehaviorSubject 时读到 true 而非 default false —— 否则整个会话
  /// 的 Subject 初值就锁死 false，window scroll 的 debounced auto-bookmark
  /// 永远不注册，IDB bookmark store 一直是空的（日志侧观察 n=0）。
  ///
  /// 顺手也打一条 diag-pos 记录注入前后 localStorage 状态，再挂一个一次性
  /// `window.scroll` 监听，确认 paginated 模式下 window 本身是否真的会滚
  /// （ttu 的 auto-bookmark trigger 是 `fromEvent(window,'scroll')`；若实际
  /// 滚动只在 `.book-content-container` 上发 scroll 事件，就算 autoBookmark
  /// 开了也写不进去，得改走 Flutter 主动调 bookmarkManager.put 的路径）。
  static const String _readerDocumentStartJs = r'''
(function(){
  try {
    var before = null;
    try { before = localStorage.getItem('autoBookmark'); } catch(e){}
    var changed = false;
    try {
      if (before !== '1') {
        localStorage.setItem('autoBookmark', '1');
        changed = true;
      }
    } catch(e){}
    function diag(tag, extra) {
      try {
        console.log(JSON.stringify({
          'hibiki-message-type': 'diag-pos',
          tag: tag,
          extra: extra || ''
        }));
      } catch(_){}
    }
    diag('docstart-autoBookmark', 'before=' + before + ' changed=' + changed);
    // 一次性 window scroll 探针：看 paginated mode 下 window 是否真会滚
    try {
      var seen = 0;
      window.addEventListener('scroll', function(){
        if (seen < 3) {
          diag('window-scroll', 'sy=' + window.scrollY + ' sx=' + window.scrollX);
        }
        seen++;
      }, { capture: true, passive: true });
    } catch(e){}
  } catch(_) {}
})();
''';

  /// This is executed upon page load and change.
  /// More accurate readability courtesy of
  /// https://github.com/birchill/10ten-ja-reader/blob/fbbbde5c429f1467a7b5a938e9d67597d7bd5ffa/src/content/get-text.ts#L314
  String javascriptToExecute = """
/*jshint esversion: 6 */

// [hibiki-diag-pos] 开书位置恢复追踪：
// 1) 打出 IDB 'books' DB 里 bookmark store 的快照 —— 关书时 ttu auto-bookmark
//    写入的值，下次开书这里读到的就是上次关书状态；
// 2) 以 150ms 间隔 poll `.book-content` 的 scrollLeft/scrollTop，记录变化，
//    观察 ttu 的 scrollToBookmark 是否真跑了、是否被后续 inject 覆盖。
// 带 __hibikiPosDiag 守卫保证多次 evaluate 只跑一次。
(function() {
  if (window.__hibikiPosDiag) return;
  window.__hibikiPosDiag = true;
  var t0 = Date.now();
  function diag(tag, extra) {
    try {
      // 走 JSON + hibiki-message-type='diag-pos' 以 isDiag 判定绕过 50ms 防抖
      // （否则 idb-bookmark / bc-scroll 连打多条会被吞到只剩第一条）
      console.log(JSON.stringify({
        'hibiki-message-type': 'diag-pos',
        dt: Date.now() - t0,
        tag: tag,
        extra: extra || ''
      }));
    } catch (e) {}
  }
  diag('init', 'url=' + location.href);
  try {
    var req = indexedDB.open('books');
    req.onerror = function(e) { diag('idb-open-err', String(e)); };
    req.onsuccess = function() {
      try {
        var db = req.result;
        var stores = Array.prototype.slice.call(db.objectStoreNames);
        if (stores.indexOf('bookmark') < 0) {
          diag('idb-no-bookmark-store', 'stores=' + stores.join(','));
          return;
        }
        var getAll = db.transaction('bookmark', 'readonly')
          .objectStore('bookmark').getAll();
        getAll.onsuccess = function(e) {
          var arr = e.target.result || [];
          diag('idb-bookmark-count', 'n=' + arr.length);
          arr.forEach(function(b) {
            diag('idb-bookmark',
              'dataId=' + b.dataId +
              ' explored=' + b.exploredCharCount +
              ' progress=' + ((b.progress || 0).toFixed ? b.progress.toFixed(4) : b.progress) +
              ' sy=' + b.scrollY +
              ' sx=' + b.scrollX +
              ' mod=' + b.lastBookmarkModified);
          });
        };
        getAll.onerror = function(e) { diag('idb-getall-err', String(e)); };
      } catch (e) { diag('idb-tx-err', String(e)); }
    };
  } catch (e) { diag('idb-outer-err', String(e)); }
  var lastSL = null, lastST = null, ticks = 0;
  var iv = setInterval(function() {
    var bc = document.querySelector('.book-content');
    if (bc) {
      if (bc.scrollLeft !== lastSL || bc.scrollTop !== lastST) {
        diag('bc-scroll',
          'sl=' + bc.scrollLeft + ' st=' + bc.scrollTop +
          ' sw=' + bc.scrollWidth + ' sh=' + bc.scrollHeight);
        lastSL = bc.scrollLeft;
        lastST = bc.scrollTop;
      }
    }
    if (++ticks > 200) { clearInterval(iv); diag('poll-end', 'ticks=' + ticks); }
  }, 150);
})();

// Inject our own avoidPageBreak CSS so paragraphs (and cue spans inside them)
// don't get split across pages. Doing this directly avoids the location.reload()
// that toggling ttu's localStorage setting would require — reload would wipe
// the audiobook bridge while Dart still thinks it's injected.
(function() {
  if (document.getElementById('hibiki-avoid-pagebreak-css')) return;
  var style = document.createElement('style');
  style.id = 'hibiki-avoid-pagebreak-css';
  style.textContent = 'p{break-inside:avoid !important;-webkit-column-break-inside:avoid !important;}';
  (document.head || document.documentElement).appendChild(style);
})();

function tapToSelect(e) {
  console.log('[hibiki] tapToSelect x=' + e.clientX + ' y=' + e.clientY + ' target=' + (e.target ? e.target.nodeName : 'null'));
  var result = document.caretRangeFromPoint(e.clientX, e.clientY);
  console.log('[hibiki] caretRangeFromPoint result=' + (result ? result.startContainer.nodeName + ' offset=' + result.startOffset : 'null'));

  if (!result || e.target.classList.contains('book-content')) {
    console.log('[hibiki] early return: result=' + (!!result) + ' isBookContent=' + (e.target && e.target.classList.contains('book-content')));
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onTapLookup', {
        "index": -1,
        "text": "",
        "x": e.clientX,
        "y": e.clientY,
      });
    }
    return;
  }

  var selectedElement = result.startContainer;
  var paragraph = result.startContainer;
  var offsetNode = result.startContainer;
  var offset = result.startOffset;

  var adjustIndex = false;

  if (!!offsetNode && offsetNode.nodeType === Node.TEXT_NODE && offset) {
      const range = new Range();
      range.setStart(offsetNode, offset - 1);
      range.setEnd(offsetNode, offset);

      const bbox = range.getBoundingClientRect();
      if (bbox.left <= e.x && bbox.right >= e.x &&
          bbox.top <= e.y && bbox.bottom >= e.y) {
          
          result.startOffset = result.startOffset - 1;
          adjustIndex = true;
      }
    }
  
  
  while (paragraph && paragraph.nodeName !== 'P') {
    paragraph = paragraph.parentNode;
  }
  if (paragraph === null) {
    paragraph = result.startContainer.parentNode;
  }
  var noFuriganaText = [];
  var noFuriganaNodes = [];
  var selectedFound = false;
  var index = 0;
  for (var value of paragraph.childNodes.values()) {
    if (value.nodeName === "#text") {
      noFuriganaText.push(value.textContent);
      noFuriganaNodes.push(value);
      if (selectedFound === false) {
        if (selectedElement !== value) {
          index = index + value.textContent.length;
        } else {
          index = index + result.startOffset;
          selectedFound = true;
        }
      }
    } else {
      for (var node of value.childNodes.values()) {
        if (node.nodeName === "#text") {
          noFuriganaText.push(node.textContent);
          noFuriganaNodes.push(node);
          if (selectedFound === false) {
            if (selectedElement !== node) {
              index = index + node.textContent.length;
            } else {
              index = index + result.startOffset;
              selectedFound = true;
            }
          }
        } else if (node.firstChild.nodeName === "#text" && node.nodeName !== "RT" && node.nodeName !== "RP") {
          noFuriganaText.push(node.firstChild.textContent);
          noFuriganaNodes.push(node.firstChild);
          if (selectedFound === false) {
            if (selectedElement !== node.firstChild) {
              index = index + node.firstChild.textContent.length;
            } else {
              index = index + result.startOffset;
              selectedFound = true;
            }
          }
        }
      }
    }
  }
  var text = noFuriganaText.join("");
  var offset = index;
  if (adjustIndex) {
    index = index - 1;
  }
  

  var character = text[index];
  console.log('[hibiki] character=' + character + ' index=' + index + ' textLen=' + text.length);
  if (character) {
    console.log('[hibiki] calling onTapLookup with index=' + index);
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onTapLookup', {
        "index": index,
        "text": text,
        "x": e.clientX,
        "y": e.clientY,
      });
    } else {
      console.log('[hibiki] flutter_inappwebview not available!');
    }
  } else {
    console.log('[hibiki] no character found, sending index=-1');
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onTapLookup', {
        "index": -1,
        "text": "",
        "x": e.clientX,
        "y": e.clientY,
      });
    }
  }
}
function getSelectionText() {
    function getRangeSelectedNodes(range) {
      var node = range.startContainer;
      var endNode = range.endContainer;
      if (node == endNode) return [node];
      var rangeNodes = [];
      while (node && node != endNode) rangeNodes.push(node = nextNode(node));
      node = range.startContainer;
      while (node && node != range.commonAncestorContainer) {
        rangeNodes.unshift(node);
        node = node.parentNode;
      }
      return rangeNodes;
      function nextNode(node) {
        if (node.hasChildNodes()) return node.firstChild;
        else {
          while (node && !node.nextSibling) node = node.parentNode;
          if (!node) return null;
          return node.nextSibling;
        }
      }
    }
    var txt = "";
    var nodesInRange;
    var selection;
    if (window.getSelection) {
      selection = window.getSelection();
      nodesInRange = getRangeSelectedNodes(selection.getRangeAt(0));
      nodes = nodesInRange.filter((node) => node.nodeName == "#text" && node.parentElement.nodeName !== "RT" && node.parentElement.nodeName !== "RP" && node.parentElement.parentElement.nodeName !== "RT" && node.parentElement.parentElement.nodeName !== "RP");
      if (selection.anchorNode === selection.focusNode) {
          txt = txt.concat(selection.anchorNode.textContent.substring(selection.baseOffset, selection.extentOffset));
      } else {
          for (var i = 0; i < nodes.length; i++) {
              var node = nodes[i];
              if (i === 0) {
                  txt = txt.concat(node.textContent.substring(selection.getRangeAt(0).startOffset));
              } else if (i === nodes.length - 1) {
                  txt = txt.concat(node.textContent.substring(0, selection.getRangeAt(0).endOffset));
              } else {
                  txt = txt.concat(node.textContent);
              }
          }
      }
    } else if (window.document.getSelection) {
      selection = window.document.getSelection();
      nodesInRange = getRangeSelectedNodes(selection.getRangeAt(0));
      nodes = nodesInRange.filter((node) => node.nodeName == "#text" && node.parentElement.nodeName !== "RT" && node.parentElement.nodeName !== "RP" && node.parentElement.parentElement.nodeName !== "RT" && node.parentElement.parentElement.nodeName !== "RP");
      if (selection.anchorNode === selection.focusNode) {
          txt = txt.concat(selection.anchorNode.textContent.substring(selection.baseOffset, selection.extentOffset));
      } else {
          for (var i = 0; i < nodes.length; i++) {
              var node = nodes[i];
              if (i === 0) {
                  txt = txt.concat(node.textContent.substring(selection.getRangeAt(0).startOffset));
              } else if (i === nodes.length - 1) {
                  txt = txt.concat(node.textContent.substring(0, selection.getRangeAt(0).endOffset));
              } else {
                  txt = txt.concat(node.textContent);
              }
          }
      }
    } else if (window.document.selection) {
      txt = window.document.selection.createRange().text;
    }
    return txt;
};
if (!window.__hibikiClickListenerRegistered) {
  window.__hibikiClickListenerRegistered = true;
  console.log('[hibiki] registering listeners');
  var __jidoTapStartX = 0, __jidoTapStartY = 0, __jidoLastTouchEnd = 0;
  var __hibikiLastTurn = 0;

  // Hoshi-style page turn via wheel event (matches volume-key path).
  // direction: 'next' or 'prev'.
  // deltaY magnitude matches volume-key path (0.001 * speed). 纯 sign 对
  // ttu 分页足够，但连续滚动模式下 0.001 会被当噪音吞掉——音量键用 0.1。
  window.__hibikiTurnPage = function(direction) {
    var now = Date.now();
    if (now - __hibikiLastTurn < 200) return;
    __hibikiLastTurn = now;
    var sign = (direction === 'next') ? -1 : +1;
    var evt = document.createEvent('MouseEvents');
    evt.initEvent('wheel', true, true);
    evt.deltaY = sign * 0.1;
    document.body.dispatchEvent(evt);
  };

  document.addEventListener('touchstart', function(e) {
    if (e.touches.length === 1) {
      __jidoTapStartX = e.touches[0].clientX;
      __jidoTapStartY = e.touches[0].clientY;
    }
  }, {capture: true, passive: true});

  document.addEventListener('touchend', function(e) {
    if (e.changedTouches.length !== 1) return;
    var touch = e.changedTouches[0];
    var dxSigned = touch.clientX - __jidoTapStartX;
    var dySigned = touch.clientY - __jidoTapStartY;
    var dx = Math.abs(dxSigned);
    var dy = Math.abs(dySigned);

    // Horizontal swipe → page turn.
    if (dx > 50 && dx > dy * 1.5) {
      __jidoLastTouchEnd = Date.now();
      window.__hibikiTurnPage(dxSigned < 0 ? 'next' : 'prev');
      return;
    }

    // Tap (small movement).
    if (dx > 15 || dy > 15) return;

    // Tap → existing select-word behavior.
    if (!e.target.closest('.book-content')) return;
    __jidoLastTouchEnd = Date.now();
    tapToSelect({
      clientX: touch.clientX, clientY: touch.clientY,
      x: touch.clientX, y: touch.clientY,
      target: e.target,
    });
  }, true);

  document.addEventListener('click', function(e) {
    if (Date.now() - __jidoLastTouchEnd < 600) return;
    if (!e.target.closest('.book-content')) return;
    tapToSelect(e);
  }, true);
}
document.head.insertAdjacentHTML('beforebegin', `
<style>
rt {
  -webkit-touch-callout:none; /* iOS Safari */
  -webkit-user-select:none;   /* Chrome/Safari/Opera */
  -khtml-user-select:none;    /* Konqueror */
  -moz-user-select:none;      /* Firefox */
  -ms-user-select:none;       /* Internet Explorer/Edge */
  user-select:none;           /* Non-prefixed version */
}
rp {
  -webkit-touch-callout:none; /* iOS Safari */
  -webkit-user-select:none;   /* Chrome/Safari/Opera */
  -khtml-user-select:none;    /* Konqueror */
  -moz-user-select:none;      /* Firefox */
  -ms-user-select:none;       /* Internet Explorer/Edge */
  user-select:none;           /* Non-prefixed version */
}

::selection {
  color: white;
  background: rgba(255, 0, 0, 0.6);
}

/* ttu 顶部 32px 隐形热区 <button>（tap 唤出 reader 工具栏）。hibiki 把
   reader 工具栏功能（TOC / 书签 / 全屏 / 退出…）挪进了有声书播放栏的
   设置面板，所以热区和它唤出的工具栏都直接隐藏。SSG 快照里 class 带
   top-0，Svelte hydrate 后 class 变成 "fixed inset-x-0 z-10 h-8 w-full"
   （没有 top-0），所以要按 fixed+h-8+w-full 匹配。 */
button.fixed.h-8.w-full,
button.fixed.inset-x-0,
button.fixed.top-0 {
  display: none !important;
}

/* ttu 通过 inline style 在 body 或容器上设了 padding-top（viewport
   padding 用户可调项，默认 40px 左右），给正文顶部留一大截空白。
   hibiki 不走原生阅读器工具栏，这一截空白没用，整段内容上移。
   只压顶部，左右和底部的 padding 保留给普通 EPUB 的排版舒适度。 */
.book-content-container,
.book-content {
  padding-top: 0 !important;
}

/* 有声书模式隐藏 ttu 原生底部进度条（h-8=32px 的 fixed div）。功能
   在播放栏的设置面板里。普通 EPUB（未挂 audiobook）保持显示，用户
   阅读进度不至于丢失。html[data-hibiki-audiobook] 属性由 Flutter
   侧 _syncAudiobookModeAttr 同步到 WebView。 */
html[data-hibiki-audiobook] div.fixed.bottom-0.left-0.z-10 {
  display: none !important;
}

/* ttu 书签指示图标（faBookmark，opacity 0.25）——滚动位置命中 bookmark
   时显示。对应 node4 Ou/Gu 渲染的 div.pointer-events-none.absolute.
   opacity-25，用 inline top/left/right 浮在正文上。hibiki 走 ttu 原生
   auto-bookmark，这颗半透明图钉对用户没用，且容易盖住正文，直接隐藏。 */
div.pointer-events-none.absolute.opacity-25 {
  display: none !important;
}
</style>
`);


function selectTextForTextLength(x, y, index, length, whitespaceOffset, isSpaceDelimited) {
  var result = document.caretRangeFromPoint(x, y);

  var selectedElement = result.startContainer;
  var paragraph = result.startContainer;
  var offsetNode = result.startContainer;
  var offset = result.startOffset;

  var adjustIndex = false;

  if (!!offsetNode && offsetNode.nodeType === Node.TEXT_NODE && offset) {
      const range = new Range();
      range.setStart(offsetNode, offset - 1);
      range.setEnd(offsetNode, offset);

      const bbox = range.getBoundingClientRect();
      if (bbox.left <= x && bbox.right >= x &&
          bbox.top <= y && bbox.bottom >= y) {
          if (length == 1) {
            const range = new Range();
            range.setStart(offsetNode, result.startOffset - 1);
            range.setEnd(offsetNode, result.startOffset);

            var selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return;
          }

          result.startOffset = result.startOffset - 1;
          adjustIndex = true;
      }
  }

  if (length == 1) {
    const range = new Range();
    range.setStart(offsetNode, result.startOffset);
    range.setEnd(offsetNode, result.startOffset + 1);

    var selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    return;
  }

  while (paragraph && paragraph.nodeName !== 'P') {
    paragraph = paragraph.parentNode;
  }
  if (paragraph === null) {
    paragraph = result.startContainer.parentNode;
  }
  var noFuriganaText = [];
  var lastNode;

  var endOffset = 0;
  var done = false;

  for (var value of paragraph.childNodes.values()) {
    if (done) {
      console.log(noFuriganaText.join());
      break;
    }
    
    if (value.nodeName === "#text") {
      endOffset = 0;
      lastNode = value;
      for (var i = 0; i < value.textContent.length; i++) {
        noFuriganaText.push(value.textContent[i]);
        endOffset = endOffset + 1;
        if (noFuriganaText.length >= length + index) {
          done = true;
          break;
        }
      }
    } else {
      for (var node of value.childNodes.values()) {
        if (done) {
          break;
        }

        if (node.nodeName === "#text") {
          endOffset = 0;
          lastNode = node;

          for (var i = 0; i < node.textContent.length; i++) {
            noFuriganaText.push(node.textContent[i]);
            endOffset = endOffset + 1;
            if (noFuriganaText.length >= length + index) {
              done = true;
              break;
            }
          }
        } else if (node.firstChild.nodeName === "#text" && node.nodeName !== "RT" && node.nodeName !== "RP") {
          endOffset = 0;
          lastNode = node.firstChild;
          for (var i = 0; i < node.firstChild.textContent.length; i++) {
            noFuriganaText.push(node.firstChild.textContent[i]);
            endOffset = endOffset + 1;
            if (noFuriganaText.length >= length + index) {
              done = true;
              break;
            }
          }
        }
      }
    }
  }

  const range = new Range();
  range.setStart(offsetNode, result.startOffset - adjustIndex + whitespaceOffset);
  if (isSpaceDelimited) {
    range.expand("word");
  } else {
    range.setEnd(lastNode, endOffset);
  }

  var selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
}

// ReaderPosition 保存触发：监听 `.book-content` / `.book-content-container`
// 的 scroll 事件，debounce 200ms 后调 `__hibikiGetViewportNormOffset()`
// 反查当前视口的 (section, 章内 normCharOffset)，再通过 flutter_inappwebview
// 的 saveReaderPos handler 回传 Dart 写 Isar。
//
// 为什么 200ms：paginated 翻一页本质是单次 scroll 事件（scrollTop 跳一大步
// 后稳定），之后无后续 scroll。更长的 debounce 相当于"等一个不会再来的
// 事件"，让用户翻页后几秒内才写库，关书前 dispose flush 才兜住。200ms
// 足够过滤同一次翻页动画里的多发 scroll（动画本身 < 100ms），又让翻页
// 到落盘基本无感延迟。Dart 侧 _persistReaderPos 自带同值去重，即便 JS
// debounce 偶尔多 fire 一次也不会额外 writeTxn。
//
// - scroll 事件不冒泡，必须 capture 阶段监听，并挂到 document 上做事件委托
//   （ttu 切换章节会重建 `.book-content` DOM，直接绑到那个元素会丢）
// - __hibikiGetViewportNormOffset 由 AudiobookBridge.inject 注入，但 inject
//   只在有 audiobook 时才跑 —— 纯 EPUB（无有声书）场景该函数不存在，这里
//   直接 return，不会抛。纯 EPUB 的位置保存后续单独做。
// - __hibikiPosSaveInstalled guard 防 onLoadStop 多次 evaluate 重复注册。
(function() {
  if (window.__hibikiPosSaveInstalled) return;
  window.__hibikiPosSaveInstalled = true;
  var timer = null;
  function schedule() {
    if (timer) clearTimeout(timer);
    timer = setTimeout(function() {
      try {
        if (!window.__hibikiGetViewportNormOffset) return;
        var p = window.__hibikiGetViewportNormOffset();
        if (!p) return;
        if (window.flutter_inappwebview) {
          window.flutter_inappwebview.callHandler('saveReaderPos', p);
        }
      } catch (e) {}
    }, 200);
  }
  document.addEventListener('scroll', function(e) {
    var t = e.target;
    if (!t) return;
    // Element vs Document 区分：document 的 scroll 事件 target === document
    // 本身（ttu paginated 下 window 不滚，这里主要过 book-content*）
    if (t === document) { schedule(); return; }
    if (t.classList && (t.classList.contains('book-content') ||
                        t.classList.contains('book-content-container'))) {
      schedule();
    }
  }, true);
})();
""";

  String get leftArrowSimulateJs => '''
    var evt = document.createEvent('MouseEvents');
    evt.initEvent('wheel', true, true);
    evt.deltaY = +0.001 * ${mediaSource.volumePageTurningSpeed * (mediaSource.volumePageTurningInverted ? -1 : 1)};
    document.body.dispatchEvent(evt);
    ''';

  String get rightArrowSimulateJs => '''
    var evt = document.createEvent('MouseEvents');
    evt.initEvent('wheel', true, true);
    evt.deltaY = -0.001 * ${mediaSource.volumePageTurningSpeed * (mediaSource.volumePageTurningInverted ? -1 : 1)};
    document.body.dispatchEvent(evt);
    ''';

  /// Override the base class to show a Hoshi-style bottom sheet instead of
  /// a half-screen overlay. The sheet slides up from the bottom, has rounded
  /// top corners, a drag handle, and supports drag-to-expand.
  @override
  Widget buildBottomHalfDictionary() {
    Color color = appModel.overrideDictionaryColor ??
        (appModel.overrideDictionaryTheme ?? theme).cardColor;

    if ((appModel.overrideDictionaryTheme ?? theme).brightness ==
        Brightness.dark) {
      color = JidoujishoColor.lighten(color, 0.05);
    } else {
      color = JidoujishoColor.darken(color, 0.05);
    }

    final Color sheetColor = color.withOpacity(dictionaryBackgroundOpacity);
    final Color handleColor =
        (appModel.overrideDictionaryTheme ?? theme).dividerColor;

    return Align(
      alignment: Alignment.bottomCenter,
      child: DraggableScrollableSheet(
        initialChildSize: 0.45,
        minChildSize: 0.25,
        maxChildSize: 0.92,
        snap: true,
        snapSizes: const [0.45, 0.92],
        builder: (context, scrollController) {
          return Container(
            decoration: BoxDecoration(
              color: sheetColor,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 12,
                  spreadRadius: 2,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Column(
              children: [
                // Drag handle — tap to dismiss
                GestureDetector(
                  onTap: clearDictionaryResult,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: handleColor.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
                // Dictionary content
                Expanded(
                  child: Stack(
                    children: [
                      buildSearchResult(),
                      buildDictionaryLoading(),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── 有声书辅助方法 ──────────────────────────────────────────────────────────

  /// 从 Isar 查找当前书的 [Audiobook]，若存在则初始化播放器并监听 cue 变化。
  /// 若未找到，再尝试以 [SrtBook] 方式初始化（字幕 EPUB 路径）。
  Future<void> _initAudiobookIfAvailable() async {
    final String? bookUid = widget.item?.uniqueKey;
    if (bookUid == null) {
      return;
    }
    debugPrint('[hibiki-audiobook] initAudiobook bookUid.len=${bookUid.length} '
        'hash=${bookUid.hashCode} uid=$bookUid');
    final AudiobookRepository repo = AudiobookRepository(appModel.database);
    final Audiobook? audiobook = repo.findByBookUid(bookUid);

    if (audiobook != null) {
      // ── 常规 EPUB 有声书路径 ─────────────────────────────────────────────
      final List<File> audioFiles = _resolveAudioFiles(
        audioPaths: audiobook.audioPaths,
        audioRoot: audiobook.audioRoot,
      );

      if (audioFiles.isEmpty) {
        return;
      }

      final AudiobookPlayerController controller = AudiobookPlayerController();
      await controller.load(
        audiobook: audiobook,
        audioFiles: audioFiles,
        initialFollowAudio: repo.readFollowAudio(bookUid),
        initialDelayMs: repo.readDelayMs(bookUid),
        initialSpeed: repo.readSpeed(bookUid),
      );
      controller.addListener(_onCueChanged);
      _wireFollowAudio(controller, bookUid: bookUid, repo: repo);

      if (mounted) {
        setState(() {
          _audiobookController = controller;
        });
        if (_controllerInitialised) {
          await _maybeInjectAudiobookBridge(
            _controller,
            trigger: 'audiobookReady',
          );
          await _syncAudiobookModeAttr();
        }
      }
    } else {
      // ── 字幕 EPUB 路径（SrtBook）──────────────────────────────────────────
      await _initSrtBookIfAvailable();
    }
  }

  /// 从 URL 中解析 ttuBookId，查找对应 [SrtBook] 并初始化播放器。
  Future<void> _initSrtBookIfAvailable() async {
    final int? ttuId = _extractTtuBookId();
    if (ttuId == null || ttuId <= 0) {
      debugPrint('[hibiki-audiobook] srt init skip: no ttuId in URL');
      return;
    }

    final SrtBookRepository srtRepo = SrtBookRepository(appModel.database);
    final List<SrtBook> allBooks = srtRepo.listAll();
    SrtBook? srtBook;
    for (final SrtBook b in allBooks) {
      if (b.ttuBookId == ttuId) {
        srtBook = b;
        break;
      }
    }
    if (srtBook == null) {
      debugPrint('[hibiki-audiobook] srt init skip: no SrtBook for ttuId=$ttuId');
      return;
    }

    final bool hasAudioConfig = (srtBook.audioPaths != null &&
            srtBook.audioPaths!.isNotEmpty) ||
        (srtBook.audioRoot != null && srtBook.audioRoot!.isNotEmpty);
    final List<File> audioFiles = _audioFilesForSrtBook(srtBook);
    if (audioFiles.isEmpty) {
      if (hasAudioConfig) {
        // 配置了音频但解析为空 — 文件丢失/路径失效，告知用户
        debugPrint('[hibiki-audiobook] srt init: audio configured but '
            'unresolved. paths=${srtBook.audioPaths} root=${srtBook.audioRoot}');
        Fluttertoast.showToast(msg: t.srt_audio_unresolved);
      } else {
        debugPrint('[hibiki-audiobook] srt init: pure subtitle book, no audio');
      }
      return;
    }

    // 用合成 Audiobook 对象满足控制器接口；bookUid = SrtBook.uid。
    final Audiobook syntheticAudiobook = Audiobook()
      ..bookUid = srtBook.uid
      ..audioRoot = srtBook.audioRoot
      ..audioPaths = srtBook.audioPaths
      ..alignmentFormat = 'srt'
      ..alignmentPath = srtBook.srtPath;

    // 闭包捕获：避免 null-promotion 在 async 闭包里丢掉。局部 `srtRepo`
    // 已是 SrtBookRepository（外层变量），这里换名区分。
    final String srtBookUid = srtBook.uid;
    final AudiobookRepository abRepo = AudiobookRepository(appModel.database);
    final AudiobookPlayerController controller = AudiobookPlayerController();
    try {
      await controller.load(
        audiobook: syntheticAudiobook,
        audioFiles: audioFiles,
        // Follow audio 仍不落库（见下注释），但延迟/速度是纯 Hive KV，按
        // srtBook.uid 做 key 不碰 Isar，SRT-book 路径安全使用。
        initialDelayMs: abRepo.readDelayMs(srtBookUid),
        initialSpeed: abRepo.readSpeed(srtBookUid),
      );
    } catch (e) {
      debugPrint('[hibiki-audiobook] srt init: controller.load failed: $e');
      Fluttertoast.showToast(msg: t.srt_audio_load_error);
      controller.dispose();
      return;
    }
    controller.addListener(_onCueChanged);
    // SRT-book 的 audiobook 是合成对象，没写进 Isar audiobooks 集合，
    // updateFollowAudio 会找不到记录。暂先只接 onCrossChapter（会话内
    // 磁铁按钮仍可切换），不落库。真正落库需要把 followAudio 搬到
    // SrtBook 模型，属于独立的数据层工作。
    // 延迟/速度走 Hive KV，可以落。
    controller.onDelayPersist = (int ms) async {
      await abRepo.updateDelayMs(bookUid: srtBookUid, ms: ms);
    };
    controller.onSpeedPersist = (double speed) async {
      await abRepo.updateSpeed(bookUid: srtBookUid, speed: speed);
    };
    controller.onCrossChapter = _handleCueCrossChapter;
    controller.getCurrentReaderSection = () => _currentTtuSection;

    if (mounted) {
      setState(() {
        _audiobookController = controller;
        _srtBookUid = srtBook!.uid;
      });
      if (_controllerInitialised) {
        await _maybeInjectAudiobookBridge(
          _controller,
          trigger: 'srtBookReady',
        );
        await _syncAudiobookModeAttr();
      }
    }
  }

  /// 从 [widget.item?.mediaIdentifier] 的 URL 中提取 `id=N` 参数。
  int? _extractTtuBookId() {
    final String? identifier = widget.item?.mediaIdentifier;
    if (identifier == null) {
      return null;
    }
    final Uri? uri = Uri.tryParse(identifier);
    return int.tryParse(uri?.queryParameters['id'] ?? '');
  }

  /// 根据 [SrtBook] 的音频来源构建有序文件列表。
  List<File> _audioFilesForSrtBook(SrtBook book) =>
      _resolveAudioFiles(audioPaths: book.audioPaths, audioRoot: book.audioRoot);

  /// 通用音频文件解析：files 模式优先于 folder 模式。
  /// folder 模式下递归扫描音频扩展名并按路径排序。
  List<File> _resolveAudioFiles({
    required List<String>? audioPaths,
    required String? audioRoot,
  }) {
    if (audioPaths != null && audioPaths.isNotEmpty) {
      return audioPaths
          .map((p) => File(p))
          .where((f) => f.existsSync())
          .toList();
    }
    if (audioRoot != null) {
      final Directory dir = Directory(audioRoot);
      if (!dir.existsSync()) {
        return [];
      }
      return dir
          .listSync()
          .whereType<File>()
          .where((f) {
            final String ext = f.path.toLowerCase();
            return ext.endsWith('.mp3') ||
                ext.endsWith('.m4a') ||
                ext.endsWith('.ogg') ||
                ext.endsWith('.aac') ||
                ext.endsWith('.wav') ||
                ext.endsWith('.mp4');
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    }
    return [];
  }

  /// 注入 / 重新注入 AudiobookBridge，并立即把当前 cue 重新高亮一次。
  ///
  /// 每次 `onLoadStop` / `onTitleChanged`（章节切换）都要重跑：
  /// - ttu 章节切换可能换 document，旧 JS 上下文消失，必须重注入函数。
  /// - 即便 JS 还在，新章节 DOM 落点是首页 — 必须主动跳到当前 cue
  ///   所在页，否则用户看到的是「回到标题页 / 第一行」。
  ///
  /// 注入流程本身是幂等的（CSS 用 id 去重，JS 用 var 覆盖，cue click
  /// handler 用 document flag 去重），所以重复调用安全。
  Future<void> _maybeInjectAudiobookBridge(
    InAppWebViewController controller, {
    required String trigger,
  }) async {
    if (_audiobookController == null) {
      return;
    }
    debugPrint('[hibiki-audiobook] injecting via $trigger');
    await _injectAudiobookBridge(controller);
    // 引导 _currentTtuSection：ttu fork 的 sectionChanged 订阅带 skip(1)，
    // 首次挂载（封面 / 最近阅读章）那次 Wn 发射被吃掉，字段会一直卡在 -1。
    // 跨章守卫 currentSec<0 下就永远不会自动跳章——用户在封面开 Follow
    // audio 时音频的 section 明明和当前页不同，但也跳不过去。inject 之后
    // 立即 probe ttu 的 __ttuCurrentSection() 把字段拨正。
    await _bootstrapCurrentTtuSection(controller);
    // 位置恢复：在 _bootstrapCurrentTtuSection 之后，这样 _currentTtuSection
    // 已经从 ttu probe 拿到真值（fork skip(1) 的坑不然留 -1，跨段判定会
    // 走错路径）。_didRestorePos 在函数内部自守只跑一次。
    await _bootstrapRestoreReaderPos();
    // 章节加载后立刻把视口拉回当前句所在页（Hoshi pendingFragment 模式）。
    _onCueChanged();
  }

  /// 把 `data-hibiki-audiobook` 属性同步到 `<html>`，触发静态 CSS 里
  /// `html[data-hibiki-audiobook] ...` 规则（目前只用来隐藏 ttu 原生底部
  /// 进度条——功能挪进播放栏设置面板）。ttu 切章节会换 document 丢失
  /// attribute，所以 onLoadStop / onTitleChanged / audiobookReady /
  /// srtBookReady / teardown 都要重新同步。
  Future<void> _syncAudiobookModeAttr() async {
    if (!_controllerInitialised || !mounted) return;
    final bool on = _audiobookController != null;
    try {
      await _controller.evaluateJavascript(source: '''
(function(on){
  var r=document.documentElement;
  if(on){r.setAttribute('data-hibiki-audiobook','1');}
  else{r.removeAttribute('data-hibiki-audiobook');}
})($on);
''');
    } catch (e) {
      debugPrint('[hibiki-audiobook] syncAudiobookModeAttr error: $e');
    }
  }

  /// 打开有声书设置面板（⚙ 按钮入口）。面板里放阅读进度、倍速、
  /// 音画同步三块。进度 probe 需要 WebView controller，所以这里构造
  /// 而不是在 [AudiobookPlayBar] 内部做。
  ///
  /// probe 结果异步，面板初次打开时先显示 "—"，拿到后 setState 替换；
  /// 或者先 await probe 再展开（更简单，用户短暂 tap 延迟可接受）。
  Future<void> _showAudiobookSettingsSheet(
    AudiobookPlayerController ctrl,
  ) async {
    (int, int)? progress;
    try {
      final TtuApiProbe probe = await AudiobookBridge.probeTtuApi(_controller);
      if (probe.currentSection != null &&
          probe.sectionCount != null &&
          probe.sectionCount! > 0) {
        progress = (probe.currentSection!, probe.sectionCount!);
      }
    } catch (e) {
      debugPrint('[hibiki-audiobook] settings probe error: $e');
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) {
        return AudiobookSettingsSheet(
          controller: ctrl,
          readerProgress: progress,
        );
      },
    );
  }

  /// 从 ttu fork 的 `__ttuCurrentSection()` 读一次当前段，用来兜住
  /// sectionChanged 初次发射被 skip(1) 吃掉的情况。fork 未就绪或 probe
  /// 失败时保留原值（多半仍是 -1，跨章守卫就继续等真正的 sectionChanged）。
  Future<void> _bootstrapCurrentTtuSection(
    InAppWebViewController controller,
  ) async {
    try {
      final TtuApiProbe probe = await AudiobookBridge.probeTtuApi(controller);
      if (!probe.hasCurrentSection || probe.currentSection == null) {
        return;
      }
      final int prev = _currentTtuSection;
      _currentTtuSection = probe.currentSection!;
      if (prev != _currentTtuSection) {
        debugPrint(
          '[hibiki-audiobook] bootstrap _currentTtuSection='
          '$_currentTtuSection (prev=$prev) via ttu probe',
        );
      }
    } catch (e) {
      debugPrint('[hibiki-audiobook] probeTtuApi failed: $e');
    }
  }

  /// 注入 JS/CSS 桥并对当前页面注册交互逻辑。
  ///
  /// - **SrtBook 路径**：EPUB 已预置 `data-cue-id` span，直接注册点击处理器，
  ///   加载全部 cue 供音频轨道追踪，不调用 [AudiobookBridge.annotate]。
  /// - **常规有声书路径**：按章节 href 查询 cue；若为空则自动标注句子。
  Future<void> _injectAudiobookBridge(
      InAppWebViewController controller) async {
    await AudiobookBridge.inject(controller);

    if (_srtBookUid != null) {
      // ── 字幕 EPUB 路径 ────────────────────────────────────────────────────
      final SrtBookRepository srtRepo = SrtBookRepository(appModel.database);
      final List<AudioCue> cues = srtRepo.cuesFor(_srtBookUid!);
      _audiobookController?.setChapterCues(cues);

      debugPrint(
        '[hibiki-audiobook] inject(srt) cues=${cues.length} '
        'firstSel=${cues.isNotEmpty ? cues.first.textFragmentId : "-"}',
      );

      await AudiobookBridge.injectCueClickHandler(
        controller,
        chapterHref: SrtParser.defaultChapter,
      );

      // 诊断：页面里到底存不存在 data-cue-id span
      final Object? probe = await controller.evaluateJavascript(source: '''
(function(){
  var all = document.querySelectorAll('[data-cue-id]');
  var sample = all.length > 0 ? all[0].outerHTML.slice(0, 120) : '';
  return JSON.stringify({count: all.length, sample: sample});
})();
''');
      debugPrint('[hibiki-audiobook] dom probe: $probe');
    } else {
      // ── 常规有声书路径 ────────────────────────────────────────────────────
      final String? bookUid = widget.item?.uniqueKey;
      if (bookUid == null) {
        return;
      }
      final AudiobookRepository repo = AudiobookRepository(appModel.database);

      // Sasayaki 路径的 cue 把位置编码在 textFragmentId 上（`sasayaki://...`），
      // 与原始 chapterHref 解耦：cues 存在某个默认 chapter（srt:// 等）下，但
      // 跨章节定位靠 sectionIndex + 归一化偏移。按章节过滤会返回空集，所以
      // 先抓全部 cue，检测到 Sasayaki 编码就沿用；否则退回按章节过滤。
      final List<AudioCue> allCues = repo.cuesForBook(bookUid);
      final bool sasayaki = allCues.any(
        (AudioCue c) => SasayakiMatchCodec.tryDecode(c.textFragmentId) != null,
      );

      final List<AudioCue> cues;
      if (sasayaki) {
        cues = allCues;
      } else {
        cues = repo.cuesForChapter(
          bookUid: bookUid,
          chapterHref: _currentChapterHref,
        );
      }
      _audiobookController?.setChapterCues(cues);

      debugPrint(
        '[hibiki-audiobook] inject(regular) chapter=$_currentChapterHref '
        'cues=${cues.length} sasayaki=$sasayaki',
      );

      if (sasayaki) {
        // Sasayaki 模式不做句级 annotate（cue 位置由 normChar 偏移编码）；
        // 只需把 sectionIndex → DOM id 映射拉起来，高亮时现场定位。
        final int? ttuId = _extractTtuBookId();
        if (ttuId != null && ttuId > 0) {
          await AudiobookBridge.initSasayakiRefs(
            controller,
            ttuBookId: ttuId,
          );
        } else {
          debugPrint(
            '[hibiki-audiobook] sasayaki init skipped: ttuBookId missing',
          );
        }
      } else if (cues.isEmpty) {
        // 无预对齐 cue，用自动标注
        await AudiobookBridge.annotate(
          controller,
          chapterHref: _currentChapterHref,
        );
      }
    }
  }

  /// currentCue 变化时高亮对应 DOM 元素。
  void _onCueChanged() {
    if (!_controllerInitialised) {
      return;
    }
    final AudiobookPlayerController? controller = _audiobookController;
    final AudioCue? cue = controller?.currentCue;
    // 对齐 Sasayaki `reveal: autoScroll && hasPlayedOnce`：Follow audio OFF
    // 或者还没按过 play 时，只加高亮 class、不把页面滚到 cue 所在页，
    // 保持用户当前阅读位置。
    final bool reveal = controller?.shouldRevealCurrentCue ?? true;
    debugPrint(
      '[hibiki-audiobook] cue changed sid=${cue?.sentenceIndex} '
      'sel=${cue?.textFragmentId} reveal=$reveal',
    );
    AudiobookBridge.highlight(_controller, cue: cue, reveal: reveal);
  }

  // ── PR8b Follow audio wiring ────────────────────────────────────────────

  /// 把 Follow audio / 延迟 / 速度 的持久化回调和跨章事件挂到控制器上。
  /// 常规 EPUB audiobook 路径走这里；SRT-book 路径暂不落库（见 caller 注释）。
  void _wireFollowAudio(
    AudiobookPlayerController controller, {
    required String bookUid,
    required AudiobookRepository repo,
  }) {
    controller.onFollowAudioPersist = (bool value) async {
      await repo.updateFollowAudio(bookUid: bookUid, value: value);
    };
    controller.onDelayPersist = (int ms) async {
      await repo.updateDelayMs(bookUid: bookUid, ms: ms);
    };
    controller.onSpeedPersist = (double speed) async {
      await repo.updateSpeed(bookUid: bookUid, speed: speed);
    };
    controller.onCrossChapter = _handleCueCrossChapter;
    controller.getCurrentReaderSection = () => _currentTtuSection;
  }

  /// cue 跨章时由控制器触发。
  ///
  /// Follow=ON：立刻请求 ttu 跳章；记 `_inFlightNavSection` 避免 ttu 回来
  /// 的 sectionChanged 又被当成用户意图。失败降级为 pill。
  /// Follow=OFF：显示 pill "→ 第 N 章"，点了手动跳。
  Future<void> _handleCueCrossChapter(int newSection) async {
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null || !_controllerInitialised) return;
    // 位置恢复期间拒绝 Follow audio 的跨章跳转：否则音频 cue 一推，reader
    // 就从恢复目标章被带走（用户期望的 "回到上次位置" 变成 "跑到音频章"）。
    // 等 _finishRestore 清了 _restoreInFlight 再放开。
    if (_restoreInFlight) {
      debugPrint(
        '[hibiki-reader-pos] cross-chapter suppressed during restore '
        '(newSection=$newSection)',
      );
      return;
    }

    if (controller.followAudio.value) {
      _inFlightNavSection = newSection;
      _armNavRestoreTimeout(newSection, controller);
      // ttu 重新挂载了章节 DOM（即便 newSection == 之前 section），旧 cueMap
      // 里的 span 已经游离。放 Dart 这层早返回守卫失效，让下一个
      // sasayakiMountedSection 事件重新跑 applySasayakiCues。JS 侧
      // __sasayakiRequestNav 里也同步清了 __hoshiSasayakiAppliedForSection，
      // 两道守卫一起下让 apply 一定重跑。
      _lastSasayakiAppliedSection = -1;
      _lastSasayakiAppliedRootLen = -1;
      try {
        await AudiobookBridge.requestSectionNav(
          _controller,
          sectionIndex: newSection,
        );
      } catch (e) {
        debugPrint('[hibiki-audiobook] requestSectionNav failed: $e');
        _completeNavRestore(
          controller: controller,
          currentReaderSection: _currentTtuSection,
          success: false,
        );
        if (mounted) {
          setState(() => _pendingNavSection = newSection);
        }
      }
      // 成功路径不在这里 notify —— evaluateJavascript 不 await JS Promise，
      // 在这里 notify 会提前清 _chapterTransition，期间下一条 cue tick 再
      // 触发跨章、scrollTop 被第二次清零到章首。改为等 ttu 真正跳完从 Wn
      // 推 sectionChanged(auto=true, idx==newSection) 回来，由
      // _handleTtuSectionChanged 调 _completeNavRestore。Timer 兜底 3s。
    } else {
      // Follow=OFF：不自动跳章，只显示 pill。controller 不会触发 onCrossChapter
      // 这条路径（_maybeEmitCrossChapter 已用 followAudio 守卫），但保险起见
      // 走 fallback 也清一下守卫。
      controller.notifySectionRestoreCompleted(
        currentReaderSection: _currentTtuSection,
        success: false,
      );
      if (mounted) {
        setState(() => _pendingNavSection = newSection);
      }
    }
  }

  /// 挂 3s 跳章兜底 Timer：ttu 没在期限内推 `sectionChanged(target,
  /// auto=true)` 回来（fork 缺失 / ttu 内部 5s 超时）时，强制 notify 一次
  /// 让 `_chapterTransition` 释放，不然 cue 推进永久卡死。3s 落在 ttu
  /// 自身 5s 超时之前，先走 pill 降级，体感比干等 5s 好。
  void _armNavRestoreTimeout(
    int newSection,
    AudiobookPlayerController controller,
  ) {
    _navRestoreTimeout?.cancel();
    _navRestoreTimeout = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_inFlightNavSection != newSection) return;
      debugPrint(
        '[hibiki-audiobook] nav restore timeout, section=$newSection',
      );
      _completeNavRestore(
        controller: controller,
        currentReaderSection: _currentTtuSection,
        success: false,
      );
      if (mounted) {
        setState(() => _pendingNavSection = newSection);
      }
    });
  }

  /// 统一跳章完成出口：取消兜底 Timer、清 in-flight 标记、调 notifyRestore。
  /// 成功路径由 [_handleTtuSectionChanged] 在 auto=true 命中 target 时调用；
  /// 失败路径由 Timer / requestSectionNav catch 调用。
  void _completeNavRestore({
    required AudiobookPlayerController controller,
    required int currentReaderSection,
    required bool success,
  }) {
    _navRestoreTimeout?.cancel();
    _navRestoreTimeout = null;
    _inFlightNavSection = null;
    controller.notifySectionRestoreCompleted(
      currentReaderSection: currentReaderSection,
      success: success,
    );
  }

  /// pill 被点击时的跳章入口；成功后清空 pill。
  Future<void> _followPillTap() async {
    final int? target = _pendingNavSection;
    if (target == null) return;
    _inFlightNavSection = target;
    try {
      await AudiobookBridge.requestSectionNav(
        _controller,
        sectionIndex: target,
      );
      _currentTtuSection = target;
      // 同 _handleCueCrossChapter：ttu 换过 DOM，cueMap 旧 span 作废，
      // 必须清 Dart 早返回守卫，否则 mountedSection handler 会 skip。
      _lastSasayakiAppliedSection = -1;
      _lastSasayakiAppliedRootLen = -1;
      if (mounted) setState(() => _pendingNavSection = null);
    } catch (e) {
      debugPrint('[hibiki-audiobook] pill tap requestSectionNav failed: $e');
      Fluttertoast.showToast(msg: 'Follow audio: 跳章失败');
    }
  }

  /// 收到 JS 侧 `sasayakiMountedSection` 事件（`__hoshiHighlightSasayaki`
  /// 在 rootTextLen 变化时测出挂载段后主动打）：对齐 Sasayaki 原版
  /// reader.js 的 applySasayakiCues 入口，把该段所有 Sasayaki cue 批量预包
  /// 成 `<span class="hoshi-sasayaki-cue">`，塞进 JS 侧 cueMap。
  ///
  /// 之后每条 cue 高亮走 `__hoshiHighlightSasayakiCueById` 的 O(1) Map 查表，
  /// 不再每句 TreeWalker 全章扫一遍。未命中（跨节点 cue / 该段还没 apply）
  /// 由 JS 自身 fallback 到旧的 `__hoshiHighlightSasayaki` 偏移定位路径。
  Future<void> _handleSasayakiMountedSection(Map<String, dynamic> json) async {
    final int mounted = (json['mountedSection'] as num?)?.toInt() ?? -1;
    final int rootLen = (json['rootTotalNormChars'] as num?)?.toInt() ?? -1;
    if (mounted < 0) return;
    // 位置恢复第二步：bootstrap 已发的 requestSectionNav 让 ttu 跳到
    // saved.section，跳完重挂 DOM → 下一次 cue-tick 的 __hoshiHighlightSasayaki
    // measure 识别出 mountedSection，在这里 consume 起来。cover / 空段触发不
    // 了 mount（not-mounted 守卫拦在 measure 之前），所以恢复**不能挂在** 这
    // 里起步 —— 起步逻辑在 _bootstrapRestoreReaderPos 里。
    final ReaderViewportPos? pending = _pendingRestorePos;
    if (pending != null && pending.section == mounted) {
      await _finishRestore();
    }
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null || !_controllerInitialised) return;
    // 同段 + 同 rootLen 已 apply 过就跳过。换章 ttu 会换 innerHTML，
    // rootLen 通常变化；相同是少数 idempotent 路径（例如重复收到事件）。
    if (_lastSasayakiAppliedSection == mounted &&
        _lastSasayakiAppliedRootLen == rootLen) {
      return;
    }
    final List<AudioCue> cues = controller.sasayakiCuesForSection(mounted);
    if (cues.isEmpty) return;
    _lastSasayakiAppliedSection = mounted;
    _lastSasayakiAppliedRootLen = rootLen;
    try {
      await AudiobookBridge.applySasayakiCues(
        _controller,
        sectionIndex: mounted,
        cues: cues,
      );
    } catch (e) {
      debugPrint('[hibiki-audiobook] applySasayakiCues failed: $e');
      // apply 失败不致命：高亮路径的 fallback 会走旧 walker 定位。下次
      // mountedSection 事件仍有机会重试（清 guard 以允许重试）。
      _lastSasayakiAppliedSection = -1;
      _lastSasayakiAppliedRootLen = -1;
    }
  }

  /// 一本书 WebView 生命周期里第一次 bootstrap —— 读 Isar 的保存位置，
  /// 决定是跳章还是什么都不做。
  ///
  /// 调用时机：[_maybeInjectAudiobookBridge] 末尾（Sasayaki refs 已在路上
  /// 加载、_bootstrapCurrentTtuSection 已 probe 过 `_currentTtuSection`）。
  /// **不挂在 sasayakiMountedSection 事件上** —— 因为 cover 段触发不了 mount
  /// （`__hoshiHighlightSasayaki` 的 not-mounted 守卫在 measure 之前 return），
  /// 恢复永远起不来。
  ///
  /// 两种路径：
  /// - saved.section == _currentTtuSection：ttu 已在目标段（上次也停在这段）
  ///   → [_finishRestore] 当场 scrollToNormOffset。要求正文段（rootTextLen ≥ 80），
  ///   cover/空段在 scrollToNormOffset 内部 not-mounted 会 return；之后的
  ///   `sasayakiMountedSection` 回调里 pending 会再兜底消费一次。
  /// - saved.section != _currentTtuSection：`requestSectionNav(saved.section)`
  ///   让 ttu 跳过去，跳完 ttu 重挂 DOM，下一次 cue-tick 的
  ///   `__hoshiHighlightSasayaki` 跑 measure → `sasayakiMountedSection` 事件
  ///   → [_handleSasayakiMountedSection] 里 pending 匹配 mountedSection
  ///   → [_finishRestore]。
  ///
  /// 无记录（新书）：置 `_didRestorePos=true` 立即返回 —— 对应 Q2 "全新书
  /// cover 起，不自动跳到音频章"。Follow audio 的 `hasPlayedOnce` 守卫本身
  /// 也会拦自动跨章；两边一起保证用户按播放之前 reader 停在 cover。
  Future<void> _bootstrapRestoreReaderPos() async {
    if (_didRestorePos) return;
    if (!_controllerInitialised) return;
    // 先置 true —— 后面任何失败分支都不再重试（防止同一本书反复调 Isar）。
    // 真正需要重试时用户关书再开就行。
    _didRestorePos = true;
    final int? ttuId = _extractTtuBookId();
    if (ttuId == null || ttuId <= 0) {
      debugPrint('[hibiki-reader-pos] restore skipped: no ttuId');
      return;
    }
    ReaderPosition? saved;
    try {
      saved = ReaderPositionRepository(appModel.database)
          .findByTtuBookId(ttuId);
    } catch (e) {
      debugPrint('[hibiki-reader-pos] restore query err: $e');
      return;
    }
    if (saved == null) {
      debugPrint('[hibiki-reader-pos] no saved pos for ttuId=$ttuId');
      return;
    }
    debugPrint(
      '[hibiki-reader-pos] bootstrap restore ttuId=$ttuId '
      'saved=s${saved.sectionIndex}/o${saved.normCharOffset} '
      'currentTtuSection=$_currentTtuSection',
    );
    _pendingRestorePos = ReaderViewportPos(
      section: saved.sectionIndex,
      offset: saved.normCharOffset,
    );
    _restoreInFlight = true;
    if (_currentTtuSection == saved.sectionIndex) {
      // 已在目标段：直接滚。mount 回调也会再兜底一次（幂等 —— pendingPos
      // 被 _finishRestore 清掉后就不会重复滚）。
      await _finishRestore();
      return;
    }
    // 跨段：发 requestSectionNav，`_handleTtuSectionChanged` 的
    // `_inFlightNavSection` 分支会处理回报；等下次 Sasayaki mount 事件
    // （mountedSection == saved.sectionIndex）再进来 consume。
    _inFlightNavSection = saved.sectionIndex;
    // ttu 重新挂载章节 DOM，旧 cueMap 失效 —— 清 apply 守卫让 Sasayaki
    // 重新包 span（跟 _handleCueCrossChapter 同一处理）。
    _lastSasayakiAppliedSection = -1;
    _lastSasayakiAppliedRootLen = -1;
    try {
      await AudiobookBridge.requestSectionNav(
        _controller,
        sectionIndex: saved.sectionIndex,
      );
    } catch (e) {
      debugPrint('[hibiki-reader-pos] restore requestSectionNav err: $e');
      _restoreInFlight = false;
      _pendingRestorePos = null;
      _inFlightNavSection = null;
    }
  }

  /// consume `_pendingRestorePos`：调 JS 滚到章内归一化偏移，清守卫。
  Future<void> _finishRestore() async {
    final ReaderViewportPos? pending = _pendingRestorePos;
    if (pending == null) {
      _restoreInFlight = false;
      return;
    }
    _pendingRestorePos = null;
    try {
      await AudiobookBridge.scrollToNormOffset(
        _controller,
        section: pending.section,
        offset: pending.offset,
      );
      debugPrint(
        '[hibiki-reader-pos] scrolled s=${pending.section} o=${pending.offset}',
      );
    } catch (e) {
      debugPrint('[hibiki-reader-pos] scrollToNormOffset err: $e');
    } finally {
      _restoreInFlight = false;
    }
  }

  /// 处理 ttu fork 外发的 sectionChanged console 事件。
  ///
  /// auto=true 来自 `__sasayakiRequestNav`，要么是我们自己刚请求的跳章
  /// （_inFlightNavSection 相等），要么是未来其他系统触发——两种都不是
  /// 用户意图，忽略。
  /// auto=false 来自 ToC 点击 / 滑动翻页等用户操作，都是明确用户意图：
  /// 复用 [_autoOffFollowOnManualTurn]，Follow=ON 时自动关 Follow 并 toast，
  /// 让用户停在翻到的位置，下一条 cue 不会 reveal 把页面拉回。
  /// Follow=OFF 时 [_autoOffFollowOnManualTurn] 自身短路，相当于只更新
  /// `_currentTtuSection`、尊重用户翻页。
  void _handleTtuSectionChanged(Map<String, dynamic> json) {
    final int? idx = (json['sectionIndex'] as num?)?.toInt();
    final bool auto = json['auto'] == true;
    if (idx == null) return;
    // 跳章 in-flight 期间，auto=true 但 idx 不是我们的 target——通常是 ttu
    // 内部中间态（Wn 在最终值前被别的管道短暂推了一次）。**不能**更新
    // _currentTtuSection，否则下一条 cue tick 看到段不匹配又会触发一次
    // 跨章跳章，ttu 被二次 __ttuGoToSection，scrollTop 被二次清零到章首。
    if (_inFlightNavSection != null &&
        auto &&
        _inFlightNavSection != idx) {
      return;
    }
    // 任何 sectionChanged 事件都更新 _currentTtuSection（无论 auto 或用户
    // 翻页）。controller 通过 getCurrentReaderSection 读这个值判定 cue
    // 是否跨章——必须始终反映 reader 真实挂载的章节。
    _currentTtuSection = idx;
    // 我们自己刚发起的跳章回报：这是 ttu 真正跳完的信号——现在（而不是
    // requestSectionNav await 返回时）才是 notifyRestore 的正确时机，
    // 避免 _chapterTransition 被提前清。
    if (_inFlightNavSection == idx) {
      final AudiobookPlayerController? controller = _audiobookController;
      if (controller != null) {
        _completeNavRestore(
          controller: controller,
          currentReaderSection: idx,
          success: true,
        );
      } else {
        _navRestoreTimeout?.cancel();
        _navRestoreTimeout = null;
        _inFlightNavSection = null;
      }
      // bootstrap restore 的同段落地：ttu 已挂好新 section DOM
      // （fork 约定 sectionChanged 发出时 DOM 已 ready），立刻滚到目标
      // offset —— 不等 Sasayaki mountedSection 事件，因为
      // `notifySectionRestoreCompleted` 在 `_pendingCue==null` 时不会
      // notifyListeners，`_onCueChanged` 也就不会触发 highlight，
      // mountedSection 事件永远不发。`_handleSasayakiMountedSection` 里
      // 的 pending consume 是幂等兜底（_finishRestore 清 pendingPos 后
      // 再进来也不会重复滚）。
      if (_restoreInFlight && _pendingRestorePos?.section == idx) {
        unawaited(_finishRestore());
      }
      return;
    }
    if (auto) {
      // 系统触发但不是我们发的（未来 ttu 内部可能有别的程序化路径），
      // 保守跳过，不关 Follow。
      return;
    }
    // Follow ON 时 swipe / ToC 跨段 = 明确用户意图，走和音量键翻页同款
    // 的 auto-off 语义：关 Follow + toast，用户停在翻到的位置。
    // Follow=OFF 时 _autoOffFollowOnManualTurn 自身短路，不动状态。
    _autoOffFollowOnManualTurn();
    // 用户翻章 → 立即写 ReaderPosition 一次（offset=0 记到段首）。不等
    // scroll debounce：用户可能翻章后瞬间关书，scroll 事件没来得及触发。
    // 下一次 scroll 的 debounce 保存会把 offset 精修到章内精确位置。
    unawaited(_persistReaderPos(
      section: idx,
      offset: 0,
      from: 'sectionChanged',
    ));
  }

  /// 用户点击句子，跳转播放器到该 cue。
  Future<void> _seekToSentence(AudiobookClickEvent event) async {
    if (_audiobookController == null) {
      return;
    }
    final AudiobookRepository repo = AudiobookRepository(appModel.database);

    // SrtBook 的 cue 全部存在 srt://default，bookUid = SrtBook.uid；
    // 常规有声书使用事件携带的 chapterHref 和 widget uniqueKey。
    final String bookUid;
    final String chapterHref;
    if (_srtBookUid != null) {
      bookUid = _srtBookUid!;
      chapterHref = SrtParser.defaultChapter;
    } else {
      bookUid = widget.item?.uniqueKey ?? '';
      chapterHref = event.chapterHref;
    }

    final AudioCue? cue = repo.findCue(
      bookUid: bookUid,
      chapterHref: chapterHref,
      sentenceIndex: event.sentenceIndex,
    );
    if (cue != null) {
      await _audiobookController?.skipToCue(cue);
    }
  }

  // ── 有声书导入按钮 ──────────────────────────────────────────────────────────

  /// 右下角耳机图标，仅在无有声书时显示，点击打开导入对话框。
  Widget buildAudiobookImportButton() {
    if (_audiobookController != null) {
      return const SizedBox.shrink();
    }
    final String? bookUid = widget.item?.uniqueKey;
    if (bookUid == null) {
      return const SizedBox.shrink();
    }
    return Positioned(
      right: 12,
      bottom: 12,
      child: Opacity(
        opacity: 0.6,
        child: FloatingActionButton.small(
          heroTag: 'audiobook_import_fab',
          tooltip: t.audiobook_import,
          onPressed: () => _openImportDialog(bookUid),
          child: const Icon(Icons.headphones, size: 20),
        ),
      ),
    );
  }

  Future<void> _openImportDialog(String bookUid) async {
    // SrtBook 路径：直接给这本字幕书补音频，不创建独立 Audiobook 记录。
    final int? ttuId = _extractTtuBookId();
    if (ttuId != null && ttuId > 0) {
      final SrtBookRepository srtRepo = SrtBookRepository(appModel.database);
      SrtBook? srtBook;
      for (final SrtBook b in srtRepo.listAll()) {
        if (b.ttuBookId == ttuId) {
          srtBook = b;
          break;
        }
      }
      if (srtBook != null) {
        await _attachAudioToSrtBook(srtBook, srtRepo);
        return;
      }
    }

    // 若是 ttu 里的真 EPUB（带 ?id=N）且本地服务已启动，把 ttuBookId +
    // serverPort 一并传给 dialog，SRT 对齐时才会跑 Sasayaki 文本匹配，把
    // cue 位置编码到 textFragmentId（否则 cue 只带默认 `[data-cue-id]`，
    // 在没有 data-cue-id 的真 EPUB 上点不到也高亮不了）。
    final int? ttuBookIdForDialog = _extractTtuBookId();
    final int? serverPort = ref
        .read(ttuServerProvider(appModel.targetLanguage))
        .valueOrNull
        ?.boundPort;

    final bool? result = await showDialog<bool>(
      context: context,
      builder: (_) => AudiobookImportDialog(
        bookUid: bookUid,
        repo: AudiobookRepository(appModel.database),
        ttuBookId: ttuBookIdForDialog,
        serverPort: serverPort,
      ),
    );
    // result == true 表示用户完成导入，重新初始化播放器；
    // result == false 表示用户移除，拆掉内存中的控制器/播放条。
    if (!mounted) return;
    if (result == true) {
      await _initAudiobookIfAvailable();
    } else if (result == false) {
      _tearDownAudiobook();
    }
  }

  /// 用户从对话框里移除有声书后调用。拆 listener、dispose 控制器、清掉
  /// SrtBook 关联状态，并 setState 让播放条消失、耳机 FAB 重新出现。
  /// Isar 那边 deleteAudiobook 已经由对话框负责；这里只管内存状态。
  void _tearDownAudiobook() {
    final AudiobookPlayerController? ctrl = _audiobookController;
    ctrl?.removeListener(_onCueChanged);
    ctrl?.dispose();
    setState(() {
      _audiobookController = null;
      _srtBookUid = null;
    });
    _syncAudiobookModeAttr();
  }

  /// 给已存在的 [SrtBook] 补音频：action sheet 选"目录"或"多文件"，
  /// 更新 [SrtBook.audioRoot] / [SrtBook.audioPaths] 后重新初始化播放器。
  Future<void> _attachAudioToSrtBook(
    SrtBook book,
    SrtBookRepository repo,
  ) async {
    final _SrtAudioSource? source = await showModalBottomSheet<_SrtAudioSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: Text(t.srt_import_pick_audio_dir),
              onTap: () => Navigator.pop(ctx, _SrtAudioSource.folder),
            ),
            ListTile(
              leading: const Icon(Icons.audio_file),
              title: Text(t.srt_import_pick_audio_files),
              onTap: () => Navigator.pop(ctx, _SrtAudioSource.files),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    String? newDir;
    List<String>? newPaths;
    if (source == _SrtAudioSource.folder) {
      newDir = await FilePicker.platform.getDirectoryPath();
      if (newDir == null) return;
    } else {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );
      if (result == null) return;
      newPaths = result.files
          .map((f) => f.path)
          .whereType<String>()
          .toList()
        ..sort();
      if (newPaths.isEmpty) return;
    }

    book.audioRoot = newDir;
    book.audioPaths = newPaths;
    debugPrint('[hibiki-audiobook] before save: uid=${book.uid} id=${book.id} '
        'audioPaths=${book.audioPaths} audioRoot=${book.audioRoot}');
    try {
      await repo.save(book);
    } catch (e, st) {
      debugPrint('[hibiki-audiobook] save failed: $e\n$st');
      Fluttertoast.showToast(msg: t.srt_audio_load_error);
      return;
    }

    // 读回校验：保存后立刻重新查同一 uid，看 DB 实际保存了什么。
    final SrtBook? reread = repo.findByUid(book.uid);
    debugPrint('[hibiki-audiobook] attached audio to SrtBook ${book.uid}: '
        'saved paths=$newPaths root=$newDir '
        '-> reread audioPaths=${reread?.audioPaths} '
        'audioRoot=${reread?.audioRoot} '
        'ttuBookId=${reread?.ttuBookId}');

    // 同时 dump 所有 SrtBook，看是否有同 ttuBookId 冲突
    final List<SrtBook> all = repo.listAll();
    for (final SrtBook b in all) {
      debugPrint('[hibiki-audiobook]   DB entry: uid=${b.uid} '
          'ttuBookId=${b.ttuBookId} '
          'audioPaths=${b.audioPaths} audioRoot=${b.audioRoot}');
    }

    if (mounted) {
      await _initAudiobookIfAvailable();
    }
  }

  // ── 有声书底部播放条 ────────────────────────────────────────────────────────

  /// 底部播放控制条。仅在 [_audiobookController] 非 null 时显示。
  Widget buildAudiobookBar() {
    final AudiobookPlayerController? ctrl = _audiobookController;
    if (ctrl == null) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        return Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildFollowPill(),
              AudiobookPlayBar(
                controller: ctrl,
                onOpenSettings: () => _showAudiobookSettingsSheet(ctrl),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Follow=OFF 跨章时的悬浮 pill。点击跳章，成功后自动消失。
  /// 没有 pending 时返回空 widget（SizedBox）——不占高度不留白。
  Widget _buildFollowPill() {
    final int? target = _pendingNavSection;
    if (target == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 12, right: 12),
      child: Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: _followPillTap,
          icon: const Icon(Icons.arrow_forward, size: 16),
          label: Text('第 ${target + 1} 章'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }
}

enum _SrtAudioSource { folder, files }

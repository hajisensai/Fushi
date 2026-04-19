import 'dart:async';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 异步检查是否有挂载有声书
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initAudiobookIfAvailable();
    });
  }

  @override
  void dispose() {
    _audiobookController?.removeListener(_onCueChanged);
    _audiobookController?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
      onKey: (data, event) {
        if (ModalRoute.of(context)?.isCurrent ?? false) {
          if (mediaSource.volumePageTurningEnabled) {
            if (isDictionaryShown) {
              clearDictionaryResult();
              unselectWebViewTextSelection(_controller);
              mediaSource.clearCurrentSentence();

              return KeyEventResult.handled;
            }

            if (event.isKeyPressed(LogicalKeyboardKey.audioVolumeUp)) {
              unselectWebViewTextSelection(_controller);
              _controller.evaluateJavascript(source: leftArrowSimulateJs);

              return KeyEventResult.handled;
            }
            if (event.isKeyPressed(LogicalKeyboardKey.audioVolumeDown)) {
              unselectWebViewTextSelection(_controller);
              _controller.evaluateJavascript(source: rightArrowSimulateJs);

              return KeyEventResult.handled;
            }
          }

          return KeyEventResult.ignored;
        } else {
          return KeyEventResult.ignored;
        }
      },
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
                Padding(
                  padding: EdgeInsets.only(
                    bottom: _audiobookController != null
                        ? _kAudiobookBarHeight +
                            MediaQuery.of(context).padding.bottom
                        : 0,
                  ),
                  child: buildBody(),
                ),
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

    // diag 消息绕过 50ms 防抖，保证一轮 tick 内多条探针都能到 Flutter 侧。
    final String? msgType = isJson
        ? messageJson['hibiki-message-type'] as String?
        : null;
    final bool isDiag = msgType != null && msgType.startsWith('diag');

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

  /// This is executed upon page load and change.
  /// More accurate readability courtesy of
  /// https://github.com/birchill/10ten-ja-reader/blob/fbbbde5c429f1467a7b5a938e9d67597d7bd5ffa/src/content/get-text.ts#L314
  String javascriptToExecute = """
/*jshint esversion: 6 */

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

    final AudiobookPlayerController controller = AudiobookPlayerController();
    try {
      await controller.load(
        audiobook: syntheticAudiobook,
        audioFiles: audioFiles,
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
    controller.onCrossChapter = _handleCueCrossChapter;

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
    // 章节加载后立刻把视口拉回当前句所在页（Hoshi pendingFragment 模式）。
    _onCueChanged();
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
    final AudioCue? cue = _audiobookController?.currentCue;
    debugPrint(
      '[hibiki-audiobook] cue changed sid=${cue?.sentenceIndex} '
      'sel=${cue?.textFragmentId}',
    );
    AudiobookBridge.highlight(_controller, cue: cue);
  }

  // ── PR8b Follow audio wiring ────────────────────────────────────────────

  /// 把 Follow audio 的持久化回调和跨章事件挂到控制器上。
  /// 常规 EPUB audiobook 路径走这里；SRT-book 路径暂不落库（见 caller 注释）。
  void _wireFollowAudio(
    AudiobookPlayerController controller, {
    required String bookUid,
    required AudiobookRepository repo,
  }) {
    controller.onFollowAudioPersist = (bool value) async {
      await repo.updateFollowAudio(bookUid: bookUid, value: value);
    };
    controller.onCrossChapter = _handleCueCrossChapter;
  }

  /// cue 跨章时由控制器触发。
  ///
  /// Follow=ON：立刻请求 ttu 跳章；记 `_inFlightNavSection` 避免 ttu 回来
  /// 的 sectionChanged 又被当成用户意图。失败降级为 pill。
  /// Follow=OFF：显示 pill "→ 第 N 章"，点了手动跳。
  Future<void> _handleCueCrossChapter(int newSection) async {
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null || !_controllerInitialised) return;

    if (controller.followAudio.value) {
      _inFlightNavSection = newSection;
      try {
        await AudiobookBridge.requestSectionNav(
          _controller,
          sectionIndex: newSection,
        );
      } catch (e) {
        debugPrint('[hibiki-audiobook] requestSectionNav failed: $e');
        // 降级到 pill，保留 Follow 状态让用户重试下一次跨章
        if (mounted) {
          setState(() => _pendingNavSection = newSection);
        }
      }
    } else {
      if (mounted) {
        setState(() => _pendingNavSection = newSection);
      }
    }
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
      if (mounted) setState(() => _pendingNavSection = null);
    } catch (e) {
      debugPrint('[hibiki-audiobook] pill tap requestSectionNav failed: $e');
      Fluttertoast.showToast(msg: 'Follow audio: 跳章失败');
    }
  }

  /// 处理 ttu fork 外发的 sectionChanged console 事件。
  ///
  /// auto=true 来自 `__sasayakiRequestNav`，要么是我们自己刚请求的跳章
  /// （_inFlightNavSection 相等），要么是未来其他系统触发——两种都不是
  /// 用户意图，忽略。
  /// auto=false 来自 ToC 点击 / 滑动翻页等用户操作：如果 Follow=ON，
  /// 把它自动翻到 OFF（并 toast 提示），让用户的意图覆盖系统行为。
  void _handleTtuSectionChanged(Map<String, dynamic> json) {
    final int? idx = (json['sectionIndex'] as num?)?.toInt();
    final bool auto = json['auto'] == true;
    if (idx == null) return;
    // 我们自己刚发起的跳章回报，清掉 in-flight 标记，不算用户意图。
    if (_inFlightNavSection == idx) {
      _inFlightNavSection = null;
      return;
    }
    if (auto) {
      // 系统触发但不是我们发的（未来 ttu 内部可能有别的程序化路径），
      // 保守跳过，不关 Follow。
      return;
    }
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;
    if (controller.followAudio.value) {
      controller.setFollowAudio(false);
      if (mounted) {
        Fluttertoast.showToast(msg: 'Follow audio 已暂停（用户手动翻页）');
      }
    }
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
              AudiobookPlayBar(controller: ctrl),
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
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 12, right: 12),
      child: Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: colors.primary,
          borderRadius: BorderRadius.circular(20),
          elevation: 2,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: _followPillTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 6,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.arrow_forward,
                    size: 16,
                    color: colors.onPrimary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '第 ${target + 1} 章',
                    style: TextStyle(
                      color: colors.onPrimary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [AudiobookPlayBar] 的视觉高度（不含底部 SafeArea inset，需调用方叠加）。
const double _kAudiobookBarHeight = 56;

enum _SrtAudioSource { folder, files }

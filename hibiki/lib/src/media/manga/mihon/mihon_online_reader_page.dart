import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:hibiki/src/media/manga/mihon/manga_page_provider.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';
import 'package:hibiki/utils.dart';

class MihonChapterReaderPage extends StatefulWidget {
  const MihonChapterReaderPage({
    required this.title,
    required this.runtime,
    required this.context,
    required this.chapter,
    required this.cacheRoot,
    super.key,
  });

  final String title;
  final MihonRuntime runtime;
  final MihonSourceContext context;
  final MihonChapter chapter;
  final Directory cacheRoot;

  @override
  State<MihonChapterReaderPage> createState() => _MihonChapterReaderPageState();
}

class _MihonChapterReaderPageState extends State<MihonChapterReaderPage> {
  List<MihonPage>? _pages;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<MihonPage> pages = await widget.runtime.getPages(
        widget.context.extension,
        widget.context.source,
        widget.chapter,
        preferences: widget.context.preferences,
      );
      if (mounted) setState(() => _pages = pages);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<MihonPage>? pages = _pages;
    if (pages != null) {
      return MihonOnlineReaderPage(
        title: widget.title,
        provider: MihonMangaPageProvider(
          runtime: widget.runtime,
          context: widget.context,
          pages: pages,
          cacheRoot: widget.cacheRoot,
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _error == null
          ? Center(child: adaptiveIndicator(context: context))
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('$_error', textAlign: TextAlign.center),
              ),
            ),
    );
  }
}

class MihonOnlineReaderPage extends StatefulWidget {
  const MihonOnlineReaderPage({
    required this.title,
    required this.provider,
    super.key,
  });

  final String title;
  final MangaPageProvider provider;

  @override
  State<MihonOnlineReaderPage> createState() => _MihonOnlineReaderPageState();
}

class _MihonOnlineReaderPageState extends State<MihonOnlineReaderPage> {
  static const String _host = 'manga.local';

  MangaReaderSession? _session;
  Object? _error;
  bool _chromeVisible = true;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final MangaReaderSession session = await widget.provider.open();
      if (!mounted) {
        await session.close();
        return;
      }
      setState(() => _session = session);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    final MangaReaderSession? session = _session;
    _session = null;
    if (session != null) unawaited(session.close());
    super.dispose();
  }

  Future<WebResourceResponse?> _intercept(WebUri uri) async {
    if (uri.host != _host) return null;
    final RegExpMatch? match =
        RegExp(r'^/online/page/(\d+)$').firstMatch(uri.path);
    if (match == null) {
      return WebResourceResponse(
        contentType: 'text/plain',
        statusCode: 404,
        reasonPhrase: 'Not Found',
        data: Uint8List(0),
      );
    }
    try {
      final MangaPageBytes page =
          await _session!.page(int.parse(match.group(1)!));
      return WebResourceResponse(
        contentType: page.contentType,
        statusCode: 200,
        reasonPhrase: 'OK',
        headers: <String, String>{
          'Cache-Control': 'private, max-age=3600',
          'Access-Control-Allow-Origin': '*',
        },
        data: page.bytes,
      );
    } on Object {
      return WebResourceResponse(
        contentType: 'text/plain',
        statusCode: 502,
        reasonPhrase: 'Bad Gateway',
        data: Uint8List(0),
      );
    }
  }

  String _document(int pageCount) {
    final String title = const HtmlEscape().convert(widget.title);
    final String pages = List<String>.generate(
      pageCount,
      (int index) =>
          '<img loading="lazy" src="https://$_host/online/page/$index" '
          'alt="${index + 1}">',
    ).join();
    return '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=4">
  <title>$title</title>
  <style>
    html,body{margin:0;padding:0;background:#111;color:#ddd}
    main{max-width:1200px;margin:0 auto;min-height:100vh}
    img{display:block;width:100%;height:auto;margin:0 auto}
  </style>
</head>
<body><main>$pages</main>
<script>
  document.addEventListener('click', function () {
    window.flutter_inappwebview.callHandler('toggleChrome');
  });
</script>
</body>
</html>
''';
  }

  @override
  Widget build(BuildContext context) {
    final MangaReaderSession? session = _session;
    return Scaffold(
      backgroundColor: const Color(0xff111111),
      appBar: _chromeVisible
          ? AppBar(
              title: Text(widget.title),
              backgroundColor: const Color(0xee111111),
              foregroundColor: Colors.white,
            )
          : null,
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '$_error',
                  style: const TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : session == null
              ? Center(child: adaptiveIndicator(context: context))
              : InAppWebView(
                  initialData: InAppWebViewInitialData(
                    data: _document(session.pageCount),
                    baseUrl: WebUri('https://$_host/online/'),
                    mimeType: 'text/html',
                    encoding: 'utf-8',
                  ),
                  initialSettings: InAppWebViewSettings(
                    useShouldInterceptRequest: true,
                    databaseEnabled: false,
                    domStorageEnabled: false,
                    verticalScrollBarEnabled: false,
                    transparentBackground: true,
                  ),
                  onWebViewCreated: (InAppWebViewController controller) {
                    controller.addJavaScriptHandler(
                      handlerName: 'toggleChrome',
                      callback: (List<dynamic> _) {
                        if (mounted) {
                          setState(() => _chromeVisible = !_chromeVisible);
                        }
                      },
                    );
                  },
                  shouldInterceptRequest: (
                    InAppWebViewController controller,
                    WebResourceRequest request,
                  ) =>
                      _intercept(request.url),
                  onReceivedError: (
                    InAppWebViewController controller,
                    WebResourceRequest request,
                    WebResourceError error,
                  ) async {
                    // Windows WebView2 reports the unresolved virtual host as
                    // a main-frame error even when subresources are supplied
                    // by shouldInterceptRequest. The initial document is
                    // already loaded from data, so no navigation fallback is
                    // needed here.
                  },
                ),
    );
  }
}

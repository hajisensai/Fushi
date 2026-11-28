// 版本更新视频的实机场景（场景名带 `uv-` 前缀，经 SITE_PREVIEW_ONLY 选）。
//
// 与官网预览共用同一套录屏 / 假指针 / 时间线装置；成片由
// tool/update_video/compose.py 按 spec 拼成 B 站横屏视频。
// 指针只是画面上的示意（不动真鼠标）：按钮走焦点 + 激活，网格改尺寸把指针位移逐帧喂给改尺寸柄的拖动回调，
// 与键盘 / 手柄用户的真实路径一致。
//
// 素材夹具（SITE_PREVIEW_UV，可空；空则用官网 demo 素材）：
//   uv.json   {"video": {file, subtitles, title, sentence, charIndex, length, cueStartMs},
//              "manga": {title}, "dicts": ["dict/a.zip", ...]}
//   manga/ocr.json + 页图（同 demo：pages[{image,width,height,blocks[{box,vertical,lines}]}]）
//   video/<片段> + .srt（同名 sidecar）
//   dict/*.zip（Yomitan 词典；uv-video / uv-paste 查词用）
part of 'site_preview_capture_itest.dart';

Map<String, Object?> _uvJson() =>
    jsonDecode(File(p.join(_kUv, 'uv.json')).readAsStringSync())
        as Map<String, Object?>;

String _uvPath(String rel) => p.normalize(p.join(_kUv, rel));

/// 更新视频的查词词典：有素材夹具就导它的（真词典），否则退回官网 demo 词库。
Future<void> _uvImportDictionaries(AppModel appModel) async {
  if (_kUv.isEmpty) {
    await _importDemoDictionaries(appModel);
    return;
  }
  for (final Object? rel in _uvJson()['dicts']! as List<Object?>) {
    final ValueNotifier<String> progress = ValueNotifier<String>('');
    try {
      await appModel.importDictionary(
        file: File(_uvPath('$rel')),
        progressNotifier: progress,
        onImportSuccess: () {},
      );
    } finally {
      progress.dispose();
    }
  }
  debugPrint('[site-preview] uv dictionaries=${appModel.dictionaries.length}');
}

/// 录制客户区：比官网的 1280×720 大一档，放大到 1080p 时字更清楚。
const Size _kUvSceneSize = Size(1440, 810);

/// [target] 内最深的可聚焦节点拿焦点（按钮内部 InkWell 的 Focus 才是激活目标）。
Future<bool> _uvFocusOn(WidgetTester tester, Finder target) async {
  final List<Element> inside = find
      .descendant(of: target, matching: find.byWidgetPredicate((_) => true))
      .evaluate()
      .toList();
  if (inside.isEmpty) return false;
  final FocusNode? node = Focus.maybeOf(inside.last);
  if (node == null) return false;
  node.requestFocus();
  await tester.pump(const Duration(milliseconds: 120));
  return FocusManager.instance.primaryFocus == node;
}

/// 假指针移到 [target] 中心并「点下」：实际走焦点 + 激活（ActivateIntent，退回 Enter）。
Future<void> _uvPress(
  WidgetTester tester,
  SitePreviewCursor cursor,
  FocusDriver driver,
  Finder target, {
  Duration move = const Duration(milliseconds: 700),
}) async {
  expect(target, findsWidgets, reason: '要点的控件应在树上：$target');
  await cursor.moveTo(tester, tester.getCenter(target.first), duration: move);
  await cursor.click(
    tester,
    onDown: () async {
      expect(
        await _uvFocusOn(tester, target.first),
        isTrue,
        reason: '$target 应能拿到焦点',
      );
      if (!await driver.activateIntent()) await driver.activate();
    },
  );
}

bool _uvLibrarySeeded = false;

/// 首页 / 外观段要有内容：播种与官网全貌同一套公有领域书库（只做一次）。
Future<void> _uvSeedLibrary(_Ctx c) async {
  if (_uvLibrarySeeded) return;
  _uvLibrarySeeded = true;
  expect(_kLibrary, isNotEmpty, reason: '首页 / 外观段需要 SITE_PREVIEW_LIBRARY');
  await seedSitePreviewLibrary(c.appModel, Directory(_kLibrary));
  final ProviderContainer container = ProviderScope.containerOf(
    c.tester.element(find.byType(MaterialApp).first),
  );
  for (final HomeTab tab in <HomeTab>[
    HomeTab.books,
    HomeTab.video,
    HomeTab.manga,
    HomeTab.home,
  ]) {
    HomePage.debugSelectTab!(tab);
    await _hold(c.tester, const Duration(milliseconds: 800));
  }
  container.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
  HomeVideoPage.debugRefreshVideos?.call();
  await _hold(c.tester, const Duration(milliseconds: 1500));
}

/// 首页：进编辑 → 拖右下角改尺寸（Shift+方向键逐格）→ 完成。
Future<void> _sceneUvHome(_Ctx c) async {
  final WidgetTester tester = c.tester;
  final FocusDriver driver = FocusDriver(tester);
  await _uvSeedLibrary(c);
  HomePage.debugSelectTab!(HomeTab.home);
  final PhysicalRect rect = await _resizeClient(tester, _kUvSceneSize);
  await _hold(tester, const Duration(milliseconds: 2500));
  final (
    SitePreviewRecording rec,
    SitePreviewTimeline tl,
    SitePreviewCursor cursor,
  ) = await c.begin(
    'uv-home',
    rect,
    const Offset(1100, 640),
  );
  await _hold(tester, const Duration(milliseconds: 1500));

  final Finder edit = find.byKey(
    const ValueKey<String>('home-toolbar-edit-home'),
  );
  if (edit.evaluate().isNotEmpty) {
    await _uvPress(tester, cursor, driver, edit);
  } else {
    // 窄宽度下「编辑首页」收进了「⋯」：走设置页同一个请求口。
    homeWidgetEditRequested.value = true;
  }
  await _hold(tester, const Duration(milliseconds: 1400));

  // 第一个可改尺寸的组件：右下角改尺寸柄。
  final Finder handles = find.byWidgetPredicate(
    (Widget w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('home-widget-resize/'),
  );
  expect(handles, findsWidgets, reason: '编辑态应有改尺寸柄');
  final String slot = (tester.widget(handles.first).key! as ValueKey<String>)
      .value
      .substring('home-widget-resize/'.length);
  final Finder tile = find.byKey(ValueKey<String>('home-widget-slot/$slot'));
  final Offset start = tester.getCenter(handles.first);
  await cursor.moveTo(
    tester,
    start,
    duration: const Duration(milliseconds: 900),
  );
  await _hold(tester, const Duration(milliseconds: 250));
  // 连续拖右下角改尺寸柄：逐帧把指针位移喂给柄自己的拖动回调（_ResizeHandle 的
  // onStart / onUpdate / onEnd，与真指针拖动同一条路径；不发坐标点击）。网格的尺寸
  // 预览随拖动实时跟手，抬起才落定。
  final Rect box = tester.getRect(tile);
  Future<void> dragTo(Offset to, Duration duration) async {
    final dynamic handle = tester.widget(handles.first);
    (handle.onStart as VoidCallback)();
    await tester.pump(const Duration(milliseconds: 16));
    await cursor.drag(
      tester,
      to,
      duration: duration,
      onDelta: (Offset d) {
        (tester.widget(handles.first) as dynamic).onUpdate(d);
      },
    );
    ((tester.widget(handles.first) as dynamic).onEnd as ValueChanged<bool>)(
      true,
    );
    await _hold(tester, const Duration(milliseconds: 500));
  }

  await dragTo(
    start + Offset(box.width * 0.95, box.height * 0.6),
    const Duration(milliseconds: 1600),
  );
  await _hold(tester, const Duration(milliseconds: 1100));
  await cursor.moveTo(
    tester,
    tester.getCenter(handles.first),
    duration: const Duration(milliseconds: 500),
  );
  await dragTo(start, const Duration(milliseconds: 1300));
  await _hold(tester, const Duration(milliseconds: 900));

  final Finder done = find.byKey(
    const ValueKey<String>('home-widget-edit-done'),
  );
  if (done.evaluate().isNotEmpty) {
    await _uvPress(tester, cursor, driver, done);
  }
  await _hold(tester, const Duration(milliseconds: 2000));
  await c.end(
    'uv-home',
    rec,
    tl,
    cursor,
    posterMs: 3000,
    outSize: _kUvSceneSize,
  );
}

/// 两套设计：M3E 色块首页 / 书架 → 在书架上切 Apple（iOS 27 玻璃）→ 书架 / 首页。
Future<void> _sceneUvApple(_Ctx c) async {
  final WidgetTester tester = c.tester;
  await _uvSeedLibrary(c);
  HomePage.debugSelectTab!(HomeTab.home);
  final PhysicalRect rect = await _resizeClient(tester, _kUvSceneSize);
  await _hold(tester, const Duration(milliseconds: 3000));
  final ThemeNotifier theme = c.appModel.themeNotifier;
  final (
    SitePreviewRecording rec,
    SitePreviewTimeline tl,
    SitePreviewCursor cursor,
  ) = await c.begin(
    'uv-apple',
    rect,
    const Offset(1500, 900),
  );
  cursor.hide();
  try {
    await _hold(tester, const Duration(milliseconds: 2500));
    HomePage.debugSelectTab!(HomeTab.books);
    await _hold(tester, const Duration(milliseconds: 2800));
    // 切换时整棵树按新设计系统重建：等到画面稳定的这段剪掉。
    final int switchFrom = _sinceStart(rec);
    await theme.setGlassMaterial(FushiGlassMaterial.premium);
    await theme.setDesignSystem('glass');
    await _hold(tester, const Duration(milliseconds: 2500));
    tl.cut(switchFrom + 200, _sinceStart(rec) - 300);
    await _hold(tester, const Duration(milliseconds: 2500));
    HomePage.debugSelectTab!(HomeTab.home);
    await _hold(tester, const Duration(milliseconds: 3000));
    await c.end(
      'uv-apple',
      rec,
      tl,
      cursor,
      posterMs: 2000,
      outSize: _kUvSceneSize,
    );
  } finally {
    await theme.setDesignSystem('material');
    HomePage.debugSelectTab!(HomeTab.home);
    await _hold(tester, const Duration(milliseconds: 1500));
  }
}

/// 漫画：台词栏 + Z 逐格读（← 下一个气泡）+ Esc 退出。
Future<void> _sceneUvManga(_Ctx c) async {
  final WidgetTester tester = c.tester;
  final String bookKey = _kUv.isEmpty ? _kDemoMangaKey : 'uv-manga';
  if (await c.appModel.database.getEpubBook(bookKey) == null) {
    if (_kUv.isEmpty) {
      await _seedDemoManga(c);
    } else {
      final Map<String, Object?> manga =
          _uvJson()['manga']! as Map<String, Object?>;
      await _seedDemoManga(
        c,
        root: _kUv,
        bookKey: bookKey,
        title: manga['title']! as String,
      );
    }
  }
  final MangaReaderPreferences prefsBefore = c.appModel.mangaReaderPreferences;
  await c.appModel.setMangaReaderPreferences(
    prefsBefore.copyWithJson(<String, Object?>{'bubbleTextStrip': true}),
  );
  try {
    final BuildContext navContext = c.nav.context;
    unawaited(
      c.nav.push(
        adaptivePageRoute<void>(
          context: navContext,
          builder: (BuildContext context) => FushiAppUiScaleNeutralizer(
            child: MangaFushiPage(item: null, bookKey: bookKey),
          ),
        ),
      ),
    );
    await _waitFor(
      tester,
      () => find
          .byKey(const ValueKey<String>('manga_content_ready'))
          .evaluate()
          .isNotEmpty,
      what: '漫画阅读页就绪',
    );
    final PhysicalRect rect = await _resizeClient(tester, _kUvSceneSize);
    await _hold(tester, const Duration(milliseconds: 2500));
    final dynamic reader = tester.state(find.byType(MangaFushiPage));
    final Finder webView = find.descendant(
      of: find.byType(MangaFushiPage),
      matching: find.byType(InAppWebView),
    );
    Future<Map<String, Object?>?> stripItem(int i) async {
      final Object? raw = await reader.debugEvaluateJavascript(
        '''JSON.stringify((() => {
          const it = document.querySelectorAll('.manga-text-strip .manga-ts-item');
          if (it.length <= $i) return null;
          const r = it[$i].getBoundingClientRect();
          return {x: r.left + Math.min(40, r.width / 2), y: r.top + r.height / 2, n: it.length};
        })())''',
      );
      if (raw == null || '$raw' == 'null') return null;
      return jsonDecode('$raw') as Map<String, Object?>;
    }

    Map<String, Object?>? first;
    for (int i = 0; i < 40 && first == null; i++) {
      first = await stripItem(0);
      if (first == null) await _hold(tester, const Duration(milliseconds: 250));
    }
    expect(first, isNotNull, reason: '台词栏应列出气泡');
    Future<void> hover(Map<String, Object?> pt) =>
        reader.debugCallDevToolsProtocolMethod(
          'Input.dispatchMouseEvent',
          <String, dynamic>{
            'type': 'mouseMoved',
            'x': pt['x'],
            'y': pt['y'],
            'button': 'none',
            'buttons': 0,
            'pointerType': 'mouse',
          },
        );

    final (
      SitePreviewRecording rec,
      SitePreviewTimeline tl,
      SitePreviewCursor cursor,
    ) = await c.begin(
      'uv-manga',
      rect,
      const Offset(700, 700),
    );
    await _hold(tester, const Duration(milliseconds: 1200));
    // 台词栏逐条悬停：页上描边对应气泡。
    for (int i = 0; i < 3; i++) {
      final Map<String, Object?>? pt = await stripItem(i);
      if (pt == null) break;
      await cursor.moveTo(
        tester,
        _webViewToGlobal(tester, webView.first, pt),
        duration: const Duration(milliseconds: 600),
      );
      await hover(pt);
      await _hold(tester, const Duration(milliseconds: 1100));
    }
    await hover(<String, Object?>{'x': 5, 'y': 5});
    cursor.hide();
    // Z 逐格读，← 依次跳气泡（RTL），Esc 退出。
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await _hold(tester, const Duration(milliseconds: 2200));
    for (int i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await _hold(tester, const Duration(milliseconds: 1800));
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _hold(tester, const Duration(milliseconds: 1800));
    await c.end(
      'uv-manga',
      rec,
      tl,
      cursor,
      posterMs: 6000,
      outSize: _kUvSceneSize,
    );
    c.nav.pop();
    await _hold(tester, const Duration(seconds: 1));
  } finally {
    await c.appModel.setMangaReaderPreferences(prefsBefore);
  }
}

/// 粘贴即读：对话框自动填入剪贴板文本 → 「阅读」→ 阅读器打开 → 点词查词。
Future<void> _sceneUvPaste(_Ctx c) async {
  final WidgetTester tester = c.tester;
  final FocusDriver driver = FocusDriver(tester);
  final Map<String, Object?> book =
      _demoJson()['book']! as Map<String, Object?>;
  final String text = <String>[
    for (final Object? e
        in jsonDecode(
              File(_demoPath(book['cues']! as String)).readAsStringSync(),
            )
            as List<Object?>)
      (e! as Map<String, Object?>)['text']! as String,
  ].join();
  HomePage.debugSelectTab!(HomeTab.books);
  final PhysicalRect rect = await _resizeClient(tester, _kUvSceneSize);
  await _hold(tester, const Duration(milliseconds: 2000));
  final (
    SitePreviewRecording rec,
    SitePreviewTimeline tl,
    SitePreviewCursor cursor,
  ) = await c.begin(
    'uv-paste',
    rect,
    const Offset(1100, 600),
  );
  await _hold(tester, const Duration(milliseconds: 1000));
  final Future<String?> dialog = showAppDialog<String>(
    context: c.nav.context,
    builder: (_) => PastedTextBookDialog(
      db: c.appModel.database,
      readClipboard: () async => '安達としまむら\n$text',
    ),
  );
  await _hold(tester, const Duration(milliseconds: 2200));
  await _uvPress(tester, cursor, driver, find.text(t.book_paste_text_read));
  final String? bookKey = await dialog.timeout(const Duration(seconds: 20));
  expect(bookKey, isNotNull, reason: '粘贴文本应落成一本书');
  cursor.hide();
  await openBookViaProductionPath(tester, bookKey!);
  await _waitFor(
    tester,
    () => find
        .byKey(const ValueKey<String>('fushi_content_ready'))
        .evaluate()
        .isNotEmpty,
    timeout: const Duration(seconds: 60),
    what: '阅读器正文就绪',
  );
  await _hold(tester, const Duration(milliseconds: 1800));
  final Finder webView = find.byKey(const ValueKey<String>('fushi_webview'));
  const String target = 'わたしたち';
  final Object? raw = await ReaderFushiPage.debugEvaluateJavascript!(
    _textPointJs(target, 0),
  );
  if (raw != null && '$raw' != 'null') {
    final Map<String, Object?> pt = jsonDecode('$raw') as Map<String, Object?>;
    cursor.show(tester.getCenter(webView) + const Offset(200, 160));
    await cursor.moveTo(
      tester,
      _webViewToGlobal(tester, webView, pt),
      duration: const Duration(milliseconds: 800),
    );
    final Stopwatch clickAt = Stopwatch();
    await cursor.click(
      tester,
      onDown: () async {
        clickAt.start();
        await ReaderFushiPage.debugEvaluateJavascript!(
          _dispatchClickJs(
            (pt['x']! as num).toDouble(),
            (pt['y']! as num).toDouble(),
          ),
        );
      },
    );
    await _timedPopup(tester, 'uv-paste', clickAt, tl);
    await _hold(tester, const Duration(milliseconds: 2800));
  }
  await c.end(
    'uv-paste',
    rec,
    tl,
    cursor,
    posterMs: 4000,
    outSize: _kUvSceneSize,
  );
  c.nav.popUntil((Route<dynamic> r) => r.isFirst);
  await _hold(tester, const Duration(seconds: 1));
}

/// 音乐：在线音源（内置 YouTube）搜到的真歌，封面与逐行歌词由 app 自己拉（LRCLIB），
/// 连着放几段、每段换一种全屏歌词动画。素材夹具 `uv.json` 的 `music`：
/// `{query, videoId, audio, startMs, stepMs, modes}`；`audio` 是同一首的本地音频，
/// 只给后期混音（录屏本身无声），与 app 在放的位置逐段对齐。
Future<void> _sceneUvLyrics(_Ctx c) async {
  expect(_kUv, isNotEmpty, reason: 'uv-lyrics 需要 SITE_PREVIEW_UV');
  final WidgetTester tester = c.tester;
  final FocusDriver driver = FocusDriver(tester);
  final Map<String, Object?> m = _uvJson()['music']! as Map<String, Object?>;
  final String audio = _uvPath(m['audio']! as String);
  final int startMs = m['startMs']! as int;
  final int stepMs = m['stepMs']! as int;
  final List<String> modes = <String>[
    for (final Object? e in m['modes']! as List<Object?>) e! as String,
  ];

  // 与「来源」页搜索同一条路径：内置 YouTube 音源搜索 → 服务器曲目 → 播放项。
  final YoutubeMusicClient yt = YoutubeMusicClient(displayName: 'YouTube');
  final MusicServerSearchResult hits = await yt.search(
    m['query']! as String,
    limit: 10,
  );
  final MusicServerTrack track = hits.tracks.firstWhere(
    (MusicServerTrack t) => t.id == m['videoId'],
    orElse: () => fail('YouTube 搜索结果里没有 ${m['videoId']}：${hits.tracks}'),
  );
  final MusicPlayItem item = musicServerPlayItem(yt, track);
  final MusicPlayerEngine engine = c.appModel.musicSession.engine;

  final String userMode = c.appModel.prefsRepo.musicVisualizerMode;
  final bool userRandom = c.appModel.prefsRepo.musicVisualizerRandom;
  final PhysicalRect rect = await _resizeClient(tester, _kUvSceneSize);
  try {
    await c.appModel.prefsRepo.setMusicVisualizerRandom(false);
    await engine.playQueue(<MusicPlayItem>[item]);
    await engine.play();
    await _waitFor(
      tester,
      () => engine.position > const Duration(seconds: 1),
      timeout: const Duration(seconds: 60),
      what: '在线曲目起播',
    );
    await engine.seek(Duration(milliseconds: startMs - 3000));
    unawaited(
      c.nav.push<void>(
        adaptivePageRoute<void>(
          context: c.nav.context,
          builder: (_) => const MusicLyricsPage(),
        ),
      ),
    );
    // 封面（YouTube 缩略图）与歌词（LRCLIB）都是起播后在线拉的：等歌词区换成逐行歌词视图
    // （KaraokeLyricsView 自绘，不是 Text，按文字找不到）。
    await _waitFor(
      tester,
      () => find
          .byWidgetPredicate(
            (Widget w) => w.runtimeType.toString() == 'KaraokeLyricsView',
          )
          .evaluate()
          .isNotEmpty,
      timeout: const Duration(seconds: 45),
      what: '在线歌词',
    );
    await _hold(tester, const Duration(milliseconds: 2500));
    final (
      SitePreviewRecording rec,
      SitePreviewTimeline tl,
      SitePreviewCursor cursor,
    ) = await c.begin(
      'uv-lyrics',
      rect,
      const Offset(1300, 700),
    );
    cursor.hide();

    // 从 [at] 起放 [lenMs]，后期按 app 此刻的真实播放位置对上本地音频。
    Future<void> playFrom(int at, int lenMs) async {
      await engine.seek(Duration(milliseconds: at));
      if (!engine.isPlaying) await engine.play();
      await _waitFor(
        tester,
        () =>
            engine.isPlaying &&
            engine.position > Duration(milliseconds: at + 100),
        timeout: const Duration(seconds: 20),
        what: '续播到 $at',
      );
      tl.playAudio(
        audio,
        fromMs: engine.position.inMilliseconds,
        durationMs: lenMs + 400,
      );
    }

    // 开场：歌词页本身（封面 + 滚动歌词）。
    await engine.pause();
    await playFrom(startMs - 3000, 3000);
    await _hold(tester, const Duration(milliseconds: 3000));
    int at = startMs;
    for (final String mode in modes) {
      // 停 → 开样式面板 → 选样式 → 跳到下一段续播：整段剪掉，成片里画面与歌声都接着上一段。
      final int cutFrom = _sinceStart(rec);
      await engine.pause();
      await c.appModel.prefsRepo.setMusicVisualizerMode(mode);
      final Finder button = find.byKey(
        const ValueKey<String>('music_lyrics_visualizer'),
      );
      if (button.evaluate().isEmpty) {
        expect(
          await _uvFocusOn(tester, find.byKey(kFushiToolbarOverflowKey)),
          isTrue,
          reason: '「⋯」应能拿到焦点',
        );
        await driver.activate();
        await _hold(tester, const Duration(milliseconds: 500));
        await _uvFocusOn(
          tester,
          find.byKey(
            const ValueKey<String>('music_lyrics_visualizer_menu_item'),
          ),
        );
      } else {
        await _uvFocusOn(tester, button);
      }
      if (!await driver.activateIntent()) await driver.activate();
      await _hold(tester, const Duration(milliseconds: 600));
      final Finder tile = find.byKey(
        ValueKey<String>('music_visualizer_style_$mode'),
      );
      final bool focused =
          (tile.evaluate().isNotEmpty && await _uvFocusOn(tester, tile)) ||
          await driver.focusWidget(tile, maxSteps: 120);
      expect(focused, isTrue, reason: '样式 $mode 应能拿到焦点');
      if (!await driver.activateIntent()) await driver.activate();
      await _hold(tester, const Duration(milliseconds: 500));
      await playFrom(at, stepMs);
      tl.cut(cutFrom, _sinceStart(rec));
      await _hold(tester, Duration(milliseconds: stepMs));
      at = engine.position.inMilliseconds;
      // 退出全屏走歌词页的 PopScope（与系统返回同一条路径），剪掉。
      final int exitFrom = _sinceStart(rec);
      await engine.pause();
      await c.nav.maybePop();
      await _hold(tester, const Duration(milliseconds: 600));
      expect(
        find.byKey(const ValueKey<String>('music_visualizer')).evaluate(),
        isEmpty,
        reason: '$mode 之后应退出全屏动画',
      );
      tl.cut(exitFrom, _sinceStart(rec));
    }
    await c.end(
      'uv-lyrics',
      rec,
      tl,
      cursor,
      posterMs: 4000,
      outSize: _kUvSceneSize,
    );
  } finally {
    await engine.pause();
    await c.appModel.prefsRepo.setMusicVisualizerMode(userMode);
    await c.appModel.prefsRepo.setMusicVisualizerRandom(userRandom);
    c.nav.popUntil((Route<dynamic> r) => r.isFirst);
    await _hold(tester, const Duration(seconds: 1));
  }
}

/// 视频：素材夹具里的片段 + 日语字幕，点字幕查词 → + 制卡。
Future<void> _sceneUvVideo(_Ctx c) async {
  expect(_kUv, isNotEmpty, reason: 'uv-video 需要 SITE_PREVIEW_UV');
  final Map<String, Object?> v = _uvJson()['video']! as Map<String, Object?>;
  await _recordVideoLookup(
    c,
    scene: 'uv-video',
    videoSrc: _uvPath(v['file']! as String),
    srtSrc: _uvPath(v['subtitles']! as String),
    sentence: v['sentence']! as String,
    charIndex: v['charIndex']! as int,
    length: v['length']! as int,
    cueStart: v['cueStartMs']! as int,
    title: v['title']! as String,
    size: _kUvSceneSize,
  );
}

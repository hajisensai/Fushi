// 版本更新视频的实机场景（见 site_preview_update_video_scenes.dart 文件头）。
//
// uv-voiced：有声漫画。AI 标注与 TTS 都不真跑（离线、不可控）：场景直接播种
// 「已标注说话人 + 已指派声音 + 每句已出配音」的状态，落盘形态与真生成一致——
// - 演出稿 `<db>/tts_cast/<sha1>.manga-script.json`（[mangaAudioScriptStoreFor]）；
// - 成品清单 + 每句音频 `<db>/manga_audio/<sha1>/`（[mangaRenderManifestFile]）；
// - 成品登记进 `Audiobooks` / `AudioCues`（[registerMangaAudio]，阅读器按它起播）；
// - 声音预设进 TTS 偏好（制作台的指派行按预设名显示）。
// 每句配音用本机 SAPI 日语声线（Haruka）现念，再按角色用 ffmpeg 变调 / 变速区分。
part of 'site_preview_capture_itest.dart';

const String _kUvVoicedKey = 'uv-voiced';

/// 一句台词的播种数据：块下标、AI 标的说话人与把握、成品里的（复核后）说话人。
class _UvVoicedLine {
  const _UvVoicedLine(
    this.blocks,
    this.speaker, {
    this.kind = CastLineKind.spoken,
    this.confidence = 0.92,
    String? finalSpeaker,
  }) : finalSpeaker = finalSpeaker ?? speaker;

  final List<int> blocks;

  /// AI 标的说话人（演出稿）。
  final String speaker;
  final CastLineKind kind;
  final double confidence;

  /// 成品清单里的说话人（复核改过的按改后的）。
  final String finalSpeaker;
}

/// MyGO!!!!! 1 卷 p80（卡拉 OK）的 15 个气泡 → 11 句；三句 AI 把握低，进复核队列。
const List<_UvVoicedLine> _kUvVoicedLines = <_UvVoicedLine>[
  _UvVoicedLine(<int>[0], '愛音', confidence: 0.94),
  _UvVoicedLine(<int>[1], '燈', confidence: 0.48, finalSpeaker: 'そよ'),
  _UvVoicedLine(<int>[2], '愛音', kind: CastLineKind.shout),
  _UvVoicedLine(<int>[3], '立希', kind: CastLineKind.shout),
  _UvVoicedLine(<int>[4], '立希', confidence: 0.95),
  _UvVoicedLine(<int>[5, 6, 7], '愛音', confidence: 0.9),
  _UvVoicedLine(<int>[8], 'そよ', confidence: 0.91),
  _UvVoicedLine(<int>[9], '愛音', confidence: 0.86),
  _UvVoicedLine(<int>[10, 11], '立希', confidence: 0.94),
  _UvVoicedLine(<int>[12, 13], 'そよ', confidence: 0.55),
  _UvVoicedLine(<int>[14], '燈', confidence: 0.41),
];

/// 角色 → (声音预设 id, 预设名, 变调倍数, 语速倍数)。
const Map<String, (String, String, double, double)> _kUvVoicedCast =
    <String, (String, String, double, double)>{
      '燈': ('uv-voice-tomori', 'Edge · Shiori', 1.07, 0.88),
      '愛音': ('uv-voice-anon', 'Edge · Nanami', 1.13, 1.06),
      'そよ': ('uv-voice-soyo', 'Edge · Mayu', 1.02, 0.94),
      '立希': ('uv-voice-taki', 'Edge · Aoi', 0.91, 1.1),
    };

/// 用本机 SAPI（Haruka）念 [texts]，按角色变调后写成 [dir] 下的 `<lineId>.m4a`；
/// 返回每句时长（毫秒）。
Future<List<int>> _uvVoicedSynthesize(
  Directory dir,
  List<String> ids,
  List<String> texts,
  List<String> speakers,
) async {
  final File list = File(p.join(dir.path, 'tts.json'));
  final File script = File(p.join(dir.path, 'tts.ps1'));
  await list.writeAsString(
    jsonEncode(<Map<String, Object?>>[
      for (int i = 0; i < ids.length; i++)
        <String, Object?>{
          'text': texts[i],
          'out': p.join(dir.path, 'raw-${ids[i]}.wav'),
        },
    ]),
  );
  await script.writeAsString(r'''
param([string]$Json)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$items = Get-Content -Raw -Encoding UTF8 $Json | ConvertFrom-Json
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
$s.SelectVoice('Microsoft Haruka Desktop')
foreach ($it in $items) {
  $s.SetOutputToWaveFile($it.out)
  $s.Speak($it.text)
  $s.SetOutputToNull()
}
''');
  final ProcessResult tts = await Process.run('powershell.exe', <String>[
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    script.path,
    '-Json',
    list.path,
  ]);
  expect(tts.exitCode, 0, reason: 'SAPI 念台词失败：${tts.stderr}');
  final List<int> durations = <int>[];
  for (int i = 0; i < ids.length; i++) {
    final (String, String, double, double) cast = _kUvVoicedCast[speakers[i]]!;
    final double pitch = cast.$3;
    final double tempo = cast.$4 / pitch;
    final String out = p.join(dir.path, '${ids[i]}.m4a');
    const String trim =
        'silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.03';
    final ProcessResult ff = await Process.run('ffmpeg', <String>[
      '-y',
      '-v',
      'error',
      '-i',
      p.join(dir.path, 'raw-${ids[i]}.wav'),
      '-af',
      'aresample=44100,asetrate=${(44100 * pitch).round()},aresample=44100,'
          'atempo=${tempo.toStringAsFixed(4)},$trim,areverse,$trim,areverse,'
          'apad=pad_dur=0.08',
      '-ac',
      '1',
      '-c:a',
      'aac',
      '-b:a',
      '128k',
      out,
    ]);
    expect(ff.exitCode, 0, reason: 'ffmpeg 变调失败：${ff.stderr}');
    final ProcessResult probe = await Process.run('ffprobe', <String>[
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'csv=p=0',
      out,
    ]);
    durations.add((double.parse('${probe.stdout}'.trim()) * 1000).round());
  }
  return durations;
}

/// 播种「已标注 + 已指派 + 已生成」的一卷有声漫画。
Future<void> _uvVoicedSeed(_Ctx c) async {
  final AppModel appModel = c.appModel;
  if (await appModel.database.getEpubBook(_kUvVoicedKey) == null) {
    await _seedDemoManga(
      c,
      root: _kUv,
      bookKey: _kUvVoicedKey,
      title: (_uvJson()['manga']! as Map<String, Object?>)['title']! as String,
    );
  }
  final EpubBookRow book = (await appModel.database.getEpubBook(
    _kUvVoicedKey,
  ))!;
  // 页图 url 改成真实导入的形态（`images/<名>`，与 `enumerateMangaPages` 同口径）：
  // 逐句复核按它找原页图；共用的 [_seedDemoManga] 写的是裸文件名。
  final File mangaJson = File(p.join(book.extractDir, book.epubPath));
  final Map<String, Object?> raw =
      jsonDecode(await mangaJson.readAsString()) as Map<String, Object?>;
  for (final Object? page in raw['pages']! as List<Object?>) {
    final Map<String, Object?> m = page! as Map<String, Object?>;
    final String url = m['url']! as String;
    if (!url.startsWith('images/')) m['url'] = 'images/$url';
  }
  await mangaJson.writeAsString(jsonEncode(raw));
  final MokuroPayload payload = parseMangaJson(await mangaJson.readAsString());
  final String signature = mangaPayloadOcrSignature(payload);
  final List<MokuroBlock> blocks = payload.images.first.blocks;
  String textOf(_UvVoicedLine l) =>
      <String>[for (final int b in l.blocks) blocks[b].lines.join()].join();

  // 声音预设：制作台的指派行显示预设名。
  final TtsServices tts = TtsServices.of(appModel.prefsRepo);
  await tts.store.savePresets(<TtsVoicePreset>[
    for (final (String, String, double, double) v in _kUvVoicedCast.values)
      TtsVoicePreset(
        id: v.$1,
        providerId: 'edge',
        name: v.$2,
        params: <String, String>{
          'voice': 'ja-JP-${v.$2.split(' · ').last}Neural',
        },
      ),
  ]);
  await tts.store.setActivePresetId(_kUvVoicedCast['愛音']!.$1);

  // 演出稿：AI 标的说话人 / 类型 / 把握 + 角色表 + 按角色的声音指派。
  final List<MangaScriptLine> lines = <MangaScriptLine>[
    for (final _UvVoicedLine l in _kUvVoicedLines)
      MangaScriptLine(
        page: 0,
        blocks: l.blocks,
        speaker: l.speaker,
        kind: l.kind,
        confidence: l.confidence,
      ),
  ];
  final MangaAudioScript script = MangaAudioScript(
    engineSignature: signature,
    voices: CastVoiceAssignment(
      defaultVoice: _kUvVoicedCast['愛音']!.$1,
      byCharacter: <String, String>{
        for (final MapEntry<String, (String, String, double, double)> e
            in _kUvVoicedCast.entries)
          e.key: e.value.$1,
      },
    ),
    roster: <String, TtsCastCharacter>{
      for (final String name in _kUvVoicedCast.keys)
        name: TtsCastCharacter(name: name, gender: 'female', age: 'teen'),
    },
    lines: lines,
    annotatedPages: <int>{0},
  );
  await mangaAudioScriptStoreFor(appModel).save(_kUvVoicedKey, script);

  // 成品：每句一段配音 + 清单，登记进库。
  final File manifestFile = mangaRenderManifestFile(appModel, _kUvVoicedKey);
  final Directory audioDir = manifestFile.parent..createSync(recursive: true);
  final List<String> ids = <String>[
    for (final MangaScriptLine l in lines) l.lineId,
  ];
  final List<int> durations = await _uvVoicedSynthesize(
    audioDir,
    ids,
    <String>[for (final _UvVoicedLine l in _kUvVoicedLines) textOf(l)],
    <String>[for (final _UvVoicedLine l in _kUvVoicedLines) l.finalSpeaker],
  );
  final MangaRenderManifest manifest = MangaRenderManifest(
    pageCount: payload.images.length,
    engineSignature: signature,
    lines: <MangaRenderedLine>[
      for (int i = 0; i < _kUvVoicedLines.length; i++)
        MangaRenderedLine(
          lineId: ids[i],
          page: 0,
          blocks: _kUvVoicedLines[i].blocks,
          speaker: _kUvVoicedLines[i].finalSpeaker,
          kind: _kUvVoicedLines[i].kind,
          beatMs: 0,
          file: '${ids[i]}.m4a',
          durationMs: durations[i],
          text: textOf(_kUvVoicedLines[i]),
          voice: _kUvVoicedCast[_kUvVoicedLines[i].finalSpeaker]!.$1,
        ),
    ],
  );
  await manifest.save(manifestFile);
  await registerMangaAudio(
    appModel.database,
    bookKey: _kUvVoicedKey,
    manifestFile: manifestFile,
    manifest: manifest,
  );
  debugPrint(
    '[site-preview] uv-voiced seeded lines=${lines.length} '
    'durations=$durations',
  );
}

/// 有声漫画：工作台（演出稿 / 角色与配音）→ 制作台的声音指派 → 逐句复核改说话人
/// → 阅读器里播成品配音（气泡高亮跟读）。
Future<void> _sceneUvVoiced(_Ctx c) async {
  expect(_kUv, isNotEmpty, reason: 'uv-voiced 需要 SITE_PREVIEW_UV');
  final WidgetTester tester = c.tester;
  final FocusDriver driver = FocusDriver(tester);
  final List<TtsVoicePreset> presetsBefore = TtsServices.of(
    c.appModel.prefsRepo,
  ).store.loadPresets();
  final String? activeBefore = TtsServices.of(
    c.appModel.prefsRepo,
  ).store.activePresetId;
  await _uvVoicedSeed(c);

  final BuildContext navContext = c.nav.context;
  unawaited(
    c.nav.push(
      adaptivePageRoute<void>(
        context: navContext,
        builder: (BuildContext context) => MangaAudioWorkbenchPage(
          appModel: c.appModel,
          bookKey: _kUvVoicedKey,
        ),
      ),
    ),
  );
  Finder key(String k) => find.byKey(ValueKey<String>(k));
  await _waitFor(
    tester,
    () => key('manga-audio-workbench-primary').evaluate().isNotEmpty,
    what: '有声漫画工作台就绪',
  );
  final PhysicalRect rect = await _resizeClient(tester, _kUvSceneSize);
  await _hold(tester, const Duration(milliseconds: 2000));

  final (
    SitePreviewRecording rec,
    SitePreviewTimeline tl,
    SitePreviewCursor cursor,
  ) = await c.begin(
    'uv-voiced',
    rect,
    const Offset(900, 500),
  );
  try {
    await _hold(tester, const Duration(milliseconds: 400));
    // 工作台：演出稿（AI 标好的说话人）→ 角色与配音 → 指派声音。
    await _uvPress(
      tester,
      cursor,
      driver,
      key('manga-audio-workbench-step-script'),
    );
    await _hold(tester, const Duration(milliseconds: 1400));
    await _uvPress(
      tester,
      cursor,
      driver,
      key('manga-audio-workbench-step-voices'),
      move: const Duration(milliseconds: 500),
    );
    await _hold(tester, const Duration(milliseconds: 700));
    await _uvPress(
      tester,
      cursor,
      driver,
      key('manga-audio-workbench-primary'),
    );
    await _waitFor(
      tester,
      () => key('manga-audio-voices').evaluate().isNotEmpty,
      what: '制作台声音指派',
    );
    cursor.hide();
    await _hold(tester, const Duration(milliseconds: 500));
    // 制作台：滚到声音指派（每个角色一行，显示指派的声音）。
    unawaited(
      Scrollable.ensureVisible(
        tester.element(key('manga-audio-voices')),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeInOutCubic,
      ),
    );
    await _hold(tester, const Duration(milliseconds: 1800));
    c.nav.pop();
    await _hold(tester, const Duration(milliseconds: 400));

    // 逐句复核：原页高亮这句的气泡；把握低的一句改说话人，自动跳下一句。
    unawaited(
      c.nav.push(
        adaptivePageRoute<void>(
          context: c.nav.context,
          builder: (BuildContext context) => MangaAudioReviewPage(
            appModel: c.appModel,
            bookKey: _kUvVoicedKey,
          ),
        ),
      ),
    );
    await _waitFor(
      tester,
      () => key('manga-audio-review-speaker-そよ').evaluate().isNotEmpty,
      what: '逐句复核就绪',
    );
    await _hold(tester, const Duration(milliseconds: 800));
    cursor.show(const Offset(1000, 640));
    await _uvPress(
      tester,
      cursor,
      driver,
      key('manga-audio-review-speaker-そよ'),
    );
    await _hold(tester, const Duration(milliseconds: 1100));
    await _uvPress(
      tester,
      cursor,
      driver,
      key('manga-audio-review-next'),
      move: const Duration(milliseconds: 600),
    );
    await _hold(tester, const Duration(milliseconds: 800));
    cursor.hide();

    // 阅读器：朗读 → 播成品配音，气泡逐句高亮。
    final int openAt = _sinceStart(rec);
    unawaited(
      c.nav.push(
        adaptivePageRoute<void>(
          context: c.nav.context,
          builder: (BuildContext context) => const FushiAppUiScaleNeutralizer(
            child: MangaFushiPage(item: null, bookKey: _kUvVoicedKey),
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
    // content_ready 之后 WebView 还要一阵才画出页图（实测约 1.5 秒黑屏）：多等一会儿，
    // 从复核页直接硬切到画好的阅读页。
    await _hold(tester, const Duration(milliseconds: 3200));
    tl.cut(openAt + 40, _sinceStart(rec) - 400);
    // 悬浮工具栏默认收着：点页外空白唤出（走 WebView 空白点击的同一个 JS 回调）。
    final dynamic reader = tester.state(find.byType(MangaFushiPage));
    final Finder readAloud = key('manga_reader_read_aloud_button');
    cursor.show(const Offset(330, 560));
    await cursor.moveTo(
      tester,
      const Offset(250, 420),
      duration: const Duration(milliseconds: 500),
    );
    await cursor.click(
      tester,
      onDown: () async {
        await reader.debugEvaluateJavascript(
          "window.flutter_inappwebview.callHandler('onTapEmpty')",
        );
      },
    );
    await _waitFor(
      tester,
      () => readAloud.evaluate().isNotEmpty,
      timeout: const Duration(seconds: 5),
      what: '阅读器工具栏「朗读」',
    );
    await _hold(tester, const Duration(milliseconds: 400));
    await _uvPress(tester, cursor, driver, readAloud);
    final int pressedAt = _sinceStart(rec);
    MangaAudioPlaybackDriver? audio() {
      final Object? companion = c.appModel.audiobookSession.companion;
      return companion is MangaAudioPlaybackDriver ? companion : null;
    }

    await _waitFor(
      tester,
      () => audio()?.currentLine != null,
      what: '有声漫画开始播第一句',
    );
    // 起播（装播放器 + 页首 lead）那段剪掉：点下去紧接着第一句。
    tl.cut(pressedAt + 250, _sinceStart(rec) - 50);
    cursor.hide();
    final File manifestFile = mangaRenderManifestFile(
      c.appModel,
      _kUvVoicedKey,
    );
    String? playing;
    int spoken = 0;
    final Stopwatch guard = Stopwatch()..start();
    while (spoken <= 4 && guard.elapsed < const Duration(seconds: 40)) {
      final MangaRenderedLine? line = audio()?.currentLine;
      if (line != null && line.lineId != playing) {
        playing = line.lineId;
        spoken++;
        if (spoken > 4) break;
        tl.playAudio(p.join(manifestFile.parent.path, line.file));
        debugPrint('[site-preview] uv-voiced line ${line.lineId} ${line.text}');
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    await audio()?.pause();
    tl.stopAudio();
    await _hold(tester, const Duration(milliseconds: 700));
    await c.end(
      'uv-voiced',
      rec,
      tl,
      cursor,
      posterMs: 2500,
      outSize: _kUvSceneSize,
    );
  } finally {
    await c.appModel.audiobookSession.stop();
    c.nav.popUntil((Route<dynamic> r) => r.isFirst);
    final TtsServices tts = TtsServices.of(c.appModel.prefsRepo);
    await tts.store.savePresets(presetsBefore);
    await tts.store.setActivePresetId(activeBefore);
    await _hold(tester, const Duration(seconds: 1));
  }
}

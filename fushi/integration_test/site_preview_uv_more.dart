// 版本更新视频的实机场景（见 site_preview_update_video_scenes.dart 文件头）：
//
//   uv-subtitle  视频全屏字幕工作台：播放页字幕菜单 → 字幕工作台 → 本机 ASR 生成日语字幕
//                → 逐句表格跟随播放 → 回播放页看生成的字幕
//   uv-srs       新一代 Fushi 复习：统计中心「复习」页（几个月的复习历史）→ 切范围 →
//                滚到「模型校准」→ 计算 → 校准图与 UM+ 图
//
// 额外素材（可缺；缺了 uv-subtitle 退回「已有字幕」的演示）：
//   <SITE_PREVIEW_UV 的上级>/uvmore/asr/reazonspeech-k2-v2/  ReazonSpeech k2-v2 fp32 模型文件
//   （encoder / decoder / joiner-epoch-99-avg-1.onnx、tokens.txt、silero_vad.onnx）。
//   隔离测试根里没有语音模型，开录前拷进隔离根的 `asr_models/<包 id>`，并把视频（混音素材）
//   的日语模型选成它——视频默认的 Parakeet 包本机没下。
part of 'site_preview_capture_itest.dart';

// ───────────────────────────── uv-subtitle ─────────────────────────────

/// 本机 ASR 模型包 id（[_uvProvisionAsr] 选给视频日语用）。
const String _kUvAsrPackId = 'reazonspeech-k2-v2';

/// 把素材里的 ReazonSpeech 模型装进隔离根，并选给视频（混音）日语；返回模型是否就位。
Future<bool> _uvProvisionAsr() async {
  final Directory seed = Directory(
    p.join(p.dirname(_kUv), 'uvmore', 'asr', _kUvAsrPackId),
  );
  if (!isAsrSupported || !seed.existsSync()) {
    debugPrint(
      '[site-preview] uv-subtitle asr unavailable '
      'supported=$isAsrSupported seed=${seed.existsSync()}',
    );
    return false;
  }
  await saveAsrModelCatalog(
    AsrModelCatalog.empty.withChoice(
      AsrLanguage.japanese,
      _kUvAsrPackId,
      profile: AsrAudioProfile.mixedAudio,
    ),
  );
  final AsrModelStore store = await openAsrModelStore(
    AsrLanguage.japanese,
    AsrAudioProfile.mixedAudio,
  );
  store.dir.createSync(recursive: true);
  for (final FileSystemEntity e in seed.listSync()) {
    if (e is! File) continue;
    final File target = File(p.join(store.dir.path, p.basename(e.path)));
    if (target.existsSync() && target.lengthSync() == e.lengthSync()) continue;
    await e.copy(target.path);
  }
  debugPrint(
    '[site-preview] uv-subtitle asr pack=${store.pack.id} dir=${store.dir.path}',
  );
  return true;
}

/// 字幕工作台：字幕菜单进工作台 → 生成日语字幕（本机 ASR）→ 表格跟随播放 → 回播放页。
Future<void> _sceneUvSubtitle(_Ctx c) async {
  expect(_kUv, isNotEmpty, reason: 'uv-subtitle 需要 SITE_PREVIEW_UV');
  final WidgetTester tester = c.tester;
  final FocusDriver driver = FocusDriver(tester);
  final Map<String, Object?> v = _uvJson()['video']! as Map<String, Object?>;
  final bool asr = await _uvProvisionAsr();
  // 分段方式定成「滑窗」：本机没有 MOSS 时「自动」也落到滑窗，面板上就不再挂一条
  // 「MOSS 不可用 / 下载 MOSS」的提示。
  await c.appModel.prefsRepo.setVideoSubtitleSegmenter(
    VideoSubtitleSegmenterMode.window,
  );

  // 视频旁不放字幕（有 ASR 时）：工作台从「还没有字幕」开始，生成的 `<名>.ja.srt` 写在旁边。
  final Directory dir = _scratch('uv-subtitle');
  for (final FileSystemEntity e in dir.listSync()) {
    e.deleteSync(recursive: true);
  }
  final File video = File(
    _uvPath(v['file']! as String),
  ).copySync(p.join(dir.path, 'kusuriya.mp4'));
  if (!asr) {
    File(
      _uvPath(v['subtitles']! as String),
    ).copySync(p.join(dir.path, 'kusuriya.srt'));
  }
  final VideoBookRepository repo = VideoBookRepository(c.appModel.database);
  final String uid = singleVideoBookUid(video.path);
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(uid),
      title: Value(v['title']! as String),
      videoPath: Value(video.absolute.path),
    ),
  );
  unawaited(
    c.nav.push(
      MaterialPageRoute<void>(
        builder: (_) => VideoFushiPage(bookUid: uid, repo: repo),
      ),
    ),
  );
  // 工作台是盖在播放页上的整页路由：播放页那时在 offstage，查它要带上 offstage。
  VideoFushiTestHooks hooks() =>
      tester.state<State<VideoFushiPage>>(
            find.byType(VideoFushiPage, skipOffstage: false),
          )
          as VideoFushiTestHooks;
  await _waitFor(
    tester,
    () =>
        find.byType(VideoFushiPage).evaluate().isNotEmpty &&
        hooks().debugPositionMs != null &&
        (hooks().debugDurationMs ?? 0) > 0 &&
        (asr || hooks().debugCueCount > 0),
    what: '视频页就绪',
  );
  final PhysicalRect rect = await _resizeClient(tester, _kUvSceneSize);
  await hooks().debugPause();
  await hooks().debugSeekMs(0);
  await _hold(tester, const Duration(milliseconds: 1500));

  final (
    SitePreviewRecording rec,
    SitePreviewTimeline tl,
    SitePreviewCursor cursor,
  ) = await c.begin(
    'uv-subtitle',
    rect,
    const Offset(1180, 640),
  );
  cursor.hide();

  Future<void> play(int fromMs) async {
    await hooks().debugSeekMs(fromMs);
    tl.playAudio(video.path, fromMs: fromMs);
    await hooks().debugPlay();
  }

  Future<void> pause() async {
    await hooks().debugPause();
    tl.stopAudio();
  }

  await _hold(tester, const Duration(milliseconds: 400));
  await play(0);
  await _hold(tester, const Duration(milliseconds: 1400));

  // 字幕菜单（播放页设置面板的「字幕」分类）→ 「字幕工作台」。
  hooks().debugOpenSubtitleSettings();
  final Finder studioEntry = find.byKey(
    const ValueKey<String>('video-subtitle-studio'),
  );
  await _waitFor(
    tester,
    () => studioEntry.evaluate().isNotEmpty,
    what: '字幕菜单里的「字幕工作台」',
  );
  await _hold(tester, const Duration(milliseconds: 900));
  cursor.show(const Offset(1180, 640));
  await _uvPress(tester, cursor, driver, studioEntry);
  await _waitFor(
    tester,
    () => find.byType(VideoSubtitleStudioPage).evaluate().isNotEmpty,
    what: '字幕工作台打开',
  );
  await _hold(tester, const Duration(milliseconds: 1800));

  int posterMs = _sinceStart(rec) + 600;
  if (asr) {
    final Finder ready = find.byKey(
      const ValueKey<String>('video-subtitle-ai-model-ready'),
    );
    final Stopwatch readyClock = Stopwatch()..start();
    while (ready.evaluate().isEmpty &&
        readyClock.elapsed < const Duration(seconds: 20)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    if (ready.evaluate().isEmpty) {
      // 认不出时把工作台上的字全打出来（模型缺哪种变体、面板报了什么）。
      final List<String> texts = <String>[
        for (final Element e
            in find
                .descendant(
                  of: find.byType(VideoSubtitleStudioPage),
                  matching: find.byType(Text),
                )
                .evaluate())
          (e.widget as Text).data ?? '',
      ];
      fail('生成面板没认出本机语音模型：${texts.join(' | ')}');
    }
    final Finder start = find.byKey(
      const ValueKey<String>('video-subtitle-ai-start'),
    );
    expect(start, findsOneWidget, reason: '生成面板应有「开始」');
    // 「开始」在工具栏底部：先滚进视野（像用户滚到那里），再指过去点。
    unawaited(
      Scrollable.ensureVisible(
        tester.element(start),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeInOutCubic,
        alignment: 0.8,
      ),
    );
    await _hold(tester, const Duration(milliseconds: 900));
    await _uvPress(tester, cursor, driver, start);
    await _hold(tester, const Duration(milliseconds: 1600));
    cursor.hide();
    // 转录期间的等待剪掉（只留开头一小段进度）；视频先停住，剪完从字幕开头接着放。
    final int waitFrom = _sinceStart(rec);
    await pause();
    final Stopwatch asrClock = Stopwatch()..start();
    await _waitFor(
      tester,
      () => hooks().debugCueCount > 0,
      timeout: const Duration(minutes: 4),
      what: 'ASR 生成的字幕挂上播放器',
    );
    debugPrint(
      '[site-preview] uv-subtitle asr cues=${hooks().debugCueCount} '
      'wall=${asrClock.elapsedMilliseconds}ms',
    );
    await _hold(tester, const Duration(milliseconds: 1200));
    // 表格换成新字幕后滚到开头：从第一句前一点接着放。
    await play(1000);
    await _hold(tester, const Duration(milliseconds: 500));
    tl.cut(waitFrom + 300, _sinceStart(rec) - 400);
    posterMs = _sinceStart(rec) + 2500;
  }
  // 逐句表格跟随播放头。
  await _hold(tester, const Duration(milliseconds: 4200));

  // 回播放页：「返回」关工作台，再「返回」一次收起字幕菜单（不退出播放页）；
  // 关菜单这一下剪掉，接上一句有字幕的地方，生成的字幕就在画面上。
  final int backFrom = _sinceStart(rec);
  await c.nav.maybePop();
  await _hold(tester, const Duration(milliseconds: 500));
  await c.nav.maybePop();
  await _hold(tester, const Duration(milliseconds: 400));
  await pause();
  await play(25300);
  await _hold(tester, const Duration(milliseconds: 300));
  tl.cut(backFrom + 600, _sinceStart(rec));
  await _hold(tester, const Duration(milliseconds: 3600));
  await pause();
  await c.end(
    'uv-subtitle',
    rec,
    tl,
    cursor,
    posterMs: posterMs,
    outSize: _kUvSceneSize,
  );
  c.nav.popUntil((Route<dynamic> r) => r.isFirst);
  await _hold(tester, const Duration(seconds: 1));
}

// ───────────────────────────── uv-srs ─────────────────────────────

/// 复习历史的单词（三个牌组共用一张词表，按牌组错开取）。
const List<String> _kUvSrsWords = <String>[
  '薬屋',
  '後宮',
  '侍女',
  '毒見',
  '皇帝',
  '妃',
  '宦官',
  '簪',
  '香料',
  '解毒',
  '診察',
  '処方',
  '調合',
  '噂',
  '謀反',
  '一族',
  '市井',
  '出回る',
  '開店',
  '閉店',
  '客',
  '娼館',
  '花街',
  '手紙',
  '縁談',
  '身請け',
  '帳簿',
  '口実',
  '密偵',
  '証拠',
  '雨上がり',
  '揺らぐ',
  '晴れ',
  '傘',
  '放課後',
  '練習',
  '歌詞',
  '旋律',
  '鼓動',
  '迷子',
  '仲間',
  '約束',
  '後悔',
  '素直',
  '強がる',
  '照れる',
  '戸惑う',
  '打ち明ける',
  '寄り添う',
  '踏み出す',
  '舞台',
  '観客',
  '拍手',
  '緊張',
  '響く',
  '届く',
  '叫ぶ',
  '黙る',
  '涙',
  '笑顔',
  '曖昧',
  '概念',
  '矛盾',
  '妥協',
  '慎重',
  '露骨',
  '頑固',
  '謙虚',
  '贅沢',
  '質素',
  '把握',
  '貢献',
  '維持',
  '模索',
  '懸念',
  '遂行',
  '是正',
  '委ねる',
  '賄う',
  '携わる',
  '紛れる',
  '逸らす',
  '綻びる',
  '滞る',
  '拗ねる',
  '怯える',
  '侮る',
  '労う',
  '募る',
  '廃れる',
  '趣',
  '風情',
  '名残',
  '気配',
  '面影',
  '佇まい',
  '余韻',
  '兆し',
  '節目',
  '瀬戸際',
  '目論見',
  '手掛かり',
  '心当たり',
  '言い訳',
  '見当',
  '目処',
  '辻褄',
  '由緒',
  '経緯',
  '顛末',
  '朧げ',
  '健気',
  '儚い',
  '潔い',
  '逞しい',
  '疎い',
  '脆い',
  '拙い',
  '夥しい',
  '煩わしい',
];

/// 几乎每次都忘的词（易忘卡那一栏要有内容）。
const Set<int> _kUvSrsLeeches = <int>{4, 37, 66, 84, 113};

/// 在独立的复习库里造约五个月的复习历史（假时钟从五个月前一天天走到现在）。
///
/// 不碰 app 自己的复习库：时钟是库打开时就定的（`SrsDbStore.open(trustedClock:)`），
/// 历史只能在一份按假时钟打开的库里造。返回库与造出的作答条数。
Future<(SrsDbStore, int)> _uvSeedSrsHistory(ProviderContainer container) async {
  const int days = 150;
  const int newPerDay = 3;
  const int dayMs = 86400000;
  final int realNow = DateTime.now().millisecondsSinceEpoch;
  final math.Random rng = math.Random(34);
  // 每天一段学习：结束于「今天」之前，时刻在一天里错开（按小时分布那张图要有起伏）。
  final List<int> sessionAt = <int>[
    for (int d = 0; d < days; d++)
      d == days - 1
          ? realNow - 50 * 60000
          : realNow -
                (days - 1 - d) * dayMs -
                ((1.5 + rng.nextDouble() * 10) * 3600000).round(),
  ];
  int? fakeNow = sessionAt.first - 3600000;
  int clockMs() => fakeNow ?? DateTime.now().millisecondsSinceEpoch;
  void advance(int ms) => fakeNow = fakeNow! + ms;

  final Directory dir = Directory(
    p.join(_scratch('uv-srs').path, 'srs-$realNow'),
  )..createSync(recursive: true);
  final SrsStorage storage = await SrsStorage.open(directory: dir.path);
  final SrsDbStore store = await SrsDbStore.open(
    core: storage.core,
    profileUid: 'uv-srs',
    deviceId: 'uv-srs-device',
    engine: container.read(srsEngineProvider),
    trustedClock: SrsTrustedClock(wallClockMs: clockMs, bootClockMs: clockMs),
  );
  await store.ensureBuiltins();
  final List<(String, SrsSourceRef Function(int i))> decks =
      <(String, SrsSourceRef Function(int i))>[
        (
          '薬屋のひとりごと',
          (int i) => SrsSourceRef.media(
            kind: SrsSourceKind.video,
            mediaKey: 'uv-kusuriya',
            startMs: 20000 + i * 7300,
            title: '薬屋のひとりごと',
          ),
        ),
        (
          "BanG Dream! It's MyGO!!!!!",
          (int i) => SrsSourceRef.manga(
            mangaKey: 'uv-mygo',
            chapterKey: 'vol-1',
            page: 4 + i % 120,
            title: "BanG Dream! It's MyGO!!!!!",
          ),
        ),
        (
          'JLPT N1',
          (int i) => SrsSourceRef.book(
            bookKey: 'uv-n1',
            sectionIndex: i % 12,
            charStart: i * 40,
            title: '安達としまむら',
          ),
        ),
      ];
  final List<String> deckIds = <String>[
    for (final (String name, _) in decks) await store.createDeck(name),
  ];
  final String expressionField = srsLapisFieldId(
    store.profileUid,
    'Expression',
  );

  final List<String> cards = <String>[];
  final List<int> wordOf = <int>[];
  final List<int> dueDay = <int>[];
  final List<double> interval = <double>[];
  int answers = 0;
  int created = 0;
  final Stopwatch sw = Stopwatch()..start();
  for (int d = 0; d < days; d++) {
    // 偶尔整天没复习（日历上有空格）；最近两周天天在背。
    if (d < days - 14 && rng.nextDouble() < 0.08) continue;
    if (sessionAt[d] > fakeNow!) fakeNow = sessionAt[d];
    final List<int> due = <int>[
      for (int i = 0; i < cards.length; i++)
        if (dueDay[i] <= d) i,
    ];
    for (final int i in due) {
      final double r = rng.nextDouble();
      // 今天那一段答得好一些（「今日」那几张数字卡不出现个位数的正确率）。
      final double again = d == days - 1
          ? 0.04
          : _kUvSrsLeeches.contains(wordOf[i])
          ? 0.4
          : 0.09;
      final int rating = r < again
          ? 1
          : r < again + 0.12
          ? 2
          : r < 0.93
          ? 3
          : 4;
      final int took = 2500 + rng.nextInt(9000);
      await store.answer(cards[i], rating, durationMs: took);
      answers++;
      advance(took + 1500 + rng.nextInt(4000));
      interval[i] = switch (rating) {
        1 => 1,
        2 => math.max(1, interval[i] * 1.3),
        3 => math.max(2, interval[i] * 2.4),
        _ => math.max(4, interval[i] * 3.3),
      }.clamp(1, 120).toDouble();
      dueDay[i] = d + interval[i].round();
    }
    if (d < 120) {
      for (int k = 0; k < newPerDay; k++) {
        final int deck = created % decks.length;
        final int word =
            (created ~/ decks.length + deck * 40) % _kUvSrsWords.length;
        final String note = await store.createNote(
          noteTypeId: store.lapisNoteTypeId,
          deckId: deckIds[deck],
          fieldsById: <String, String>{expressionField: _kUvSrsWords[word]},
          source: decks[deck].$2(created),
        );
        final String card = (await store.cardsOfNote(note)).first.id;
        final int rating = rng.nextDouble() < 0.2 ? 1 : 3;
        final int took = 4000 + rng.nextInt(8000);
        await store.answer(card, rating, durationMs: took);
        answers++;
        advance(took + 2000);
        cards.add(card);
        wordOf.add(word);
        interval.add(1);
        dueDay.add(d + 1);
        created++;
      }
    }
  }
  // 造完：时钟回到真实时间（只往前走）。
  fakeNow = null;
  debugPrint(
    '[site-preview] uv-srs seeded cards=${cards.length} answers=$answers '
    'in ${sw.elapsedMilliseconds}ms',
  );
  return (store, answers);
}

/// 模型校准的演示报告（FSRS 留出预测 + RWKV，及 UM+）。
///
/// 隔离根里没有 RWKV 权重，真管线只出得了 FSRS 一条线、没有 UM+；这里按 [reviews] 条
/// 作答造一份形状合理的报告（校准箱按 20 个对数箱、UM+ 按分歧 41 箱，与内核同口径）。
SrsCalibrationReport _uvCalibrationReport(int reviews) {
  double edge(int i) => math.log(i + 1) / math.log(21);
  SrsCalibrationSeries series(double wobble, double phase, double logLoss) {
    final List<double> weights = <double>[
      for (int i = 0; i < 20; i++)
        i < 4 ? 0 : math.pow((edge(i) + edge(i + 1)) / 2, 7).toDouble(),
    ];
    final double sum = weights.fold<double>(0, (double a, double b) => a + b);
    final List<SrsCalibrationBin> bins = <SrsCalibrationBin>[];
    double se = 0;
    int total = 0;
    for (int i = 0; i < 20; i++) {
      final int count = (reviews * 0.93 * weights[i] / sum).round();
      if (count < 8) continue;
      final double predicted = (edge(i) + edge(i + 1)) / 2;
      final double actual = (predicted + wobble * math.sin(i * 1.9 + phase))
          .clamp(0.0, 1.0)
          .toDouble();
      final double ci = 1.96 * math.sqrt(actual * (1 - actual) / count);
      bins.add(
        SrsCalibrationBin(
          index: i,
          count: count,
          predicted: predicted,
          actual: actual,
          lower: (actual - ci).clamp(0.0, 1.0).toDouble(),
          upper: (actual + ci).clamp(0.0, 1.0).toDouble(),
        ),
      );
      se += count * math.pow(predicted - actual, 2);
      total += count;
    }
    return SrsCalibrationSeries(
      count: total,
      logLoss: logLoss,
      rmse: math.sqrt(se / math.max(1, total)),
      bins: bins,
    );
  }

  final int paired = (reviews * 0.9).round();
  const double sigma = 0.2;
  final List<SrsUmPlusBin> um = <SrsUmPlusBin>[];
  double fsrsSe = 0;
  double rwkvSe = 0;
  int umTotal = 0;
  for (int j = 0; j < 41; j++) {
    final double d = -1 + j * 0.05;
    final double density =
        math.exp(-d * d / (2 * sigma * sigma)) /
        (sigma * math.sqrt(2 * math.pi));
    final int count = (paired * 0.05 * density).round();
    if (count == 0) continue;
    final double fsrsError = 0.52 * d + 0.012 * math.sin(j * 2.3);
    final double rwkvError = 0.07 * d + 0.009 * math.cos(j * 1.7);
    um.add(
      SrsUmPlusBin(
        index: j,
        count: count,
        disagreement: d,
        fsrsError: fsrsError,
        rwkvError: rwkvError,
      ),
    );
    fsrsSe += count * fsrsError * fsrsError;
    rwkvSe += count * rwkvError * rwkvError;
    umTotal += count;
  }
  return SrsCalibrationReport(
    eligible: reviews,
    hasRwkv: true,
    fsrs: series(0.028, 0.4, 0.338),
    rwkv: series(0.012, 2.1, 0.317),
    umPlus: SrsUmPlus(
      count: umTotal,
      fsrsScore: math.sqrt(fsrsSe / umTotal),
      rwkvScore: math.sqrt(rwkvSe / umTotal),
      bins: um,
    ),
  );
}

/// 统计中心（同 `StatisticsCenterPage` 的页头与页签），只是「复习」页签挂的是带校准替身的
/// [SrsStatisticsTab]；其它页签这一段不切过去，留空。
class _UvSrsStatsPage extends StatelessWidget {
  const _UvSrsStatsPage({required this.reviews});

  final int reviews;

  @override
  Widget build(BuildContext context) {
    final List<(StatsCenterTab, String)> tabs = <(StatsCenterTab, String)>[
      (StatsCenterTab.overview, t.stat_center_tab_overview),
      (StatsCenterTab.reading, t.home_filter_read),
      (StatsCenterTab.video, t.home_filter_watch),
      (StatsCenterTab.game, t.home_filter_game),
      (StatsCenterTab.srs, t.nav_srs),
    ];
    return DefaultTabController(
      length: tabs.length,
      initialIndex: tabs.length - 1,
      child: Builder(
        builder: (BuildContext context) => FushiPageScaffold(
          masthead: true,
          title: t.stat_center_title,
          headerTitle: LibrarySectionTabs<StatsCenterTab>.controlled(
            tabs: <LibrarySectionTab<StatsCenterTab>>[
              for (final (StatsCenterTab tab, String label) in tabs)
                LibrarySectionTab<StatsCenterTab>(value: tab, label: label),
            ],
            controller: DefaultTabController.of(context),
            focusIdPrefix: 'stats-center-tab',
            floating: true,
          ),
          body: TabBarView(
            physics: const NeverScrollableScrollPhysics(),
            children: <Widget>[
              for (final (StatsCenterTab tab, String _) in tabs)
                StatCenterTabScope(
                  child: tab == StatsCenterTab.srs
                      ? SrsStatisticsTab(
                          debugCalibrationLoader:
                              (
                                SrsDbStore _,
                                _,
                                SrsCalibrationProgress onProgress,
                              ) async {
                                // 进度条走一遍（FSRS 训练 → RWKV 回放）。
                                for (final SrsCalibrationPhase phase
                                    in SrsCalibrationPhase.values) {
                                  for (int i = 0; i <= 12; i++) {
                                    onProgress(phase, i, 12);
                                    await Future<void>.delayed(
                                      const Duration(milliseconds: 70),
                                    );
                                  }
                                }
                                return SrsCalibrationData.empty();
                              },
                          debugCalibrationReporter:
                              (SrsCalibrationData _, List<String>? _) async =>
                                  _uvCalibrationReport(reviews),
                        )
                      : const SizedBox.shrink(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 新一代 Fushi 复习：统计页满屏图表 → 切范围 → 模型校准 → 校准图 + UM+。
Future<void> _sceneUvSrs(_Ctx c) async {
  final WidgetTester tester = c.tester;
  final FocusDriver driver = FocusDriver(tester);
  final ProviderContainer container = ProviderScope.containerOf(c.nav.context);
  final (SrsDbStore store, int reviews) = await _uvSeedSrsHistory(container);
  final PhysicalRect rect = await _resizeClient(tester, _kUvSceneSize);
  unawaited(
    c.nav.push(
      adaptivePageRoute<void>(
        context: c.nav.context,
        builder: (_) => ProviderScope(
          overrides: <Override>[
            srsStoreProvider.overrideWith((Ref ref) async => store),
          ],
          child: _UvSrsStatsPage(reviews: reviews),
        ),
      ),
    ),
  );
  final Finder calibration = find.byKey(
    const ValueKey<String>('srs-stats-calibration'),
    skipOffstage: false,
  );
  await _waitFor(
    tester,
    () => calibration.evaluate().isNotEmpty,
    timeout: const Duration(seconds: 60),
    what: '复习统计载入',
  );
  await _hold(tester, const Duration(milliseconds: 2500));

  final (
    SitePreviewRecording rec,
    SitePreviewTimeline tl,
    SitePreviewCursor cursor,
  ) = await c.begin(
    'uv-srs',
    rect,
    const Offset(1250, 560),
  );
  await _hold(tester, const Duration(milliseconds: 1800));
  // 范围换成「3 个月」：各图按新范围重算、错峰重新进场。
  await _uvPress(
    tester,
    cursor,
    driver,
    find.text(t.srs_stats_range_three_months),
  );
  await _hold(tester, const Duration(milliseconds: 2600));
  cursor.hide();

  // 滚到「模型校准」。
  unawaited(
    Scrollable.ensureVisible(
      tester.element(calibration),
      duration: const Duration(milliseconds: 1500),
      curve: Curves.easeInOutCubic,
      alignment: 0.24,
    ),
  );
  await _hold(tester, const Duration(milliseconds: 2000));
  final Finder compute = find.byKey(
    const ValueKey<String>('srs-stats-calibration-compute'),
  );
  cursor.show(const Offset(1250, 600));
  await _uvPress(tester, cursor, driver, compute);
  await _waitFor(
    tester,
    () => find
        .byKey(const ValueKey<String>('srs-stats-umplus-chart'))
        .evaluate()
        .isNotEmpty,
    what: '校准图与 UM+ 图出来',
  );
  cursor.hide();
  final int posterMs = _sinceStart(rec) + 1500;
  await _hold(tester, const Duration(milliseconds: 4500));
  await c.end(
    'uv-srs',
    rec,
    tl,
    cursor,
    posterMs: posterMs,
    outSize: _kUvSceneSize,
  );
  c.nav.popUntil((Route<dynamic> r) => r.isFirst);
  await _hold(tester, const Duration(seconds: 1));
}

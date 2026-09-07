import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// TODO-131 守卫：锁定「打开书籍白屏优化」的开书路径接线，防回归。
/// reader_fushi_page.dart 太重（WebView + DB + profile providers）不便在 host
/// widget 测试里整页 mount，纯函数等价性由 book_open_char_counts_test.dart 覆盖；
/// 这里用源码扫描守住 _initBook 的关键时序/数据流不变量。
///
/// TODO-2527：语料先过 [maskCommentsAndScriptLines]，方法体窗口改由 [methodBody]
/// 的花括号配对给出。旧写法两处都能假绿：
/// - 窗口是「本方法签名 → **下一个**方法签名」的文本切片，中间夹的方法体也算进窗口；
/// - 窗口不掩码，`_recomputeCharCountsInBackground` / `_chapterCumulativeChars`
///   这些符号本来就写在本页的说明注释里，实现删光只留注释照样绿。
void main() {
  late String src;

  setUpAll(() {
    src = maskCommentsAndScriptLines(readReaderPageSource());
  });

  test('_initBook 并行起跑 profile/settings 链与书本定位/解析链', () {
    final int profileIdx = src.indexOf('_resolveProfileAndSettings(db)');
    final int locateIdx = src.indexOf('_locateBookOnDisk(db)');
    final int firstAwaitIdx = src.indexOf('await profileSettingsFuture;');
    expect(profileIdx, greaterThan(0));
    expect(locateIdx, greaterThan(0));
    expect(firstAwaitIdx, greaterThan(0));
    // 两条链的 Future 必须都在第一个 await 之前就被创建（并行起跑），否则退化成
    // 串行，白屏优化失效。
    expect(
      profileIdx,
      lessThan(firstAwaitIdx),
      reason: 'profile/settings Future 必须在 await 之前起跑',
    );
    expect(
      locateIdx,
      lessThan(firstAwaitIdx),
      reason: 'book-locate Future 必须在 await 之前起跑（与 profile 链并行）',
    );
  });

  test('开书优先复用 DB 已存的 per-chapter 字符数（跳过整本 html_parser 计数）', () {
    expect(
      containsCodeLine(src, 'parseBookOnly'),
      isTrue,
      reason: '冷开首屏走 parseBookOnly（不在 isolate 里整本计数）',
    );
    expect(
      containsCodeLine(src, 'charCountsFromChaptersJson('),
      isTrue,
      reason: '必须从 chaptersJson 复用 DB 计数',
    );
    // 整本「解析+计数」入口 parseAndCountChapters 不应再出现在开书路径
    // （只保留给等价性测试/旧路径），否则等于没省下计数。
    expect(
      containsCodeLine(src, 'compute(parseAndCountChapters'),
      isFalse,
      reason: '_initBook 不应再 compute(parseAndCountChapters)——那会整本计数',
    );
  });

  test('DB 计数缺失时后台补算并重置字数账本（坐标系整体变更）', () {
    expect(containsCodeLine(src, '_recomputeCharCountsInBackground'), isTrue);
    // 后台补算落定后必须 _readLedger.reset()：全书绝对偏移的坐标系换了口径，零计数
    // 期间记下的并集与当前单元不再有意义（旧标量水位时代这里是把水位校到当前位置，
    // 否则计数落定后首个进度回调会把整段前缀误当本次新读字数）。
    final String body = methodBody(
      src,
      'void _recomputeCharCountsInBackground()',
    );
    expect(
      containsCodeLine(body, '_readLedger.reset()'),
      isTrue,
      reason: '补算落定后必须清账本（并集 + 当前单元），杜绝统计 spike / 旧坐标残留',
    );
    expect(
      containsCodeLine(body, 'identical(_book, book)'),
      isTrue,
      reason: '只在仍是同一本书时采用补算结果（防换书竞态）',
    );
  });

  test('_applyCharCounts 重建累计前缀并刷新进度总字数', () {
    final String body = methodBody(
      src,
      'void _applyCharCounts(List<int> counts)',
    );
    expect(containsCodeLine(body, '_chapterCumulativeChars'), isTrue);
    expect(containsCodeLine(body, '_progressTotalChars'), isTrue);
  });

  test('跨章收藏高亮复用书内缓存并按 section 过滤', () {
    expect(
      containsCodeLine(src, '_favoriteSentencesForBookCache'),
      isTrue,
      reason: 'reader 应缓存当前书收藏，跨章只做内存过滤，避免每章全量 getAll/decode/sort',
    );
    expect(containsCodeLine(src, '_favoriteSentencesForSection'), isTrue);

    final String helperBody = methodBody(
      src,
      'Future<List<FavoriteSentence>> _favoriteSentencesForSection(',
    );
    expect(containsCodeLine(helperBody, 's.bookKey == widget.bookKey'), isTrue);
    expect(
      containsCodeLine(helperBody, 's.sectionIndex == section'),
      isTrue,
      reason: '章节高亮必须只取当前 section，不能把整本收藏都交给高亮桥',
    );

    // 旧写法拿 `_applyLyricsFavorites` 当 `_applyChapterHighlights` 的右边界，
    // 顺带证明了它存在。换成花括号配对后不再需要它定边界，存在性单独锁住，
    // 避免这次迁移悄悄少守一个符号。
    expect(
      containsCodeLine(src, 'Future<void> _applyLyricsFavorites()'),
      isTrue,
      reason: '歌词模式收藏高亮入口必须还在',
    );
    final String applyBody = methodBody(
      src,
      'Future<void> _applyChapterHighlights()',
    );
    final String refreshBody = methodBody(
      src,
      'Future<void> _refreshSectionHighlights(int section)',
    );
    expect(
      containsCodeLine(
        applyBody,
        '_favoriteSentencesForSection(_currentChapter)',
      ),
      isTrue,
    );
    expect(
      containsCodeLine(refreshBody, '_favoriteSentencesForSection(section)'),
      isTrue,
    );
    expect(
      containsCodeLine(applyBody, 'getAll()'),
      isFalse,
      reason: '_applyChapterHighlights 跑在每章加载路径，不能每章全量解码收藏',
    );
    expect(
      containsCodeLine(refreshBody, 'getAll()'),
      isFalse,
      reason: '_refreshSectionHighlights 也应复用缓存并只按 section 筛',
    );
  });

  test('收藏新增删除会失效缓存再刷新高亮', () {
    expect(
      containsCodeLine(src, 'void _invalidateFavoriteSentenceCache()'),
      isTrue,
    );

    // TODO-589 batch7: 这些方法搬进了 reader_fushi/chrome.part.dart（合并语料末尾）。
    // 旧写法用「下一个方法名」当右边界，方法一被搬走/改名窗口就整段错位；改成花括号
    // 配对后窗口与成员顺序、文件归属无关。旧右边界 `_buildTopProgressBar` 的存在性
    // 单独锁住，不因这次迁移丢覆盖。
    expect(
      containsCodeLine(src, 'Widget _buildTopProgressBar()'),
      isTrue,
      reason: '顶栏进度条构建入口必须还在',
    );
    // 面板构造已从 _showAppearanceSheet 抽成 _buildQuickSettingsSheet（三种呈现共用
    // 一份回调接线），删除收藏的闭包随之搬家；守卫跟着看新方法体。
    final String settingsBody = methodBody(
      src,
      'Widget _buildQuickSettingsSheet({',
    );
    final String toggleBody = methodBody(
      src,
      'Future<void> _toggleFavoriteSentence()',
    );
    // 这两条锚点是**跨行**的相邻语句对（「删完紧接着失效缓存」），containsCodeLine 逐行
    // 匹配表达不了，故保留整段 contains——窗口已掩码，注释满足不了它。
    expect(
      settingsBody,
      contains(
        'await favRepo.removeById(fav.id);\n        _invalidateFavoriteSentenceCache();',
      ),
      reason: '设置面板删除收藏后，当前 reader 缓存必须失效',
    );
    // BUG-494：取消收藏优先按缓存的精确条目 id removeById 删单条，无 id 时才回退内容键
    // removeByContent（包在 else 分支里，故内容键删单条这段多缩进一层，text: 现为 10 空格
    // 缩进）。守卫更新到当前缩进，不变量强度不变：内容键删除仍走 removeByContent 单条删。
    expect(
      toggleBody,
      contains('await repo.removeByContent(\n          text: sentence,'),
    );
    expect(
      containsCodeLine(toggleBody, '_invalidateFavoriteSentenceCache();'),
      isTrue,
    );
    // 删除路径（内容键回退分支）删后必失效缓存。
    final int removeIdx = toggleBody.indexOf('await repo.removeByContent(');
    final int removeInvalidateIdx = toggleBody.indexOf(
      '_invalidateFavoriteSentenceCache();',
      removeIdx,
    );
    expect(
      removeInvalidateIdx,
      greaterThan(removeIdx),
      reason: '删除收藏（内容键回退）后当前 reader 缓存必须失效',
    );
    // 新增收藏：repo.add(fav) 后必记住精确 id（BUG-494 removeById 用）并失效缓存再刷新
    // 高亮。BUG-494 在 add 与 invalidate 之间插入 _currentFavoriteId = fav.id;，故不再是
    // 紧邻两行——改为「add 之后、rebuild 之前必有 _currentFavoriteId 记账 + 缓存失效」，
    // 不变量强度不变（新增后缓存必失效）。
    final int addIdx = toggleBody.indexOf('await repo.add(fav);');
    expect(addIdx, greaterThan(0), reason: '新增收藏必须 repo.add(fav)');
    final int rebuildAfterAddIdx = toggleBody.indexOf(
      '_rebuild(() => _currentSentenceIsFavorited = true)',
      addIdx,
    );
    expect(
      rebuildAfterAddIdx,
      greaterThan(addIdx),
      reason: '新增收藏后必须 rebuild 星标态',
    );
    final String addBody = toggleBody.substring(addIdx, rebuildAfterAddIdx);
    expect(
      containsCodeLine(addBody, '_currentFavoriteId = fav.id;'),
      isTrue,
      reason: 'BUG-494：新增后记住精确 id，供随后 removeById 精确删单条',
    );
    expect(
      containsCodeLine(addBody, '_invalidateFavoriteSentenceCache();'),
      isTrue,
      reason: '新增收藏后必须失效缓存重新拉取/过滤，保证高亮和星标状态准确',
    );
  });
}

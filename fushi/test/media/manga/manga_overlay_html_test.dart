import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

MokuroImage _pageWithTwoBlocks() {
  return const MokuroImage(
    url: 'p001.jpg',
    size: Size(1000, 2000),
    blocks: <MokuroBlock>[
      MokuroBlock(
        rectangle: Rect.fromLTWH(100, 200, 300, 400),
        isVertical: true,
        fontSize: 32,
        zIndex: 0,
        lines: <String>['一行目', '二行目'],
      ),
      MokuroBlock(
        rectangle: Rect.fromLTWH(500, 600, 200, 100),
        isVertical: false,
        fontSize: 24,
        zIndex: 1,
        lines: <String>['横書き'],
      ),
    ],
  );
}

void main() {
  group('mangaOcrBoxesHtml', () {
    test('每个 block 生成一个 <p class="ocr-box">', () {
      final String html = mangaOcrBoxesHtml(_pageWithTwoBlocks());
      final int count = '<p class="ocr-box"'.allMatches(html).length;
      expect(count, 2, reason: '两个 block 应生成两个 ocr-box <p>');
    });

    test('多行拆成字符区域且 DOM 顺序连续，绝不含字面换行', () {
      final String html = mangaOcrBoxesHtml(_pageWithTwoBlocks());
      expect('class="ocr-char"'.allMatches(html).length, 9,
          reason: '竖排两行 6 字 + 横排 3 字都必须成为独立命中区域');
      expect(html.indexOf('>一</span>') < html.indexOf('>二</span>'), isTrue,
          reason: '跨行扫描顺序必须保持 OCR 行顺序');
      expect(html.contains('一行目\n二行目'), isFalse);
      expect(html.contains('一行目\\n二行目'), isFalse);
    });

    test('scanDelimiters 契约：换行符 \\n 在扫描分隔集里（故必须用 <br>）', () {
      // develop 的 ReaderSelectionScripts.scanDelimiters 是含 `\n` 的大标点集；
      // 若覆盖层用裸 `\n` 连接跨行文本，扫描会在换行处截断跨行长词。这里锚定该
      // 契约：源码含 scanDelimiters 且包含换行符，佐证覆盖层用 <br> 的必要性。
      final String scripts = ReaderSelectionScripts.source();
      expect(scripts.contains('scanDelimiters'), isTrue,
          reason: '选区脚本应定义 scanDelimiters（扫描分隔集）');
      expect(scripts.contains(r'\n'), isTrue,
          reason: 'scanDelimiters 含换行 → 覆盖层必须用 <br> 而非 \\n');
      // BLOCK_SELECTOR 认 p → <p class="ocr-box"> 能被 findParagraph 命中为块。
      expect(RegExp(r'BLOCK_SELECTOR:\s*.p[,\x27]').hasMatch(scripts), isTrue,
          reason: 'BLOCK_SELECTOR 必须含 p（覆盖层块级 <p> 才会被命中）');
    });

    test('坐标按百分比换算（box / page.size）', () {
      final String html = mangaOcrBoxesHtml(_pageWithTwoBlocks());
      // block1: left=100/1000=10%, top=200/2000=10%, width=300/1000=30%, height=400/2000=20%
      expect(html.contains('left:10%'), isTrue);
      expect(html.contains('top:10%'), isTrue);
      expect(html.contains('width:30%'), isTrue);
      expect(html.contains('height:20%'), isTrue);
    });

    test('字号用容器查询单位 cqi（ERRATA H5），绝不用 font-size:% ', () {
      final String html = mangaOcrBoxesHtml(_pageWithTwoBlocks());
      // H5: font-size:% 相对父字号会塌缩让点击全 miss → 改用容器相对单位。
      // 用 cqi（inline-size 容器单位）而非 cqh：cqh 需 size containment，会塌缩
      // img 驱动的页高、两框重叠串字（设备实测过）。block0: fontSize 32 /
      // img_width 1000 * 100 = 3.2cqi。
      expect(html.contains('cqi'), isTrue, reason: 'OCR 框字号必须用容器查询单位 cqi');
      // 绝不能出现 font-size:<数字>%（相对父字号会塌缩）
      expect(RegExp(r'font-size:\s*[\d.]+%').hasMatch(html), isFalse,
          reason: '字号绝不能用百分比（相对父字号）');
      expect(html.contains('font-size:3.2cqi'), isTrue,
          reason: 'block0 字号应为 32/1000*100=3.2cqi');
    });

    test('font_size==0 不塌缩：用非零下限 cqi（ERRATA M1）', () {
      // mokuro 偶尔给 font_size==0 → font-size:0cqi 会把透明文字塌成 0 高、整框
      // 命中区域塌缩到原点点框全 miss。须落地非零下限（3cqi）。
      const MokuroImage page = MokuroImage(
        url: 'p.jpg',
        size: Size(1000, 1000),
        blocks: <MokuroBlock>[
          MokuroBlock(
            rectangle: Rect.fromLTWH(0, 0, 500, 500),
            isVertical: false,
            fontSize: 0, // ← 缺字段容错回退
            zIndex: 0,
            lines: <String>['あ'],
          ),
        ],
      );
      final String html = mangaOcrBoxesHtml(page);
      expect(html.contains('font-size:0cqi'), isFalse,
          reason: 'font_size==0 绝不能写出 font-size:0cqi（塌缩）');
      expect(html.contains('font-size:3cqi'), isTrue,
          reason: 'font_size==0 应回退到非零下限 3cqi');
    });

    test('竖排框带 writing-mode:vertical-rl，横排框不带', () {
      final String html = mangaOcrBoxesHtml(_pageWithTwoBlocks());
      expect('writing-mode:vertical-rl'.allMatches(html).length, 1,
          reason: '仅竖排 block 应带 vertical-rl');
    });

    test('文字 transparent + margin/padding 清零，字符公共命中样式不重复内联', () {
      final String html = mangaOcrBoxesHtml(_pageWithTwoBlocks());
      expect(html.contains('color:transparent'), isTrue);
      expect(html.contains('margin:0'), isTrue);
      expect(html.contains('padding:0'), isTrue);
      expect(html.contains('class="ocr-char"'), isTrue);
      expect(html.contains('position:absolute;display:block'), isFalse,
          reason: '密集页面不能为每个字符重复公共 CSS，否则 WebView 文档会膨胀并超时');
    });

    test('HTML 特殊字符转义（< > & 不破坏结构）', () {
      const MokuroImage page = MokuroImage(
        url: 'p.jpg',
        size: Size(100, 100),
        blocks: <MokuroBlock>[
          MokuroBlock(
            rectangle: Rect.fromLTWH(0, 0, 10, 10),
            isVertical: false,
            fontSize: 10,
            zIndex: 0,
            lines: <String>['a<b>&c'],
          ),
        ],
      );
      final String html = mangaOcrBoxesHtml(page);
      expect(html.contains('>&lt;</span>'), isTrue);
      expect(html.contains('>&gt;</span>'), isTrue);
      expect(html.contains('>&amp;</span>'), isTrue,
          reason: '字符区域里的 < > & 必须分别转义');
    });

    test('Lens 拆开的竖排气泡合成整句，并排除窄假名注音', () {
      // 取自 BUG-1333 用户实际 Lens 缓存 page-000003.jpg 的块形状：
      // 「大丈夫だよな?」被拆成注音 + 三个正文列。
      const MokuroImage page = MokuroImage(
        url: 'page-000003.jpg',
        size: Size(1170, 1600),
        blocks: <MokuroBlock>[
          MokuroBlock(
            rectangle: Rect.fromLTRB(288, 565, 309, 675),
            isVertical: true,
            fontSize: 21,
            zIndex: 0,
            lines: <String>['だいじょうぶ'],
          ),
          MokuroBlock(
            rectangle: Rect.fromLTRB(250, 561, 288, 687),
            isVertical: true,
            fontSize: 37,
            zIndex: 1,
            lines: <String>['大丈夫'],
          ),
          MokuroBlock(
            rectangle: Rect.fromLTRB(205, 565, 240, 687),
            isVertical: true,
            fontSize: 34,
            zIndex: 2,
            lines: <String>['だよな'],
          ),
          MokuroBlock(
            rectangle: Rect.fromLTRB(164, 644, 177, 683),
            isVertical: true,
            fontSize: 22,
            zIndex: 3,
            lines: <String>['?'],
          ),
          MokuroBlock(
            rectangle: Rect.fromLTRB(322, 560, 360, 686),
            isVertical: true,
            fontSize: 34,
            zIndex: 4,
            lines: <String>['なに?'],
          ),
        ],
      );

      expect(
        mangaBlockSentenceTexts(page),
        <String>[
          '大丈夫だよな?',
          '大丈夫だよな?',
          '大丈夫だよな?',
          '大丈夫だよな?',
          'なに?',
        ],
        reason: '相邻正文列应按竖排阅读顺序合并；右侧窄假名只作注音',
      );

      final String html = mangaOcrBoxesHtml(page);
      expect(
        'data-manga-sentence="大丈夫だよな?"'.allMatches(html).length,
        4,
      );
      expect(
        'data-manga-sentence-group="0"'.allMatches(html).length,
        4,
        reason: '同一气泡的每个 OCR 块必须共享定位组',
      );
      expect(
        '<p class="ocr-box" data-ocr-orientation="vertical"'
            .allMatches(html)
            .length,
        5,
      );
    });

    test('横排相邻行合句但在强句末停止', () {
      const MokuroImage page = MokuroImage(
        url: 'horizontal.jpg',
        size: Size(1000, 1000),
        blocks: <MokuroBlock>[
          MokuroBlock(
            rectangle: Rect.fromLTWH(100, 100, 120, 30),
            isVertical: false,
            fontSize: 30,
            zIndex: 0,
            lines: <String>['今日は'],
          ),
          MokuroBlock(
            rectangle: Rect.fromLTWH(100, 138, 100, 30),
            isVertical: false,
            fontSize: 30,
            zIndex: 1,
            lines: <String>['晴れ。'],
          ),
          MokuroBlock(
            rectangle: Rect.fromLTWH(100, 176, 100, 30),
            isVertical: false,
            fontSize: 30,
            zIndex: 2,
            lines: <String>['帰る。'],
          ),
        ],
      );

      expect(
        mangaBlockSentenceTexts(page),
        <String>['今日は晴れ。', '今日は晴れ。', '帰る。'],
      );
      final String html = mangaOcrBoxesHtml(page);
      expect(
        '<p class="ocr-box" data-ocr-orientation="horizontal"'
            .allMatches(html)
            .length,
        3,
      );
    });

    test('选区 payload 读取整句、方向、精确页，并以整组边界作为弹窗锚点', () {
      final String scripts = ReaderSelectionScripts.source();
      expect(scripts.contains("closest('[data-manga-sentence]')"), isTrue);
      expect(scripts.contains("getAttribute('data-ocr-orientation')"), isTrue);
      expect(
        scripts.contains(
          'querySelectorAll(\n'
          "        '.ocr-box[data-manga-sentence-group]'\n"
          '      )',
        ),
        isTrue,
      );
      expect(
        scripts.contains('rect: mangaGroupRect || this.getSelectionRect(x, y)'),
        isTrue,
        reason: '竖排应以完整气泡左右边界避让，横排应以整行上下边界避让',
      );
      expect(scripts.contains('verticalWriting: verticalWriting'), isTrue);
      expect(
        scripts.contains("Number(mangaPage.getAttribute('data-page'))"),
        isTrue,
        reason: '双页模式制卡必须携带 OCR 命中的精确页，不能只知道当前 spread',
      );
      expect(scripts.contains('mangaPageIndex: mangaPageIndex'), isTrue);
    });
  });

  group('mangaEffectiveTextRegions', () {
    test('横排从左到右、竖排从上到下拆字符，并保留 UTF-16 偏移', () {
      const MokuroBlock horizontal = MokuroBlock(
        rectangle: Rect.fromLTWH(10, 20, 60, 10),
        isVertical: false,
        fontSize: 10,
        zIndex: 0,
        lines: <String>['日本語'],
      );
      final List<MangaOcrTextRegion> horizontalRegions =
          mangaEffectiveTextRegions(horizontal);
      expect(horizontalRegions.map((r) => r.rectangle).toList(), <Rect>[
        const Rect.fromLTWH(10, 20, 20, 10),
        const Rect.fromLTWH(30, 20, 20, 10),
        const Rect.fromLTWH(50, 20, 20, 10),
      ]);

      const MokuroBlock vertical = MokuroBlock(
        rectangle: Rect.fromLTWH(80, 30, 12, 60),
        isVertical: true,
        fontSize: 10,
        zIndex: 0,
        lines: <String>['𠮷野家'],
      );
      final List<MangaOcrTextRegion> verticalRegions =
          mangaEffectiveTextRegions(vertical);
      expect(verticalRegions.map((r) => r.rectangle).toList(), <Rect>[
        const Rect.fromLTWH(80, 30, 12, 20),
        const Rect.fromLTWH(80, 50, 12, 20),
        const Rect.fromLTWH(80, 70, 12, 20),
      ]);
      expect(verticalRegions.first.utf16Start, 0);
      expect(verticalRegions.first.utf16End, 2,
          reason: '补充平面字符必须按 UTF-16 两个 code unit 计数');
      expect(verticalRegions[1].utf16Start, 2);
    });

    test('多列竖排按右到左分列，lines_coords 优先使用真实行框', () {
      const MokuroBlock fallback = MokuroBlock(
        rectangle: Rect.fromLTWH(10, 20, 40, 100),
        isVertical: true,
        fontSize: 10,
        zIndex: 0,
        lines: <String>['右', '左'],
      );
      final List<MangaOcrTextRegion> fallbackRegions =
          mangaEffectiveTextRegions(fallback);
      expect(
          fallbackRegions[0].rectangle, const Rect.fromLTWH(30, 20, 20, 100));
      expect(
          fallbackRegions[1].rectangle, const Rect.fromLTWH(10, 20, 20, 100));

      const MokuroBlock withCoordinates = MokuroBlock(
        rectangle: Rect.fromLTWH(0, 0, 100, 100),
        isVertical: false,
        fontSize: 10,
        zIndex: 0,
        lines: <String>['AB'],
        linesCoords: <List<List<double>>>[
          <List<double>>[
            <double>[20, 30],
            <double>[80, 30],
            <double>[80, 50],
            <double>[20, 50],
          ],
        ],
      );
      final List<MangaOcrTextRegion> coordinateRegions =
          mangaEffectiveTextRegions(withCoordinates);
      expect(
          coordinateRegions[0].rectangle, const Rect.fromLTWH(20, 30, 30, 20));
      expect(
          coordinateRegions[1].rectangle, const Rect.fromLTWH(50, 30, 30, 20));
    });
  });

  group('mangaPageDivHtml', () {
    test(
        '包 <div class="manga-page"> + container-type:inline-size + <img '
        'pointer-events:none> + 框', () {
      final String html =
          mangaPageDivHtml(_pageWithTwoBlocks(), 'manga.local/0/p001.jpg');
      expect(html.contains('<div class="manga-page"'), isTrue);
      // H5: 容器查询上下文必须在 .manga-page 上（cqi 才有参照宽）。用 inline-size
      // 而非 size（size 会塌缩 img 驱动的页高、两框重叠串字）。
      expect(html.contains('container-type:inline-size'), isTrue,
          reason: '.manga-page 必须声明 container-type:inline-size 供 cqi 参照');
      expect(html.contains('src="manga.local/0/p001.jpg"'), isTrue);
      // 底图必须 pointer-events:none（点裸图→放大，点框→查词，互斥命中）
      expect(
        RegExp(r'<img[^>]*pointer-events\s*:\s*none').hasMatch(html),
        isTrue,
        reason: '底图 <img> 必须 pointer-events:none',
      );
      expect(html.contains('<p class="ocr-box"'), isTrue);
    });

    // spread 页同时受槽宽与 100vh 限制，横屏/矮窗口都不得裁切。
    test('spread 单页同时受 100vw 与 100vh 宽高约束', () {
      final String html = mangaPageDivHtml(_pageWithTwoBlocks(), 'p.jpg',
          pagesInSpread: 1, isWebtoon: false);
      // 1000×2000：宽=min(100vw,50vh)，高=min(100vh,200vw)。
      expect(html.contains('width:min(100vw,50vh)'), isTrue);
      expect(html.contains('height:min(100vh,200vw)'), isTrue);
      expect(html.contains('aspect-ratio:'), isTrue,
          reason: 'OCR 覆盖层仍需与原图保持同一宽高比');
    });

    test('spread 双页每页最多 50vw 且高度不超过 100vh', () {
      final String html = mangaPageDivHtml(_pageWithTwoBlocks(), 'p.jpg',
          pagesInSpread: 2, isWebtoon: false);
      expect(html.contains('width:min(50vw,50vh)'), isTrue);
      expect(html.contains('height:min(100vh,100vw)'), isTrue);
    });

    test('webtoon → .manga-page div 不内联 width（宽由 style 块 width:100vw 给）', () {
      // 用无 OCR 框的页：OCR 框自带 width:% 会干扰「div 是否内联 width」的判定。
      const MokuroImage blank = MokuroImage(
          url: 'p.jpg', size: Size(800, 1200), blocks: <MokuroBlock>[]);
      final String html =
          mangaPageDivHtml(blank, 'p.jpg', pagesInSpread: 1, isWebtoon: true);
      // .manga-page div 的 style 不含 vw 宽（webtoon 宽由外部 style 块给）。
      expect(html.contains('width:100vw'), isFalse,
          reason: 'webtoon 页 div 不应内联 width:100vw');
      expect(html.contains('width:50vw'), isFalse);
      expect(html.contains('aspect-ratio:'), isTrue);
      // webtoon 底图必须 lazy 加载（整书单文档，避免一次性解码全卷）。
      expect(html.contains('loading="lazy"'), isTrue,
          reason: 'webtoon <img> 必须 loading="lazy"');
    });
  });

  group('mangaWindowDocument', () {
    test('spread RTL → flex-row + direction:rtl，内联选词 JS + null-guard', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page],
        <String>['manga.local/0/p001.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: ReaderSelectionScripts.source(),
      );
      expect(doc.contains('<!DOCTYPE html>'), isTrue);
      expect(doc.contains('flex-direction:row'), isTrue);
      expect(doc.contains('direction:rtl'), isTrue);
      // 内联选词 JS 源进文档
      expect(doc.contains('window.fushiSelection'), isTrue);
      // 调 selectText 前必须 null-guard bridge
      expect(doc.contains('window.flutter_inappwebview'), isTrue);
      expect(doc.contains('selection.selectFromPosition(node, 0, 40, x, y)'),
          isTrue,
          reason: '字符区域命中后必须带 maxLength=40 进入统一查词管线');
      // 唯一一个 pointerup 监听
      expect('pointerup'.allMatches(doc).length, 1,
          reason: '全文档恰好一个 pointerup 监听（C1 收敛不变式）');
    });

    test('spread 视口裁剪 + translateX 翻页机（ERRATA C1）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: ReaderSelectionScripts.source(),
        pageSpreadIndices: <int>[0, 1],
        currentSpread: 1,
      );
      // 外层固定视口 overflow:hidden（只显示当前跨页）。
      expect(doc.contains('#manga-viewport{overflow:hidden'), isTrue,
          reason: 'spread 必须有 overflow:hidden 视口裁剪');
      expect(doc.contains('id="manga-viewport"'), isTrue);
      // strip 用 translateX 平移；翻页机 + 恢复定位函数存在。
      expect(doc.contains('__mangaApplyTranslate'), isTrue,
          reason: 'spread 必须有 translateX 定位函数');
      expect(doc.contains('translateX'), isTrue);
      // 翻页手势报 onMangaTurn。
      expect(doc.contains('onMangaTurn'), isTrue,
          reason: 'spread swipe 必须报 onMangaTurn');
      // 恢复定位用到 currentSpread=1。
      expect(RegExp(r'CURRENT\s*=\s*1').hasMatch(doc), isTrue,
          reason: '恢复定位必须用 currentSpread');
      // 每页带 data-spread 标注（供 JS 按跨页分组）。
      expect(doc.contains('data-spread="0"'), isTrue);
      expect(doc.contains('data-spread="1"'), isTrue);
    });

    test('裸图单击不打开大图，OCR 区单击或 Shift 悬停都能查词', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page],
        <String>['p.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: ReaderSelectionScripts.source(),
        pageSpreadIndices: <int>[0],
      );
      expect(doc.contains('onImageTap'), isFalse,
          reason: '裸图单击必须留在阅读器，不再打开独立大图');
      expect(doc.contains("b.callHandler('onTapEmpty')"), isTrue);
      expect(doc.contains('function _hitOcrChar(x, y)'), isTrue);
      expect(doc.contains('r.left - 4'), isTrue,
          reason: '不同缩放下都必须保留 Niratan 的 4 屏幕像素命中余量');
      expect(doc.contains('area < bestArea'), isTrue,
          reason: '重叠字符区域必须选择面积最小者');
      expect(doc.contains('selection.selectFromPosition(node, 0, 40, x, y)'),
          isTrue,
          reason: '必须从精确命中的字符节点发起现有查词管线');
      expect(doc.contains('_selectOcrChar(e.clientX, e.clientY, true)'), isTrue,
          reason: 'Shift 悬停必须复用同一精确字符命中路径');
      expect(doc.contains('if (!e.shiftKey)'), isTrue);
      // 收敛不变式：恰好一个 pointerup 监听。
      expect("addEventListener('pointerup'".allMatches(doc).length, 1,
          reason: '全文档恰好一个 pointerup 监听（C1 收敛不变式）');
      expect(doc.contains('__mangaReplaceOcr'), isTrue,
          reason: '后台 OCR 必须能逐页热替换透明文字层');
    });

    test('webtoon → 竖向堆叠（column）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page],
        <String>['manga.local/0/p001.jpg'],
        mode: MangaReadingMode.webtoon,
        spreadDirection: 'rtl',
        inlineSelectionJs: ReaderSelectionScripts.source(),
      );
      expect(doc.contains('flex-direction:column'), isTrue);
      // webtoon 滚动近边缘报 onMangaScroll（ERRATA C1）。
      expect(doc.contains('onMangaScroll'), isTrue,
          reason: 'webtoon 滚动必须报 onMangaScroll');
      // webtoon 不裁 spread 视口（靠文档竖滚）。
      expect(doc.contains('#manga-viewport{overflow:hidden'), isFalse,
          reason: 'webtoon 不应有 spread 视口裁剪');
      // webtoon 模式不报 spread 翻页。
      expect(doc.contains('onMangaTurn'), isTrue,
          reason: '手势机仍内联（IS_WEBTOON 闸门内部不触发翻页）');
    });

    test('spread 双页跨页：固定视口容器内完整居中', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
        pageSpreadIndices: <int>[0, 0],
        pagesPerSpread: <int>[2, 2], // 同一双页跨页
      );
      expect('width:min(50vw,50vh)'.allMatches(doc).length, 2,
          reason: '双页各自受 50vw 与 100vh 双重约束');
      expect(doc.contains('#manga-viewport{overflow:hidden'), isTrue);
      expect(doc.contains('class="manga-spread" data-spread="0"'), isTrue);
      expect(
          doc.contains('width:100vw;height:100vh;align-items:center;'
              'justify-content:center'),
          isTrue,
          reason: '每个 spread 必须有独立的全视口居中槽');
    });

    test('spread 单页跨页：每页在独立 100vw 容器内 contain', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'ltr',
        inlineSelectionJs: '',
        pageSpreadIndices: <int>[0, 1],
        pagesPerSpread: <int>[1, 1], // 两个独立单页跨页
      );
      expect('width:min(100vw,50vh)'.allMatches(doc).length, 2);
      expect('class="manga-spread"'.allMatches(doc).length, 2,
          reason: '两个单页 spread 应各有一个固定视口容器');
    });

    // HIGH-1：webtoon scroll 报**页内** fraction（(scrollY-offsetTop)/offsetHeight），
    // 与 __mangaScrollToSpread 恢复口径统一；绝非文档全局 y/docH。
    test('webtoon scroll 报页内 fraction（HIGH-1），非文档全局', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.webtoon,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
      );
      // 页内归一化：(y - page.offsetTop) / page.offsetHeight。
      expect(doc.contains('pages[i].offsetTop'), isTrue,
          reason: 'fraction 必须按视口顶部所在页的 offsetTop 算页内偏移');
      expect(doc.contains('pages[i].offsetHeight'), isTrue,
          reason: 'fraction 分母必须是该页 offsetHeight（页内口径）');
      // 旧的文档全局口径（scrollHeight - vh 当分母）必须移除。
      expect(doc.contains('scrollHeight - vh'), isFalse,
          reason: 'webtoon fraction 不得再用文档全局口径（scrollHeight-vh）');
      // 恢复函数仍按页内 fraction 微调。
      expect(doc.contains('__mangaScrollToSpread'), isTrue);
      expect(doc.contains('page.offsetTop + (fraction'), isTrue,
          reason: '恢复定位必须 page.offsetTop + fraction*page.offsetHeight（同口径）');
    });

    // BUG-051：桌面鼠标三种自然操作（滚轮/拖动/键盘）在 spread 模式全失效。
    // ① spread 必须监听 wheel→onMangaTurn（overflow:hidden 视口下滚轮本是死操作，
    //    复用为桌面 swipe 等价物）；② webtoon 不接 wheel→翻页（保留原生竖滚）；
    // ③ 禁用 user-select/user-drag + dragstart preventDefault，消除拖动残影「秃瓢」。
    test('spread 接 wheel→onMangaTurn 且 IS_WEBTOON=false 闸门放行（BUG-051）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
        pageSpreadIndices: <int>[0, 1],
      );
      // wheel 监听内联存在，且被 `if (!IS_WEBTOON) {` 闸门包裹（闸门在监听注册之前）。
      final int wheelIdx = doc.indexOf("addEventListener('wheel'");
      final int spreadWheelIdx =
          doc.indexOf("addEventListener('wheel'", wheelIdx + 1);
      final int gateIdx = doc.lastIndexOf('if (!IS_WEBTOON) {', spreadWheelIdx);
      expect(gateIdx >= 0, isTrue, reason: 'wheel 必须有 if(!IS_WEBTOON) 闸门');
      expect(spreadWheelIdx > gateIdx, isTrue,
          reason: 'wheel 监听必须在 !IS_WEBTOON 闸门之内');
      // spread → IS_WEBTOON=false → 运行时闸门放行，滚轮翻页生效。
      expect(doc.contains('var IS_WEBTOON = false'), isTrue,
          reason: 'spread 必须 IS_WEBTOON=false（滚轮翻页生效）');
      // wheel 回调必须 preventDefault（overflow:hidden 视口下消除无操作反馈）并按
      // deltaY 符号报 next/prev。
      expect(doc.contains('e.preventDefault()'), isTrue);
      expect(doc.contains("dir > 0 ? 'next' : 'prev'"), isTrue,
          reason: 'wheel 必须按滚动方向报 next/prev');
      // 翻页触发按**累计位移**而非「一个事件 = 一页」：鼠标一格立即翻，触控板碎
      // delta 攒够才翻。旧实现首个事件就翻 + 320ms 全禁，滚轮上限约 3 页/秒。
      expect(doc.contains('_wheelAccum'), isTrue,
          reason: '滚轮翻页必须按累计 delta 触发，不能一个事件翻一页');
      expect(doc.contains('_wheelLock = false; }, 110)'), isTrue,
          reason: '滚轮合并窗口 110ms（旧 320ms 把翻页上限压到约 3 页/秒）');
    });

    test('webtoon IS_WEBTOON=true 运行时跳过 wheel→翻页（保留原生竖滚，BUG-051）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.webtoon,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
      );
      // wheel 源码内联（与 onMangaTurn 同样常驻），但 IS_WEBTOON=true 让
      // if(!IS_WEBTOON) 闸门在运行时跳过滚轮翻页 → 不抢 WebView 原生竖滚。
      expect(doc.contains('var IS_WEBTOON = true'), isTrue,
          reason: 'webtoon 必须 IS_WEBTOON=true（运行时跳过滚轮翻页闸门）');
    });

    test('spread + webtoon 都禁用原生选区/拖拽残影「秃瓢」（BUG-051）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      for (final MangaReadingMode mode in <MangaReadingMode>[
        MangaReadingMode.spread,
        MangaReadingMode.webtoon,
      ]) {
        final String doc = mangaWindowDocument(
          <MokuroImage>[page],
          <String>['a.jpg'],
          mode: mode,
          spreadDirection: 'rtl',
          inlineSelectionJs: '',
        );
        // 文字选区禁用（查词走坐标式 DOM 读取，不依赖原生选区，故安全）。
        expect(doc.contains('user-select:none'), isTrue,
            reason: '$mode：必须禁用原生文字选区');
        // 图片拖拽禁用 + dragstart 兜底 preventDefault。
        expect(doc.contains('user-drag:none'), isTrue,
            reason: '$mode：必须禁用原生图片拖拽');
        expect(
            RegExp(r"addEventListener\(\s*'dragstart'").hasMatch(doc), isTrue,
            reason: '$mode：必须 preventDefault dragstart 兜底消除残影');
      }
    });

    test('spread RTL 只反转组内页序，根 strip 保持 LTR 稳定几何', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String docRtl = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
      );
      // 同一个 spread 内部的两页 DOM 顺序不变（左右由 CSS direction 翻）；根 strip
      // 保持 LTR，让 offsetLeft 恒为 100vw 的整数倍。跨 spread 的排列顺序另见
      // 「spread RTL 的 strip 几何倒序」。
      expect(docRtl.indexOf('a.jpg') < docRtl.indexOf('b.jpg'), isTrue);
      expect(
          docRtl.contains('#manga-root{display:flex;flex-direction:row;'
              'direction:ltr;'),
          isTrue);
      expect(docRtl.contains('justify-content:center;direction:rtl'), isTrue);

      final String docLtr = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'ltr',
        inlineSelectionJs: '',
      );
      expect(docLtr.contains('justify-content:center;direction:ltr'), isTrue);
      expect(docLtr.contains('direction:rtl'), isFalse);
    });

    test('spread RTL 的 strip 几何倒序：下一跨页在左，翻页动画方向才对', () {
      final MokuroImage page = _pageWithTwoBlocks();
      List<int> spreadOrderOf(String doc) {
        // 只取 spread 容器：每页的 .manga-page 也带 data-spread，混进来会得到
        // [2,2,1,1,0,0] 这种成对序列。
        final RegExp re = RegExp(r'class="manga-spread" data-spread="(\d+)"');
        return re
            .allMatches(doc)
            .map((RegExpMatch m) => int.parse(m.group(1)!))
            .toList();
      }

      final String docRtl = mangaWindowDocument(
        <MokuroImage>[page, page, page],
        <String>['a.jpg', 'b.jpg', 'c.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        pageSpreadIndices: const <int>[0, 1, 2],
        inlineSelectionJs: '',
      );
      // RTL：spread 2 排在最左（offsetLeft 最小），所以「前进」= 画面向右滑、新页
      // 从左边进——与 tap zone / 方向键早已按 RTL 镜像的输入语义一致。
      // 修复前这里是 [0, 1, 2]：输入镜像了、视觉没镜像，按前进键画面往后退的方向滑。
      expect(spreadOrderOf(docRtl), <int>[2, 1, 0]);

      final String docLtr = mangaWindowDocument(
        <MokuroImage>[page, page, page],
        <String>['a.jpg', 'b.jpg', 'c.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'ltr',
        pageSpreadIndices: const <int>[0, 1, 2],
        inlineSelectionJs: '',
      );
      expect(spreadOrderOf(docLtr), <int>[0, 1, 2]);

      // 两个方向都必须保持根 strip 的 LTR 几何：offsetLeft 得是稳定的 100vw 整数倍，
      // 否则 __mangaApplyTranslate 的 -offsetLeft 口径失效（这正是当初钉死 LTR 的原因）。
      for (final String doc in <String>[docRtl, docLtr]) {
        expect(
            doc.contains('#manga-root{display:flex;flex-direction:row;'
                'direction:ltr;'),
            isTrue);
      }
    });

    test('swipe 方向随 RTL 镜像，与 strip 几何同源', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page],
        <String>['a.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
      );
      // 拖动内容向左露出的是 strip 右边那一跨页；RTL 倒序后右边是 prev，所以判据
      // 必须含 IS_RTL。修复前是写死的 `dx < 0 ? 'next' : 'prev'`。
      expect(doc.contains("(swipeRight === IS_RTL) ? 'next' : 'prev'"), isTrue,
          reason: 'swipe 必须按 IS_RTL 镜像，否则与倒序后的 strip 几何相反');
      expect(doc.contains("dx < 0 ? 'next' : 'prev'"), isFalse,
          reason: '不许再有不看阅读方向的写死 swipe 判据');
    });

    test('键盘平移导出 __mangaPanBy，且平移被钳制在视口内', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page],
        <String>['a.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
      );
      // 视口比例入参 + 「视野怎么动」的符号（故 _panBy 取负）。
      expect(doc.contains('window.__mangaPanBy = function(fx, fy){'), isTrue,
          reason: '方向键平移要走导出的 JS 入口，而不是在 JS 里自己监听键盘');
      expect(
          doc.contains(
              '_panBy(-window.innerWidth * fx, -window.innerHeight * fy);'),
          isTrue);
      // 钳制：PAN_X ∈ [vw*(1-ZOOM), 0]，spread 的 PAN_Y 同理。此前完全没有边界，
      // 拖动/方向键能把页面推出视口且回不来。
      expect(doc.contains('function _clampPan(){'), isTrue);
      expect(
          doc.contains('var minX = window.innerWidth * (1 - ZOOM);'), isTrue);
      expect(doc.contains('if (canvasMoved) { _clampPan(); _applyCanvas(); }'),
          isTrue,
          reason: '拖动/惯性/方向键三条平移路径必须共用同一条钳制规则');
      // ZOOM<=1 时位置归 _recenterPan 居中，钳制必须让路，否则缩小后页面被顶到左边。
      expect(doc.contains('if (ZOOM <= 1) return;'), isTrue);
    });

    test('Lens regions render transparent character hit targets', () {
      const MokuroImage page = MokuroImage(
        url: 'p.jpg',
        size: Size(100, 200),
        blocks: <MokuroBlock>[
          MokuroBlock(
            rectangle: Rect.fromLTWH(10, 20, 40, 20),
            isVertical: false,
            fontSize: 10,
            zIndex: 0,
            lines: <String>['日本'],
            regions: <MangaOcrTextRegion>[
              MangaOcrTextRegion(
                rectangle: Rect.fromLTWH(10, 20, 20, 20),
                utf16Start: 0,
                utf16End: 1,
              ),
            ],
          ),
        ],
      );
      final String doc = mangaWindowDocument(
        <MokuroImage>[page],
        <String>['p.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
      );
      expect(doc.contains('class="ocr-char"'), isTrue);
      expect(doc.contains('>日</span>'), isTrue);
      expect(doc.contains('color:transparent;pointer-events:auto'), isTrue);
      expect(
          doc.contains(
              '.ocr-char{position:absolute;display:block;overflow:hidden;'),
          isTrue,
          reason: '字符命中层的公共布局应只在文档 CSS 中声明一次');
    });

    test('online image load replaces bootstrap dimensions with natural size',
        () {
      final String doc = mangaWindowDocument(
        <MokuroImage>[
          const MokuroImage(
            url: 'online.jpg',
            size: Size(1000, 1400),
            blocks: <MokuroBlock>[],
          ),
        ],
        <String>['online.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
      );

      expect(doc.contains('window.__mangaUpdatePageGeometry'), isTrue);
      expect(doc.contains('image.naturalWidth'), isTrue);
      expect(doc.contains('image.naturalHeight'), isTrue);
      expect(doc.contains("page.style.aspectRatio = width + ' / ' + height"),
          isTrue);
      expect(doc.contains("page.style.width =\n        'min('"), isTrue);
    });

    test('desktop zoom and right-button drag/menu contract is embedded', () {
      final String doc = mangaWindowDocument(
        <MokuroImage>[_pageWithTwoBlocks()],
        <String>['p.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
        zoomPercent: 100,
      );
      // 缩放边界由参数注入（默认 50%..400%），不再是写死的 0.5/2。
      expect(doc.contains('var ZOOM_MIN = 0.5;'), isTrue);
      expect(doc.contains('var ZOOM_MAX = 4.0;'), isTrue);
      expect(doc.contains('rightDrag.startX) > 4'), isTrue);
      expect(doc.contains("callHandler('onMangaContextMenu'"), isTrue);
      expect(doc.contains("callHandler('onMangaZoomChanged'"), isTrue);
      expect(doc.contains('e.ctrlKey || e.metaKey'), isTrue);
      // 滚轮缩放必须是**对齐到 ZOOM_STEP 网格的定量步进**，与右键菜单的 ±10 个
      // 百分点同口径。曾经用过按 delta 幅值的乘法 `Math.exp(steps * 0.2 * ZOOM_SENS)`，
      // 那让「一格缩多少」取决于本机 deltaY 的绝对值（WebView2 高 DPI 上一格不是
      // 100，BUG-1065 实测 67），用户实测一格约 112%、既非设计值也无法预期。
      expect(
          doc.contains(
              'var ZOOM_STEP = Math.max(1, Math.round(10 * ZOOM_SENS));'),
          isTrue,
          reason: '滚轮步长必须是 10 个百分点（乘灵敏度）的定量网格，不能是乘法缩放');
      expect(doc.contains('Math.exp('), isFalse,
          reason: '乘法指数缩放已废弃：一格缩多少不能取决于本机 deltaY 绝对值');
      expect(
          doc.contains('(Math.floor(cur / ZOOM_STEP) + 1) * ZOOM_STEP'), isTrue,
          reason: '放大必须对齐到网格，否则捏合留下的非整值会一路歪下去');
      expect(
          doc.contains('(Math.ceil(cur / ZOOM_STEP) - 1) * ZOOM_STEP'), isTrue,
          reason: '缩小必须对齐到网格');
      expect(doc.contains('var cur = Math.round(ZOOM * 1000) / 10;'), isTrue,
          reason: '必须先消掉浮点毛刺，否则 1.2000000000000002 缩小一步会原地不动');
      // 「一格」的判定复用翻页滚轮的累计口径（阈值 40 + 反向清账）：鼠标一格无论
      // deltaY 是 57/67/100 都 >=40 恒好一步，触控板碎 delta 攒够才走。
      expect(doc.contains('if (_zoomAccum < 40) return 0;'), isTrue,
          reason: '必须按累计位移判定一格，否则触控板碎 delta 要么失灵要么暴走');
      expect(
          doc.contains(
              'if (dir !== _zoomDir) { _zoomAccum = 0; _zoomDir = dir; }'),
          isTrue,
          reason: '反向必须立刻清账，否则来回滚会被上一方向的余量吃掉');
      expect(doc.contains('e.deltaMode === 1'), isTrue,
          reason: 'deltaMode 必须归一化，否则行/页模式步长完全不同');
    });

    test('缩放范围与灵敏度随参数注入，触屏有捏合缩放', () {
      final String doc = mangaWindowDocument(
        <MokuroImage>[_pageWithTwoBlocks()],
        <String>['p.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
        zoomPercent: 100,
        zoomMaxPercent: 300,
        zoomSensitivity: 200,
      );
      expect(doc.contains('var ZOOM_MAX = 3.0;'), isTrue);
      expect(doc.contains('var ZOOM_SENS = 2.0;'), isTrue);
      // 触屏此前完全无法缩放：viewport 是 user-scalable=no（必须，否则浏览器原生
      // 缩放与 #manga-canvas 的 transform 打架），而 JS 侧没有任何多指处理。
      expect(doc.contains("e.pointerType === 'touch'"), isTrue,
          reason: '必须自己处理触点，浏览器原生缩放被 user-scalable=no 禁掉了');
      expect(doc.contains('_pinchGeom'), isTrue, reason: '必须有双指捏合几何');
      expect(doc.contains('Math.pow(g.dist / pinch.dist, ZOOM_SENS)'), isTrue,
          reason: '灵敏度设置声明覆盖滚轮与捏合，pinch 比率也必须应用 ZOOM_SENS');
      expect(doc.contains("addEventListener('pointermove'"), isTrue,
          reason: '捏合需要 pointermove 才能跟手');
    });

    test('点击边缘翻页可关，且方向随 RTL 镜像', () {
      String docFor({required bool tapZonePaging, required String direction}) =>
          mangaWindowDocument(
            <MokuroImage>[_pageWithTwoBlocks()],
            <String>['p.jpg'],
            mode: MangaReadingMode.spread,
            spreadDirection: direction,
            inlineSelectionJs: '',
            tapZonePaging: tapZonePaging,
          );
      final String on = docFor(tapZonePaging: true, direction: 'rtl');
      expect(on.contains('var TAP_ZONE_PAGING = true;'), isTrue);
      expect(on.contains('var IS_RTL = true;'), isTrue);
      // RTL 下左边缘前进（LTR 相反）——同一份 JS 靠 IS_RTL 分流。
      expect(on.contains("IS_RTL ? 'next' : 'prev'"), isTrue);
      final String off = docFor(tapZonePaging: false, direction: 'ltr');
      expect(off.contains('var TAP_ZONE_PAGING = false;'), isTrue);
      expect(off.contains('var IS_RTL = false;'), isTrue);
    });

    test('翻页动画偏好决定 #manga-root 过渡声明', () {
      String docFor(MangaPageAnimation animation) => mangaWindowDocument(
            <MokuroImage>[_pageWithTwoBlocks()],
            <String>['p.jpg'],
            mode: MangaReadingMode.spread,
            spreadDirection: 'rtl',
            inlineSelectionJs: '',
            pageAnimation: animation,
          );
      expect(docFor(MangaPageAnimation.slide).contains('transition:transform '),
          isTrue);
      // none = 完全不声明过渡（要极限响应的用户）。
      final String none = docFor(MangaPageAnimation.none);
      expect(none.contains('transition:transform '), isFalse);
      expect(none.contains('transition:opacity '), isFalse);
      // fade 只过渡 opacity，位移在淡出后瞬时完成，否则会同时看到滑动与淡入淡出。
      final String fade = docFor(MangaPageAnimation.fade);
      expect(fade.contains('transition:opacity '), isTrue);
      expect(fade.contains('transition:transform '), isFalse);
      expect(fade.contains("PAGE_ANIM !== 'fade'"), isTrue);
    });

    test('window document exposes its navigation generation', () {
      final String doc = mangaWindowDocument(
        <MokuroImage>[_pageWithTwoBlocks()],
        <String>['p.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
        currentSpread: 7,
        documentGeneration: 42,
      );
      expect(doc.contains('window.__mangaDocumentGeneration=42;'), isTrue);
      expect(doc.contains('var CURRENT = 7;'), isTrue);
    });

    test('稳定图片 strip 只物化指定页面的密集 OCR 命中层', () {
      final String doc = mangaWindowDocument(
        <MokuroImage>[_pageWithTwoBlocks(), _pageWithTwoBlocks()],
        <String>['p0.jpg', 'p1.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'ltr',
        inlineSelectionJs: '',
        pageSpreadIndices: const <int>[0, 1],
        pagesPerSpread: const <int>[1, 1],
        pageNumbers: const <int>[0, 1],
        ocrPageIndices: const <int>{1},
      );
      expect('class="manga-page"'.allMatches(doc).length, 2,
          reason: '图片页全部常驻，翻页不应重建 WebView 文档');
      expect('class="ocr-char"'.allMatches(doc).length, 9,
          reason: '只有当前页面物化字符节点，避免密集杂志把 loadData 撑爆');
      expect(
          doc.contains('data-page="0" data-pw="1000" data-ph="2000" '
              'data-ocr-loaded="0"'),
          isTrue);
      expect(
          doc.contains('data-page="1" data-pw="1000" data-ph="2000" '
              'data-ocr-loaded="1"'),
          isTrue);
    });

    // BUG-1701：手机端「放大缩小跟上下滑动混了」的根因有两条，这一组把两个不变式
    // 钉死。① 手势所有权：touch-action 默认 auto 时浏览器在第一个 touchstart 就锁定
    // 原生 pan，pointermove 的 preventDefault 按 Pointer Events 规范并不阻止滚动，
    // 于是捏合与竖向滚动同时发生、滚动接管后还会取消指针序列把捏合状态清掉。
    // ② 纵向所有权：webtoon 是竖滚文档，纵向位置只能由 window.scrollY 表达；此前
    // PAN_Y 也参与，一次缩放同时产生 transform 位移和滚动位移。
    group('BUG-1701 触屏缩放与竖向滚动的所有权', () {
      String docFor(MangaReadingMode mode, {int zoomPercent = 100}) =>
          mangaWindowDocument(
            <MokuroImage>[_pageWithTwoBlocks()],
            <String>['p.jpg'],
            mode: mode,
            spreadDirection: 'ltr',
            inlineSelectionJs: '',
            zoomPercent: zoomPercent,
          );

      test('touch-action 恒为 none，不再有运行期切换的特例', () {
        for (final MangaReadingMode mode in MangaReadingMode.values) {
          final String doc = docFor(mode);
          expect(doc.contains('touch-action:none;'), isTrue,
              reason: '$mode：手势必须在第一个 touchstart 前就归 JS 独占，'
                  '否则捏合会被原生二指 pan 抢走');
          expect(doc.contains('document.body.style.touchAction'), isFalse,
              reason: '$mode：运行期切换 touch-action 对已开始的手势无效，'
                  '这个特例必须保持消除');
        }
      });

      test('webtoon 纵向位置只由 scrollY 拥有，PAN_Y 恒 0', () {
        final String doc = docFor(MangaReadingMode.webtoon);
        expect(
            doc.contains(
                'PAN_Y = IS_WEBTOON ? 0 : window.innerHeight * (1 - ZOOM) / 2;'),
            isTrue,
            reason: 'webtoon 竖滚文档不得再用 spread 的 PAN_Y 居中公式');
        expect(doc.contains('PAN_Y = IS_WEBTOON ? 0 : ay - localY * ZOOM;'),
            isTrue,
            reason: '缩放锚点补偿在 webtoon 必须写 scrollY 而非 PAN_Y');
        // 位置断言前先确认锚点唯一，避免同形 token 抢走 indexOf 的窗口。
        expect('var IS_WEBTOON = '.allMatches(doc).length, 1,
            reason: 'IS_WEBTOON 只允许一处声明');
        expect(
            doc.indexOf('var IS_WEBTOON = ') <
                doc.indexOf('function _recenterPan()'),
            isTrue,
            reason: '_recenterPan/_applyCanvas 在文档解析期就跑，'
                'IS_WEBTOON 必须先就绪，否则首帧按 spread 公式算 PAN_Y');
      });

      test('webtoon 缩放态下滚动坐标两端都换算 ZOOM', () {
        final String doc = docFor(MangaReadingMode.webtoon);
        expect(
            doc.contains('var top = (page.offsetTop + (fraction || 0) * '
                'page.offsetHeight) * ZOOM;'),
            isTrue,
            reason: 'offsetTop 是布局坐标，scrollTo 收视觉坐标，缺 *ZOOM 会定位错页');
        expect(doc.contains('var y = window.scrollY / ZOOM;'), isTrue,
            reason: 'onMangaScroll 的 fraction 与 offsetTop 同口径，'
                'scrollY 必须换回布局坐标');
        expect(
            doc.contains(
                'var localY = (IS_WEBTOON ? window.scrollY + ay : ay - PAN_Y) '
                '/ ZOOM;'),
            isTrue,
            reason: 'webtoon 的锚点屏幕坐标是 layout*ZOOM - scrollY');
        expect(
            doc.contains(
                'window.scrollTo(0, Math.max(0, localY * ZOOM - ay));'),
            isTrue,
            reason: '捏合后必须把锚点补偿写回 scrollY，否则画面跟着缩放跳走');
      });

      test('原生滚动关掉后 webtoon 竖滚由 JS 自己实现，带惯性', () {
        final String doc = docFor(MangaReadingMode.webtoon);
        expect(doc.contains('window.scrollBy(0, -dy);'), isTrue,
            reason: 'touch-action:none 后单指拖动必须自己驱动竖滚');
        expect(doc.contains('flickVy *= Math.pow(0.002, dt / 1000);'), isTrue,
            reason: '自实现滚动必须补上惯性，否则手感比原生退化');
        expect(doc.contains('if (drag && drag.touch) _startFlick(drag.vy);'),
            isTrue,
            reason: '惯性只给触屏：鼠标松手不该继续滑');
      });

      test('放大态的拖动是平移，不是翻页', () {
        final String doc = docFor(MangaReadingMode.spread, zoomPercent: 150);
        expect(doc.contains('if (!IS_WEBTOON && ZOOM <= 1 &&'), isTrue,
            reason: 'ZOOM>1 时拖动已被 _panBy 消费为平移，再判 swipe 会每次平移都翻页');
        expect(doc.contains('function _panBy(dx, dy)'), isTrue,
            reason: '放大后必须能平移查看页面各处');
      });
    });
  });
}

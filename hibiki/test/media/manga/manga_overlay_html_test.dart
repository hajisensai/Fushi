import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/manga_overlay_html.dart';
import 'package:hibiki/src/media/manga/manga_reading_mode.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';

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
      // 取自 BUG-1229 用户实际 Lens 缓存 page-000003.jpg 的块形状：
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

    test('选区 payload 读取整句、方向，并以整组边界作为弹窗锚点', () {
      final String scripts = ReaderSelectionScripts.source();
      expect(scripts.contains("closest('[data-manga-sentence]')"), isTrue);
      expect(scripts.contains("getAttribute('data-ocr-orientation')"), isTrue);
      expect(
        scripts.contains(
          "querySelectorAll(\n"
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
      expect(doc.contains('window.hoshiSelection'), isTrue);
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
      expect(doc.contains("d > 0 ? 'next' : 'prev'"), isTrue,
          reason: 'wheel 必须按滚动方向报 next/prev');
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
      // DOM 顺序不变，根 strip 保持 LTR；每个 spread 内部用 RTL 翻转双页。
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

    test('desktop zoom and right-button drag/menu contract is embedded', () {
      final String doc = mangaWindowDocument(
        <MokuroImage>[_pageWithTwoBlocks()],
        <String>['p.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
        zoomPercent: 100,
      );
      expect(doc.contains('Math.min(2, Math.max(0.5'), isTrue);
      expect(doc.contains('rightDrag.startX) > 4'), isTrue);
      expect(doc.contains("callHandler('onMangaContextMenu'"), isTrue);
      expect(doc.contains("callHandler('onMangaZoomChanged'"), isTrue);
      expect(doc.contains('e.ctrlKey || e.metaKey'), isTrue);
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
  });
}

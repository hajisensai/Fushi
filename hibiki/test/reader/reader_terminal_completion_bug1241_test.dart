import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';
import 'package:hibiki/src/reader/reader_visual_novel_scripts.dart';

void main() {
  test('all reader engines expose a physical terminal predicate', () {
    final String paged = ReaderPaginationScripts.paginatedShellSource();
    final String continuous = ReaderPaginationScripts.continuousShellSource();
    final String vn = ReaderVisualNovelScripts.vnShellScript();

    expect(
      paged,
      contains('this.getPagePosition(context) >= metrics.maxScroll - 1'),
      reason: '分页末页必须读 terminal clamp，不能用首字符分数猜 99.9%',
    );
    expect(
      continuous,
      contains('root.scrollTop >= maxY - 1'),
      reason: '连续横排必须读物理滚动终点',
    );
    expect(
      continuous,
      contains('Math.abs(window.scrollX || root.scrollLeft || 0) >= maxX - 1'),
      reason: '连续竖排必须兼容 vertical-rl 的负 scrollX',
    );
    expect(
      vn,
      contains('this.currentScreenIndex >= this.screens.length - 1'),
      reason: 'VN 完成态必须以末屏索引为准',
    );
  });

  test('host clamps only a physical terminal snapshot to total', () {
    final String webview = File(
      'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
    ).readAsStringSync();
    expect(
      webview,
      contains("typeof r.isAtEnd === 'function' && r.isAtEnd()"),
    );
    expect(
      webview,
      contains('(atEnd ? total : Math.round(p * total))'),
      reason: '只有真实末端变 100%，中间页仍保留原字符级进度',
    );
    expect(
      webview,
      contains("return mediaAtEnd ? '1,1,-1' : '';"),
      reason: '纯图片末章也必须在真实末页生成完成快照，不能永远停在 fallback UI',
    );
  });
}

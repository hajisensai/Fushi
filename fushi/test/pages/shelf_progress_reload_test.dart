import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';

/// 书架对 `reader_positions` 写入的响应：只在书架真被看着时立刻重算，否则记一笔
/// 等切回书架再算（对端推来的进度不经本机同步收尾，书架靠这条表信号刷新）。
void main() {
  test('书架在前、没有书开着 → 立刻重算', () {
    expect(
      shouldReloadShelfProgressNow(shelfVisible: true, mediaOpen: false),
      isTrue,
    );
  });

  test('书开着（阅读器翻页写位置）→ 推迟，关书由 onSourceExit 失效', () {
    expect(
      shouldReloadShelfProgressNow(shelfVisible: true, mediaOpen: true),
      isFalse,
    );
  });

  test('书架不在前 → 推迟到切回书架', () {
    expect(
      shouldReloadShelfProgressNow(shelfVisible: false, mediaOpen: false),
      isFalse,
    );
  });
}

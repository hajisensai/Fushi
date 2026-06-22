import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-690 / BUG-399：桌面拖窗口边框 resize 后阅读器文字渲染错乱、不自动重排，翻页
/// 才恢复。根因——唯一 resize→重排入口是 didChangeMetrics→_syncPageSize，但 Windows
/// 拖边框时 didChangeMetrics / MediaQuery.size 更新滞后，JS 分页几何缓存（--page-width/
/// height / this.pageWidth / _contW / paginationMetrics）无人失效 → 错位。
///
/// 修复——在阅读器树内（HibikiAppUiScaleNeutralizer 之下、WebView 子树外层）包一个
/// **透明** LayoutBuilder：builder 零几何变换，只读 constraints 交给尾沿防抖
/// （Timer 50ms）触发 _syncPageSize，timer 在 dispose 取消。constraints 与
/// _syncPageSize 读的 MediaQuery.size 同坐标空间，靠 _lastSyncedWidth/Height 基线去重。
///
/// 真正的 WebView2 文字错乱是渲染产物，widget 测试照不到；本组用源码扫描锁定接线，
/// 防回归（运行时序列另由纯谓词 reader_viewport_repaginate_test 覆盖）。
void main() {
  group('TODO-690 reader window-resize repaginate 接线守卫', () {
    late String src;

    setUpAll(() {
      src = readReaderPageSource();
    });

    test('build 在 reader 树外层包透明 LayoutBuilder 并调 _onReaderConstraintsChanged',
        () {
      // LayoutBuilder 必须在 build 里包住 reader 子树（return Actions 前），builder
      // 第一件事就是把 constraints 交给 resize 通道（零几何变换，原样返回子树）。
      final int idxBuild = src.indexOf('Widget build(BuildContext context) {');
      expect(idxBuild, greaterThan(0), reason: 'build 方法必须存在');
      final int idxLayoutBuilder =
          src.indexOf('return LayoutBuilder(', idxBuild);
      expect(idxLayoutBuilder, greaterThan(idxBuild),
          reason: 'build 必须用透明 LayoutBuilder 包裹 reader 子树（TODO-690 resize 通道）');
      final int idxConstraintsCall = src.indexOf(
          '_onReaderConstraintsChanged(constraints)', idxLayoutBuilder);
      final int idxReturnActions =
          src.indexOf('return Actions(', idxLayoutBuilder);
      expect(idxConstraintsCall, greaterThan(idxLayoutBuilder),
          reason:
              'LayoutBuilder.builder 必须把 constraints 交给 _onReaderConstraintsChanged');
      expect(idxReturnActions, greaterThan(idxConstraintsCall),
          reason:
              'builder 必须先调 _onReaderConstraintsChanged 再返回原 reader 子树（零几何变换）');
    });

    test('_onReaderConstraintsChanged 用纯谓词判定 + Timer 50ms 尾沿防抖调 _syncPageSize',
        () {
      final int idx = src.indexOf(
          'void _onReaderConstraintsChanged(BoxConstraints constraints) {');
      expect(idx, greaterThan(0), reason: '_onReaderConstraintsChanged 必须存在');
      final String body = src.substring(idx, idx + 1200);
      // 判定复用纯谓词，不另写阈值（保 BUG-210 的 1px 容差/lastWidth>0 门控）。
      expect(body.contains('readerLayoutResizeNeedsRepaginate('), isTrue,
          reason:
              '必须用纯谓词 readerLayoutResizeNeedsRepaginate 判定（复用 1px 容差，不另写阈值）');
      // 尾沿防抖：先取消旧 timer 再起新的，超阈值才起。
      final int idxCancel = body.indexOf('_resizeRepaginateDebounce?.cancel()');
      final int idxNewTimer =
          body.indexOf('_resizeRepaginateDebounce = Timer(');
      expect(idxCancel, greaterThanOrEqualTo(0),
          reason: '起新 timer 前必须取消旧 timer（尾沿防抖，拖拽期不堆积）');
      expect(idxNewTimer, greaterThan(idxCancel),
          reason: '取消旧 timer 后才起新的 Timer');
      expect(body.contains('Duration(milliseconds: 50)'), isTrue,
          reason: '尾沿防抖窗口为 ~50ms（拖拽停手后最终尺寸落一次重排）');
      // timer 回调直接调 _syncPageSize（含 readerViewportNeedsRepaginate 判定与基线去重）。
      expect(body.contains('if (mounted) _syncPageSize()'), isTrue,
          reason:
              'timer 回调必须 mounted 守卫后调 _syncPageSize（不另起 updatePageSize 调用）');
      // 绝不在 builder/判定里 Future.delayed（会泄漏/重入）——用 Timer 字段。
      expect(body.contains('Future.delayed'), isFalse,
          reason: '禁止 Future.delayed（会泄漏 timer/重入）；尾沿防抖必须用可取消的 Timer 字段');
    });

    test('防抖 timer 在 dispose 取消（不泄漏）', () {
      final int idxDispose = src.indexOf('void dispose() {');
      expect(idxDispose, greaterThan(0), reason: 'dispose 必须存在');
      final int idxSuperDispose = src.indexOf('super.dispose()', idxDispose);
      expect(idxSuperDispose, greaterThan(idxDispose));
      final String body = src.substring(idxDispose, idxSuperDispose);
      expect(body.contains('_resizeRepaginateDebounce?.cancel()'), isTrue,
          reason: 'dispose 必须取消 _resizeRepaginateDebounce，否则 timer 在页面销毁后回调泄漏');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// BUG-1329 的静态守卫：下载 / 导入字幕后，字幕轨列表必须**当场**多出那一条，而不是
/// 作废整份枚举缓存、等一个在面板已经开着时永远不会再来的「进入字幕分类」事件。
///
/// media_kit 跑不了 headless、ffmpeg 枚举也不能在单测里真跑，所以这里锁调用点契约：
///  - 两个落盘点（Jimaku 下载 / 外挂导入）都调 `_registerImportedSubtitleSource`；
///  - 旧的 `_invalidateSubtitleMenuSourcesCache`（清缓存 key 等下次重探）彻底消失；
///  - `_subtitleMenuLoading` 的每一个置真点都有配对的收敛路径，不存在「抛错就永远转圈」。
void main() {
  final String src = readVideoHibikiSource();

  String region(String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  test('BUG-1329: Jimaku 下载完把新档就地并入字幕轨列表', () {
    final String body = region(
      'Future<void> _openJimakuDialog(VideoPlayerController controller) async {',
      'Future<void> _pickAndImportSubtitle(',
    );
    expect(body.contains('_registerImportedSubtitleSource(downloaded)'), isTrue,
        reason: '下载几乎总是从已经打开的「字幕」分类里发起的，只清缓存 key 不会有任何'
            '事件把它重新枚举出来 → 用户看不到自己刚下载的字幕（BUG-1329）');
  });

  test('BUG-1329: 导入外挂字幕后把新档就地并入字幕轨列表', () {
    final String body = region(
      'Future<void> _importExternalSubtitleInner(',
      'void _showSubtitleLoadingOverlay() {',
    );
    expect(body.contains('_registerImportedSubtitleSource(dest)'), isTrue,
        reason: '导入落盘后同样要当场进列表，与 Jimaku 下载走同一条并入路径（BUG-1329）');
  });

  test('BUG-1329: 并入不重探容器、不重置枚举缓存 key', () {
    final String body = region(
      'void _registerImportedSubtitleSource(String path) {',
      '/// 选中某副字幕源',
    );
    expect(body.contains('_subtitleMenuSourcesPath != videoPath'), isTrue,
        reason: '尚未为当前视频枚举过时不该硬塞（首次枚举本就会带上它）');
    expect(body.contains('sameExternalSubtitlePathForMenu('), isTrue,
        reason: '已在列表里的同一路径不能再插一条重复行');
    expect(body.contains('_subtitleMenuSourcesPath = null'), isFalse,
        reason: '并入新档不得作废枚举缓存——那正是「重新 ffmpeg 探整个容器 + 长时间'
            '挂加载条」的来源（BUG-1329 第二个症状）');
    expect(body.contains('_subtitleMenuLoading'), isFalse,
        reason: '就地并入是纯内存操作，不该点亮任何加载态');
  });

  test('BUG-1329: 旧的「清缓存等下次重探」路径已彻底移除', () {
    // 连注释一起断言为零：留着这个名字就意味着还有别的调用点在走旧语义。
    expect(src.contains('_invalidateSubtitleMenuSourcesCache'), isFalse,
        reason: '缓存作废式刷新已被就地并入取代，不得残留（BUG-1329）');
  });

  test('BUG-1329: YouTube 字幕轨 cue 解析抛错也要收掉加载条', () {
    final String body = region(
      'Future<void> _applyYoutubeCaptionTrack(',
      'Future<void> _importExternalSubtitle(',
    );
    final int resolve = body.indexOf('resolveYoutubeCaptionCues(');
    expect(resolve, greaterThanOrEqualTo(0),
        reason: 'missing cue resolve call');
    final int tryIdx = body.lastIndexOf('try {', resolve);
    expect(tryIdx, greaterThanOrEqualTo(0),
        reason: 'cue 解析必须包在 try 里，否则抛错时下面的复位语句谁也走不到');
    final String afterResolve = body.substring(resolve);
    final int finallyIdx = afterResolve.indexOf('} finally {');
    expect(finallyIdx, greaterThanOrEqualTo(0),
        reason: '必须有 finally 收敛加载态（BUG-1329）');
    expect(
      afterResolve
          .substring(finallyIdx)
          .contains('_rebuild(() => _subtitleMenuLoading = false)'),
      isTrue,
      reason: 'finally 里必须真把 _subtitleMenuLoading 复位；否则解析异常后字幕轨区'
          '顶部的进度条永远转下去，且再没有入口能关掉它（BUG-1329）',
    );
  });

  test('BUG-1329: 字幕轨枚举单出口收敛加载态', () {
    final String body = region(
      'Future<void> _ensureSubtitleMenuSourcesLoaded() async {',
      'void _registerImportedSubtitleSource(',
    );
    // 置真恰好一次；置真之后的复位也恰好一次（函数开头远端/无路径分支里的那次
    // `= false` 是清空态复位，不在这条加载链路上，不该被算进来）。
    expect('_subtitleMenuLoading = true'.allMatches(body).length, 1,
        reason: '加载态只应有一个置真点');
    final int truePoint = body.indexOf('_subtitleMenuLoading = true');
    final String afterTrue = body.substring(truePoint);
    expect('_subtitleMenuLoading = false'.allMatches(afterTrue).length, 1,
        reason: '置真之后有多个复位点，正是「某条 return 忘了复位、加载条永远转」的'
            '温床（BUG-1329）；收敛成唯一出口');
  });
}

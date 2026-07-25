import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';

/// 守卫（TODO-160子d / BUG-227 / TODO-291 阶段2）：书架长按 EPUB 书籍菜单的 extraActions
/// 含悬浮字幕入口。TODO-291 阶段2 把该入口从「只切 setShowFloatingLyric 偏好」升级为
/// 「启动该书的后台听书会话」（无正在播用该书启动 + 拉悬浮窗；该书已是活动会话则停止），
/// 走 AppModel.startBackgroundListening / stopBackgroundListening。host 跑不到 dialog
/// 渲染与 Platform 分支，故源码扫描钉接线。
void main() {
  late String src;
  setUpAll(() {
    src = readReaderHistorySource();
  });

  test('extraActions 含悬浮字幕开关 label', () {
    expect(
      src.contains('floating_lyric_toggle_action'),
      isTrue,
      reason: '长按书籍菜单必须有悬浮字幕开关入口。',
    );
  });

  test('书架入口启动/停止后台听书会话（TODO-291 阶段2）', () {
    expect(
      src.contains('_toggleFloatingLyricFromShelf'),
      isTrue,
      reason: '书架入口走专用切换方法。',
    );
    expect(
      src.contains('startBackgroundListening'),
      isTrue,
      reason: '书架入口必须启动该书的后台听书会话（不再只切偏好）。',
    );
    expect(
      src.contains('stopBackgroundListening'),
      isTrue,
      reason: '该书已是活动会话时入口必须能停止后台听书。',
    );
  });

  test('入口门控 Android/Windows（与 isSupported 一致，不删现有入口）', () {
    expect(
      src.contains('Platform.isAndroid || Platform.isWindows'),
      isTrue,
      reason: '悬浮字幕仅 Android/Windows 支持。',
    );
  });

  test('书籍长按动作移除标签按钮但保留其它管理动作', () {
    final String epubActions = _sectionSource(
      src,
      'List<DialogAction> extraActions(MediaItem item) {',
      '  String? _parseBookKey(String mediaIdentifier) =>',
    );
    final String srtActions = _sectionSource(
      src,
      'List<DialogAction> _srtExtraActions(',
      '  Future<void> _showSrtBookDialog(',
    );

    for (final String actions in <String>[epubActions, srtActions]) {
      expect(
        actions,
        isNot(contains('t.tag_label')),
        reason: 'TODO-455 removes the Tag button from book long-press menus.',
      );
      expect(actions, isNot(contains('Icons.sell_outlined')));
    }

    expect(epubActions, contains('t.view_illustrations'));
    expect(epubActions, contains('t.audiobook_import'));
    expect(epubActions, contains('t.profile_book_profile'));
    expect(epubActions, contains('t.book_css_editor_edit_css'));
    expect(epubActions, contains('floating_lyric_toggle_action'));

    // TODO-1191：SRT 卡长按菜单不再列冗余的「选择封面图片」——选封面统一走
    // 「编辑信息」弹窗（MediaItemEditDialogPage 的封面覆盖字段）。
    expect(
      srtActions,
      isNot(contains('t.srt_import_pick_cover')),
      reason: 'TODO-1191：SRT 卡长按菜单移除冗余「选择封面图片」，走编辑信息弹窗。',
    );
    expect(srtActions, contains('t.audio_import'));
    expect(srtActions, contains('t.profile_book_profile'));
    expect(srtActions, contains('t.book_css_editor_edit_css'));
    // TODO-1068：SRT/有声书卡长按菜单对称补悬浮字幕入口，与 EPUB 侧一致。
    expect(
      srtActions,
      contains('floating_lyric_toggle_action'),
      reason: 'SRT/有声书卡长按菜单也必须有悬浮字幕入口（TODO-1068）。',
    );
    expect(
      srtActions,
      contains('_toggleFloatingLyricFromShelf'),
      reason: 'SRT 卡悬浮字幕入口复用 EPUB 侧同一后台听书切换回调。',
    );
    expect(
      srtActions,
      contains('Platform.isAndroid || Platform.isWindows'),
      reason: 'SRT 卡悬浮字幕入口平台门控与 EPUB 侧一致。',
    );
  });

  test('单卡长按菜单含「加入合集」入口，合集详情页语境隐藏', () {
    final String epubActions = _sectionSource(
      src,
      'List<DialogAction> extraActions(MediaItem item) {',
      '  String? _parseBookKey(String mediaIdentifier) =>',
    );
    final String srtActions = _sectionSource(
      src,
      'List<DialogAction> _srtExtraActions(',
      '  Future<void> _showSrtBookDialog(',
    );
    // EPUB 卡：有入口，entryKey 编码与批量三档一致（epub → bookKey），
    // 合集详情页成员卡语境（inCollectionDetail）隐藏。
    expect(epubActions, contains('t.add_to_collection'));
    expect(epubActions, contains("mediaType: 'epub'"));
    expect(epubActions, contains('entryKey: bookKey'));
    expect(epubActions, contains('if (!inCollectionDetail)'));
    // SRT/有声书卡：有入口，entryKey 编码一致（srt → uid），详情页注入
    // 「移出合集」时隐藏（removeFromCollection 非空）。
    expect(srtActions, contains('t.add_to_collection'));
    expect(srtActions, contains("mediaType: 'srt'"));
    expect(srtActions, contains('entryKey: book.uid'));
    expect(srtActions, contains('if (removeFromCollection == null)'));
    // 合集详情页渲染路径必须真的走 inCollectionDetail: true（隐藏加入入口）。
    expect(
      src,
      contains('_epubExtraActions(it, inCollectionDetail: true)'),
      reason: '详情页成员卡菜单必须经 inCollectionDetail 隐藏「加入合集」。',
    );
    // 两侧落库都走共享单卡弹窗（与批量三档同一 addToCollection DAO 路径）。
    expect(epubActions, contains('showAddToCollectionDialog'));
    expect(srtActions, contains('showAddToCollectionDialog'));
  });

  test('SRT 卡长按菜单对称补「查看插画」并 EPUB-backed 门控（TODO-1191）', () {
    final String srtActions = _sectionSource(
      src,
      'List<DialogAction> _srtExtraActions(',
      '  Future<void> _showSrtBookDialog(',
    );
    // 对称：SRT 卡菜单必须与 EPUB 卡一样含「查看插画」入口。
    expect(
      srtActions,
      contains('t.view_illustrations'),
      reason: 'SRT/有声书卡长按菜单也必须有「查看插画」入口（TODO-1191）。',
    );
    // 复用 EPUB 侧同一 _openIllustrations 回调，不另起实现。
    expect(
      srtActions,
      contains('_openIllustrations(item, bookKey)'),
      reason: 'SRT 卡「查看插画」复用 EPUB 侧同一 _openIllustrations 回调。',
    );
    // 门控：仅在该 SRT 书有对应 EpubBooks 行（extractDir 存在）时展示；
    // 纯字幕书 / EPUB 未生成完不命中，入口不显示。
    expect(
      srtActions,
      contains('_epubBackedBookKeys.contains(bookKey)'),
      reason: 'SRT 卡「查看插画」必须按 EPUB-backing 门控（纯 SRT 无 EPUB 不显示）。',
    );
    // TODO-1191（用户反馈）：外层「选择封面图片」与「编辑信息」弹窗重复，移除；
    // 选封面统一走编辑信息弹窗，且封面在 SRT 卡上经 override thumbnail 真正生效
    //（见下方 _buildSrtCover override 守卫）。
    expect(
      srtActions,
      isNot(contains('t.srt_import_pick_cover')),
      reason: 'TODO-1191：SRT 卡长按菜单移除冗余「选择封面图片」。',
    );
  });

  test('_epubBackedBookKeys 由 books（EpubBooks 行）真值填充（TODO-1191）', () {
    // 门控真值来源：books 列表（hibikiBooksProvider 的全部 EpubBooks 行）解析出的
    // bookKey 全集；确保门控不是空集导致入口永不显示。
    expect(
      src.contains('epubBackedBookKeys.add(key)'),
      isTrue,
      reason: '_epubBackedBookKeys 必须从 books 的 EpubBooks 行填充。',
    );
    expect(
      src.contains('_epubBackedBookKeys = epubBackedBookKeys;'),
      isTrue,
      reason: '填充后的 EPUB-backing 集合必须写回 state 供菜单门控读取。',
    );
  });

  test('SRT 卡封面尊重编辑信息弹窗写入的 override thumbnail（TODO-1191）', () {
    // 移除外层「选择封面图片」后，选封面唯一入口是编辑信息弹窗，它经
    // MediaSource.setOverrideThumbnailFromMediaItem 写 override thumbnail 文件。
    // 因此 SRT 卡封面渲染必须优先读该 override（否则编辑信息里选的封面不生效）。
    final String srtCover = _sectionSource(
      src,
      'Widget _buildSrtCover(SrtBook book',
      '  MediaItem _srtBookMediaItem(SrtBook book) {',
    );
    expect(
      srtCover,
      contains('getOverrideThumbnailFilename'),
      reason: 'SRT 卡封面必须优先读编辑信息弹窗写入的 override thumbnail（TODO-1191）。',
    );
    // 仍保留 book.coverPath 回退，向后兼容历史外层「选择封面图片」写入的封面。
    expect(
      srtCover,
      contains('book.coverPath'),
      reason: '无 override 时仍回退历史 book.coverPath（向后兼容）。',
    );
  });

  test('书籍长按对话框隐藏阅读按钮，点击卡片仍负责阅读', () {
    final String srtDialog = _sectionSource(
      src,
      // 复查F3 起签名带 onRemoveFromCollection 注入参，锚点用前缀。
      'Future<void> _showSrtBookDialog(SrtBook book,',
      '  bool _srtBookHasMissingAudio(',
    );
    final String epubDialog = _sectionSource(
      src,
      'onLongPress: () async {',
      '      child: buildMediaItemContent(item),',
    );

    expect(srtDialog, contains('showLaunchAction: false'));
    expect(epubDialog, contains('showLaunchAction: false'));
    expect(src, contains('onTap: () async {'));
    expect(src, contains('await appModel.openMedia('));
  });
}

String _sectionSource(String source, String startToken, String endToken) {
  final int start = source.indexOf(startToken);
  final int end = source.indexOf(endToken, start + startToken.length);
  expect(start, isNonNegative, reason: 'Missing source marker: $startToken');
  expect(end, greaterThan(start),
      reason: 'Missing end marker after $startToken: $endToken');
  return source.substring(start, end);
}

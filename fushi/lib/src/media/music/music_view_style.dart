/// 音乐模块列表 / 网格类视图的两种样式（封面色块 / 单列行）与它的记忆。
///
/// 按视图种类各记各的（[MusicViewKind]）：专辑、艺人、歌单、曲目四类——同一类
/// 视图在曲库、服务器曲库、插件来源、Apple Music 等各处共用一份选择（换一页仍是
/// 上次选的），不同类互不牵连（艺人默认是行、专辑默认是卡，全局一份会让一边的
/// 切换把另一边也翻过去）。
///
/// 没选过时为 null：各页按自己的原有画法取缺省（[MusicViewStyleStore.effective] 的
/// `fallback`）——例如曲目在歌单详情里原本是色块、在曲库「歌曲」分区里原本是行；
/// 用户点过一次切换后，这一类在所有页面统一跟着走。
///
/// 持久化：偏好键 `music_view_style_<kind>`（值 `blocks` / `list`），经
/// [PreferencesRepository] 读写（AppModel 建好偏好仓库后 [bind]）。没绑（单页
/// widget 测试）时退回进程内记忆。
library;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/models/preferences_repository.dart';

/// 两种样式：封面色块（封面网格布局下即原有封面卡）/ 单列行。
enum MusicViewStyle {
  blocks('blocks'),
  list('list');

  const MusicViewStyle(this.prefValue);

  /// 落库值。
  final String prefValue;

  /// 另一种（切换键点了换成的那一种）。
  MusicViewStyle get other => this == MusicViewStyle.blocks
      ? MusicViewStyle.list
      : MusicViewStyle.blocks;

  static MusicViewStyle? fromPref(Object? value) {
    for (final MusicViewStyle s in MusicViewStyle.values) {
      if (s.prefValue == value) return s;
    }
    return null;
  }
}

/// 记样式的视图种类。
enum MusicViewKind {
  albums('albums'),
  artists('artists'),
  playlists('playlists'),
  tracks('tracks');

  const MusicViewKind(this.prefSuffix);

  final String prefSuffix;

  /// 偏好键（见库注释）。
  String get prefKey => 'music_view_style_$prefSuffix';
}

/// 样式记忆。读不缓存（偏好仓库在同步 / 换档案后会整体重载，每次现读才不过期），
/// 写完通知监听者重建。
class MusicViewStyleStore extends ChangeNotifier {
  MusicViewStyleStore._();

  /// 进程内唯一一份。
  static final MusicViewStyleStore instance = MusicViewStyleStore._();

  PreferencesRepository? _prefs;

  /// 没绑偏好仓库时的进程内记忆。
  final Map<MusicViewKind, MusicViewStyle> _memory =
      <MusicViewKind, MusicViewStyle>{};

  /// 接上偏好仓库（AppModel 建好仓库时调；换了仓库再调一次即可）。
  void bind(PreferencesRepository prefs) {
    if (identical(_prefs, prefs)) return;
    _prefs = prefs;
    notifyListeners();
  }

  /// 用户选过的样式；没选过为 null。
  MusicViewStyle? stored(MusicViewKind kind) {
    final PreferencesRepository? prefs = _prefs;
    if (prefs == null) return _memory[kind];
    return MusicViewStyle.fromPref(prefs.getPref(kind.prefKey));
  }

  /// 生效的样式：选过的，没选过用调用页的原有画法 [fallback]。
  MusicViewStyle effective(MusicViewKind kind, MusicViewStyle fallback) =>
      stored(kind) ?? fallback;

  /// 记下 [kind] 的样式（所有页面同一类视图跟着换）。
  Future<void> set(MusicViewKind kind, MusicViewStyle style) async {
    final PreferencesRepository? prefs = _prefs;
    if (prefs == null) {
      _memory[kind] = style;
      notifyListeners();
      return;
    }
    // 先通知再落库：界面立刻换，写库在后台完成（setPref 先写内存缓存，
    // 随后的读已是新值）。
    final Future<void> write = prefs.setPref(kind.prefKey, style.prefValue);
    notifyListeners();
    await write;
  }

  /// 测试用：清掉进程内记忆、解绑仓库。
  @visibleForTesting
  void resetForTesting() {
    _prefs = null;
    _memory.clear();
    notifyListeners();
  }
}

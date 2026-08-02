import 'package:flutter/foundation.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

/// 媒体导出字段（音频 / 图片）共用的搜索状态与回退取词逻辑。
///
/// [AudioExportField] 与 [ImageExportField] 此前各自复制了
/// `setSearching` / `getSearchTermWithFallback` 与搜索状态字段；
/// 此 mixin 是单一真相源，行为与原实现逐字一致。
mixin ExportFieldSearch on Field {
  /// The current search term for the media being searched.
  String? get currentSearchTerm => _currentSearchTerm;
  String? _currentSearchTerm;

  /// Whether or not searching is in progress.
  bool get isSearching => _isSearching;
  bool _isSearching = false;

  /// 子类内部写搜索词状态（不触发 refresh）。
  @protected
  set currentSearchTermInternal(String? value) => _currentSearchTerm = value;

  /// 子类内部写搜索中状态（不触发 refresh）。
  @protected
  set isSearchingInternal(bool value) => _isSearching = value;

  /// Flag for showing the loading state of the picker.
  void setSearching({
    required AppModel appModel,
    required CreatorModel creatorModel,
    required bool isSearching,
    String? searchTerm,
  }) {
    _isSearching = isSearching;
    _currentSearchTerm = searchTerm;
    creatorModel.refresh();
  }

  /// Fetches the search term to use from the [CreatorModel]. If the field
  /// controller is empty, use a fallback and inform the user that a fallback
  /// has been used.
  String? getSearchTermWithFallback({
    required AppModel appModel,
    required CreatorModel creatorModel,
    required List<Field> fallbackSearchTerms,
  }) {
    String searchTerm = creatorModel.getFieldController(this).text.trim();
    if (searchTerm.isNotEmpty) {
      return searchTerm;
    } else {
      for (Field fallbackField in fallbackSearchTerms) {
        String fallbackTerm =
            creatorModel.getFieldController(fallbackField).text.trim();
        if (fallbackTerm.isNotEmpty) {
          HibikiToast.show(
            msg: t.field_fallback_used(
              field: getLocalisedLabel(appModel),
              secondField: fallbackField.getLocalisedLabel(appModel),
            ),
            toastLength: Toast.LENGTH_SHORT,
            gravity: ToastGravity.BOTTOM,
            severity: ToastSeverity.warning,
          );

          return fallbackTerm;
        }
      }
    }

    HibikiToast.show(
      msg: t.no_text_to_search,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
      severity: ToastSeverity.error,
    );

    return null;
  }
}

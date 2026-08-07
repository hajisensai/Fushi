import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:network_to_file_image/network_to_file_image.dart';
import 'package:fushi/creator.dart';
import 'package:fushi/models.dart';

/// A special kind of field that has a special widget at the top of the creator.
/// For example, the audio field has a media player that can be controlled
/// based on its values.
abstract class ImageExportField extends Field
    with ChangeNotifier, ExportFieldSearch {
  /// Initialise this field with the predetermined and hardset values.
  ImageExportField({
    required super.uniqueKey,
    required super.label,
    required super.description,
    required super.icon,
  });

  /// The image file selected for export.
  NetworkToFileImage? get exportFile => _exportFile;
  NetworkToFileImage? _exportFile;

  /// The images shown in a carousel for selection.
  List<NetworkToFileImage>? get currentImageSuggestions => _imageSuggestions;
  List<NetworkToFileImage>? _imageSuggestions;

  /// Selected index for [currentImageSuggestions].
  int? get selectedIndex => _indexNotifier.value;

  /// Notifier for updating the count.
  ValueNotifier<int> get indexNotifier => _indexNotifier;
  final ValueNotifier<int> _indexNotifier = ValueNotifier<int>(0);

  /// Whether or not the current media cannot be overridden by an auto enhancement.
  bool _autoCannotOverride = false;

  /// Whether or not to show the top widget.
  bool get showWidget =>
      currentImageSuggestions != null &&
      (exportFile != null || selectedIndex == -1);

  /// Clears this field's data. The state refresh afterwards is not performed
  /// here and should be performed by the invocation of the clear field button.
  void clearFieldState({
    required CreatorModel creatorModel,
  }) {
    _exportFile = null;
    _imageSuggestions = null;
    _indexNotifier.value = 0;
    currentSearchTermInternal = null;
    isSearchingInternal = false;
    _autoCannotOverride = false;

    creatorModel.refresh();
  }

  /// Perform a function that generates a list of images and attempt a search
  /// with a given search term.
  Future<void> setImages({
    required AppModel appModel,
    required CreatorModel creatorModel,
    required Future<List<NetworkToFileImage>> Function() generateImages,
    required EnhancementTriggerCause cause,
    required bool newAutoCannotOverride,
    String? searchTerm,
  }) async {
    if (_autoCannotOverride && cause == EnhancementTriggerCause.auto) {
      return;
    }

    if (creatorModel.scrollController.hasClients &&
        cause == EnhancementTriggerCause.manual) {
      creatorModel.scrollController
          .jumpTo(creatorModel.scrollController.position.minScrollExtent);
    }

    carouselKey = UniqueKey();

    /// Show loading state.
    setSearching(
        appModel: appModel,
        creatorModel: creatorModel,
        isSearching: true,
        searchTerm: searchTerm);
    try {
      List<NetworkToFileImage> images = await generateImages();

      if (images.isNotEmpty) {
        setSearchSuggestions(
          appModel: appModel,
          creatorModel: creatorModel,
          images: images,
          searchTermUsed: searchTerm,
        );
        _autoCannotOverride = newAutoCannotOverride;
      }
    } finally {
      /// Finish loading state.
      setSearching(
        appModel: appModel,
        creatorModel: creatorModel,
        isSearching: false,
        searchTerm: searchTerm,
      );
    }
  }

  /// Takes a non-empty new list of images to set as the new image suggestions.
  /// By default, this replaces the [exportFile] with the index set in
  /// [newSelectedSuggestionIndex].
  void setSearchSuggestions({
    required AppModel appModel,
    required CreatorModel creatorModel,
    required List<NetworkToFileImage> images,
    String? searchTermUsed,
    int newSelectedSuggestionIndex = 0,
  }) {
    creatorModel.getFieldController(this).clear();
    // HBK-AUDIT-081: the old guard `idx < 0 && idx >= length` is always false
    // (can't be both), so it only fired on empty AND fell through to
    // `images.first` — crashing on an empty list. Use `||` for real bounds and
    // return so we don't dereference images.first when there is nothing valid.
    if (images.isEmpty ||
        newSelectedSuggestionIndex < 0 ||
        newSelectedSuggestionIndex >= images.length) {
      clearFieldState(
        creatorModel: creatorModel,
      );
      return;
    }

    _imageSuggestions = images;
    _exportFile = images.first;
    _indexNotifier.value = newSelectedSuggestionIndex;
    currentSearchTermInternal = searchTermUsed;
    isSearchingInternal = false;
    creatorModel.refresh();
    carouselNotifier.notifyListeners();
  }

  /// Change the index of the selected search suggestion and update the state
  /// of the image picker.
  void setSelectedSearchSuggestion({
    required int index,
  }) {
    if (index == -1) {
      _exportFile = null;
    } else {
      _exportFile = _imageSuggestions![index];
    }

    _indexNotifier.value = index;
  }

  /// Media fields are special and have a [Widget] that is shown at the top of
  /// the Card Creator.
  Widget buildTopWidget({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required Orientation orientation,
  });

  /// For setting carousel item position.
  ChangeNotifier carouselNotifier = ChangeNotifier();

  /// For setting carousel item position.
  UniqueKey carouselKey = UniqueKey();
}

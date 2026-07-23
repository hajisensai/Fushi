import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

/// A special kind of field that has a special widget at the top of the creator.
/// For example, the audio field has a media player that can be controlled
/// based on its values.
abstract class AudioExportField extends Field with ExportFieldSearch {
  /// Initialise this field with the predetermined and hardset values.
  AudioExportField({
    required super.uniqueKey,
    required super.label,
    required super.description,
    required super.icon,
  });

  /// The image file selected for export.
  File? get exportFile => _exportFile;
  File? _exportFile;

  /// Whether or not the current media cannot be overridden by an auto enhancement.
  bool _autoCannotOverride = false;

  /// Whether or not to show the top widget.
  bool get showWidget => exportFile != null;

  /// Clears this field's data. The state refresh afterwards is not performed
  /// here and should be performed by the invocation of the clear field button.
  void clearFieldState({
    required CreatorModel creatorModel,
  }) {
    _exportFile = null;
    currentSearchTermInternal = null;
    _autoCannotOverride = false;
    creatorModel.refresh();
  }

  /// Takes a new file as the audio file.
  void setAudioFile({
    required AppModel appModel,
    required CreatorModel creatorModel,
    required File file,
    String? searchTermUsed,
  }) {
    creatorModel.getFieldController(this).clear();
    _exportFile = file;
    currentSearchTermInternal = searchTermUsed;
    isSearchingInternal = false;
    creatorModel.refresh();
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

  /// Executed on close of the creator screen.
  void onCreatorClose();

  /// Perform a function that generates a list of images and attempt a search
  /// with a given search term.
  Future<void> setAudio({
    required AppModel appModel,
    required CreatorModel creatorModel,
    required Future<File?> Function() generateAudio,
    required bool newAutoCannotOverride,
    required EnhancementTriggerCause cause,
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

    /// Show loading state.
    setSearching(
        appModel: appModel,
        creatorModel: creatorModel,
        isSearching: true,
        searchTerm: searchTerm);
    try {
      File? file = await generateAudio();

      if (file != null) {
        setAudioFile(
          appModel: appModel,
          creatorModel: creatorModel,
          file: file,
          searchTermUsed: searchTerm,
        );
      } else {
        if (cause == EnhancementTriggerCause.manual) {
          HibikiToast.show(
            msg: t.audio_unavailable,
            toastLength: Toast.LENGTH_SHORT,
            gravity: ToastGravity.BOTTOM,
          );
        }
      }

      _autoCannotOverride = newAutoCannotOverride;
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
}

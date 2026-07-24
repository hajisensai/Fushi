import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/models.dart';

/// An entity that executes an action when selected on the upper-right of a
/// dictionary entry widget. An action is initialised at runtime in the
/// initialisation step, and can be assigned to a quick action slot.
/// When dictionary search results are displayed, the user can then tap on the
/// icon representing the action to execute its functionality for a certain
/// dictionary entry.
///
/// The identity, labelling, localisation and one-shot initialisation are
/// inherited from [CreatorRegistryEntry]; this class only adds the
/// single-dictionary visibility flag, the icon colour hook and the
/// [executeAction] contract.
abstract class QuickAction extends CreatorRegistryEntry {
  /// Initialise this action with the predetermined and hardset values.
  QuickAction({
    required super.uniqueKey,
    required super.label,
    required super.description,
    required super.icon,
    this.showInSingleDictionary = false,
  });

  /// Whether or not to show this action in the single dictionary dropdown
  /// options.
  final bool showInSingleDictionary;

  /// If non-null, sets a custom enabled color that this action should have for
  /// a certain condition in the application. By default, this is the
  /// foreground color.
  Future<Color?> getIconColor({
    required AppModel appModel,
    required DictionaryEntry entry,
  }) async {
    return null;
  }

  /// Execute the functionality of this action.
  Future<void> executeAction({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required String? dictionaryName,
  });
}

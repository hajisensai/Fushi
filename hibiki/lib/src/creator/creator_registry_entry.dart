import 'package:flutter/widgets.dart';
import 'package:hibiki/models.dart';

/// Shared registration scaffold for creator entities that are declared once,
/// initialised at runtime and assigned to a slot the user can tap. Both
/// [Enhancement] (creator field mutators) and [QuickAction] (dictionary entry
/// actions) derive their identity, labelling, localisation and one-shot
/// initialisation from this base; each subclass only adds its own divergent
/// members (e.g. the target field, the executed behaviour).
abstract class CreatorRegistryEntry {
  /// Initialise this entry with the predetermined and hardset values.
  CreatorRegistryEntry({
    required this.uniqueKey,
    required this.label,
    required this.description,
    required this.icon,
  });

  /// A unique name that allows distinguishing this type from others,
  /// particularly for the purposes of differentiating between persistent
  /// settings keys.
  final String uniqueKey;

  /// Name of the entry that very shortly describes what it does.
  final String label;

  /// A longer description of what the entry can do, or details left
  /// by or regarding the developer.
  final String description;

  /// An icon that will show the entry if activated by the user in the
  /// quick menu.
  final IconData icon;

  /// Localisations for this entry, where the key is a locale tag and
  /// the value is the [label] of the entry. If the value for the current
  /// locale is non-null, it will be used instead of [label].
  final Map<String, String> labelLocalisation = const {};

  /// Localisations for this entry, where the key is a locale tag and
  /// the value is the [description] of the entry. If the value for the
  /// current locale is non-null, it will be used instead of [description].
  final Map<String, String> descriptionLocalisation = const {};

  /// Get the best localisation for the label of this entry. If there
  /// is no localisation, the fallback is [label].
  String getLocalisedLabel(AppModel appModel) {
    return labelLocalisation[appModel.appLocale.toLanguageTag()] ?? label;
  }

  /// Get the best localisation for the description of this entry. If
  /// there is no localisation, the fallback is [description].
  String getLocalisedDescription(AppModel appModel) {
    return descriptionLocalisation[appModel.appLocale.toLanguageTag()] ??
        description;
  }

  /// Whether or not [initialise] has been called for this entry.
  bool _initialised = false;

  /// This function is run once during the initialisation step. It is not
  /// called again if already run.
  Future<void> initialise() async {
    if (_initialised) {
      return;
    } else {
      await prepareResources();
      _initialised = true;
    }
  }

  /// If this entry requires resources to function, they can be prepared
  /// here and this function will be run once only at runtime during the
  /// initialisation step.
  Future<void> prepareResources() async {}
}

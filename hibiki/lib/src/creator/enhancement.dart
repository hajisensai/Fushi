import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/models.dart';

/// List of causes that may be of interest when executing an enhancement and
/// may change the context of how the enhancement should be executed.
enum EnhancementTriggerCause {
  /// Used when an enhancement is executed when opening the card creator.
  auto,

  /// Used when an enhancement is executed by clicking the button representing
  /// the enhancement in the card creator.
  manual,

  /// Used when an enhancement is executed by another enhancement.
  cascade,
}

/// An entity that functionally mutates creator fields and returns an output.
/// An enhancement is given and assigned a field at runtime in the
/// initialisation step, and can be assigned to a field enhancement slot.
/// In the creator, the user can then tap on the icon representing the
/// enhancement to execute its functionality.
///
/// The identity, labelling, localisation and one-shot initialisation are
/// inherited from [CreatorRegistryEntry]; this class only adds the target
/// [field] and the [enhanceCreatorParams] contract.
abstract class Enhancement extends CreatorRegistryEntry {
  /// Initialise this enhancement with the predetermined and hardset values.
  Enhancement({
    required super.uniqueKey,
    required super.label,
    required super.description,
    required this.field,
    required super.icon,
  });

  /// Which field this enhancement is for.
  final Field field;

  /// Perform a change to the [CreatorModel], executing the functionality of
  /// this enhancement. An [EnhancementTriggerCause] may be used to modify the
  /// behavior of the enhancement's function depending on whether the
  /// enhancement is being executed on auto, manual or cascade modes.
  Future<void> enhanceCreatorParams({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required EnhancementTriggerCause cause,
  });
}

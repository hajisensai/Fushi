import 'package:hibiki/creator.dart';

/// An entity for enhancements that specificallly generate images.
abstract class ImageEnhancement extends Enhancement {
  /// Initialise this enhancement with the predetermined and hardset values.
  ImageEnhancement({
    required super.uniqueKey,
    required super.label,
    required super.description,
    required super.field,
    required super.icon,
  });

  // HBK-AUDIT-082: removed the abstract `fetchImages` contract. Its only
  // caller (BingImagesSearchEnhancement) no longer exists; the three current
  // subclasses (pick/camera/crop) all drove image generation through their own
  // enhanceCreatorParams + ImageExportField.setImages path and stubbed
  // fetchImages with UnimplementedError / [] — a dead contract two implementers
  // rejected at runtime. Deleting it removes the inconsistent stubs entirely.
}

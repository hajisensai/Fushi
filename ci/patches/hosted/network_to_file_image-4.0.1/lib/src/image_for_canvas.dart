import 'dart:ui' as ui;
import 'package:flutter/material.dart';

typedef LoadCallback<T> = void Function(ImageInfo image, T obj, Object? key);

/// IMPORTANT: See example file: main_image_for_canvas.dart
///
/// Use this `ImageForCanvas` class if you want to create images to use with
/// Canvas. It will use the regular image cache from Flutter, and works with
/// NetworkToFileImage provider, or any other image providers.
///
/// In more detail:
///
/// ImageProviders can't be used directly with the `Canvas` object
/// of the `paint` method of a `CustomPainter`.
/// Use this to download and save in the cache images to use with canvas.
///
/// For example: Suppose a User object that contains url and filename
/// properties.
///
/// ```
/// var imageForCanvas = ImageForCanvas<User>(
///        imageProviderSupplier: (User user) =>
///           NetworkToFileImage(file: user.file, url: user.url),
///        keySupplier: (User user) => user.filename,
///        loadCallback: (image, obj, key) => setState((){}),
///      );
///
/// // While the image is downloading, this will return null.
/// var myImage = imageForCanvas.image(user);
///
/// if (myImage != null) {
///    canvas.drawImage(myImage, ...);
///    }
/// ```
///
class ImageForCanvas<T> {
  static final Map<Object?, ui.Image?> _images = {};

  ImageForCanvas({
    required this.imageProviderSupplier,
    required this.loadCallback,
    this.keySupplier,
  });

  final ImageProvider? Function(T obj) imageProviderSupplier;

  final LoadCallback<T>? loadCallback;

  final Object Function(T obj)? keySupplier;

  void clearInternalCache() => _images.clear();

  ui.Image? image(T obj) {
    var key = (keySupplier == null) ? obj : keySupplier!(obj);
    var image = _images[key];

    if (image == null) {
      if (!_images.containsKey(key)) {
        _images[key] = null;

        ImageProvider? imgProvider = imageProviderSupplier(obj);

        if (imgProvider == null)
          return null;
        else {
          final stream = imgProvider.resolve(ImageConfiguration.empty);
          stream.addListener(ImageStreamListener((ImageInfo info, bool synchronousCall) {
            _onImage(info, obj, key);
          }));
        }
      }
    }

    return image;
  }

  void _onImage(ImageInfo image, T obj, Object? key) {
    _images[key] = image.image;
    loadCallback?.call(image, obj, key);
  }
}

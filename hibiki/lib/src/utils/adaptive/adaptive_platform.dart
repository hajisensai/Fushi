import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

bool isCupertinoPlatform(BuildContext context) {
  final platform = Theme.of(context).platform;
  return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
}

bool get isCupertinoDefault {
  return defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
}

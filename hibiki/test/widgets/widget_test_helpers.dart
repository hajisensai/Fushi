import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/spacing.dart';

Widget buildTestApp(Widget child, {ThemeData? theme}) {
  return MaterialApp(
    theme: theme ?? ThemeData.light(useMaterial3: true),
    home: Spacing(
      dataBuilder: (context) => SpacingData.generate(10),
      child: Scaffold(body: child),
    ),
  );
}

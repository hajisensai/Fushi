import 'package:flutter/material.dart';

Widget buildTestApp(Widget child, {ThemeData? theme}) {
  return MaterialApp(
    theme: theme ?? ThemeData.light(useMaterial3: true),
    home: Scaffold(body: child),
  );
}

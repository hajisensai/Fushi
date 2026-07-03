import 'package:flutter/material.dart';

Widget buildGoldenApp(
  Widget child, {
  ThemeData? theme,
  Size size = const Size(400, 200),
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme ?? ThemeData.light(useMaterial3: true),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: Center(child: child),
        ),
      ),
    ),
  );
}

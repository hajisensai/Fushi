import 'package:flutter/foundation.dart';

/// Builds the error-log source label for a framework-caught Flutter error.
///
/// [FlutterErrorDetails.context] is a [DiagnosticsNode], commonly an
/// [ErrorDescription]. Its default [Object.toString] only exposes the runtime
/// type (`Instance of 'ErrorDescription'`); [DiagnosticsNode.toDescription]
/// is the framework API that returns the human-readable catch context.
String flutterErrorLogSource(FlutterErrorDetails details) {
  final String? context = details.context?.toDescription().trim();
  return 'FlutterError: ${context == null || context.isEmpty ? 'unknown' : context}';
}

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

/// Builds the "show this error" step of the app's `FlutterError.onError`.
///
/// [host] is the handler installed before the app replaced it. Normally that is
/// the framework default [FlutterError.presentError], and so is the result:
/// production behaviour is unchanged. Under `flutter_test` (integration tests
/// start the real `main()` inside a test) the binding owns the handler and fails
/// the test from it. Replacing it outright broke two things (BUG-5601):
/// framework errors during an itest went only to the app's error log and never
/// failed the test, and when a test did fail, the binding's own failure report
/// reached the app's handler instead, tripped flutter_test's
/// `_pendingExceptionDetails != null` assertion and looped until the process ran
/// out of memory, so a red itest became a hang. Non-silent errors therefore go
/// to a non-default [host]; silent ones (image decode failures and similar,
/// which the default presenter also keeps quiet) are still only presented.
FlutterExceptionHandler flutterErrorPresenterFor(
  FlutterExceptionHandler? host,
) {
  if (host == null || host == FlutterError.presentError) {
    return FlutterError.presentError;
  }
  return (FlutterErrorDetails details) {
    if (details.silent) {
      FlutterError.presentError(details);
    } else {
      host(details);
    }
  };
}

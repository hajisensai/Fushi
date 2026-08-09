/// Shared result and failure contracts for optional external media providers.
library;

import 'dart:async';

import 'package:http/http.dart' as http;

/// A stable, UI-safe classification of an external provider failure.
enum ExternalProviderFailureKind {
  unavailable,
  unauthorized,
  forbidden,
  rateLimited,
  quotaExceeded,
  timeout,
  network,
  invalidResponse,
  notFound,
  unsupported,
  integrity,
  unknown,
}

/// A deliberately redacted external failure.
///
/// [message] must never contain a request URL, response body, API key, token,
/// password, or temporary download link. The type does not retain the original
/// exception so accidental logging cannot reveal provider credentials.
class ExternalProviderFailure implements Exception {
  const ExternalProviderFailure({
    required this.providerId,
    required this.operation,
    required this.kind,
    required this.message,
    this.statusCode,
    this.retryAfter,
    this.quotaRemaining,
    this.retryable = false,
  });

  final String providerId;
  final String operation;
  final ExternalProviderFailureKind kind;
  final String message;
  final int? statusCode;
  final Duration? retryAfter;
  final int? quotaRemaining;
  final bool retryable;

  factory ExternalProviderFailure.fromException({
    required String providerId,
    required String operation,
    required Object error,
  }) {
    if (error is ExternalProviderFailure) return error;
    if (error is TimeoutException) {
      return ExternalProviderFailure(
        providerId: providerId,
        operation: operation,
        kind: ExternalProviderFailureKind.timeout,
        message: 'provider request timed out',
        retryable: true,
      );
    }
    if (error is http.ClientException) {
      return ExternalProviderFailure(
        providerId: providerId,
        operation: operation,
        kind: ExternalProviderFailureKind.network,
        message: 'provider network request failed',
        retryable: true,
      );
    }
    if (error is FormatException) {
      return ExternalProviderFailure(
        providerId: providerId,
        operation: operation,
        kind: ExternalProviderFailureKind.invalidResponse,
        message: 'provider returned an invalid response',
      );
    }
    return ExternalProviderFailure(
      providerId: providerId,
      operation: operation,
      kind: ExternalProviderFailureKind.unknown,
      message: 'provider request failed',
    );
  }

  @override
  String toString() {
    final String status = statusCode == null ? '' : ', status=$statusCode';
    return 'ExternalProviderFailure(provider=$providerId, '
        'operation=$operation, kind=${kind.name}$status): $message';
  }
}

/// Results from one or more providers, preserving partial success.
class ProviderBatchResult<T> {
  ProviderBatchResult({
    Iterable<T> items = const <Never>[],
    Iterable<ExternalProviderFailure> failures =
        const <ExternalProviderFailure>[],
    this.successfulProviderCount = 0,
  })  : items = List<T>.unmodifiable(items),
        failures = List<ExternalProviderFailure>.unmodifiable(failures);

  factory ProviderBatchResult.success(
    Iterable<T> items, {
    int successfulProviderCount = 1,
  }) =>
      ProviderBatchResult<T>(
        items: items,
        successfulProviderCount: successfulProviderCount,
      );

  factory ProviderBatchResult.failure(ExternalProviderFailure failure) =>
      ProviderBatchResult<T>(failures: <ExternalProviderFailure>[failure]);

  final List<T> items;
  final List<ExternalProviderFailure> failures;
  final int successfulProviderCount;

  bool get hasItems => items.isNotEmpty;
  bool get hasFailures => failures.isNotEmpty;

  /// A provider that succeeded with a legitimate empty result still makes a
  /// mixed batch partial when another provider failed. Tying this to
  /// [hasItems] hid the failure warning on valid "0 matches + 1 outage"
  /// searches and made that state indistinguishable from an all-green empty
  /// result.
  bool get isPartial => successfulProviderCount > 0 && hasFailures;
  bool get isTotalFailure => successfulProviderCount == 0 && hasFailures;

  static ProviderBatchResult<T> merge<T>(
    Iterable<ProviderBatchResult<T>> results,
  ) {
    final List<T> items = <T>[];
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[];
    int successfulProviderCount = 0;
    for (final ProviderBatchResult<T> result in results) {
      items.addAll(result.items);
      failures.addAll(result.failures);
      successfulProviderCount += result.successfulProviderCount;
    }
    return ProviderBatchResult<T>(
      items: items,
      failures: failures,
      successfulProviderCount: successfulProviderCount,
    );
  }
}

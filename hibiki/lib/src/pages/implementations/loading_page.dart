import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// Shows a bare loading circle.
class LoadingPage extends BasePage {
  /// Create an instance of this page.
  const LoadingPage({
    super.key,
  });

  @override
  BasePageState createState() => _LoadingPageState();
}

class _LoadingPageState extends BasePageState<LoadingPage> {
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: HibikiTransientScaffold(body: buildLoading()),
    );
  }
}

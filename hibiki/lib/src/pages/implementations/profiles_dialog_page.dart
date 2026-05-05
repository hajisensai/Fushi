import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';

/// Stub — the old multi-profile manager is replaced by AnkiSettingsPage.
/// Kept as a typedef so call-sites (e.g. AppModel.showProfilesMenu) compile.
class ProfilesManagementPage extends BasePage {
  const ProfilesManagementPage({
    this.models = const [],
    this.initialModel = '',
    super.key,
  });

  final List<String> models;
  final String initialModel;

  @override
  BasePageState createState() => _ProfilesManagementPageState();
}

class _ProfilesManagementPageState
    extends BasePageState<ProfilesManagementPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const AnkiSettingsPage()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

typedef ProfilesDialogPage = ProfilesManagementPage;

import 'package:material_ui/material_ui.dart';

/// Details of one library item (`library.details {ref}`): info, chapters /
/// episodes, Continue on top, Mark finished. Pushed on the Library tab's
/// current mode navigator by Browse lists and by Main mode's "Details".
/// STUB — filled by the S5 Browse work.
class CompanionLibraryDetailsPage extends StatelessWidget {
  const CompanionLibraryDetailsPage({
    required this.itemRef,
    this.title,
    super.key,
  });

  /// `CompanionLibraryItem.ref`.
  final String itemRef;

  /// Shown while the details load.
  final String? title;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text(title ?? '')));
}

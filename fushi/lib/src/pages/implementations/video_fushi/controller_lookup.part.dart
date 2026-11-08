part of '../video_fushi_page.dart';

// Controller lookup mode (S6, hold L1 / Select) adapter of the video page.
// STUB: implemented by the S6 page agent.

class _VideoControllerLookupTarget extends ControllerLookupTarget {
  _VideoControllerLookupTarget(this._s, {required super.readPref});

  final _VideoFushiPageState _s;

  @override
  bool get isAvailable => _s.mounted;

  @override
  void onModeEntered() {}

  @override
  void onModeExited() {}

  @override
  Future<void> stepCursor(int dir, {required bool word}) async {}

  @override
  Future<void> stepLine(int dir) async {}

  @override
  Future<void> lookupAtCursor() async {}
}

extension _VideoControllerLookup on _VideoFushiPageState {
  void _attachControllerLookup() {
    final _VideoControllerLookupTarget target = _VideoControllerLookupTarget(
      this,
      readPref: (String key) => appModel.prefsRepo.getPref(key),
    );
    _controllerLookupTarget = target;
    ControllerLookupMode.instance.attach(target);
  }

  void _detachControllerLookup() {
    final _VideoControllerLookupTarget? target = _controllerLookupTarget;
    if (target == null) return;
    ControllerLookupMode.instance.detach(target);
    _controllerLookupTarget = null;
  }
}

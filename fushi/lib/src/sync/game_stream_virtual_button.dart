enum GameStreamVirtualButton {
  up,
  down,
  left,
  right,
  confirm,
  cancel,
  menu,
  shoulderLeft,
  shoulderRight,
}

extension GameStreamVirtualButtonWire on GameStreamVirtualButton {
  String get wireName => switch (this) {
    GameStreamVirtualButton.up => 'dpad_up',
    GameStreamVirtualButton.down => 'dpad_down',
    GameStreamVirtualButton.left => 'dpad_left',
    GameStreamVirtualButton.right => 'dpad_right',
    GameStreamVirtualButton.confirm => 'confirm',
    GameStreamVirtualButton.cancel => 'cancel',
    GameStreamVirtualButton.menu => 'menu',
    GameStreamVirtualButton.shoulderLeft => 'shoulder_left',
    GameStreamVirtualButton.shoulderRight => 'shoulder_right',
  };
}

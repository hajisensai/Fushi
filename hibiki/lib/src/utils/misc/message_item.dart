/// Used to allow persistence of a message from ChatGPT.
class MessageItem {
  /// Initialise this object.
  MessageItem({
    required this.message,
    required this.isBot,
    this.id,
  });

  /// Used for database purposes.
  int? id;

  /// Message to show for this item.
  final String message;

  /// True if bot, false if user.
  final bool isBot;
}

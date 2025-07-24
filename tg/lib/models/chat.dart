class Chat {
  final int id;
  final String title;
  final String? lastMessage;
  final DateTime? lastMessageDate;
  final int unreadCount;
  final String? profilePhotoUrl;
  final String? order;

  Chat({
    required this.id,
    required this.title,
    this.lastMessage,
    this.lastMessageDate,
    this.unreadCount = 0,
    this.profilePhotoUrl,
    this.order,
  });

  factory Chat.fromJson(Map<String, dynamic> json) {
    String? lastMessage;
    DateTime? lastMessageDate;

    if (json['last_message'] != null) {
      final contentType = json['last_message']['content']?['@type'];
      if (contentType == 'messageText') {
        lastMessage =
            json['last_message']['content']['text']['text'] ?? 'No message';
      } else if (contentType == 'messageVoiceNote') {
        lastMessage = '🔈 پیغام صوتی';
      } else {
        lastMessage = 'Unsupported message type';
      }
      lastMessageDate = json['last_message']['date'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              json['last_message']['date'] * 1000,
            )
          : null;
    }

    return Chat(
      id: json['id'] ?? 0,
      title: json['title'] ?? 'Unknown Chat',
      lastMessage: lastMessage,
      lastMessageDate: lastMessageDate,
      unreadCount: json['unread_count'] ?? 0,
      profilePhotoUrl: json['profile_photo_url'],
      order: json['order']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'last_message': lastMessage != null
          ? {
              'content': {
                '@type': lastMessage == '🔈 پیغام صوتی'
                    ? 'messageVoiceNote'
                    : 'messageText',
                'text': {'text': lastMessage},
              },
              'date': lastMessageDate?.millisecondsSinceEpoch != null
                  ? (lastMessageDate!.millisecondsSinceEpoch ~/ 1000)
                  : null,
            }
          : null,
      'unread_count': unreadCount,
      'profile_photo_url': profilePhotoUrl,
      'order': order,
    };
  }
}

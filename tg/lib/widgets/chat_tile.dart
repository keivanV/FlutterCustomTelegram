import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import '../models/chat.dart';

class ChatTile extends StatelessWidget {
  final Chat chat;
  final bool isDarkMode;

  const ChatTile({required this.chat, required this.isDarkMode, super.key});

  // Format timestamp to match Telegram's style
  String _formatTimestamp(DateTime? date) {
    if (date == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(date.year, date.month, date.day);
    if (messageDate == today) {
      return DateFormat('HH:mm').format(date); // e.g., 14:30
    } else if (date.year == now.year) {
      return DateFormat('dd MMM', 'fa_IR').format(date); // e.g., 01 مهر
    } else {
      return DateFormat(
        'dd MMM yyyy',
        'fa_IR',
      ).format(date); // e.g., 01 مهر 1403
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color textColor = isDarkMode ? Colors.white : Colors.black87;
    final Color secondaryTextColor = isDarkMode
        ? Colors.white70
        : Colors.black54;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isDarkMode
                ? Colors.white.withOpacity(0.1)
                : Colors.black.withOpacity(0.05),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          // Avatar
          CircleAvatar(
            radius: 26,
            backgroundColor: Colors.grey[400],
            child: chat.profilePhotoUrl != null
                ? ClipOval(
                    child: CachedNetworkImage(
                      imageUrl: chat.profilePhotoUrl!,
                      width: 52,
                      height: 52,
                      fit: BoxFit.cover,
                      placeholder: (context, url) =>
                          const CircularProgressIndicator(strokeWidth: 2.0),
                      errorWidget: (context, url, error) => Icon(
                        Icons.person,
                        color: isDarkMode ? Colors.black : Colors.white,
                        size: 30,
                      ),
                    ),
                  )
                : Icon(
                    chat.id == 777000 ? Icons.notifications : Icons.person,
                    color: isDarkMode ? Colors.black : Colors.white,
                    size: 30,
                  ),
          ),
          const SizedBox(width: 12),
          // Chat details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Chat title
                Text(
                  chat.id == 777000 ? 'اعلان‌های تلگرام' : chat.title,
                  style: TextStyle(
                    fontFamily: 'Vazir',
                    fontSize: 16,
                    fontWeight: FontWeight.normal,
                    color: textColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                // Last message preview
                Text(
                  chat.lastMessage ?? '',
                  style: TextStyle(
                    fontFamily: 'Vazir',
                    fontSize: 14,
                    color: secondaryTextColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Timestamp
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formatTimestamp(chat.lastMessageDate),
                style: TextStyle(
                  fontFamily: 'Vazir',
                  fontSize: 12,
                  color: secondaryTextColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

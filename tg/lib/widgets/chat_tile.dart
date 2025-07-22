import 'package:flutter/material.dart';
import '../models/chat.dart';

class ChatTile extends StatelessWidget {
  final Chat chat;
  final VoidCallback onTap;

  const ChatTile({required this.chat, required this.onTap, super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF2A3B4C), // Telegram tile background
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: CircleAvatar(
          radius: 28,
          backgroundColor: const Color(
            0xFF3C5064,
          ), // Telegram avatar background
          backgroundImage: chat.profilePhotoUrl != null
              ? NetworkImage(chat.profilePhotoUrl!)
              : null,
          child: chat.profilePhotoUrl == null
              ? Text(
                  chat.title.isNotEmpty ? chat.title[0].toUpperCase() : '?',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                )
              : null,
        ),
        title: Text(
          chat.id == 777000 ? 'اعلان‌های تلگرام' : chat.title,
          style: TextStyle(
            color: Colors.white,
            fontWeight: chat.unreadCount > 0
                ? FontWeight.w600
                : FontWeight.w400,
            fontSize: 16,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: chat.lastMessage != null
            ? Text(
                chat.lastMessage!,
                style: TextStyle(
                  color: chat.unreadCount > 0 ? Colors.white : Colors.white70,
                  fontSize: 14,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              )
            : null,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (chat.lastMessageDate != null)
              Text(
                '${chat.lastMessageDate!.hour}:${chat.lastMessageDate!.minute.toString().padLeft(2, '0')}',
                style: const TextStyle(
                  color: Color(0xFF7AA7C8), // Telegram timestamp color
                  fontSize: 12,
                ),
              ),
            if (chat.unreadCount > 0)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF00A4EF), // Telegram unread count color
                ),
                child: Text(
                  chat.unreadCount.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat.dart';
import '../widgets/chat_tile.dart';
import 'conversation_screen.dart';

class ChatScreen extends StatefulWidget {
  final String phoneNumber;

  const ChatScreen({required this.phoneNumber, super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  List<Chat> chats = [];
  bool isLoading = true;
  bool isLoadingMore = false;
  String? errorMessage;
  int offset = 0;
  final int limit = 20; // Load 20 chats at a time
  final ScrollController _scrollController = ScrollController();
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _initPrefsAndLoadChats();
    _scrollController.addListener(_onScroll);
  }

  Future<void> _initPrefsAndLoadChats() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadCachedChats();
    // Only fetch from server if cache is empty or outdated
    if (chats.isEmpty || _isCacheOutdated()) {
      await _fetchChats(background: true);
    } else {
      setState(() {
        isLoading = false;
      });
    }
  }

  bool _isCacheOutdated() {
    final lastFetchTime =
        _prefs?.getInt('last_fetch_time_${widget.phoneNumber}') ?? 0;
    final currentTime = DateTime.now().millisecondsSinceEpoch;
    // Consider cache outdated if older than 10 minutes
    return (currentTime - lastFetchTime) > 10 * 60 * 1000;
  }

  Future<void> _loadCachedChats() async {
    if (!mounted) return;
    setState(() {
      isLoading = true;
      errorMessage = null;
    });
    final cachedChats = _prefs?.getString('cached_chats_${widget.phoneNumber}');
    if (cachedChats != null) {
      try {
        final List<dynamic> jsonList = jsonDecode(cachedChats);
        final cachedChatList = jsonList
            .map((json) => Chat.fromJson(json))
            .toList();
        // Remove duplicates based on chat ID
        final uniqueChats = <int, Chat>{};
        for (var chat in cachedChatList) {
          uniqueChats[chat.id] = chat;
        }
        if (mounted) {
          setState(() {
            chats = uniqueChats.values.toList();
            // Sort chats by order (descending)
            chats.sort(
              (a, b) => int.parse(
                b.order ?? '0',
              ).compareTo(int.parse(a.order ?? '0')),
            );
            isLoading =
                false; // Set isLoading to false immediately after loading cache
          });
        }
      } catch (e) {
        print('Error loading cached chats: $e');
        if (mounted) {
          setState(() {
            errorMessage = 'خطا در بارگذاری چت‌های ذخیره‌شده: $e';
            isLoading = false;
          });
        }
      }
    } else {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchChats({
    bool loadMore = false,
    bool background = false,
  }) async {
    if (isLoadingMore) return;

    try {
      if (!background) {
        setState(() {
          if (!loadMore) {
            isLoading = true;
          } else {
            isLoadingMore = true;
          }
          errorMessage = null;
        });
      }
      final response = await http.post(
        Uri.parse('http://192.168.1.3:8000/get_chats'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'phone_number': widget.phoneNumber,
          'offset': loadMore ? offset : 0,
          'limit': limit,
        }),
      );

      print('Get chats response: ${response.statusCode} ${response.body}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final newChats = (data['chats'] as List<dynamic>)
            .map((json) => Chat.fromJson(json))
            .toList();
        if (mounted) {
          setState(() {
            // Remove duplicates by merging with existing chats
            final uniqueChats = <int, Chat>{};
            for (var chat in chats) {
              uniqueChats[chat.id] = chat;
            }
            for (var chat in newChats) {
              uniqueChats[chat.id] = chat;
            }
            chats = uniqueChats.values.toList();
            // Sort chats by order (descending)
            chats.sort(
              (a, b) => int.parse(
                b.order ?? '0',
              ).compareTo(int.parse(a.order ?? '0')),
            );
            offset = chats.length;
            if (!background) {
              isLoading = false;
              isLoadingMore = false;
            }
            // Cache the chats
            _prefs?.setString(
              'cached_chats_${widget.phoneNumber}',
              jsonEncode(chats.map((chat) => chat.toJson()).toList()),
            );
            _prefs?.setInt(
              'last_fetch_time_${widget.phoneNumber}',
              DateTime.now().millisecondsSinceEpoch,
            );
          });
        }
      } else {
        if (mounted && !background) {
          setState(() {
            errorMessage = 'خطا در دریافت چت‌ها: ${response.statusCode}';
            isLoading = false;
            isLoadingMore = false;
          });
        }
      }
    } catch (e, stackTrace) {
      print('Error fetching chats: $e\n$stackTrace');
      if (mounted && !background) {
        setState(() {
          errorMessage = 'خطای شبکه در دریافت چت‌ها: $e';
          isLoading = false;
          isLoadingMore = false;
        });
      }
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 100 &&
        !isLoadingMore) {
      _fetchChats(loadMore: true);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('چت‌ها'),
        backgroundColor: Colors.blueGrey[800],
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: () {
              offset = 0;
              _fetchChats();
            },
          ),
        ],
      ),
      body: isLoading && chats.isEmpty
          ? const Center(
              child: CircularProgressIndicator(
                color: Colors.blueAccent,
                strokeWidth: 2.0,
              ),
            )
          : RefreshIndicator(
              onRefresh: () async {
                offset = 0;
                await _fetchChats();
              },
              child: Column(
                children: [
                  if (errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(
                        errorMessage!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  Expanded(
                    child: chats.isEmpty && !isLoading
                        ? const Center(
                            child: Text(
                              'هیچ چتی موجود نیست',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 16,
                              ),
                            ),
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            itemCount: chats.length + (isLoadingMore ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index == chats.length && isLoadingMore) {
                                return const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(8.0),
                                    child: CircularProgressIndicator(
                                      color: Colors.blueAccent,
                                      strokeWidth: 2.0,
                                    ),
                                  ),
                                );
                              }
                              final chat = chats[index];
                              return ChatTile(
                                chat: chat,
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => ConversationScreen(
                                        chatId: chat.id,
                                        chatTitle: chat.id == 777000
                                            ? 'اعلان‌های تلگرام'
                                            : chat.title,
                                        phoneNumber: widget.phoneNumber,
                                      ),
                                    ),
                                  ).then((_) {
                                    // Reload cached chats when returning
                                    _loadCachedChats();
                                  });
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}

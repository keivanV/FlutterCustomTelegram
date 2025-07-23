import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
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
  final int limit = 20;
  final ScrollController _scrollController = ScrollController();
  bool isDarkMode = true;
  SharedPreferences? _prefs;
  final TextEditingController _searchController = TextEditingController();
  int retryCount = 0;
  static const int maxRetries = 10;
  static const Duration baseDelay = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _initPrefsAndLoadChats();
    _scrollController.addListener(_onScroll);
  }

  Future<void> _initPrefsAndLoadChats() async {
    _prefs = await SharedPreferences.getInstance();
    isDarkMode = _prefs?.getBool('isDarkMode') ?? true;
    await _loadCachedChats();
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
    return (currentTime - lastFetchTime) > 10 * 60 * 1000; // 10 minutes
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
        final uniqueChats = <int, Chat>{};
        for (var chat in cachedChatList) {
          uniqueChats[chat.id] = chat;
        }
        if (mounted) {
          setState(() {
            chats = uniqueChats.values.toList();
            chats.sort(
              (a, b) => int.parse(
                b.order ?? '0',
              ).compareTo(int.parse(a.order ?? '0')),
            );
            isLoading = false;
          });
        }
      } catch (e) {
        print('Error loading cached chats: $e');
        if (mounted) {
          setState(() {
            errorMessage = 'خطا در بارگذاری چت‌های ذخیره‌شده';
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

    while (retryCount < maxRetries && mounted) {
      try {
        if (!background) {
          setState(() {
            if (!loadMore) {
              isLoading = true;
            } else {
              isLoadingMore = true;
            }
            errorMessage = loadMore
                ? null
                : 'در حال اتصال به سرور... تلاش ${retryCount + 1}';
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
              final uniqueChats = <int, Chat>{};
              for (var chat in chats) {
                uniqueChats[chat.id] = chat;
              }
              for (var chat in newChats) {
                uniqueChats[chat.id] = chat;
              }
              chats = uniqueChats.values.toList();
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
              _prefs?.setString(
                'cached_chats_${widget.phoneNumber}',
                jsonEncode(chats.map((chat) => chat.toJson()).toList()),
              );
              _prefs?.setInt(
                'last_fetch_time_${widget.phoneNumber}',
                DateTime.now().millisecondsSinceEpoch,
              );
              retryCount = 0; // Reset retry count on success
            });
          }
          return;
        } else {
          throw Exception(
            'Backend responded with status: ${response.statusCode}',
          );
        }
      } catch (e) {
        retryCount++;
        if (retryCount >= maxRetries) {
          if (mounted && !background) {
            setState(() {
              errorMessage =
                  'خطا در اتصال به سرور پس از $maxRetries تلاش. لطفاً دوباره تلاش کنید.';
              isLoading = false;
              isLoadingMore = false;
            });
          }
          return;
        }

        // Exponential backoff
        final delay = baseDelay * (1 << retryCount);
        if (mounted && !background) {
          setState(() {
            errorMessage =
                'خطا در اتصال. تلاش مجدد پس از ${delay.inSeconds} ثانیه...';
          });
        }
        await Future.delayed(delay);
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

  void _toggleTheme() {
    setState(() {
      isDarkMode = !isDarkMode;
      _prefs?.setBool('isDarkMode', isDarkMode);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color backgroundColor = isDarkMode
        ? const Color(0xFF17212B)
        : const Color(0xFFEFEFEF);
    final Color appBarColor = isDarkMode
        ? const Color(0xFF2A3A4A)
        : const Color(0xFF5181B8);
    final Color textColor = isDarkMode ? Colors.white : Colors.black87;
    final Color errorColor = isDarkMode ? Colors.red[300]! : Colors.redAccent;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text(
          'تلگرام',
          style: TextStyle(
            fontFamily: 'Vazir',
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: appBarColor,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.menu, color: Colors.white),
          onPressed: () {
            Scaffold.of(context).openDrawer();
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search, color: Colors.white),
            onPressed: () {
              showSearch(context: context, delegate: ChatSearchDelegate(chats));
            },
          ),
          IconButton(
            icon: Icon(
              isDarkMode ? Icons.wb_sunny : Icons.nightlight_round,
              color: Colors.white,
            ),
            onPressed: _toggleTheme,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: () {
              offset = 0;
              retryCount = 0;
              _fetchChats();
            },
          ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(color: appBarColor),
              child: const Text(
                'منو',
                style: TextStyle(
                  fontFamily: 'Vazir',
                  color: Colors.white,
                  fontSize: 24,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text(
                'تنظیمات',
                style: TextStyle(fontFamily: 'Vazir'),
              ),
              onTap: () {
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.group_add),
              title: const Text(
                'گروه جدید',
                style: TextStyle(fontFamily: 'Vazir'),
              ),
              onTap: () {
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
      body: isLoading && chats.isEmpty
          ? Center(
              child: CircularProgressIndicator(
                color: appBarColor,
                strokeWidth: 3.0,
              ),
            )
          : RefreshIndicator(
              color: appBarColor,
              backgroundColor: backgroundColor,
              onRefresh: () async {
                offset = 0;
                retryCount = 0;
                await _fetchChats();
              },
              child: Column(
                children: [
                  if (errorMessage != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      color: errorColor.withOpacity(0.2),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            errorMessage!,
                            style: TextStyle(
                              color: errorColor,
                              fontSize: 14,
                              fontFamily: 'Vazir',
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              retryCount = 0;
                              _fetchChats();
                            },
                            child: Text(
                              'تلاش مجدد',
                              style: TextStyle(
                                color: isDarkMode
                                    ? Colors.blue[300]
                                    : Colors.blue[600],
                                fontFamily: 'Vazir',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: chats.isEmpty && !isLoading
                        ? Center(
                            child: Text(
                              'هیچ چتی موجود نیست',
                              style: TextStyle(
                                color: textColor.withOpacity(0.6),
                                fontSize: 16,
                                fontFamily: 'Vazir',
                              ),
                            ),
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            itemCount: chats.length + (isLoadingMore ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index == chats.length && isLoadingMore) {
                                return Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: CircularProgressIndicator(
                                      color: appBarColor,
                                      strokeWidth: 3.0,
                                    ),
                                  ),
                                );
                              }
                              final chat = chats[index];
                              return AnimatedOpacity(
                                opacity: 1.0,
                                duration: const Duration(milliseconds: 300),
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              ConversationScreen(
                                                chatId: chat.id,
                                                chatTitle: chat.id == 777000
                                                    ? 'اعلان‌های تلگرام'
                                                    : chat.title,
                                                phoneNumber: widget.phoneNumber,
                                              ),
                                        ),
                                      ).then((_) {
                                        _loadCachedChats();
                                      });
                                    },
                                    hoverColor: isDarkMode
                                        ? Colors.white.withOpacity(0.1)
                                        : Colors.black.withOpacity(0.05),
                                    child: ChatTile(
                                      chat: chat,
                                      isDarkMode: isDarkMode,
                                    ),
                                  ),
                                ),
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

class ChatSearchDelegate extends SearchDelegate {
  final List<Chat> chats;

  ChatSearchDelegate(this.chats);

  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () {
          query = '';
        },
      ),
    ];
  }

  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () {
        close(context, null);
      },
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    final results = chats
        .where((chat) => chat.title.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, index) {
        final chat = results[index];
        return ChatTile(
          chat: chat,
          isDarkMode: Theme.of(context).brightness == Brightness.dark,
        );
      },
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    final suggestions = chats
        .where((chat) => chat.title.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return ListView.builder(
      itemCount: suggestions.length,
      itemBuilder: (context, index) {
        final chat = suggestions[index];
        return ChatTile(
          chat: chat,
          isDarkMode: Theme.of(context).brightness == Brightness.dark,
        );
      },
    );
  }
}

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shamsi_date/shamsi_date.dart';
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
  Color? _errorMessageColor;
  int offset = 0;
  final int limit = 20;
  final ScrollController _scrollController = ScrollController();
  bool isDarkMode = true;
  SharedPreferences? _prefs;
  final TextEditingController _searchController = TextEditingController();
  int retryCount = 0;
  static const int maxRetries = 10;
  static const Duration baseDelay = Duration(seconds: 2);
  String? userFullName;

  @override
  void initState() {
    super.initState();
    _initPrefsAndLoadChats();
    _scrollController.addListener(_onScroll);
  }

  Future<void> _initPrefsAndLoadChats() async {
    _prefs = await SharedPreferences.getInstance();
    isDarkMode = _prefs?.getBool('isDarkMode') ?? true;
    userFullName = _prefs?.getString('user_full_name') ?? 'کاربر';
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
      _errorMessageColor = null;
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
        if (mounted) {
          setState(() {
            errorMessage = 'خطا در بارگذاری چت‌های ذخیره‌شده';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
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
              errorMessage = 'بروز رسانی لیست مخاطبین تلاش ${retryCount + 1}';
              _errorMessageColor = Colors.white; // رنگ متن سفید
            } else {
              isLoadingMore = true;
            }
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

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final newChats = (data['chats'] as List<dynamic>)
              .map((json) => Chat.fromJson(json))
              .toList();
          if (mounted) {
            setState(() {
              if (!background && !loadMore) {
                errorMessage = 'در حال به‌روزرسانی...';
                _errorMessageColor = Colors.green;
              }
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
                Future.delayed(const Duration(seconds: 2), () {
                  if (mounted) {
                    setState(() {
                      errorMessage = null;
                      _errorMessageColor = null;
                    });
                  }
                });
              }
              _prefs?.setString(
                'cached_chats_${widget.phoneNumber}',
                jsonEncode(chats.map((chat) => chat.toJson()).toList()),
              );
              _prefs?.setInt(
                'last_fetch_time_${widget.phoneNumber}',
                DateTime.now().millisecondsSinceEpoch,
              );
              retryCount = 0;
            });
          }
          return;
        } else {
          setState(() {
            errorMessage =
                'خطا در اتصال به سرور: کد وضعیت ${response.statusCode}';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
            if (!background) {
              isLoading = false;
              isLoadingMore = false;
            }
          });
        }
      } catch (e) {
        setState(() {
          errorMessage = 'خطا در اتصال به سرور: $e';
          _errorMessageColor = isDarkMode ? Colors.red[300] : Colors.redAccent;
          if (!background) {
            isLoading = false;
            isLoadingMore = false;
          }
        });
      }

      retryCount++;
      if (retryCount >= maxRetries) {
        if (mounted && !background) {
          setState(() {
            errorMessage =
                'خطا در اتصال به سرور پس از $maxRetries تلاش. لطفاً دوباره تلاش کنید.';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
            isLoading = false;
            isLoadingMore = false;
          });
        }
        return;
      }

      final delay = baseDelay * (1 << retryCount);
      if (mounted && !background) {
        setState(() {
          errorMessage =
              'خطا در اتصال. تلاش مجدد پس از ${delay.inSeconds} ثانیه...';
          _errorMessageColor = isDarkMode ? Colors.red[300] : Colors.redAccent;
        });
      }
      await Future.delayed(delay);
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

    // Format today's date in Persian (YYYY/MM/DD)
    final jalaliDate = Jalali.now();
    final today =
        '${jalaliDate.year}/${jalaliDate.month.toString().padLeft(2, '0')}/${jalaliDate.day.toString().padLeft(2, '0')}';

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // تاریخ در سمت چپ
            Text(
              today,
              style: const TextStyle(
                fontFamily: 'Vazir',
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: Colors.white70,
              ),
              textAlign: TextAlign.left,
              textDirection: TextDirection.rtl,
            ),
            // ویس گرام در سمت راست
            Text(
              'ویس گرام',
              style: const TextStyle(
                fontFamily: 'Vazir',
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
              textAlign: TextAlign.right,
              textDirection: TextDirection.rtl,
            ),
          ],
        ),
        backgroundColor: appBarColor,
        elevation: 0,
        leading: Builder(
          builder: (BuildContext context) {
            return IconButton(
              icon: const Icon(Icons.menu, color: Colors.white),
              onPressed: () {
                Scaffold.of(context).openDrawer();
              },
            );
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
                'ویس گرام',
                style: TextStyle(
                  fontFamily: 'Vazir',
                  color: Colors.white,
                  fontSize: 24,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person),
              title: Text(
                userFullName ?? 'کاربر',
                style: const TextStyle(fontFamily: 'Vazir'),
              ),
              onTap: () {
                Navigator.pop(context);
              },
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
            ListTile(
              leading: const Icon(Icons.support_agent),
              title: const Text(
                'پشتیبانی',
                style: TextStyle(fontFamily: 'Vazir'),
              ),
              onTap: () {
                Navigator.pop(context);
                // TODO: Add support action (e.g., open email or chat)
              },
            ),
            ListTile(
              leading: const Icon(Icons.info),
              title: const Text(
                'نسخه برنامه: ۱ بتا',
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
                      color: errorMessage!.contains('بروز رسانی لیست مخاطبین')
                          ? Colors.green.withOpacity(0.9) // پس‌زمینه سبز
                          : (_errorMessageColor?.withOpacity(0.2) ??
                                errorColor.withOpacity(0.9)),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            errorMessage!,
                            style: TextStyle(
                              color: _errorMessageColor ?? errorColor,
                              fontSize: 14,
                              fontFamily: 'Vazir',
                            ),
                          ),
                          if (_errorMessageColor != Colors.green &&
                              !errorMessage!.contains(
                                'بروز رسانی لیست مخاطبین',
                              ))
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

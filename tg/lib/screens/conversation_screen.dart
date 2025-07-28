import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart' as AudioPlayers;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart' as Record;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart' as intl;
import 'package:intl/date_symbol_data_local.dart';
import '../models/message.dart';
import 'auth_screen.dart';

class ConversationScreen extends StatefulWidget {
  final int chatId;
  final String chatTitle;
  final String phoneNumber;

  const ConversationScreen({
    required this.chatId,
    required this.chatTitle,
    required this.phoneNumber,
    super.key,
  });

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen>
    with SingleTickerProviderStateMixin {
  List<Message> messages = [];
  String? errorMessage;
  Color? _errorMessageColor;
  bool isLoading = true;
  final TextEditingController _messageController = TextEditingController();
  final AudioPlayers.AudioPlayer _audioPlayer = AudioPlayers.AudioPlayer();
  final Record.AudioRecorder _recorder = Record.AudioRecorder();
  final ScrollController _scrollController = ScrollController();
  bool _isRecording = false;
  bool _isPlaying = false;
  bool _isAudioLoading = false;
  String? _recordedFilePath;
  int? _recordingDuration;
  List<double>? _waveformData;
  bool _isWaveformLoading = false;
  Duration _audioPosition = Duration.zero;
  Duration _audioDuration = Duration.zero;
  String? _currentPlayingUrl;
  StreamSubscription<AudioPlayers.PlayerState>? _playerStateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  Timer? _recordingTimer;
  bool isDarkMode = true;
  SharedPreferences? _prefs;
  late AnimationController _animationController;
  late Animation<double> _waveformAnimation;
  int _fetchRetryCount = 0;
  int _sendMessageRetryCount = 0;
  int _sendVoiceRetryCount = 0;
  Map<String, String> _pendingMessages = {};
  bool _isSendingMessage = false;

  static const int maxRetries = 10;
  static const List<int> retryDelaysInSeconds = [
    3,
    5,
    10,
    15,
    30,
    60,
    60,
    60,
    60,
    60,
  ];

  @override
  void initState() {
    super.initState();
    _initPrefs();
    initializeDateFormatting('fa_IR', null).then((_) {
      _fetchMessages();
    });
    _setupAudioPlayer();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
    _waveformAnimation = Tween<double>(begin: 0.9, end: 1.1).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeInOutSine,
      ),
    );
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        isDarkMode = _prefs?.getBool('isDarkMode') ?? true;
      });
    }
  }

  void _setupAudioPlayer() {
    _playerStateSubscription = _audioPlayer.onPlayerStateChanged.listen((
      state,
    ) {
      if (mounted) {
        setState(() {
          _isPlaying = state == AudioPlayers.PlayerState.playing;
          if (state == AudioPlayers.PlayerState.completed ||
              state == AudioPlayers.PlayerState.stopped) {
            _isPlaying = false;
            _isAudioLoading = false;
            _audioPosition = Duration.zero;
            _currentPlayingUrl = null;
            _animationController.reset();
          } else if (state == AudioPlayers.PlayerState.playing) {
            _animationController.forward();
          }
        });
      }
    });

    _positionSubscription = _audioPlayer.onPositionChanged.listen((position) {
      if (mounted) {
        setState(() => _audioPosition = position);
      }
    });

    _durationSubscription = _audioPlayer.onDurationChanged.listen((duration) {
      if (mounted) {
        setState(() => _audioDuration = duration ?? Duration.zero);
      }
    });
  }

  Future<bool> _checkSession() async {
    try {
      print('Checking session for phone_number=${widget.phoneNumber}');
      setState(() {
        errorMessage = 'در حال بررسی نشست...';
        _errorMessageColor = isDarkMode
            ? Colors.yellow[300]
            : Colors.yellowAccent;
      });
      final response = await http.post(
        Uri.parse('http://192.168.1.3:8000/check_session'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'phone_number': widget.phoneNumber}),
      );
      print('Check session response: ${response.statusCode} ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        bool isAuthenticated = data['is_authenticated'] ?? false;
        print(
          'Session check result: isAuthenticated=$isAuthenticated, auth_state=${data['auth_state']}',
        );

        if (!isAuthenticated && mounted) {
          print('Not authenticated, redirecting to AuthScreen');
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => AuthScreen(
                phoneNumber: widget.phoneNumber,
                initialState:
                    data['auth_state'] == 'authorizationStateWaitPhoneNumber'
                    ? 'wait_phone'
                    : data['auth_state'],
              ),
            ),
          );
        } else if (isAuthenticated) {
          print('Authenticated, clearing error');
          if (mounted) {
            setState(() {
              errorMessage = null;
              _errorMessageColor = null;
            });
          }
        }
        return isAuthenticated;
      } else {
        throw Exception(
          'Check session failed with status: ${response.statusCode}',
        );
      }
    } catch (e, stackTrace) {
      print('Error checking session: $e\n$stackTrace');
      if (mounted) {
        setState(() {
          errorMessage = 'خطا در بررسی جلسه: $e';
          _errorMessageColor = isDarkMode ? Colors.red[300] : Colors.redAccent;
        });
      }
      return false;
    }
  }

  Future<void> _fetchMessages({int limit = 50}) async {
    bool isRetrying = false;
    try {
      print('Starting fetchMessages: limit=$limit');
      if (mounted) {
        setState(() {
          isLoading = true;
          errorMessage = 'در حال اتصال به سرور';
          _errorMessageColor = isDarkMode ? Colors.red[300] : Colors.redAccent;
        });
      }

      print(
        'Sending get messages request: phone_number=${widget.phoneNumber}, chat_id=${widget.chatId}, limit=$limit',
      );
      final response = await http.post(
        Uri.parse('http://192.168.1.3:8000/get_messages'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'phone_number': widget.phoneNumber,
          'chat_id': widget.chatId,
          'limit': limit,
          'from_message_id': 0,
        }),
      );

      print('Get messages response: ${response.statusCode} ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted) {
          setState(() {
            errorMessage = 'در حال دریافت پیام‌ها از سرور';
            _errorMessageColor = Colors.green;
          });
          await Future.delayed(const Duration(seconds: 2));
        }

        final newMessages = (data['messages'] as List<dynamic>)
            .map((json) {
              try {
                return Message.fromJson(json);
              } catch (e) {
                print('Error parsing message JSON: $json\nError: $e');
                return null;
              }
            })
            .where((msg) => msg != null)
            .cast<Message>()
            .toList();

        print(
          'Fetched ${newMessages.length} messages: ${newMessages.map((m) => 'id=${m.id}, content=${m.content}').join(', ')}',
        );

        if (mounted) {
          setState(() {
            final existingMessages = Map.fromEntries(
              messages.map((msg) => MapEntry(msg.id, msg)),
            );

            for (var newMessage in newMessages) {
              if (newMessage.isOutgoing) {
                final pendingKey = _pendingMessages.keys.firstWhere(
                  (key) => _pendingMessages[key] == newMessage.content,
                  orElse: () => '',
                );
                if (pendingKey.isNotEmpty) {
                  print('Removing pending message with tempId=$pendingKey');
                  existingMessages.remove(
                    int.parse(pendingKey.replaceAll('temp_', '')),
                  );
                  _pendingMessages.remove(pendingKey);
                  print(
                    'Replaced pending message $pendingKey with ${newMessage.id}',
                  );
                }
              }
              existingMessages[newMessage.id] = newMessage;
            }

            messages = existingMessages.values.toList();
            messages.sort((a, b) => a.date.compareTo(b.date));

            print('Updated messages list: ${messages.length} messages');

            isLoading = false;
            errorMessage = null;
            _errorMessageColor = null;
            _fetchRetryCount = 0;
          });

          Future.delayed(const Duration(milliseconds: 100), () {
            if (_scrollController.hasClients && mounted) {
              print(
                'Scrolling to maxScrollExtent: ${_scrollController.position.maxScrollExtent}',
              );
              _scrollController.animateTo(
                _scrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            }
          });
        }
        print('Messages fetched successfully: ${newMessages.length} messages');
      } else if (response.statusCode == 401) {
        print('Unauthorized, checking session');
        bool isAuthenticated = await _checkSession();
        if (!isAuthenticated && mounted) {
          setState(() {
            isLoading = false;
            errorMessage = 'نیاز به احراز هویت. لطفاً وارد شوید.';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
            _fetchRetryCount = 0;
          });
        }
      } else {
        throw Exception(
          'Backend responded with status: ${response.statusCode}',
        );
      }
    } catch (e, stackTrace) {
      print('Error fetching messages: $e\n$stackTrace');
      if (_fetchRetryCount >= maxRetries) {
        if (mounted) {
          setState(() {
            errorMessage =
                'خطا در اتصال به سرور پس از $maxRetries تلاش. لطفاً دوباره تلاش کنید.';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
            isLoading = false;
            _fetchRetryCount = 0;
          });
        }
        print('Max retries reached, stopping fetch attempts');
        return;
      }

      final delaySeconds =
          retryDelaysInSeconds[_fetchRetryCount < retryDelaysInSeconds.length
              ? _fetchRetryCount
              : retryDelaysInSeconds.length - 1];
      _fetchRetryCount++;
      if (mounted) {
        setState(() {
          errorMessage =
              'تلاش مجدد در حال اتصال به سرور، تلاش $_fetchRetryCount، پس از $delaySeconds ثانیه';
          _errorMessageColor = isDarkMode
              ? Colors.yellow[300]
              : Colors.yellowAccent;
        });
        print('Waiting for $delaySeconds seconds before retry (fetch)...');
        await Future.delayed(Duration(seconds: delaySeconds));
        isRetrying = false;
        await _fetchMessages(limit: limit);
      }
    } finally {
      if (mounted) {
        setState(() {
          isRetrying = false;
        });
      }
      print('Fetch messages finally block: isRetrying reset to false');
    }
  }

  Future<void> _sendMessage() async {
    if (_isSendingMessage) {
      print('Send message blocked: already sending');
      return;
    }

    final text = _messageController.text.trim();
    if (text.isEmpty) {
      print('Send message blocked: empty message');
      return;
    }

    print('Attempting to send message: text=$text');
    setState(() {
      _isSendingMessage = true;
    });

    final tempId = 'temp_${DateTime.now().millisecondsSinceEpoch}';

    try {
      if (mounted) {
        setState(() {
          _pendingMessages[tempId] = text;
          messages = [
            ...messages,
            Message(
              id: int.parse(tempId.replaceAll('temp_', '')),
              content: text,
              isVoice: false,
              voiceUrl: null,
              duration: 0,
              isOutgoing: true,
              date: DateTime.now(),
              waveformData: null,
            ),
          ];
          messages.sort((a, b) => a.date.compareTo(b.date));
          _messageController.clear();
        });
        Future.delayed(const Duration(milliseconds: 100), () {
          if (_scrollController.hasClients && mounted) {
            print(
              'Scrolling to maxScrollExtent: ${_scrollController.position.maxScrollExtent}',
            );
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });
      }

      print(
        'Sending message request: phone_number=${widget.phoneNumber}, chat_id=${widget.chatId}, message=$text',
      );
      final response = await http.post(
        Uri.parse('http://192.168.1.3:8000/send_message'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'phone_number': widget.phoneNumber,
          'chat_id': widget.chatId,
          'message': text,
        }),
      );
      print('Send message response: ${response.statusCode} ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('Send message response data: $data');
        if (mounted) {
          setState(() {
            errorMessage = null;
            _errorMessageColor = null;
          });
          await _fetchMessages();
        }
        _sendMessageRetryCount = 0;
      } else if (response.statusCode == 401) {
        print('Unauthorized, checking session');
        bool isAuthenticated = await _checkSession();
        if (!isAuthenticated && mounted) {
          setState(() {
            errorMessage = 'نیاز به احراز هویت. لطفاً وارد شوید.';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
            messages.removeWhere((msg) => msg.id.toString() == tempId);
            _pendingMessages.remove(tempId);
            _sendMessageRetryCount = 0;
          });
        }
      } else {
        throw Exception(
          'Backend responded with status: ${response.statusCode}',
        );
      }
    } catch (e, stackTrace) {
      print('Error sending message: $e\n$stackTrace');
      if (_sendMessageRetryCount >= maxRetries) {
        if (mounted) {
          setState(() {
            errorMessage =
                'خطا در ارسال پیام پس از $maxRetries تلاش. لطفاً دوباره تلاش کنید.';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
            messages.removeWhere((msg) => msg.id.toString() == tempId);
            _pendingMessages.remove(tempId);
            _sendMessageRetryCount = 0;
          });
        }
      } else {
        final delaySeconds =
            retryDelaysInSeconds[_sendMessageRetryCount <
                    retryDelaysInSeconds.length
                ? _sendMessageRetryCount
                : retryDelaysInSeconds.length - 1];
        _sendMessageRetryCount++;
        if (mounted) {
          setState(() {
            errorMessage =
                'تلاش مجدد در ارسال پیام، تلاش $_sendMessageRetryCount، پس از $delaySeconds ثانیه';
            _errorMessageColor = isDarkMode
                ? Colors.yellow[300]
                : Colors.yellowAccent;
          });
          print(
            'Waiting for $delaySeconds seconds before retry (send message)...',
          );
          await Future.delayed(Duration(seconds: delaySeconds));
          await _sendMessage();
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSendingMessage = false;
        });
      }
      print('Send message finally block: _isSendingMessage reset to false');
    }
  }

  Future<void> _sendVoiceMessage() async {
    if (_recordedFilePath == null || _recordingDuration == null) {
      if (mounted) {
        setState(() {
          errorMessage = 'هیچ ضبطی برای ارسال موجود نیست';
          _errorMessageColor = isDarkMode ? Colors.red[300] : Colors.redAccent;
        });
      }
      return;
    }

    try {
      setState(() {
        errorMessage = 'در حال ارسال پیام صوتی...';
        _errorMessageColor = isDarkMode
            ? Colors.yellow[300]
            : Colors.yellowAccent;
      });

      final file = File(_recordedFilePath!);
      if (!await file.exists()) {
        if (mounted) {
          setState(() {
            errorMessage = 'فایل ضبط‌شده یافت نشد';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
          });
        }
        return;
      }

      var request = http.MultipartRequest(
        'POST',
        Uri.parse('http://192.168.1.3:8000/send_voice_message'),
      );
      request.fields['request'] = jsonEncode({
        'phone_number': widget.phoneNumber,
        'chat_id': widget.chatId,
        'duration': _recordingDuration,
      });
      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          _recordedFilePath!,
          filename: 'voice.wav',
        ),
      );
      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      print('Send voice response: ${response.statusCode} $responseBody');

      if (response.statusCode == 200) {
        final data = jsonDecode(responseBody);
        print('Send voice response data: $data');
        // Treat as success unless it's a critical error
        if (data['status'] == 'error' &&
            data['message'] != 'No valid message event received') {
          if (mounted) {
            setState(() {
              errorMessage =
                  'خطا در ارسال پیام صوتی: ${data['message'] ?? 'نامشخص'}';
              _errorMessageColor = isDarkMode
                  ? Colors.red[300]
                  : Colors.redAccent;
              _sendVoiceRetryCount = 0;
            });
          }
        } else {
          if (mounted) {
            setState(() {
              errorMessage = null;
              _errorMessageColor = null;
              _recordedFilePath = null;
              _recordingDuration = null;
              _waveformData = null;
              _isWaveformLoading = false;
              _sendVoiceRetryCount = 0;
            });
            await _fetchMessages();
          }
          await file.delete();
        }
      } else if (response.statusCode == 401) {
        bool isAuthenticated = await _checkSession();
        if (!isAuthenticated && mounted) {
          setState(() {
            errorMessage = 'نیاز به احراز هویت. لطفاً وارد شوید.';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
            _sendVoiceRetryCount = 0;
          });
        }
      } else {
        throw Exception(
          'Backend responded with status: ${response.statusCode}',
        );
      }
    } catch (e, stackTrace) {
      print('Error sending voice message: $e\n$stackTrace');
      if (_sendVoiceRetryCount >= maxRetries) {
        if (mounted) {
          setState(() {
            errorMessage =
                'خطا در ارسال پیام صوتی پس از $maxRetries تلاش. لطفاً دوباره تلاش کنید.';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
            _sendVoiceRetryCount = 0;
          });
        }
      } else {
        final delaySeconds =
            retryDelaysInSeconds[_sendVoiceRetryCount <
                    retryDelaysInSeconds.length
                ? _sendVoiceRetryCount
                : retryDelaysInSeconds.length - 1];
        _sendVoiceRetryCount++;
        if (mounted) {
          setState(() {
            errorMessage =
                'تلاش مجدد در ارسال پیام صوتی، تلاش $_sendVoiceRetryCount، پس از $delaySeconds ثانیه';
            _errorMessageColor = isDarkMode
                ? Colors.yellow[300]
                : Colors.yellowAccent;
          });
          print(
            'Waiting for $delaySeconds seconds before retry (send voice)...',
          );
          await Future.delayed(Duration(seconds: delaySeconds));
          await _sendVoiceMessage();
        }
      }
    }
  }

  Future<void> _startRecording() async {
    try {
      if (await Permission.microphone.request().isGranted) {
        final tempDir = await getTemporaryDirectory();
        _recordedFilePath =
            '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.wav';
        await _recorder.start(
          const Record.RecordConfig(
            encoder: Record.AudioEncoder.wav,
            bitRate: 64000,
            sampleRate: 16000,
            numChannels: 1,
          ),
          path: _recordedFilePath!,
        );
        if (mounted) {
          setState(() {
            _isRecording = true;
            _recordingDuration = 0;
            _waveformData = null;
            _isWaveformLoading = false;
            errorMessage = null;
            _errorMessageColor = null;
          });
          _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
            if (!_isRecording || !mounted) {
              timer.cancel();
              return;
            }
            setState(() => _recordingDuration = (_recordingDuration ?? 0) + 1);
          });
        }
      } else {
        if (mounted) {
          setState(() {
            errorMessage = 'نیاز به اجازه دسترسی به میکروفون';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRecording = false;
          errorMessage = 'خطا در شروع ضبط';
          _errorMessageColor = isDarkMode ? Colors.red[300] : Colors.redAccent;
        });
      }
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;
    try {
      final path = await _recorder.stop();
      if (mounted && path != null && await File(path).exists()) {
        setState(() {
          _isRecording = false;
          _isWaveformLoading = true;
        });
        await _sendVoiceMessage();
      } else {
        if (mounted) {
          setState(() {
            _isWaveformLoading = false;
            _isRecording = false;
            errorMessage = 'فایل ضبط‌شده یافت نشد';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isWaveformLoading = false;
          _isRecording = false;
          errorMessage = 'خطا در توقف ضبط';
          _errorMessageColor = isDarkMode ? Colors.red[300] : Colors.redAccent;
        });
      }
    } finally {
      _recordingTimer?.cancel();
    }
  }

  Future<void> _playVoice(String? url) async {
    if (url == null || url.isEmpty) {
      print('Invalid voice URL: $url');
      if (mounted) {
        setState(() {
          errorMessage = 'آدرس صوتی معتبر نیست';
          _errorMessageColor = isDarkMode ? Colors.red[300] : Colors.redAccent;
        });
      }
      return;
    }
    try {
      print('Attempting to play voice URL: $url');
      setState(() => _isAudioLoading = true);

      final response = await http.head(Uri.parse(url));
      print(
        'HEAD response for $url: ${response.statusCode} ${response.headers}',
      );
      if (response.statusCode != 200) {
        throw Exception(
          'Cannot access audio file: HTTP ${response.statusCode}',
        );
      }

      await _audioPlayer.stop();

      if (kIsWeb) {
        await _audioPlayer.play(
          AudioPlayers.UrlSource(url, mimeType: 'audio/wav'),
        );
      } else {
        final tempDir = await getTemporaryDirectory();
        final filePath =
            '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.wav';
        final file = File(filePath);
        final audioResponse = await http.get(Uri.parse(url));
        if (audioResponse.statusCode == 200) {
          await file.writeAsBytes(audioResponse.bodyBytes);
          await _audioPlayer.play(
            AudioPlayers.DeviceFileSource(filePath, mimeType: 'audio/wav'),
          );
          print('Playback started for $url (local file: $filePath)');
        } else {
          throw Exception(
            'Failed to download audio file: HTTP ${audioResponse.statusCode}',
          );
        }
      }

      if (mounted) {
        setState(() {
          _isPlaying = true;
          _isAudioLoading = false;
          _currentPlayingUrl = url;
        });
      }
    } catch (e) {
      print('Playback error for $url: $e');
      if (mounted) {
        setState(() {
          _isAudioLoading = false;
          _isPlaying = false;
          errorMessage = 'خطا در پخش پیام صوتی';
          _errorMessageColor = isDarkMode ? Colors.red[300] : Colors.redAccent;
        });
      }
    }
  }

  Future<void> _stopAudio() async {
    try {
      await _audioPlayer.stop();
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _audioPosition = Duration.zero;
          _currentPlayingUrl = null;
        });
      }
    } catch (e) {
      print('Error stopping audio: $e');
      if (mounted) {
        setState(() {
          errorMessage = 'خطا در توقف پخش';
          _errorMessageColor = isDarkMode ? Colors.red[300] : Colors.redAccent;
        });
      }
    }
  }

  void _toggleTheme() {
    setState(() {
      isDarkMode = !isDarkMode;
      _prefs?.setBool('isDarkMode', isDarkMode);
    });
  }

  String _formatTimestamp(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(date.year, date.month, date.day);
    if (messageDate == today) {
      return intl.DateFormat('HH:mm').format(date);
    } else if (date.year == now.year) {
      return intl.DateFormat('dd MMM', 'fa_IR').format(date);
    } else {
      return intl.DateFormat('yyyy MMM dd', 'fa_IR').format(date);
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _audioPlayer.dispose();
    _recorder.dispose();
    _scrollController.dispose();
    _playerStateSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _recordingTimer?.cancel();
    _animationController.dispose();
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
        title: Text(
          widget.chatTitle,
          style: const TextStyle(
            fontFamily: 'Courier',
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: appBarColor,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _fetchMessages,
          ),
          IconButton(
            icon: Icon(
              isDarkMode ? Icons.wb_sunny : Icons.nightlight_round,
              color: Colors.white,
            ),
            onPressed: _toggleTheme,
          ),
        ],
      ),
      body: Column(
        children: [
          if (errorMessage != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: (_errorMessageColor ?? errorColor).withOpacity(0.2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    errorMessage!,
                    style: TextStyle(
                      color: _errorMessageColor ?? errorColor,
                      fontSize: 14,
                      fontFamily: 'Courier',
                    ),
                  ),
                  if (errorMessage!.contains('تلاش') ||
                      errorMessage!.contains('نیاز به احراز هویت'))
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _fetchRetryCount = 0;
                          _sendMessageRetryCount = 0;
                          _sendVoiceRetryCount = 0;
                          errorMessage = null;
                          _errorMessageColor = null;
                        });
                        _fetchMessages();
                      },
                      child: Text(
                        'تلاش مجدد',
                        style: TextStyle(
                          color: isDarkMode
                              ? Colors.blue[300]
                              : Colors.blue[600],
                          fontFamily: 'Courier',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: isLoading
                ? Center(
                    child: CircularProgressIndicator(
                      color: appBarColor,
                      strokeWidth: 3.0,
                    ),
                  )
                : messages.isEmpty
                ? Center(
                    child: Text(
                      'هیچ پیامی موجود نیست',
                      style: TextStyle(
                        color: textColor.withOpacity(0.6),
                        fontSize: 16,
                        fontFamily: 'Courier',
                      ),
                    ),
                  )
                : ListView.builder(
                    key: ValueKey(
                      '${messages.length}_${messages.isNotEmpty ? messages.last.id : 0}',
                    ),
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      print(
                        'Rendering message: id=${message.id}, content=${message.content}, isOutgoing=${message.isOutgoing}',
                      );
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 4.0,
                          horizontal: 8.0,
                        ),
                        child: Align(
                          alignment: message.isOutgoing
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Column(
                            crossAxisAlignment: message.isOutgoing
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              Container(
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context).size.width * 0.7,
                                ),
                                padding: const EdgeInsets.all(10.0),
                                decoration: BoxDecoration(
                                  color: message.isOutgoing
                                      ? (isDarkMode
                                            ? const Color(0xFF005F42)
                                            : Colors.blue[100])
                                      : (isDarkMode
                                            ? Colors.grey[900]
                                            : Colors.white),
                                  borderRadius: BorderRadius.circular(8),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(
                                        isDarkMode ? 0.2 : 0.1,
                                      ),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: message.isVoice
                                    ? Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: Icon(
                                              _isPlaying &&
                                                      _currentPlayingUrl ==
                                                          message.voiceUrl
                                                  ? Icons.pause
                                                  : Icons.play_arrow,
                                              color: isDarkMode
                                                  ? Colors.white
                                                  : Colors.black87,
                                              size: 28,
                                            ),
                                            onPressed:
                                                _isAudioLoading &&
                                                    _currentPlayingUrl ==
                                                        message.voiceUrl
                                                ? null
                                                : () {
                                                    if (_isPlaying &&
                                                        _currentPlayingUrl ==
                                                            message.voiceUrl) {
                                                      _stopAudio();
                                                    } else if (message
                                                            .voiceUrl !=
                                                        null) {
                                                      _playVoice(
                                                        message.voiceUrl,
                                                      );
                                                    } else {
                                                      setState(() {
                                                        errorMessage =
                                                            'پیام صوتی در دسترس نیست';
                                                        _errorMessageColor =
                                                            isDarkMode
                                                            ? Colors.red[300]
                                                            : Colors.redAccent;
                                                      });
                                                    }
                                                  },
                                          ),
                                          const SizedBox(width: 8),
                                          Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${message.duration ?? 0} ثانیه',
                                                style: TextStyle(
                                                  fontFamily: 'Courier',
                                                  fontSize: 12,
                                                  color: textColor,
                                                ),
                                              ),
                                              if (_isWaveformLoading &&
                                                  message.isOutgoing &&
                                                  message.voiceUrl == null)
                                                const SizedBox(
                                                  width: 150,
                                                  height: 20,
                                                  child:
                                                      LinearProgressIndicator(),
                                                ),
                                              if (message.waveformData !=
                                                      null &&
                                                  (!_isWaveformLoading ||
                                                      message.voiceUrl != null))
                                                SizedBox(
                                                  height: 24,
                                                  width: 150,
                                                  child: AnimatedBuilder(
                                                    animation:
                                                        _waveformAnimation,
                                                    builder: (context, _) {
                                                      return CustomPaint(
                                                        painter: WaveformPainter(
                                                          data: message
                                                              .waveformData!,
                                                          isPlaying:
                                                              _isPlaying &&
                                                              _currentPlayingUrl ==
                                                                  message
                                                                      .voiceUrl,
                                                          progress:
                                                              _audioDuration
                                                                      .inMilliseconds >
                                                                  0
                                                              ? _audioPosition
                                                                        .inMilliseconds /
                                                                    _audioDuration
                                                                        .inMilliseconds
                                                              : 0.0,
                                                          isDarkMode:
                                                              isDarkMode,
                                                          animationValue:
                                                              _waveformAnimation
                                                                  .value,
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              if (_isPlaying &&
                                                  _currentPlayingUrl ==
                                                      message.voiceUrl)
                                                Text(
                                                  '${_audioPosition.inSeconds} / ${_audioDuration.inSeconds} ثانیه',
                                                  style: TextStyle(
                                                    fontFamily: 'Courier',
                                                    fontSize: 10,
                                                    color: textColor,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ],
                                      )
                                    : Text(
                                        message.content ?? '',
                                        style: TextStyle(
                                          fontFamily: 'Courier',
                                          fontSize: 16,
                                          color: textColor,
                                        ),
                                      ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _formatTimestamp(message.date),
                                style: TextStyle(
                                  color: textColor.withOpacity(0.6),
                                  fontSize: 12,
                                  fontFamily: 'Courier',
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
            color: isDarkMode ? Colors.grey[900] : const Color(0xFFF5F5F5),
            child: Row(
              children: [
                Expanded(
                  child: Directionality(
                    textDirection: TextDirection.rtl,
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: 'پیام خود را بنویسید...',
                        hintStyle: TextStyle(
                          color: textColor.withOpacity(0.6),
                          fontFamily: 'Arial',
                        ),
                        filled: true,
                        fillColor: isDarkMode ? Colors.grey[800] : Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      style: TextStyle(color: textColor, fontFamily: 'Arial'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FloatingActionButton(
                  mini: true,
                  heroTag: "record_button_${widget.chatId}",
                  backgroundColor: appBarColor,
                  onPressed: _isRecording ? _stopRecording : _startRecording,
                  child: Icon(
                    _isRecording ? Icons.stop : Icons.mic,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 8),
                FloatingActionButton(
                  mini: true,
                  heroTag: "send_button_${widget.chatId}",
                  backgroundColor: appBarColor,
                  onPressed: _isSendingMessage ? null : _sendMessage,
                  child: const Icon(Icons.send, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class WaveformPainter extends CustomPainter {
  final List<double> data;
  final bool isPlaying;
  final double progress;
  final bool isDarkMode;
  final double animationValue;

  WaveformPainter({
    required this.data,
    required this.isPlaying,
    required this.progress,
    required this.isDarkMode,
    required this.animationValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final barWidth = 3.0;
    final barSpacing = 4.0;
    final totalBarWidth = barWidth + barSpacing;
    final barCount = (size.width / totalBarWidth).floor();
    final height = size.height;

    final bgPaint = Paint()
      ..color = isDarkMode ? Colors.grey[600]! : Colors.grey[400]!
      ..style = PaintingStyle.fill;

    final fgPaint = Paint()
      ..color = isDarkMode ? Colors.green[400]! : Colors.blue[600]!
      ..style = PaintingStyle.fill;

    final normalizedData = _normalizeData(data, barCount);

    for (int i = 0; i < barCount; i++) {
      final x = i * totalBarWidth;
      final dataIndex = (i * (normalizedData.length / barCount)).floor().clamp(
        0,
        normalizedData.length - 1,
      );
      var amplitude = normalizedData[dataIndex] * (height / 2) * 0.8;

      if (isPlaying && (x / size.width) <= progress) {
        amplitude *= animationValue;
      }

      amplitude = amplitude < 1.0 ? 1.0 : amplitude;

      final paint = (isPlaying && (x / size.width) <= progress)
          ? fgPaint
          : bgPaint;
      canvas.drawRect(
        Rect.fromLTWH(x, height / 2 - amplitude, barWidth, amplitude * 2),
        paint,
      );
    }
  }

  List<double> _normalizeData(List<double> data, int barCount) {
    if (data.isEmpty) return List.filled(barCount, 0.0);

    final filteredData = data.where((x) => x.isFinite && x >= 0).toList();
    if (filteredData.isEmpty) return List.filled(barCount, 0.0);

    final maxAmplitude = filteredData.reduce((a, b) => a > b ? a : b);
    final normalized = filteredData
        .map((x) => maxAmplitude > 0 ? x / maxAmplitude : 0.0)
        .toList();

    final step = normalized.length / barCount;
    final List<double> result = [];
    for (var i = 0; i < barCount; i++) {
      final index = (i * step).floor().clamp(0, normalized.length - 1);
      result.add(normalized[index]);
    }
    return result;
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    final oldPainter = oldDelegate as WaveformPainter;
    return oldPainter.data != data ||
        oldPainter.isPlaying != isPlaying ||
        oldPainter.progress != progress ||
        oldPainter.isDarkMode != isDarkMode ||
        oldPainter.animationValue != animationValue;
  }
}

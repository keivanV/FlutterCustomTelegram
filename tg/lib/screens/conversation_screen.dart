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
  bool isLoadingMore = false;
  int? oldestMessageId;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _messageController = TextEditingController();
  final AudioPlayers.AudioPlayer _audioPlayer = AudioPlayers.AudioPlayer();
  final Record.AudioRecorder _recorder = Record.AudioRecorder();
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
  bool _isAtBottom = true;
  bool isDarkMode = true;
  SharedPreferences? _prefs;
  late AnimationController _animationController;
  late Animation<double> _waveformAnimation;
  int _fetchRetryCount = 0;
  int _sendMessageRetryCount = 0;
  int _sendVoiceRetryCount = 0;
  bool _isRetrying = false;
  static const int maxRetries = 10;
  static const List<int> retryDelaysInSeconds = [
    3,
    5,
    15,
    30,
    60,
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
    _scrollController.addListener(_onScroll);
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

  void _onScroll() {
    if (_scrollController.hasClients) {
      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentScroll = _scrollController.position.pixels;
      _isAtBottom = currentScroll >= maxScroll - 50;

      if (currentScroll <= _scrollController.position.minScrollExtent + 100 &&
          !isLoadingMore &&
          oldestMessageId != null) {
        _fetchMessages(fromMessageId: oldestMessageId);
      }
    }
  }

  Future<bool> _checkSession() async {
    try {
      setState(() {
        errorMessage = 'در حال بررسی جلسه...';
        _errorMessageColor = isDarkMode
            ? Colors.yellow[300]
            : Colors.yellowAccent;
      });
      final response = await http.post(
        Uri.parse('http://192.168.1.3:8000/check_session'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'phone_number': widget.phoneNumber}),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        bool isAuthenticated = data['is_authenticated'];
        if (!isAuthenticated && mounted) {
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
        }
        print('Check session response: ${response.statusCode} $data');
        return isAuthenticated;
      }
      return false;
    } catch (e) {
      print('Error checking session: $e');
      return false;
    }
  }

  Future<void> _fetchMessages({int? fromMessageId, int limit = 50}) async {
    if (isLoadingMore || _isRetrying) return;
    _isRetrying = true;

    try {
      setState(() {
        if (fromMessageId == null) {
          isLoading = true;
          errorMessage = 'در حال اتصال به سرور';
          _errorMessageColor = isDarkMode ? Colors.red[300] : Colors.redAccent;
        } else {
          isLoadingMore = true;
        }
      });

      final response = await http.post(
        Uri.parse('http://192.168.1.3:8000/get_messages'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'phone_number': widget.phoneNumber,
          'chat_id': widget.chatId,
          'limit': limit,
          'from_message_id': fromMessageId ?? 0,
        }),
      );

      print(
        'Get messages request: phone_number=${widget.phoneNumber}, chat_id=${widget.chatId}, from_message_id=${fromMessageId ?? 0}',
      );
      print('Get messages response: ${response.statusCode} ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['messages'] == null || data['messages'].isEmpty) {
          if (mounted) {
            setState(() {
              isLoading = false;
              isLoadingMore = false;
              errorMessage = 'هیچ پیامی دریافت نشد';
              _errorMessageColor = isDarkMode
                  ? Colors.red[300]
                  : Colors.redAccent;
              _fetchRetryCount = 0;
            });
          }
          return;
        }

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

        if (mounted) {
          setState(() {
            final existingMessageIds = {for (var msg in messages) msg.id: msg};
            for (var message in newMessages) {
              if (!existingMessageIds.containsKey(message.id)) {
                if (fromMessageId != null) {
                  messages.insert(0, message);
                } else {
                  messages.add(message);
                }
              } else if (message.isVoice &&
                  existingMessageIds[message.id]!.voiceUrl == null &&
                  message.voiceUrl != null) {
                final index = messages.indexWhere((m) => m.id == message.id);
                messages[index] = message;
              }
            }
            messages.sort((a, b) => a.date.compareTo(b.date));
            if (newMessages.isNotEmpty) {
              oldestMessageId = messages.first.id;
            }
            isLoading = false;
            isLoadingMore = false;
            errorMessage = null;
            _errorMessageColor = null;
            _fetchRetryCount = 0;
            // Scroll to the bottom after initial load
            if (fromMessageId == null && _isAtBottom) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_scrollController.hasClients) {
                  _scrollController.jumpTo(
                    _scrollController.position.maxScrollExtent,
                  );
                }
              });
            }
          });
        }
        print('Messages fetched successfully: ${newMessages.length} messages');
        // Fetch more messages if fewer than limit were received and fromMessageId was not set
        if (newMessages.length < limit &&
            fromMessageId == null &&
            newMessages.isNotEmpty) {
          await _fetchMessages(fromMessageId: oldestMessageId, limit: limit);
        }
        return;
      } else if (response.statusCode == 401) {
        bool isAuthenticated = await _checkSession();
        if (!isAuthenticated) {
          if (mounted) {
            setState(() {
              isLoading = false;
              isLoadingMore = false;
              errorMessage = 'نیاز به احراز هویت. لطفاً وارد شوید.';
              _errorMessageColor = isDarkMode
                  ? Colors.red[300]
                  : Colors.redAccent;
              _fetchRetryCount = 0;
            });
          }
          return;
        }
        print('Retrying fetch messages after session check');
        if (mounted) {
          setState(() {
            errorMessage = 'در حال تلاش مجدد...';
            _errorMessageColor = isDarkMode
                ? Colors.yellow[300]
                : Colors.yellowAccent;
          });
          await Future.delayed(const Duration(seconds: 1));
          await _fetchMessages(fromMessageId: fromMessageId, limit: limit);
        }
        return;
      } else {
        throw Exception(
          'Backend responded with status: ${response.statusCode}',
        );
      }
    } catch (e, stackTrace) {
      print('Error fetching messages: $e\n$stackTrace');
      if (_fetchRetryCount >= maxRetries - 1) {
        if (mounted) {
          setState(() {
            errorMessage =
                'خطا در اتصال به سرور پس از $maxRetries تلاش. لطفاً دوباره تلاش کنید.';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
            isLoading = false;
            isLoadingMore = false;
            _fetchRetryCount = 0;
          });
        }
        return;
      }

      if (e.toString().contains('SocketException')) {
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
                ? Colors.red[300]
                : Colors.redAccent;
          });
          print('Waiting for $delaySeconds seconds before retry...');
          await Future.delayed(Duration(seconds: delaySeconds));
          print('Retry after $delaySeconds seconds completed.');
          if (mounted) {
            await _fetchMessages(fromMessageId: fromMessageId, limit: limit);
          }
        }
      } else {
        if (mounted) {
          setState(() {
            errorMessage = 'در حال تلاش مجدد...';
            _errorMessageColor = isDarkMode
                ? Colors.yellow[300]
                : Colors.yellowAccent;
          });
          print('Retrying fetch messages after non-network error');
          await Future.delayed(const Duration(seconds: 1));
          if (mounted) {
            await _fetchMessages(fromMessageId: fromMessageId, limit: limit);
          }
        }
      }
    } finally {
      _isRetrying = false;
    }
  }

  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty || _isRetrying) return;
    _isRetrying = true;

    try {
      setState(() {
        errorMessage = 'در حال اتصال به سرور';
        _errorMessageColor = isDarkMode ? Colors.red[300] : Colors.redAccent;
      });

      final response = await http.post(
        Uri.parse('http://192.168.1.3:8000/send_message'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'phone_number': widget.phoneNumber,
          'chat_id': widget.chatId,
          'message': _messageController.text,
        }),
      );
      print('Send message response: ${response.statusCode} ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data.containsKey('status') && data['status'] == 'error') {
          if (mounted) {
            setState(() {
              errorMessage = 'خطا در ارسال پیام';
              _errorMessageColor = isDarkMode
                  ? Colors.red[300]
                  : Colors.redAccent;
              _sendMessageRetryCount = 0;
            });
          }
          return;
        }
        if (mounted) {
          setState(() {
            errorMessage = 'در حال دریافت پیام‌ها از سرور';
            _errorMessageColor = Colors.green;
            _messageController.clear();
            _sendMessageRetryCount = 0;
          });
          await Future.delayed(const Duration(seconds: 2));
          _fetchMessages();
          setState(() {
            errorMessage = null;
            _errorMessageColor = null;
          });
        }
        return;
      } else if (response.statusCode == 401) {
        bool isAuthenticated = await _checkSession();
        if (!isAuthenticated) {
          if (mounted) {
            setState(() {
              errorMessage = 'نیاز به احراز هویت. لطفاً وارد شوید.';
              _errorMessageColor = isDarkMode
                  ? Colors.red[300]
                  : Colors.redAccent;
              _sendMessageRetryCount = 0;
            });
          }
          return;
        }
        if (mounted) {
          setState(() {
            errorMessage = 'در حال تلاش مجدد...';
            _errorMessageColor = isDarkMode
                ? Colors.yellow[300]
                : Colors.yellowAccent;
          });
          await Future.delayed(const Duration(seconds: 1));
          await _sendMessage();
        }
        return;
      } else {
        throw Exception(
          'Backend responded with status: ${response.statusCode}',
        );
      }
    } catch (e, stackTrace) {
      print('Error sending message: $e\n$stackTrace');
      if (_sendMessageRetryCount >= maxRetries - 1) {
        if (mounted) {
          setState(() {
            errorMessage =
                'خطا در ارسال پیام پس از $maxRetries تلاش. لطفاً دوباره تلاش کنید.';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
            _sendMessageRetryCount = 0;
          });
        }
        return;
      }

      if (e.toString().contains('SocketException')) {
        final delaySeconds =
            retryDelaysInSeconds[_sendMessageRetryCount <
                    retryDelaysInSeconds.length
                ? _sendMessageRetryCount
                : retryDelaysInSeconds.length - 1];
        _sendMessageRetryCount++;
        if (mounted) {
          setState(() {
            errorMessage =
                'تلاش مجدد در حال اتصال به سرور، تلاش $_sendMessageRetryCount، پس از $delaySeconds ثانیه';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
          });
          print('Waiting for $delaySeconds seconds before retry...');
          await Future.delayed(Duration(seconds: delaySeconds));
          print('Retry after $delaySeconds seconds completed.');
          if (mounted) {
            await _sendMessage();
          }
        }
      } else {
        if (mounted) {
          setState(() {
            errorMessage = 'در حال تلاش مجدد...';
            _errorMessageColor = isDarkMode
                ? Colors.yellow[300]
                : Colors.yellowAccent;
          });
          print('Retrying fetch messages after non-network error');
          await Future.delayed(const Duration(seconds: 1));
          if (mounted) {
            await _sendMessage();
          }
        }
      }
    } finally {
      _isRetrying = false;
    }
  }

  Future<void> _sendVoiceMessage() async {
    if (_recordedFilePath == null ||
        _recordingDuration == null ||
        _isRetrying) {
      if (mounted) {
        setState(() {
          errorMessage = 'هیچ ضبطی برای ارسال موجود نیست';
          _errorMessageColor = isDarkMode ? Colors.red[300] : Colors.redAccent;
        });
      }
      return;
    }
    _isRetrying = true;

    try {
      setState(() {
        errorMessage = 'در حال اتصال به سرور';
        _errorMessageColor = isDarkMode ? Colors.red[300] : Colors.redAccent;
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
        if (data['status'] == 'error') {
          if (mounted) {
            setState(() {
              errorMessage = 'خطا در ارسال پیام صوتی';
              _errorMessageColor = isDarkMode
                  ? Colors.red[300]
                  : Colors.redAccent;
              _sendVoiceRetryCount = 0;
            });
          }
          await file.delete();
          return;
        }
        if (data.containsKey('waveformData') && data['waveformData'] is List) {
          _waveformData = List<double>.from(
            data['waveformData'].map((x) => x.toDouble()),
          );
          print(
            'Waveform data for sent message: ${_waveformData!.take(10).toList()}',
          );
        }
        if (mounted) {
          setState(() {
            errorMessage = 'در حال دریافت پیام‌ها از سرور';
            _errorMessageColor = Colors.green;
            _recordedFilePath = null;
            _recordingDuration = null;
            _waveformData = null;
            _isWaveformLoading = false;
            _sendVoiceRetryCount = 0;
          });
          await Future.delayed(const Duration(seconds: 2));
          _fetchMessages();
          setState(() {
            errorMessage = null;
            _errorMessageColor = null;
          });
        }
        await file.delete();
        return;
      } else if (response.statusCode == 401) {
        bool isAuthenticated = await _checkSession();
        if (!isAuthenticated) {
          if (mounted) {
            setState(() {
              errorMessage = 'نیاز به احراز هویت. لطفاً وارد شوید.';
              _errorMessageColor = isDarkMode
                  ? Colors.red[300]
                  : Colors.redAccent;
              _sendVoiceRetryCount = 0;
            });
          }
          return;
        }
        if (mounted) {
          setState(() {
            errorMessage = 'در حال تلاش مجدد...';
            _errorMessageColor = isDarkMode
                ? Colors.yellow[300]
                : Colors.yellowAccent;
          });
          await Future.delayed(const Duration(seconds: 1));
          await _sendVoiceMessage();
        }
        return;
      } else {
        throw Exception(
          'Backend responded with status: ${response.statusCode}',
        );
      }
    } catch (e, stackTrace) {
      print('Error sending voice message: $e\n$stackTrace');
      if (_sendVoiceRetryCount >= maxRetries - 1) {
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
        return;
      }

      if (e.toString().contains('SocketException')) {
        final delaySeconds =
            retryDelaysInSeconds[_sendVoiceRetryCount <
                    retryDelaysInSeconds.length
                ? _sendVoiceRetryCount
                : retryDelaysInSeconds.length - 1];
        _sendVoiceRetryCount++;
        if (mounted) {
          setState(() {
            errorMessage =
                'تلاش مجدد در حال اتصال به سرور، تلاش $_sendVoiceRetryCount، پس از $delaySeconds ثانیه';
            _errorMessageColor = isDarkMode
                ? Colors.red[300]
                : Colors.redAccent;
          });
          print('Waiting for $delaySeconds seconds before retry...');
          await Future.delayed(Duration(seconds: delaySeconds));
          print('Retry after $delaySeconds seconds completed.');
          if (mounted) {
            await _sendVoiceMessage();
          }
        }
      } else {
        if (mounted) {
          setState(() {
            errorMessage = 'در حال تلاش مجدد...';
            _errorMessageColor = isDarkMode
                ? Colors.yellow[300]
                : Colors.yellowAccent;
          });
          print('Retrying fetch messages after non-network error');
          await Future.delayed(const Duration(seconds: 1));
          if (mounted) {
            await _sendVoiceMessage();
          }
        }
      }
    } finally {
      _isRetrying = false;
    }
  }

  Future<void> _startRecording() async {
    try {
      if (await Permission.microphone.request().isGranted) {
        final tempDir = await getTemporaryDirectory();
        _recordedFilePath =
            '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.wav';
        await Future.delayed(const Duration(milliseconds: 100));
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
      return intl.DateFormat('dd MMM yyyy', 'fa_IR').format(date);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _messageController.dispose();
    _audioPlayer.dispose();
    _recorder.dispose();
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
            fontFamily: 'Vazir',
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
                      fontFamily: 'Vazir',
                    ),
                  ),
                  if (errorMessage!.contains('تلاش مجدد') ||
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
                          fontFamily: 'Vazir',
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
                        fontFamily: 'Vazir',
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    itemCount: messages.length + (isLoadingMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == messages.length) {
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
                      final message = messages[messages.length - 1 - index];
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
                                            ? const Color(0xFF005F4B)
                                            : const Color(0xFFDCF8C6))
                                      : (isDarkMode
                                            ? const Color(0xFF2A3A4A)
                                            : const Color(0xFFFFFFFF)),
                                  borderRadius: BorderRadius.circular(12.0),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(
                                        isDarkMode ? 0.3 : 0.1,
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
                                                  fontFamily: 'Vazir',
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
                                                    builder: (context, child) {
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
                                                    fontFamily: 'Vazir',
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
                                          fontFamily: 'Vazir',
                                          fontSize: 16,
                                          color: textColor,
                                        ),
                                      ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _formatTimestamp(message.date),
                                style: TextStyle(
                                  fontFamily: 'Vazir',
                                  fontSize: 12,
                                  color: textColor.withOpacity(0.6),
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
            color: isDarkMode
                ? const Color(0xFF2A3A4A)
                : const Color(0xFFF5F5F5),
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
                          fontFamily: 'Vazir',
                          color: textColor.withOpacity(0.6),
                        ),
                        filled: true,
                        fillColor: isDarkMode
                            ? const Color(0xFF3B4A5A)
                            : Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20.0),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      style: TextStyle(fontFamily: 'Vazir', color: textColor),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FloatingActionButton(
                  mini: true,
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
                  backgroundColor: appBarColor,
                  onPressed: _sendMessage,
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
    final barWidth = 1.5;
    final barSpacing = 1.0;
    final totalBarWidth = barWidth + barSpacing;
    final barCount = (size.width / totalBarWidth).floor();
    final height = size.height;

    final bgPaint = Paint()
      ..color = isDarkMode ? Colors.grey[600]! : Colors.grey[400]!
      ..style = PaintingStyle.fill;

    final fgPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        colors: isPlaying
            ? [Colors.blue[400]!, Colors.cyan[300]!]
            : isDarkMode
            ? [Colors.grey[500]!, Colors.grey[700]!]
            : [Colors.blue[200]!, Colors.blue[300]!],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Rect.fromLTWH(0, 0, size.width, height));

    final normalizedData = _normalizeData(data, barCount);

    for (int i = 0; i < barCount; i++) {
      final x = i * totalBarWidth;
      final dataIndex = (i * (normalizedData.length / barCount)).floor().clamp(
        0,
        normalizedData.length - 1,
      );
      var amplitude = normalizedData[dataIndex] * (height / 2) * 0.6;

      if (isPlaying && (x / size.width) <= progress) {
        amplitude *= animationValue;
      }

      amplitude = amplitude < 1.0 ? 1.0 : amplitude;

      final paint = (isPlaying && (x / size.width) <= progress)
          ? fgPaint
          : bgPaint;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, height / 2 - amplitude, barWidth, amplitude * 2),
          const Radius.circular(0.5),
        ),
        paint,
      );
    }
  }

  List<double> _normalizeData(List<double> data, int barCount) {
    if (data.isEmpty) return List.filled(barCount, 0.1);

    final filteredData = data.where((x) => x.isFinite && x >= 0).toList();
    if (filteredData.isEmpty) return List.filled(barCount, 0.1);

    final maxAmplitude = filteredData.reduce((a, b) => a > b ? a : b);
    final normalized = filteredData
        .map((x) => maxAmplitude > 0 ? x / maxAmplitude : 0.1)
        .toList();

    final step = normalized.length / barCount;
    final result = <double>[];
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

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

class Message {
  final int id;
  final String? content;
  final String? voiceUrl;
  final int? duration;
  final bool isOutgoing;
  final DateTime date;
  final bool isVoice;
  final List<double>? waveformData;

  Message({
    required this.id,
    this.content,
    this.voiceUrl,
    this.duration,
    required this.isOutgoing,
    required this.date,
    required this.isVoice,
    this.waveformData,
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('status') && json['status'] == 'error') {
      return Message(
        id: 0,
        content: json['message'] ?? 'خطا در پردازش پیام',
        isOutgoing: false,
        date: DateTime.now(),
        isVoice: false,
      );
    }

    final contentType = json['content']?['@type'];
    if (contentType == 'messageText') {
      return Message(
        id: json['id'] ?? 0,
        content: json['content']['text']['text'] ?? 'بدون محتوا',
        isOutgoing: json['is_outgoing'] ?? false,
        date: json['date'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['date'] * 1000)
            : DateTime.now(),
        isVoice: false,
      );
    } else if (json['content']?['@type'] == 'messageVoiceNote') {
      final waveformData = json['content']['voice_note']['waveform'];
      List<double>? parsedWaveformData;
      if (waveformData is List) {
        parsedWaveformData = waveformData.cast<double>();
      } else if (waveformData is String && waveformData.isNotEmpty) {
        try {
          final decoded = base64Decode(waveformData);
          parsedWaveformData = decoded.map((b) => b / 255.0).toList();
        } catch (e) {
          print('Error decoding waveform: $e');
          parsedWaveformData = null;
        }
      } else {
        parsedWaveformData = null;
      }

      String? voiceUrl =
          json['content']['voice_note']['voice']['remote']['url'];
      if (voiceUrl == null || voiceUrl.isEmpty) {
        final remoteId = json['content']['voice_note']['voice']['remote']['id'];
        if (remoteId != null) {
          voiceUrl = 'http://192.168.1.3:8000/files/voice_${remoteId}.wav';
        }
      }

      return Message(
        id: json['id'] ?? 0,
        content: '[پیام صوتی]',
        voiceUrl: voiceUrl,
        duration: json['content']['voice_note']['duration'],
        isOutgoing: json['is_outgoing'] ?? false,
        date: json['date'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['date'] * 1000)
            : DateTime.now(),
        isVoice: true,
        waveformData: parsedWaveformData,
      );
    }
    return Message(
      id: json['id'] ?? 0,
      content: 'محتوای پشتیبانی‌نشده',
      isOutgoing: json['is_outgoing'] ?? false,
      date: DateTime.now(),
      isVoice: false,
    );
  }
}

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

class _ConversationScreenState extends State<ConversationScreen> {
  List<Message> messages = [];
  String? errorMessage;
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
  Timer? _pollTimer;
  bool _isAtBottom = true;

  @override
  void initState() {
    super.initState();
    _fetchMessages();
    _scrollController.addListener(_onScroll);
    _setupAudioPlayer();
    _pollTimer = Timer.periodic(Duration(seconds: 5), (_) {
      if (_isAtBottom) {
        _fetchMessages();
      }
    });
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

  Future<void> _fetchMessages({int? fromMessageId, int limit = 50}) async {
    if (isLoadingMore) return;

    try {
      setState(() {
        if (fromMessageId == null) {
          isLoading = true;
        } else {
          isLoadingMore = true;
        }
        errorMessage = null;
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
        final newMessages = (data['messages'] as List<dynamic>)
            .map((json) => Message.fromJson(json))
            .toList();

        if (mounted) {
          setState(() {
            final existingMessageIds = {for (var msg in messages) msg.id: msg};

            // فقط پیام‌های جدید یا پیام‌های به‌روزرسانی‌شده را اضافه می‌کنیم
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
                // به‌روزرسانی پیام صوتی که اکنون URL دارد
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
          });
        }
      } else {
        if (mounted) {
          setState(() {
            errorMessage = 'خطا در دریافت پیام‌ها: ${response.statusCode}';
            isLoading = false;
            isLoadingMore = false;
          });
        }
      }
    } catch (e, stackTrace) {
      print('Error fetching messages: $e\n$stackTrace');
      if (mounted) {
        setState(() {
          errorMessage = 'خطای شبکه در دریافت پیام‌ها: $e';
          isLoading = false;
          isLoadingMore = false;
        });
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
          setState(() => errorMessage = 'نیاز به اجازه دسترسی به میکروفون');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRecording = false;
          errorMessage = 'خطا در شروع ضبط: $e';
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
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isWaveformLoading = false;
          _isRecording = false;
          errorMessage = 'خطا در توقف ضبط: $e';
        });
      }
    } finally {
      _recordingTimer?.cancel();
    }
  }

  Future<void> _sendVoiceMessage() async {
    if (_recordedFilePath == null || _recordingDuration == null) {
      if (mounted) {
        setState(() => errorMessage = 'هیچ ضبطی برای ارسال موجود نیست');
      }
      return;
    }
    try {
      final file = File(_recordedFilePath!);
      if (!await file.exists()) {
        if (mounted) {
          setState(() => errorMessage = 'فایل ضبط‌شده یافت نشد');
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
            setState(
              () => errorMessage = 'خطا در ارسال پیام صوتی: ${data['message']}',
            );
          }
          await file.delete();
          return;
        }
        if (mounted) {
          setState(() {
            _recordedFilePath = null;
            _recordingDuration = null;
            _waveformData = null;
            _isWaveformLoading = false;
          });
          await Future.delayed(Duration(seconds: 1));
          _fetchMessages();
        }
        await file.delete();
      } else {
        if (mounted) {
          setState(
            () => errorMessage = 'خطا در ارسال پیام صوتی: $responseBody',
          );
        }
      }
    } catch (e) {
      print('Error sending voice message: $e');
      if (mounted) {
        setState(() => errorMessage = 'خطای شبکه در ارسال پیام صوتی: $e');
      }
    }
  }

  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;
    try {
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
            setState(
              () => errorMessage = 'خطا در ارسال پیام: ${data['message']}',
            );
          }
          return;
        }
        if (mounted) {
          setState(() => _messageController.clear());
          await Future.delayed(Duration(seconds: 1));
          _fetchMessages();
        }
      } else {
        if (mounted) {
          setState(
            () => errorMessage = 'خطا در ارسال پیام: ${response.statusCode}',
          );
        }
      }
    } catch (e) {
      print('Error sending message: $e');
      if (mounted) {
        setState(() => errorMessage = 'خطای شبکه در ارسال پیام: $e');
      }
    }
  }

  Future<void> _playVoice(String? url) async {
    if (url == null || url.isEmpty) {
      print('Invalid voice URL: $url');
      if (mounted) {
        setState(() => errorMessage = 'آدرس صوتی معتبر نیست');
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

      final contentType = response.headers['content-type'];
      if (contentType != 'audio/wav') {
        print('Unexpected Content-Type: $contentType');
        throw Exception('Unsupported Content-Type: $contentType');
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
          errorMessage = 'خطا در پخش پیام صوتی: $e';
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
        setState(() => errorMessage = 'خطا در توقف پخش: $e');
      }
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _scrollController.dispose();
    _messageController.dispose();
    _audioPlayer.dispose();
    _recorder.dispose();
    _playerStateSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _recordingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.chatTitle)),
      body: Column(
        children: [
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : messages.isEmpty
                ? const Center(child: Text('هیچ پیامی موجود نیست'))
                : ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    itemCount: messages.length + (isLoadingMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == messages.length) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final message = messages[messages.length - 1 - index];
                      return ListTile(
                        title: Align(
                          alignment: message.isOutgoing
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.all(8.0),
                            margin: const EdgeInsets.symmetric(
                              vertical: 4.0,
                              horizontal: 8.0,
                            ),
                            decoration: BoxDecoration(
                              color: message.isOutgoing
                                  ? Colors.blue[100]
                                  : Colors.grey[200],
                              borderRadius: BorderRadius.circular(8.0),
                            ),
                            child: message.isVoice
                                ? Column(
                                    crossAxisAlignment: message.isOutgoing
                                        ? CrossAxisAlignment.end
                                        : CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: Icon(
                                              _isPlaying &&
                                                      _currentPlayingUrl ==
                                                          message.voiceUrl
                                                  ? Icons.pause
                                                  : Icons.play_arrow,
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
                                                      setState(
                                                        () => errorMessage =
                                                            'پیام صوتی در دسترس نیست',
                                                      );
                                                    }
                                                  },
                                          ),
                                          Text(
                                            '${message.duration ?? 0} ثانیه',
                                          ),
                                        ],
                                      ),
                                      if (_isWaveformLoading &&
                                          message.isOutgoing &&
                                          message.voiceUrl == null)
                                        const SizedBox(
                                          height: 20,
                                          child: LinearProgressIndicator(),
                                        ),
                                      if (message.waveformData != null &&
                                          (!_isWaveformLoading ||
                                              message.voiceUrl != null))
                                        SizedBox(
                                          height: 40,
                                          width: 100,
                                          child: CustomPaint(
                                            painter: WaveformPainter(
                                              data: message.waveformData!,
                                              isPlaying:
                                                  _isPlaying &&
                                                  _currentPlayingUrl ==
                                                      message.voiceUrl,
                                              progress:
                                                  _audioDuration
                                                          .inMilliseconds >
                                                      0
                                                  ? _audioPosition
                                                            .inMilliseconds /
                                                        _audioDuration
                                                            .inMilliseconds
                                                  : 0.0,
                                            ),
                                          ),
                                        ),
                                      if (_isPlaying &&
                                          _currentPlayingUrl ==
                                              message.voiceUrl)
                                        Text(
                                          '${_audioPosition.inSeconds} / ${_audioDuration.inSeconds} ثانیه',
                                          style: const TextStyle(fontSize: 10),
                                        ),
                                    ],
                                  )
                                : Text(message.content ?? ''),
                          ),
                        ),
                        subtitle: Text(
                          message.date.toString().substring(0, 16),
                          style: const TextStyle(fontSize: 10),
                        ),
                      );
                    },
                  ),
          ),
          if (errorMessage != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                errorMessage!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(
                      hintText: 'پیام خود را بنویسید...',
                      border: OutlineInputBorder(),
                    ),
                    textDirection: TextDirection.rtl,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sendMessage,
                ),
                IconButton(
                  icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                  onPressed: _isRecording ? _stopRecording : _startRecording,
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

  WaveformPainter({
    required this.data,
    required this.isPlaying,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final barWidth = 1.0;
    final barSpacing = 0.5;
    final totalBarWidth = barWidth + barSpacing;
    final barCount = (size.width / totalBarWidth).floor();
    final height = size.height;

    final bgPaint = Paint()
      ..color = Colors.grey[600]!
      ..style = PaintingStyle.fill;

    final fgPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        colors: isPlaying
            ? [Colors.cyanAccent, Colors.blueAccent]
            : [Colors.grey[400]!, Colors.grey[600]!],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.3
      ..color = isPlaying ? Colors.cyanAccent.withOpacity(0.8) : Colors.black45;

    final dataStep = data.length / barCount;

    for (int i = 0; i < barCount; i++) {
      final x = i * totalBarWidth;
      final dataIndex = (i * dataStep).floor().clamp(0, data.length - 1);
      final amplitude = (data[dataIndex].abs() * (height / 2)) * 0.7;
      final isInProgress = isPlaying && (x / size.width) <= progress;

      final paint = isInProgress ? fgPaint : bgPaint;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, height / 2 - amplitude, barWidth, amplitude * 2),
          const Radius.circular(1.0),
        ),
        paint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, height / 2 - amplitude, barWidth, amplitude * 2),
          const Radius.circular(1.0),
        ),
        strokePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    final oldPainter = oldDelegate as WaveformPainter;
    return oldPainter.data != data ||
        oldPainter.isPlaying != isPlaying ||
        oldPainter.progress != progress;
  }
}

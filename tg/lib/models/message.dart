import 'dart:convert';

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
    // Helper function to safely parse int from dynamic (String or int)
    int parseInt(dynamic value) {
      if (value is int) return value;
      if (value is String) return int.parse(value);
      return 0; // Default value if null or invalid
    }

    // Handle error response
    if (json.containsKey('status') && json['status'] == 'error') {
      return Message(
        id: 0,
        content: json['message'] ?? 'خطا در پردازش پیام',
        isOutgoing: false,
        date: DateTime.now(),
        isVoice: false,
      );
    }

    // Check if content is a String (new server JSON format)
    if (json['content'] is String) {
      final isVoice = json['isVoice'] ?? false;
      List<double>? parsedWaveformData;
      if (isVoice && json['waveformData'] is List) {
        parsedWaveformData = List<double>.from(
          json['waveformData'].map((x) => x.toDouble()),
        );
        print(
          'Raw waveform data for message ${json['id']}: ${parsedWaveformData.take(10).toList()}',
        );
      } else if (isVoice &&
          json['waveformData'] is String &&
          json['waveformData'].isNotEmpty) {
        try {
          final decoded = base64Decode(json['waveformData']);
          parsedWaveformData = decoded.map((b) => b / 255.0).toList();
          print(
            'Raw waveform data for message ${json['id']}: ${parsedWaveformData.take(10).toList()}',
          );
        } catch (e) {
          print('Error decoding waveform: $e');
          parsedWaveformData = null;
        }
      } else {
        parsedWaveformData = null;
      }

      return Message(
        id: parseInt(json['id']),
        content: json['content'] ?? (isVoice ? '[پیام صوتی]' : 'بدون محتوا'),
        voiceUrl: json['voiceUrl'],
        duration: parseInt(json['duration']),
        isOutgoing: json['is_outgoing'] ?? false,
        date: json['date'] != null
            ? DateTime.fromMillisecondsSinceEpoch(parseInt(json['date']) * 1000)
            : DateTime.now(),
        isVoice: isVoice,
        waveformData: parsedWaveformData,
      );
    }

    // Fallback for old format (content as Map with @type)
    final contentType = json['content']?['@type'];
    if (contentType == 'messageText') {
      return Message(
        id: parseInt(json['id']),
        content: json['content']['text']['text'] ?? 'بدون محتوا',
        isOutgoing: json['is_outgoing'] ?? false,
        date: json['date'] != null
            ? DateTime.fromMillisecondsSinceEpoch(parseInt(json['date']) * 1000)
            : DateTime.now(),
        isVoice: false,
      );
    } else if (contentType == 'messageVoiceNote') {
      final waveformData = json['content']['voice_note']['waveform'];
      List<double>? parsedWaveformData;
      if (waveformData is List) {
        parsedWaveformData = waveformData.cast<double>();
      } else if (waveformData is String && waveformData.isNotEmpty) {
        try {
          final decoded = base64Decode(waveformData);
          parsedWaveformData = decoded.map((b) => b / 255.0).toList();
          print(
            'Raw waveform data for message ${json['id']}: ${parsedWaveformData.take(10).toList()}',
          );
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
        id: parseInt(json['id']),
        content: '[پیام صوتی]',
        voiceUrl: voiceUrl,
        duration: parseInt(json['content']['voice_note']['duration']),
        isOutgoing: json['is_outgoing'] ?? false,
        date: json['date'] != null
            ? DateTime.fromMillisecondsSinceEpoch(parseInt(json['date']) * 1000)
            : DateTime.now(),
        isVoice: true,
        waveformData: parsedWaveformData,
      );
    }

    return Message(
      id: parseInt(json['id']),
      content: 'محتوای پشتیبانی‌نشده',
      isOutgoing: json['is_outgoing'] ?? false,
      date: DateTime.now(),
      isVoice: false,
    );
  }
}

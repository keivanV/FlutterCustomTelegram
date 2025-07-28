import 'package:equatable/equatable.dart';

enum MessageStatus { pending, success, reject }

class Message extends Equatable {
  final int id;
  final String? content;
  final bool isVoice;
  final String? voiceUrl;
  final int? duration;
  final bool isOutgoing;
  final DateTime date;
  final List<double>? waveformData;
  final MessageStatus status;

  const Message({
    required this.id,
    this.content,
    required this.isVoice,
    this.voiceUrl,
    this.duration,
    required this.isOutgoing,
    required this.date,
    this.waveformData,
    required this.status,
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    final waveformData = json['waveform_data'] != null
        ? (json['waveform_data'] as List<dynamic>).cast<double>()
        : null;

    final statusString = json['status'] as String? ?? 'success';
    final status = MessageStatus.values.firstWhere(
      (e) => e.toString().split('.').last == statusString,
      orElse: () => MessageStatus.success,
    );

    return Message(
      id: json['id'] as int,
      content: json['content'] as String?,
      isVoice: json['is_voice'] as bool,
      voiceUrl: json['voice_url'] as String?,
      duration: json['duration'] as int?,
      isOutgoing:
          json['is_outgoing'] as bool? ?? false, // Default to false if null
      date: DateTime.fromMillisecondsSinceEpoch((json['date'] as int) * 1000),
      waveformData: waveformData,
      status: status,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'content': content,
      'is_voice': isVoice,
      'voice_url': voiceUrl,
      'duration': duration,
      'is_outgoing': isOutgoing,
      'date': date.millisecondsSinceEpoch ~/ 1000,
      'waveform_data': waveformData,
      'status': status.toString().split('.').last,
    };
  }

  Message copyWith({
    int? id,
    String? content,
    bool? isVoice,
    String? voiceUrl,
    int? duration,
    bool? isOutgoing,
    DateTime? date,
    List<double>? waveformData,
    MessageStatus? status,
  }) {
    return Message(
      id: id ?? this.id,
      content: content ?? this.content,
      isVoice: isVoice ?? this.isVoice,
      voiceUrl: voiceUrl ?? this.voiceUrl,
      duration: duration ?? this.duration,
      isOutgoing: isOutgoing ?? this.isOutgoing,
      date: date ?? this.date,
      waveformData: waveformData ?? this.waveformData,
      status: status ?? this.status,
    );
  }

  @override
  List<Object?> get props => [
    id,
    content,
    isVoice,
    voiceUrl,
    duration,
    isOutgoing,
    date,
    waveformData,
    status,
  ];
}

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:async';
import 'dart:convert';

class WebSocketService {
  WebSocketChannel? _channel;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  bool _isConnecting = false;
  int _retryCount = 0;
  static const int _maxRetries = 10;
  static const List<int> _retryDelaysInSeconds = [
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

  Stream<Map<String, dynamic>> get events => _controller.stream;

  Future<void> connect(String phoneNumber) async {
    if (_channel != null || _isConnecting) {
      print(
        'WebSocket already connected or connecting for phone: $phoneNumber',
      );
      return;
    }
    _isConnecting = true;

    while (_retryCount < _maxRetries) {
      try {
        final encodedPhoneNumber = Uri.encodeComponent(phoneNumber);
        final url = 'ws://192.168.1.3:8000/ws/$encodedPhoneNumber';
        print('Connecting to WebSocket: $url (Attempt ${_retryCount + 1})');
        _channel = IOWebSocketChannel.connect(
          Uri.parse(url),
          pingInterval: const Duration(seconds: 30),
        );

        await _channel!.ready;
        print('WebSocket connected successfully for phone: $phoneNumber');

        _channel!.stream.listen(
          (data) {
            try {
              final event = jsonDecode(data as String);
              print('WebSocket event received: $event');
              _controller.add(event);
              _retryCount = 0;
            } catch (e) {
              print('Error parsing WebSocket data: $e');
              _controller.addError(e);
            }
          },
          onError: (error) {
            print('WebSocket error: $error');
            _controller.addError(error);
            disconnect();
            _retryConnection(phoneNumber);
          },
          onDone: () {
            print('WebSocket closed');
            disconnect();
            _retryConnection(phoneNumber);
          },
          cancelOnError: true,
        );

        _isConnecting = false;
        return;
      } catch (e) {
        print('WebSocket connection failed: $e');
        _controller.addError(e);
        _retryCount++;
        if (_retryCount < _maxRetries) {
          final delaySeconds =
              _retryDelaysInSeconds[_retryCount < _retryDelaysInSeconds.length
                  ? _retryCount
                  : _retryDelaysInSeconds.length - 1];
          print('Retrying WebSocket connection in $delaySeconds seconds...');
          await Future.delayed(Duration(seconds: delaySeconds));
        } else {
          print('Max WebSocket retries reached');
          _controller.addError(
            Exception(
              'Failed to connect to WebSocket after $_maxRetries attempts',
            ),
          );
          _isConnecting = false;
          return;
        }
      }
    }
  }

  void _retryConnection(String phoneNumber) {
    disconnect();
    connect(phoneNumber);
  }

  void disconnect() {
    try {
      _channel?.sink.close();
      print('WebSocket closed gracefully');
    } catch (e) {
      print('Error closing WebSocket: $e');
    }
    _channel = null;
    _isConnecting = false;
  }

  void dispose() {
    disconnect();
    _controller.close();
    print('WebSocketService disposed');
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:animated_theme_switcher/animated_theme_switcher.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'package:intl/date_symbol_data_local.dart';
import 'screens/auth_screen.dart';
import 'screens/chat_screen.dart';
import 'themes/telegram_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ThemeProvider(
      initTheme: telegramLightTheme,
      builder: (context, theme) {
        return MaterialApp(
          title: 'Telegram Client',
          theme: theme,
          darkTheme: telegramDarkTheme,
          themeMode: ThemeMode.system,
          home: LoadingScreen(),
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}

class LoadingScreen extends StatefulWidget {
  @override
  _LoadingScreenState createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen> {
  final storage = FlutterSecureStorage();
  String? errorMessage;
  bool isConnecting = true;
  int retryCount = 0;
  static const int maxRetries = 10;
  static const Duration baseDelay = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _checkBackendAndNavigate();
  }

  Future<void> _checkBackendAndNavigate() async {
    String? phoneNumber = await storage.read(key: 'phone_number');
    while (retryCount < maxRetries && isConnecting && mounted) {
      try {
        setState(() {
          errorMessage = 'Connecting to backend... Attempt ${retryCount + 1}';
        });

        final response = await http.post(
          Uri.parse('http://localhost:8000/check_session'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'phone_number': phoneNumber ?? ''}),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          String initialState = data['auth_state'];
          bool isAuthenticated = data['is_authenticated'];

          if (mounted) {
            if (isAuthenticated && phoneNumber != null) {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (context) => ChatScreen(phoneNumber: phoneNumber),
                ),
              );
            } else {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (context) => AuthScreen(
                    phoneNumber: phoneNumber,
                    initialState:
                        initialState == 'authorizationStateWaitPhoneNumber'
                        ? 'wait_phone'
                        : initialState,
                  ),
                ),
              );
            }
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
          setState(() {
            errorMessage =
                'Failed to connect to backend after $maxRetries attempts. Please try again later.';
            isConnecting = false;
          });
          return;
        }

        final delay = baseDelay * (1 << retryCount);
        setState(() {
          errorMessage =
              'Connection failed. Retrying in ${delay.inSeconds} seconds...';
        });
        await Future.delayed(delay);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 20),
            Text(
              errorMessage ?? 'Connecting to backend...',
              style: TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
            if (!isConnecting) ...[
              SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    retryCount = 0;
                    isConnecting = true;
                    errorMessage = null;
                  });
                  _checkBackendAndNavigate();
                },
                child: Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

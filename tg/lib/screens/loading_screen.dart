import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_screen.dart';
import 'chat_screen.dart';

class LoadingScreen extends StatefulWidget {
  const LoadingScreen({super.key});

  @override
  _LoadingScreenState createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen>
    with SingleTickerProviderStateMixin {
  final storage = const FlutterSecureStorage();
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  bool isDarkMode = true;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _initPrefs();
    _setupAnimation();
    _checkSession();
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        isDarkMode = _prefs?.getBool('isDarkMode') ?? true;
      });
    }
  }

  void _setupAnimation() {
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _animationController.forward();
  }

  Future<void> _checkSession() async {
    try {
      String? phoneNumber = await storage.read(key: 'phone_number');
      print('Checking session for phone: $phoneNumber');
      if (phoneNumber == null || phoneNumber.isEmpty) {
        print('No phone number stored, navigating to AuthScreen');
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => AuthScreen()),
        );
        return;
      }

      final response = await http.post(
        Uri.parse('http://localhost:8000/check_session'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'phone_number': phoneNumber}),
      );

      print('Check session response: ${response.statusCode} ${response.body}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['is_authenticated']) {
          print('Session authenticated, navigating to ChatScreen');
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => ChatScreen(phoneNumber: phoneNumber),
            ),
          );
        } else {
          print(
            'Session not authenticated, navigating to AuthScreen with state: ${data['auth_state']}',
          );
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => AuthScreen(
                phoneNumber: phoneNumber,
                initialState: data['auth_state'],
              ),
            ),
          );
        }
      } else {
        print('Check session failed: ${response.body}');
        if (mounted) {
          setState(() {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Directionality(
                  textDirection: TextDirection.rtl,
                  child: Text(
                    'خطا در بررسی جلسه: ${response.body}',
                    style: const TextStyle(fontFamily: 'Vazir', fontSize: 14),
                  ),
                ),
                backgroundColor: isDarkMode
                    ? Colors.red[300]!.withOpacity(0.8)
                    : Colors.redAccent.withOpacity(0.8),
                duration: const Duration(seconds: 3),
              ),
            );
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => AuthScreen(phoneNumber: phoneNumber),
              ),
            );
          });
        }
      }
    } catch (e) {
      print('Error checking session: $e');
      if (mounted) {
        setState(() {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Directionality(
                textDirection: TextDirection.rtl,
                child: Text(
                  'خطا در بررسی جلسه: $e',
                  style: const TextStyle(fontFamily: 'Vazir', fontSize: 14),
                ),
              ),
              backgroundColor: isDarkMode
                  ? Colors.red[300]!.withOpacity(0.8)
                  : Colors.redAccent.withOpacity(0.8),
              duration: const Duration(seconds: 3),
            ),
          );
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => AuthScreen()),
          );
        });
      }
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color backgroundColor = isDarkMode
        ? const Color(0xFF17212B)
        : const Color(0xFFEFEFEF);
    final Color progressColor = isDarkMode
        ? const Color(0xFF2A3A4A)
        : const Color(0xFF5181B8);
    final Color textColor = isDarkMode ? Colors.white : Colors.black87;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: progressColor, strokeWidth: 3.0),
              const SizedBox(height: 16),
              Directionality(
                textDirection: TextDirection.rtl,
                child: Text(
                  'در حال بارگذاری...',
                  style: TextStyle(
                    fontFamily: 'Vazir',
                    fontSize: 16,
                    color: textColor.withOpacity(0.8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

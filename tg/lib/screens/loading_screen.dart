import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'auth_screen.dart';
import 'chat_screen.dart';

class LoadingScreen extends StatefulWidget {
  @override
  _LoadingScreenState createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen> {
  final storage = FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _checkSession();
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
        setState(() {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to check session: ${response.body}'),
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
    } catch (e) {
      print('Error checking session: $e');
      setState(() {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error checking session: $e')));
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => AuthScreen()),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

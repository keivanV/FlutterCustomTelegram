import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'chat_screen.dart';

class AuthScreen extends StatefulWidget {
  final String? phoneNumber;
  final String? initialState;
  AuthScreen({this.phoneNumber, this.initialState});

  @override
  _AuthScreenState createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _emailCodeController = TextEditingController();
  final storage = FlutterSecureStorage();
  String authStatus = 'wait_phone';
  String? errorMessage;

  @override
  void initState() {
    super.initState();
    if (widget.phoneNumber != null) {
      _phoneController.text = widget.phoneNumber!;
    }
    if (widget.initialState != null) {
      authStatus = widget.initialState == 'authorizationStateWaitPhoneNumber'
          ? 'wait_phone'
          : widget.initialState!;
    }
    _authenticate();
  }

  Future<void> _authenticate() async {
    setState(() {
      errorMessage = null;
    });

    String phoneNumber = _phoneController.text;
    if (phoneNumber.isEmpty && authStatus == 'wait_phone') {
      setState(() {
        errorMessage = 'Phone number is required';
      });
      return;
    }

    final authData = {
      'phone_number': authStatus == 'wait_phone' ? phoneNumber : null,
      'code': authStatus == 'wait_code' ? _codeController.text : null,
      'password': authStatus == 'wait_password'
          ? _passwordController.text
          : null,
      'first_name': authStatus == 'wait_registration'
          ? _firstNameController.text
          : null,
      'last_name': authStatus == 'wait_registration'
          ? _lastNameController.text
          : null,
      'email': authStatus == 'wait_email' ? _emailController.text : null,
      'email_code': authStatus == 'wait_email_code'
          ? _emailCodeController.text
          : null,
    };

    if (phoneNumber.isNotEmpty) {
      await storage.write(key: 'phone_number', value: phoneNumber);
    }

    final sessionPhone = phoneNumber.isNotEmpty
        ? phoneNumber
        : await storage.read(key: 'phone_number') ?? '';
    if (sessionPhone.isEmpty && authStatus != 'wait_phone') {
      setState(() {
        errorMessage = 'Session phone number is required';
      });
      return;
    }

    try {
      print(
        'Sending authenticate request: auth=$authData, session=$sessionPhone',
      );
      final response = await http.post(
        Uri.parse('http://localhost:8000/authenticate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'auth': authData,
          'session': {'phone_number': sessionPhone},
        }),
      );

      print('Authenticate response: ${response.statusCode} ${response.body}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          authStatus = data['status'];
        });

        if (authStatus == 'authenticated') {
          print('Authenticated, navigating to ChatScreen');
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => ChatScreen(phoneNumber: sessionPhone),
            ),
          );
        } else if (authStatus == 'wait_premium') {
          setState(() {
            errorMessage = 'Telegram Premium subscription is required';
          });
        } else if (authStatus == 'closed') {
          setState(() {
            errorMessage = 'Session closed unexpectedly';
          });
        } else if (authStatus == 'unknown') {
          setState(() {
            errorMessage =
                'Authentication failed: Unknown state. Please try again.';
          });
        }
      } else {
        setState(() {
          errorMessage = 'Authentication failed: ${response.body}';
        });
      }
    } catch (e) {
      print('Authentication error: $e');
      setState(() {
        errorMessage = 'Network error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Telegram Login')),
      body: Padding(
        padding: EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            children: [
              if (errorMessage != null)
                Text(
                  errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              SizedBox(height: 16),
              if (authStatus == 'wait_phone') ...[
                TextField(
                  controller: _phoneController,
                  decoration: InputDecoration(
                    labelText: 'Phone Number (e.g., +1234567890)',
                    errorText:
                        _phoneController.text.isEmpty && errorMessage != null
                        ? 'Required'
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  keyboardType: TextInputType.phone,
                ),
                SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _authenticate,
                  child: Text('Send Code'),
                ),
              ],
              if (authStatus == 'wait_code') ...[
                TextField(
                  controller: _codeController,
                  decoration: InputDecoration(
                    labelText: 'Authentication Code',
                    errorText:
                        _codeController.text.isEmpty && errorMessage != null
                        ? 'Required'
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  keyboardType: TextInputType.number,
                ),
                SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _authenticate,
                  child: Text('Verify Code'),
                ),
              ],
              if (authStatus == 'wait_password') ...[
                TextField(
                  controller: _passwordController,
                  decoration: InputDecoration(
                    labelText: '2FA Password',
                    errorText:
                        _passwordController.text.isEmpty && errorMessage != null
                        ? 'Required'
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  obscureText: true,
                ),
                SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _authenticate,
                  child: Text('Submit Password'),
                ),
              ],
              if (authStatus == 'wait_registration') ...[
                TextField(
                  controller: _firstNameController,
                  decoration: InputDecoration(
                    labelText: 'First Name',
                    errorText:
                        _firstNameController.text.isEmpty &&
                            errorMessage != null
                        ? 'Required'
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                TextField(
                  controller: _lastNameController,
                  decoration: InputDecoration(
                    labelText: 'Last Name',
                    errorText:
                        _lastNameController.text.isEmpty && errorMessage != null
                        ? 'Required'
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _authenticate,
                  child: Text('Register'),
                ),
              ],
              if (authStatus == 'wait_email') ...[
                TextField(
                  controller: _emailController,
                  decoration: InputDecoration(
                    labelText: 'Email Address',
                    errorText:
                        _emailController.text.isEmpty && errorMessage != null
                        ? 'Required'
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _authenticate,
                  child: Text('Submit Email'),
                ),
              ],
              if (authStatus == 'wait_email_code') ...[
                TextField(
                  controller: _emailCodeController,
                  decoration: InputDecoration(
                    labelText: 'Email Code',
                    errorText:
                        _emailCodeController.text.isEmpty &&
                            errorMessage != null
                        ? 'Required'
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  keyboardType: TextInputType.number,
                ),
                SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _authenticate,
                  child: Text('Verify Email Code'),
                ),
              ],
              if (authStatus == 'unknown') ...[
                ElevatedButton(
                  onPressed: _authenticate,
                  child: Text('Retry Authentication'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

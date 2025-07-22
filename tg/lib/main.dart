import 'dart:async';

import 'package:flutter/material.dart';
import 'package:animated_theme_switcher/animated_theme_switcher.dart';
import 'screens/loading_screen.dart';
import 'themes/telegram_theme.dart';

void main() {
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
        );
      },
    );
  }
}

//=============================================================
// import 'dart:async';
// import 'dart:io' show File, Platform;
// import 'dart:typed_data';
// import 'package:flutter/foundation.dart' show kIsWeb;
// import 'package:flutter/material.dart';
// import 'package:animate_do/animate_do.dart';
// import 'package:audioplayers/audioplayers.dart';
// import 'package:path_provider/path_provider.dart';
// import 'package:permission_handler/permission_handler.dart';
// import 'package:record/record.dart';
// import 'package:http/http.dart' as http;

// const String backendUrl = 'http://localhost:8000';

// void main() {
//   WidgetsFlutterBinding.ensureInitialized();
//   runApp(const AudioRecorderApp());
// }

// class AudioRecorderApp extends StatelessWidget {
//   const AudioRecorderApp({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return MaterialApp(
//       title: 'اپلیکیشن ضبط صدا',
//       debugShowCheckedModeBanner: false,
//       theme: ThemeData(
//         primarySwatch: Colors.blue,
//         fontFamily: 'Vazir',
//         scaffoldBackgroundColor: Colors.blueGrey[900],
//         textTheme: const TextTheme(
//           headlineLarge: TextStyle(
//             fontSize: 28,
//             fontWeight: FontWeight.bold,
//             color: Colors.white,
//           ),
//           bodyMedium: TextStyle(fontSize: 16, color: Colors.white70),
//         ),
//         elevatedButtonTheme: ElevatedButtonThemeData(
//           style: ElevatedButton.styleFrom(
//             backgroundColor: Colors.blueAccent,
//             foregroundColor: Colors.white,
//             padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
//             shape: RoundedRectangleBorder(
//               borderRadius: BorderRadius.circular(10),
//             ),
//           ),
//         ),
//         snackBarTheme: SnackBarThemeData(
//           backgroundColor: Colors.blueGrey[800],
//           contentTextStyle: const TextStyle(color: Colors.white, fontSize: 16),
//           shape: RoundedRectangleBorder(
//             borderRadius: BorderRadius.circular(10),
//           ),
//           behavior: SnackBarBehavior.floating,
//         ),
//       ),
//       home: const RecordScreen(),
//     );
//   }
// }

// class ModelSelectionScreen extends StatelessWidget {
//   final String audioPath;
//   final double f0UpKey;

//   const ModelSelectionScreen({
//     super.key,
//     required this.audioPath,
//     required this.f0UpKey,
//   });

//   Future<Map<String, dynamic>> _convertAudio(
//     BuildContext context,
//     String model,
//   ) async {
//     try {
//       final uri = Uri.parse('$backendUrl/convert');
//       final request = http.MultipartRequest('POST', uri)
//         ..fields['f0_up_key'] = f0UpKey.toString()
//         ..fields['model'] = model;
//       if (!kIsWeb) {
//         request.files.add(await http.MultipartFile.fromPath('file', audioPath));
//       }
//       final response = await request.send();
//       if (response.statusCode == 200) {
//         final tempDir = await getTemporaryDirectory();
//         final outputPath =
//             '${tempDir.path}/converted_${DateTime.now().millisecondsSinceEpoch}.wav';
//         final outputFile = File(outputPath);
//         await outputFile.writeAsBytes(await response.stream.toBytes());
//         return {'output_path': outputPath};
//       } else {
//         throw Exception('Failed to convert audio: ${response.statusCode}');
//       }
//     } catch (e) {
//       ScaffoldMessenger.of(context).showSnackBar(
//         SnackBar(
//           content: Text('خطا در تبدیل صدا: $e'),
//           backgroundColor: Colors.red,
//           duration: const Duration(seconds: 4),
//           behavior: SnackBarBehavior.floating,
//         ),
//       );
//       return {};
//     }
//   }

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       backgroundColor: Colors.blueGrey[900],
//       appBar: AppBar(
//         backgroundColor: Colors.blueGrey[800],
//         title: const Text('انتخاب مدل', style: TextStyle(color: Colors.white)),
//       ),
//       body: Center(
//         child: Column(
//           mainAxisAlignment: MainAxisAlignment.center,
//           children: [
//             ElevatedButton(
//               onPressed: () async {
//                 final result = await _convertAudio(context, 'model1');
//                 if (result.isNotEmpty && context.mounted) {
//                   Navigator.pop(context, result);
//                 }
//               },
//               child: const Text('مدل ۱'),
//             ),
//             const SizedBox(height: 20),
//             ElevatedButton(
//               onPressed: () async {
//                 final result = await _convertAudio(context, 'model2');
//                 if (result.isNotEmpty && context.mounted) {
//                   Navigator.pop(context, result);
//                 }
//               },
//               child: const Text('مدل ۲'),
//             ),
//           ],
//         ),
//       ),
//     );
//   }
// }

// class RecordScreen extends StatefulWidget {
//   const RecordScreen({super.key});

//   @override
//   _RecordScreenState createState() => _RecordScreenState();
// }

// class _RecordScreenState extends State<RecordScreen>
//     with SingleTickerProviderStateMixin {
//   final AudioRecorder _recorder = AudioRecorder();
//   final AudioPlayer _audioPlayer = AudioPlayer();
//   List<double>? _waveformData;
//   bool _isRecording = false;
//   bool _isPlaying = false;
//   String? _audioPath;
//   String? _convertedAudioPath;
//   late AnimationController _animationController;
//   late Animation<double> _pulseAnimation;
//   bool _isWaveformLoading = false;
//   Duration _audioDuration = Duration.zero;
//   Duration _audioPosition = Duration.zero;
//   StreamSubscription<PlayerState>? _playerStateSubscription;
//   StreamSubscription<Duration>? _durationSubscription;
//   StreamSubscription<Duration>? _positionSubscription;
//   double _f0UpKey = 0;
//   int _recordingSeconds = 0;
//   Timer? _recordingTimer;

//   @override
//   void initState() {
//     super.initState();
//     _animationController = AnimationController(
//       vsync: this,
//       duration: const Duration(seconds: 1),
//     )..repeat(reverse: true);
//     _pulseAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
//       CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
//     );
//     _playerStateSubscription = _audioPlayer.onPlayerStateChanged.listen((
//       state,
//     ) {
//       if (mounted &&
//           (state == PlayerState.stopped || state == PlayerState.completed)) {
//         setState(() {
//           _isPlaying = false;
//           _audioPosition = Duration.zero;
//         });
//       }
//     });
//     _durationSubscription = _audioPlayer.onDurationChanged.listen((duration) {
//       if (mounted) {
//         setState(() => _audioDuration = duration);
//       }
//     });
//     _positionSubscription = _audioPlayer.onPositionChanged.listen((position) {
//       if (mounted) {
//         setState(() => _audioPosition = position);
//       }
//     });
//   }

//   Future<void> _showNotification(String title, String body) async {
//     if (mounted) {
//       ScaffoldMessenger.of(context).showSnackBar(
//         SnackBar(
//           content: FadeInUp(
//             duration: const Duration(milliseconds: 300),
//             child: Text('$title: $body'),
//           ),
//           backgroundColor: title == 'موفقیت' ? Colors.green : Colors.red,
//           duration: const Duration(seconds: 4),
//           behavior: SnackBarBehavior.floating,
//         ),
//       );
//     }
//   }

//   Future<void> _startRecording() async {
//     try {
//       if (await Permission.microphone.request().isGranted) {
//         final tempDir = await getTemporaryDirectory();
//         final filePath =
//             '${tempDir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.wav';
//         await _recorder.start(
//           const RecordConfig(encoder: AudioEncoder.wav),
//           path: filePath,
//         );
//         if (mounted) {
//           setState(() {
//             _isRecording = true;
//             _audioPath = filePath;
//             _recordingSeconds = 0;
//           });
//           _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
//             if (!_isRecording || !mounted) {
//               timer.cancel();
//               return;
//             }
//             setState(() => _recordingSeconds++);
//           });
//           await _showNotification('موفقیت', 'ضبط صدا شروع شد');
//         }
//       } else {
//         await _showNotification('خطا', 'اجازه دسترسی به میکروفون داده نشد');
//       }
//     } catch (e) {
//       if (mounted) {
//         setState(() => _isRecording = false);
//         await _showNotification('خطا', 'خطا در شروع ضبط: $e');
//       }
//     }
//   }

//   Future<void> _stopRecording() async {
//     if (!_isRecording) return;
//     try {
//       final path = await _recorder.stop();
//       if (mounted && path != null && File(path).existsSync()) {
//         setState(() {
//           _isRecording = false;
//           _audioPath = path;
//           _isWaveformLoading = true;
//         });
//         final file = File(path);
//         final bytes = await file.readAsBytes();
//         final samples = _extractWaveformData(bytes);
//         if (mounted) {
//           setState(() {
//             _waveformData = samples;
//             _isWaveformLoading = false;
//           });
//           await _showNotification('موفقیت', 'ضبط صدا با موفقیت ذخیره شد');
//         }
//       } else {
//         setState(() => _isWaveformLoading = false);
//         await _showNotification('خطا', 'فایل ضبط‌شده یافت نشد');
//       }
//     } catch (e) {
//       if (mounted) {
//         setState(() {
//           _isRecording = false;
//           _isWaveformLoading = false;
//         });
//         await _showNotification('خطا', 'خطا در توقف ضبط: $e');
//       }
//     } finally {
//       _recordingTimer?.cancel();
//     }
//   }

//   Future<void> _playAudio({bool isConverted = false}) async {
//     final path = isConverted ? _convertedAudioPath : _audioPath;
//     if (path == null || (!kIsWeb && !File(path).existsSync())) {
//       await _showNotification('خطا', 'هیچ فایلی برای پخش وجود ندارد');
//       return;
//     }
//     try {
//       await _audioPlayer.play(DeviceFileSource(path));
//       if (mounted) {
//         setState(() => _isPlaying = true);
//         await _showNotification('موفقیت', 'پخش صدا شروع شد');
//       }
//     } catch (e) {
//       if (mounted) {
//         setState(() {
//           _isPlaying = false;
//           _audioPosition = Duration.zero;
//         });
//         await _showNotification('خطا', 'خطا در پخش صدا: $e');
//       }
//     }
//   }

//   Future<void> _stopAudio() async {
//     try {
//       await _audioPlayer.stop();
//       if (mounted) {
//         setState(() {
//           _isPlaying = false;
//           _audioPosition = Duration.zero;
//         });
//         await _showNotification('موفقیت', 'پخش صدا متوقف شد');
//       }
//     } catch (e) {
//       await _showNotification('خطا', 'خطا در توقف پخش: $e');
//     }
//   }

//   void _deleteAndRestart() {
//     if (_audioPath != null && !kIsWeb && File(_audioPath!).existsSync()) {
//       File(_audioPath!).deleteSync();
//     }
//     if (_convertedAudioPath != null &&
//         !kIsWeb &&
//         File(_convertedAudioPath!).existsSync()) {
//       File(_convertedAudioPath!).deleteSync();
//     }
//     if (mounted) {
//       setState(() {
//         _audioPath = null;
//         _convertedAudioPath = null;
//         _waveformData = null;
//         _audioDuration = Duration.zero;
//         _audioPosition = Duration.zero;
//         _f0UpKey = 0;
//         _recordingSeconds = 0;
//       });
//       _showNotification('موفقیت', 'فایل ضبط‌شده حذف شد');
//     }
//   }

//   Future<void> _selectModel() async {
//     if (_audioPath == null) {
//       await _showNotification('خطا', 'ابتدا صدا را ضبط کنید');
//       return;
//     }
//     final result = await Navigator.push(
//       context,
//       PageRouteBuilder(
//         pageBuilder: (context, animation, secondaryAnimation) =>
//             ModelSelectionScreen(audioPath: _audioPath!, f0UpKey: _f0UpKey),
//         transitionsBuilder: (context, animation, secondaryAnimation, child) {
//           const begin = Offset(1.0, 0.0);
//           const end = Offset.zero;
//           const curve = Curves.easeInOut;
//           var tween = Tween(
//             begin: begin,
//             end: end,
//           ).chain(CurveTween(curve: curve));
//           return SlideTransition(
//             position: animation.drive(tween),
//             child: child,
//           );
//         },
//       ),
//     );
//     if (result != null && mounted) {
//       setState(() {
//         _convertedAudioPath = result['output_path'] as String;
//       });
//       await _showNotification('موفقیت', 'صدا با موفقیت تبدیل شد');
//     }
//   }

//   List<double> _extractWaveformData(Uint8List bytes) {
//     try {
//       final byteData = bytes.buffer.asByteData();
//       final sampleCount = byteData.lengthInBytes ~/ 2; // 16-bit PCM
//       const int targetSamples = 200;
//       final step = (sampleCount / targetSamples).ceil();
//       List<double> samples = [];
//       for (int i = 0; i < sampleCount; i += step) {
//         if (i * 2 + 1 < byteData.lengthInBytes) {
//           final sample =
//               byteData.getInt16(i * 2, Endian.little) /
//               32768.0; // Normalize to [-1, 1]
//           samples.add(sample.abs());
//         }
//       }
//       return samples.isEmpty ? List<double>.filled(200, 0.1) : samples;
//     } catch (e) {
//       print('Error extracting waveform: $e');
//       return List<double>.filled(200, 0.1); // Fallback waveform
//     }
//   }

//   @override
//   void dispose() {
//     _animationController.dispose();
//     _recorder.dispose();
//     _playerStateSubscription?.cancel();
//     _durationSubscription?.cancel();
//     _positionSubscription?.cancel();
//     try {
//       _audioPlayer.dispose();
//     } catch (e) {
//       print('Error disposing AudioPlayer: $e');
//     }
//     _recordingTimer?.cancel();
//     super.dispose();
//   }

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       backgroundColor: Colors.blueGrey[900],
//       appBar: AppBar(
//         backgroundColor: Colors.blueGrey[800],
//         title: const Text(
//           'ضبط و پخش صدا',
//           style: TextStyle(color: Colors.white),
//         ),
//         leading: IconButton(
//           icon: const Icon(Icons.arrow_back, color: Colors.white),
//           onPressed: () => Navigator.pop(context, false),
//         ),
//       ),
//       body: Center(
//         child: SingleChildScrollView(
//           child: Column(
//             mainAxisAlignment: MainAxisAlignment.center,
//             children: [
//               FadeIn(
//                 duration: const Duration(seconds: 1),
//                 child: const Text(
//                   'ضبط صدای خود را شروع کنید',
//                   style: TextStyle(
//                     fontSize: 24,
//                     fontWeight: FontWeight.bold,
//                     color: Colors.white,
//                   ),
//                 ),
//               ),
//               const SizedBox(height: 40),
//               ScaleTransition(
//                 scale: _pulseAnimation,
//                 child: ZoomIn(
//                   duration: const Duration(seconds: 1),
//                   child: GestureDetector(
//                     onTap: _isRecording ? _stopRecording : _startRecording,
//                     child: Container(
//                       width: 100,
//                       height: 100,
//                       decoration: BoxDecoration(
//                         shape: BoxShape.circle,
//                         color: _isRecording
//                             ? Colors.redAccent
//                             : Colors.blueAccent,
//                         boxShadow: [
//                           BoxShadow(
//                             color: _isRecording
//                                 ? Colors.redAccent.withOpacity(0.5)
//                                 : Colors.blueAccent.withOpacity(0.5),
//                             blurRadius: 20,
//                             spreadRadius: 5,
//                           ),
//                         ],
//                       ),
//                       child: Icon(
//                         _isRecording ? Icons.stop : Icons.mic,
//                         size: 50,
//                         color: Colors.white,
//                       ),
//                     ),
//                   ),
//                 ),
//               ),
//               const SizedBox(height: 20),
//               if (_isRecording)
//                 Text(
//                   'در حال ضبط: $_recordingSeconds ثانیه',
//                   style: const TextStyle(fontSize: 18, color: Colors.white70),
//                 ),
//               if (!_isRecording && _audioPath != null) ...[
//                 const SizedBox(height: 20),
//                 if (_isWaveformLoading)
//                   const CircularProgressIndicator(color: Colors.blueAccent)
//                 else if (!kIsWeb && _waveformData != null)
//                   FadeInUp(
//                     duration: const Duration(seconds: 1),
//                     child: Container(
//                       height: 80,
//                       margin: const EdgeInsets.symmetric(horizontal: 20),
//                       decoration: BoxDecoration(
//                         color: Colors.blueGrey[800],
//                         borderRadius: const BorderRadius.all(
//                           Radius.circular(20.0),
//                         ),
//                         boxShadow: [
//                           BoxShadow(
//                             color: Colors.black.withOpacity(0.3),
//                             blurRadius: 10,
//                             spreadRadius: 2,
//                           ),
//                         ],
//                       ),
//                       padding: const EdgeInsets.all(8.0),
//                       child: CustomPaint(
//                         size: const Size(double.infinity, 80),
//                         painter: WaveformPainter(
//                           data: _waveformData!,
//                           isPlaying: _isPlaying,
//                           progress: _audioDuration.inMilliseconds > 0
//                               ? _audioPosition.inMilliseconds /
//                                     _audioDuration.inMilliseconds
//                               : 0.0,
//                         ),
//                       ),
//                     ),
//                   ),
//                 const SizedBox(height: 20),
//                 FadeInUp(
//                   duration: const Duration(seconds: 1),
//                   child: Card(
//                     color: Colors.blueGrey[800],
//                     shape: RoundedRectangleBorder(
//                       borderRadius: BorderRadius.circular(15),
//                     ),
//                     elevation: 5,
//                     margin: const EdgeInsets.symmetric(horizontal: 20),
//                     child: Padding(
//                       padding: const EdgeInsets.symmetric(
//                         vertical: 20,
//                         horizontal: 10,
//                       ),
//                       child: Column(
//                         children: [
//                           const Text(
//                             'تنظیم زیر و بم صدا',
//                             style: TextStyle(
//                               color: Colors.white,
//                               fontSize: 16,
//                               fontWeight: FontWeight.bold,
//                             ),
//                           ),
//                           Slider(
//                             value: _f0UpKey,
//                             min: -20,
//                             max: 20,
//                             divisions: 40,
//                             label: _f0UpKey.round().toString(),
//                             activeColor: Colors.blueAccent,
//                             inactiveColor: Colors.blueGrey,
//                             onChanged: (value) {
//                               setState(() => _f0UpKey = value);
//                             },
//                           ),
//                           const Text(
//                             'صدا بم‌تر: منفی | صدا زیرتر: مثبت',
//                             style: TextStyle(
//                               color: Colors.white70,
//                               fontSize: 14,
//                             ),
//                           ),
//                           const SizedBox(height: 15),
//                           ElevatedButton(
//                             onPressed: () => _playAudio(),
//                             style: ElevatedButton.styleFrom(
//                               backgroundColor: _isPlaying
//                                   ? Colors.orangeAccent
//                                   : Colors.greenAccent,
//                               minimumSize: const Size(double.infinity, 50),
//                               shape: RoundedRectangleBorder(
//                                 borderRadius: BorderRadius.circular(10),
//                               ),
//                               elevation: 3,
//                               shadowColor: Colors.black.withOpacity(0.3),
//                             ),
//                             child: Text(
//                               _isPlaying ? 'توقف' : 'پخش صدای اصلی',
//                               style: const TextStyle(
//                                 color: Colors.white,
//                                 fontSize: 16,
//                                 fontWeight: FontWeight.w500,
//                               ),
//                             ),
//                           ),
//                           const SizedBox(height: 15),
//                           if (_convertedAudioPath != null)
//                             ElevatedButton(
//                               onPressed: () => _playAudio(isConverted: true),
//                               style: ElevatedButton.styleFrom(
//                                 backgroundColor: Colors.purpleAccent,
//                                 minimumSize: const Size(double.infinity, 50),
//                                 shape: RoundedRectangleBorder(
//                                   borderRadius: BorderRadius.circular(10),
//                                 ),
//                                 elevation: 3,
//                                 shadowColor: Colors.black.withOpacity(0.3),
//                               ),
//                               child: const Text(
//                                 'پخش صدای تبدیل شده',
//                                 style: TextStyle(
//                                   color: Colors.white,
//                                   fontSize: 16,
//                                   fontWeight: FontWeight.w500,
//                                 ),
//                               ),
//                             ),
//                           const SizedBox(height: 15),
//                           ElevatedButton(
//                             onPressed: _deleteAndRestart,
//                             style: ElevatedButton.styleFrom(
//                               backgroundColor: Colors.redAccent,
//                               minimumSize: const Size(double.infinity, 50),
//                               shape: RoundedRectangleBorder(
//                                 borderRadius: BorderRadius.circular(10),
//                               ),
//                               elevation: 3,
//                               shadowColor: Colors.black.withOpacity(0.3),
//                             ),
//                             child: const Text(
//                               'حذف و شروع مجدد',
//                               style: TextStyle(
//                                 color: Colors.white,
//                                 fontSize: 16,
//                                 fontWeight: FontWeight.w500,
//                               ),
//                             ),
//                           ),
//                           const SizedBox(height: 15),
//                           ElevatedButton(
//                             onPressed: _selectModel,
//                             style: ElevatedButton.styleFrom(
//                               backgroundColor: Colors.blueAccent,
//                               minimumSize: const Size(double.infinity, 50),
//                               shape: RoundedRectangleBorder(
//                                 borderRadius: BorderRadius.circular(10),
//                               ),
//                               elevation: 3,
//                               shadowColor: Colors.black.withOpacity(0.3),
//                             ),
//                             child: const Text(
//                               'انتخاب مدل',
//                               style: TextStyle(
//                                 color: Colors.white,
//                                 fontSize: 16,
//                                 fontWeight: FontWeight.w500,
//                               ),
//                             ),
//                           ),
//                         ],
//                       ),
//                     ),
//                   ),
//                 ),
//               ],
//               const SizedBox(height: 20),
//             ],
//           ),
//         ),
//       ),
//     );
//   }
// }

// class WaveformPainter extends CustomPainter {
//   final List<double> data;
//   final bool isPlaying;
//   final double progress;

//   WaveformPainter({
//     required this.data,
//     required this.isPlaying,
//     required this.progress,
//   });

//   @override
//   void paint(Canvas canvas, Size size) {
//     final barWidth = 1.0;
//     final barSpacing = 0.5;
//     final totalBarWidth = barWidth + barSpacing;
//     final barCount = (size.width / totalBarWidth).floor();
//     final height = size.height;

//     final bgPaint = Paint()
//       ..color = Colors.blueGrey[600]!
//       ..style = PaintingStyle.fill;

//     final fgPaint = Paint()
//       ..style = PaintingStyle.fill
//       ..shader = LinearGradient(
//         colors: isPlaying
//             ? [Colors.cyanAccent, Colors.blueAccent]
//             : [Colors.blueGrey[400]!, Colors.blueGrey[600]!],
//         begin: Alignment.topCenter,
//         end: Alignment.bottomCenter,
//       ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

//     final strokePaint = Paint()
//       ..style = PaintingStyle.stroke
//       ..strokeWidth = 0.3
//       ..color = isPlaying ? Colors.cyanAccent.withOpacity(0.8) : Colors.white30;

//     final dataStep = data.length / barCount;

//     for (int i = 0; i < barCount; i++) {
//       final x = i * totalBarWidth;
//       final dataIndex = (i * dataStep).floor().clamp(0, data.length - 1);
//       final amplitude = (data[dataIndex].abs() * (height / 2)) * 0.7;
//       final isInProgress = isPlaying && (x / size.width) <= progress;

//       final paint = isInProgress ? fgPaint : bgPaint;

//       canvas.drawRRect(
//         RRect.fromRectAndRadius(
//           Rect.fromLTWH(x, height / 2 - amplitude, barWidth, amplitude * 2),
//           const Radius.circular(1.0),
//         ),
//         paint,
//       );
//       canvas.drawRRect(
//         RRect.fromRectAndRadius(
//           Rect.fromLTWH(x, height / 2 - amplitude, barWidth, amplitude * 2),
//           const Radius.circular(1.0),
//         ),
//         strokePaint,
//       );
//     }
//   }

//   @override
//   bool shouldRepaint(covariant CustomPainter oldDelegate) {
//     final oldPainter = oldDelegate as WaveformPainter;
//     return oldPainter.data != data ||
//         oldPainter.isPlaying != isPlaying ||
//         oldPainter.progress != progress;
//   }
// }
//======================================
// import 'dart:io';
// import 'package:flutter/material.dart';
// import 'package:audioplayers/audioplayers.dart';
// import 'package:http/http.dart' as http;
// import 'package:path_provider/path_provider.dart';
// import 'package:animate_do/animate_do.dart';

// void main() {
//   runApp(const MyApp());
// }

// class MyApp extends StatelessWidget {
//   const MyApp({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return const MaterialApp(home: AudioTestPage());
//   }
// }

// class AudioTestPage extends StatefulWidget {
//   const AudioTestPage({super.key});

//   @override
//   _AudioTestPageState createState() => _AudioTestPageState();
// }

// class _AudioTestPageState extends State<AudioTestPage> {
//   final String _audioUrl =
//       "http://192.168.1.3:8000/files/42aa3780b8b3005ea0842fa524a3d48b/voice/6046124173812569713.wav?phone_number=%2B989142008998";
//   final AudioPlayer _audioPlayer = AudioPlayer();
//   bool _isLoading = false;
//   bool _isPlaying = false;
//   String? _audioPath;
//   String? _errorMessage;
//   Duration _audioDuration = Duration.zero;
//   Duration _audioPosition = Duration.zero;
//   StreamSubscription<PlayerState>? _playerStateSubscription;
//   StreamSubscription<Duration>? _durationSubscription;
//   StreamSubscription<Duration>? _positionSubscription;

//   @override
//   void initState() {
//     super.initState();
//     // Set up audio player listeners like voiceapp
//     _playerStateSubscription = _audioPlayer.onPlayerStateChanged.listen((
//       state,
//     ) {
//       if (mounted &&
//           (state == PlayerState.stopped || state == PlayerState.completed)) {
//         setState(() {
//           _isPlaying = false;
//           _audioPosition = Duration.zero;
//         });
//       }
//     });
//     _durationSubscription = _audioPlayer.onDurationChanged.listen((duration) {
//       if (mounted) {
//         setState(() {
//           _audioDuration = duration;
//         });
//       }
//     });
//     _positionSubscription = _audioPlayer.onPositionChanged.listen((position) {
//       if (mounted) {
//         setState(() {
//           _audioPosition = position;
//         });
//       }
//     });
//   }

//   Future<void> _showNotification(String title, String body) async {
//     if (!mounted) return; // Guard against async gap
//     ScaffoldMessenger.of(context).showSnackBar(
//       SnackBar(
//         content: FadeInUp(
//           duration: const Duration(milliseconds: 300),
//           child: Text('$title: $body'),
//         ),
//         backgroundColor: title == 'خطا' ? Colors.red : Colors.green,
//         duration: const Duration(seconds: 4),
//         behavior: SnackBarBehavior.floating,
//       ),
//     );
//   }

//   Future<void> _downloadAndPlayAudio() async {
//     setState(() {
//       _isLoading = true;
//       _errorMessage = null;
//       _isPlaying = false;
//     });

//     try {
//       // Check if the file exists on the server
//       final headResponse = await http.head(Uri.parse(_audioUrl));
//       if (headResponse.statusCode != 200) {
//         throw Exception(
//           'فایل صوتی روی سرور پیدا نشد: HTTP ${headResponse.statusCode}',
//         );
//       }

//       // Download the WAV file
//       final response = await http.get(Uri.parse(_audioUrl));
//       if (response.statusCode != 200) {
//         throw Exception(
//           'دانلود فایل صوتی ناموفق بود: HTTP ${response.statusCode}',
//         );
//       }

//       // Check if the file is empty
//       if (response.bodyBytes.isEmpty) {
//         throw Exception('فایل دانلودشده خالی است');
//       }

//       // Save to temporary directory
//       final tempDir = await getTemporaryDirectory();
//       final wavPath =
//           '${tempDir.path.replaceAll('\\', '/')}/temp_audio_${DateTime.now().millisecondsSinceEpoch}.wav';
//       final wavFile = File(wavPath);
//       await wavFile.writeAsBytes(response.bodyBytes, flush: true);

//       // Check file existence and size
//       if (!wavFile.existsSync()) {
//         throw Exception('فایل WAV ایجاد نشد');
//       }
//       final fileSize = await wavFile.length();
//       print('فایل WAV دانلود شد: $wavPath, اندازه: $fileSize بایت');

//       // Verify file is accessible
//       try {
//         await wavFile.readAsBytes();
//         print('فایل WAV قابل دسترسی است');
//       } catch (e) {
//         throw Exception('خطا در دسترسی به فایل: $e');
//       }

//       // Store the path for playback
//       setState(() {
//         _audioPath = wavPath;
//       });

//       // Play the WAV file
//       await _audioPlayer.play(DeviceFileSource(wavPath));
//       if (mounted) {
//         setState(() {
//           _isPlaying = true;
//         });
//       }
//     } catch (e) {
//       if (mounted) {
//         setState(() {
//           _errorMessage = 'خطا: $e';
//         });
//         await _showNotification('خطا', 'خطا در پخش صدا: $e');
//       }
//       print('خطای کامل: $e');
//     } finally {
//       if (mounted) {
//         setState(() {
//           _isLoading = false;
//         });
//       }
//     }
//   }

//   Future<void> _stopAudio() async {
//     try {
//       await _audioPlayer.stop();
//       if (mounted) {
//         setState(() {
//           _isPlaying = false;
//           _audioPosition = Duration.zero;
//         });
//       }
//     } catch (e) {
//       if (mounted) {
//         await _showNotification('خطا', 'خطا در توقف پخش: $e');
//       }
//     }
//   }

//   @override
//   void dispose() {
//     _playerStateSubscription?.cancel();
//     _durationSubscription?.cancel();
//     _positionSubscription?.cancel();
//     _audioPlayer.stop();
//     _audioPlayer.dispose();
//     if (_audioPath != null && File(_audioPath!).existsSync()) {
//       File(_audioPath!).deleteSync();
//     }
//     super.dispose();
//   }

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(title: const Text('پخش صوت')),
//       body: Center(
//         child: Column(
//           mainAxisAlignment: MainAxisAlignment.center,
//           children: [
//             if (_isLoading) const CircularProgressIndicator(),
//             if (_errorMessage != null)
//               Padding(
//                 padding: const EdgeInsets.all(8.0),
//                 child: Text(
//                   _errorMessage!,
//                   style: const TextStyle(color: Colors.red),
//                   textAlign: TextAlign.center,
//                 ),
//               ),
//             if (_audioPath != null && !_isLoading)
//               Column(
//                 children: [
//                   Text(
//                     'مدت زمان: ${_audioDuration.inSeconds} ثانیه',
//                     style: const TextStyle(color: Colors.white),
//                   ),
//                   Text(
//                     'موقعیت: ${_audioPosition.inSeconds} ثانیه',
//                     style: const TextStyle(color: Colors.white),
//                   ),
//                   ElevatedButton(
//                     onPressed: _isPlaying ? _stopAudio : _downloadAndPlayAudio,
//                     style: ElevatedButton.styleFrom(
//                       backgroundColor: _isPlaying
//                           ? Colors.orangeAccent
//                           : Colors.greenAccent,
//                       minimumSize: const Size(double.infinity, 50),
//                       shape: RoundedRectangleBorder(
//                         borderRadius: BorderRadius.circular(10),
//                       ),
//                     ),
//                     child: Text(
//                       _isPlaying ? 'توقف' : 'پخش صوت',
//                       style: const TextStyle(color: Colors.white, fontSize: 16),
//                     ),
//                   ),
//                 ],
//               )
//             else
//               ElevatedButton(
//                 onPressed: _downloadAndPlayAudio,
//                 style: ElevatedButton.styleFrom(
//                   backgroundColor: Colors.blueAccent,
//                   minimumSize: const Size(double.infinity, 50),
//                   shape: RoundedRectangleBorder(
//                     borderRadius: BorderRadius.circular(10),
//                   ),
//                 ),
//                 child: const Text(
//                   'پخش صوت',
//                   style: TextStyle(color: Colors.white, fontSize: 16),
//                 ),
//               ),
//           ],
//         ),
//       ),
//     );
//   }
// }

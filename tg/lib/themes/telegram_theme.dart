import 'package:flutter/material.dart';

ThemeData telegramLightTheme = ThemeData(
  brightness: Brightness.light,
  primaryColor: Color(0xFF527DA3),
  colorScheme: ColorScheme.light(
    primary: Color(0xFF527DA3),
    secondary: Color(0xFF40C4FF),
    background: Color(0xFFF7F7F7),
    surface: Colors.white,
    onPrimary: Colors.white,
    onSecondary: Colors.black,
    onBackground: Colors.black,
    onSurface: Colors.black,
    error: Colors.red,
  ),
  scaffoldBackgroundColor: Color(0xFFF7F7F7),
  appBarTheme: AppBarTheme(
    backgroundColor: Color(0xFF527DA3),
    foregroundColor: Colors.white,
    elevation: 0,
    titleTextStyle: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w500,
      fontFamily: 'Roboto',
    ),
  ),
  textTheme: TextTheme(
    bodyLarge: TextStyle(color: Colors.black, fontFamily: 'Roboto'),
    bodyMedium: TextStyle(color: Colors.black87, fontFamily: 'Roboto'),
    bodySmall: TextStyle(
      color: Colors.black54,
      fontFamily: 'Roboto',
      fontSize: 12,
    ),
  ),
  listTileTheme: ListTileThemeData(
    tileColor: Colors.white,
    selectedTileColor: Color(0xFFE0F0FF),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: Color(0xFF527DA3),
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  ),
);

ThemeData telegramDarkTheme = ThemeData(
  brightness: Brightness.dark,
  primaryColor: Color(0xFF2F6EA5),
  colorScheme: ColorScheme.dark(
    primary: Color(0xFF2F6EA5),
    secondary: Color(0xFF40C4FF),
    background: Color(0xFF17212B),
    surface: Color(0xFF242F3D),
    onPrimary: Colors.white,
    onSecondary: Colors.white,
    onBackground: Colors.white,
    onSurface: Colors.white,
    error: Colors.redAccent,
  ),
  scaffoldBackgroundColor: Color(0xFF17212B),
  appBarTheme: AppBarTheme(
    backgroundColor: Color(0xFF2F6EA5),
    foregroundColor: Colors.white,
    elevation: 0,
    titleTextStyle: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w500,
      fontFamily: 'Roboto',
    ),
  ),
  textTheme: TextTheme(
    bodyLarge: TextStyle(color: Colors.white, fontFamily: 'Roboto'),
    bodyMedium: TextStyle(color: Colors.white70, fontFamily: 'Roboto'),
    bodySmall: TextStyle(
      color: Colors.white54,
      fontFamily: 'Roboto',
      fontSize: 12,
    ),
  ),
  listTileTheme: ListTileThemeData(
    tileColor: Color(0xFF242F3D),
    selectedTileColor: Color(0xFF2A3B4E),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: Color(0xFF2F6EA5),
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  ),
);

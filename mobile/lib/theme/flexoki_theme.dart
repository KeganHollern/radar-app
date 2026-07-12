import 'package:flutter/material.dart';

abstract final class Flexoki {
  static const black = Color(0xFF100F0F);
  static const base50 = Color(0xFF1C1B1A);
  static const base100 = Color(0xFF282726);
  static const base150 = Color(0xFF343331);
  static const base200 = Color(0xFF403E3C);
  static const base300 = Color(0xFF575653);
  static const base500 = Color(0xFF878580);
  static const base700 = Color(0xFFCECDC3);
  static const paper = Color(0xFFFFFCF0);

  static const red = Color(0xFFD14D41);
  static const orange = Color(0xFFDA702C);
  static const yellow = Color(0xFFD0A215);
  static const green = Color(0xFF879A39);
  static const cyan = Color(0xFF3AA99F);
  static const blue = Color(0xFF4385BE);
  static const purple = Color(0xFF8B7EC8);
  static const magenta = Color(0xFFCE5D97);

  static ThemeData get darkTheme {
    const scheme = ColorScheme.dark(
      primary: cyan,
      onPrimary: black,
      secondary: blue,
      onSecondary: paper,
      error: red,
      onError: paper,
      surface: base50,
      onSurface: base700,
      surfaceContainerHighest: base150,
      outline: base300,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: black,
      canvasColor: base50,
      dividerColor: base200,
      fontFamily: 'sans-serif',
      textTheme: const TextTheme(
        headlineSmall: TextStyle(
          color: paper,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        titleMedium: TextStyle(color: paper, fontWeight: FontWeight.w700),
        bodyMedium: TextStyle(color: base700, height: 1.35),
        labelLarge: TextStyle(fontWeight: FontWeight.w700),
      ),
      cardTheme: const CardThemeData(
        color: base50,
        elevation: 8,
        shadowColor: Color(0x99000000),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(18)),
          side: BorderSide(color: base200),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: base50,
        modalBackgroundColor: base50,
        showDragHandle: true,
        dragHandleColor: base300,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: base150,
        contentTextStyle: TextStyle(color: paper),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

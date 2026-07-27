import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Central design tokens for AgriKhata.
class AppColors {
  AppColors._();

  // ── Brand ──────────────────────────────────────────────────────────────
  static const Color primary = Color(0xFF1B4332);
  static const Color accent = Color(0xFF95D5B2);
  static const Color surface = Color(0xFFF7F9F4);
  static const Color whatsapp = Color(0xFF25D366);

  // Primary greens (legacy aliases)
  static const Color darkGreen = primary;
  static const Color mediumDarkGreen = Color.fromARGB(255, 55, 90, 75);
  static const Color mediumGreen = Color(0xFF2D6A4F);
  static const Color accentGreen = Color(0xFF40916C);
  static const Color lightGreenAccent = Color.fromARGB(255, 183, 228, 199);
  static const Color lightGreen = Color(0xFF3B6D11);

  // Surfaces
  static const Color background = surface;
  static const Color cardSurface = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFE2EBE0);
  static const Color tableHeaderBg = Color(0xFFF0F4EE);
  static const Color rowHover = Color(0xFFF0F7EB);

  // Text
  static const Color textPrimary = Color(0xFF1B4332);
  static const Color textMuted = Color(0xFF6B8F71);
  static const Color textHint = Color(0xFF95B89A);

  // Badges
  static const Color tagGreenBg = Color(0xFFD8F3DC);
  static const Color tagGreenText = Color(0xFF2D6A4F);
  static const Color tagRedBg = Color(0xFFFCEBEB);
  static const Color tagRedText = Color(0xFF791F1F);
  static const Color tagAmberBg = Color(0xFFFAEEDA);
  static const Color tagAmberText = Color(0xFF633806);
  static const Color tagBlueBg = Color(0xFFE6F1FB);
  static const Color tagBlueText = Color(0xFF0C447C);

  // Sidebar
  static const Color sidebarBg = Color(0xFF1B4332);
  static const Color sidebarBgEnd = Color(0xFF173B2B);
  static const Color sidebarActive = Color(0xFF2D6A4F);
  static const Color sidebarAccentBar = accent;
  static const Color sidebarText = Color(0xFFA7C4A0);
  static const Color sidebarNavIdle = Color(0xFFB7CFB9);
  static const Color sidebarSection = Color(0xFF6B9E7A);
  static const Color sidebarGlow = Color(0xFF40916C);
  static const Color sidebarVersion = Color(0xFF5C8468);

  static const Color cropDotColor = Color.fromARGB(255, 239, 159, 39);
  static const Color activeSeasonBadge = Color.fromARGB(255, 234, 243, 222);

  static const Color cardBorder = border;
  static const Color inputBorder = Color(0xFFC6DEC9);

  static const Color recBg = Color(0xFFEAF3DE);
  static const Color recBorder = Color(0xFF97C459);
  static const Color dangerBg = Color(0xFFFCEBEB);
  static const Color dangerBorder = Color(0xFFF7C1C1);
  static const Color dangerText = Color(0xFF791F1F);

  static const Color success = Color(0xFF2D6A4F);
  static const Color error = Color(0xFFC62828);
}

class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

class AppRadius {
  AppRadius._();

  static const double sm = 6;
  static const double md = 10;
  /// Primary control radius (buttons) — matches design reference.
  static const double button = 12;
  static const double lg = 16;
  static const double xl = 12;

  static BorderRadius get smAll => BorderRadius.circular(sm);
  static BorderRadius get mdAll => BorderRadius.circular(md);
  static BorderRadius get buttonAll => BorderRadius.circular(button);
  static BorderRadius get lgAll => BorderRadius.circular(lg);
  static BorderRadius get xlAll => BorderRadius.circular(xl);
}

/// Uniform typography tokens used across screens.
class AppTextStyles {
  AppTextStyles._();

  static const TextStyle pageTitle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
    height: 1.25,
  );

  static const TextStyle pageSubtitle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.textHint,
    height: 1.3,
  );

  static const TextStyle breadcrumbIdle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w200,
    color: AppColors.textMuted,
  );

  static const TextStyle breadcrumbActive = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    color: Colors.black,
  );

  static const TextStyle tableHeader = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: AppColors.mediumGreen,
    letterSpacing: 0.4,
    height: 1.2,
  );

  static const TextStyle body = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
    height: 1.35,
  );

  static const TextStyle bodySmall = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
    height: 1.3,
  );

  static const TextStyle label = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: AppColors.textMuted,
    height: 1.2,
  );

  static const TextStyle button = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.2,
  );

  static const TextStyle dialogTitle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );
}

class AppShadows {
  AppShadows._();

  static const List<BoxShadow> header = [
    BoxShadow(
      color: Colors.black12,
      blurRadius: 4,
      offset: Offset(0, 2),
    ),
  ];
}

class AppTheme {
  static ThemeData get theme => ThemeData(
        useMaterial3: true,
        fontFamily: GoogleFonts.tinos().fontFamily,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          primary: AppColors.primary,
          secondary: AppColors.accent,
          surface: AppColors.cardSurface,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.cardSurface,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
          titleTextStyle: AppTextStyles.pageTitle,
        ),
        cardTheme: CardThemeData(
          color: AppColors.cardSurface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: AppRadius.xlAll,
            side: const BorderSide(color: AppColors.border, width: 0.5),
          ),
          margin: EdgeInsets.zero,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            elevation: 0,
            minimumSize: const Size(0, 38),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonAll),
            textStyle: AppTextStyles.button,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.primary,
            side: const BorderSide(color: AppColors.inputBorder),
            minimumSize: const Size(0, 38),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonAll),
            textStyle: AppTextStyles.button,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.cardSurface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: AppColors.border, width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: AppColors.border, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide:
                const BorderSide(color: AppColors.accentGreen, width: 1.5),
          ),
          hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 13),
        ),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w500,
            color: AppColors.textPrimary,
          ),
          titleLarge: AppTextStyles.pageTitle,
          titleMedium: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppColors.textPrimary,
          ),
          bodyMedium: AppTextStyles.body,
          bodySmall: TextStyle(fontSize: 11, color: AppColors.textMuted),
        ),
        dividerTheme: const DividerThemeData(
          color: AppColors.border,
          thickness: 0.5,
          space: 0,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: AppColors.cardSurface,
          shape: RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
          titleTextStyle: AppTextStyles.dialogTitle,
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
        ),
      );
}

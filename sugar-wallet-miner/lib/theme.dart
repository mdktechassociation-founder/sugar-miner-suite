import 'package:flutter/material.dart';

const kBg = Color(0xFF0C0F14);
const kPanel = Color(0xFF151A23);
const kPanel2 = Color(0xFF1B2230);
const kLine = Color(0xFF242C3B);
const kInk = Color(0xFFE7ECF3);
const kMuted = Color(0xFF8B98AD);
const kAccent = Color(0xFFF5C451);
const kOk = Color(0xFF43D17A);
const kBad = Color(0xFFEF5F6B);
const kWarn = Color(0xFFE8A33D);

ThemeData sugarTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: kBg,
    colorScheme: base.colorScheme.copyWith(
      primary: kAccent,
      onPrimary: const Color(0xFF111111),
      surface: kPanel,
      error: kBad,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: kBg,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(color: kInk, fontSize: 18, fontWeight: FontWeight.w600),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 46),
        side: const BorderSide(color: kLine),
        foregroundColor: kInk,
      ),
    ),
    cardTheme: const CardThemeData(color: kPanel, elevation: 0, margin: EdgeInsets.zero),
    dividerTheme: const DividerThemeData(color: kLine, thickness: 1, space: 1),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: kPanel2,
      contentTextStyle: TextStyle(color: kInk),
      behavior: SnackBarBehavior.floating,
    ),
    textTheme: base.textTheme.apply(bodyColor: kInk, displayColor: kInk),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: kPanel,
      indicatorColor: Color(0x33F5C451),
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
    ),
  );
}

/// A title/value row used across the screens.
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String? note;
  final Color? color;
  const StatTile({super.key, required this.label, required this.value, this.note, this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: kPanel2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kLine),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: kMuted, fontSize: 11.5)),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w600, color: color ?? kInk)),
            if (note != null) ...[
              const SizedBox(height: 2),
              Text(note!, style: const TextStyle(color: kMuted, fontSize: 11)),
            ],
          ],
        ),
      );
}

class SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  const SectionCard({super.key, required this.title, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kLine),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      );
}

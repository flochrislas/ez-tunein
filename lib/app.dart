import 'package:flutter/material.dart';

import 'app_prefs.dart';
import 'player/player_page.dart';

class RadioApp extends StatelessWidget {
  const RadioApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuilds whenever the user picks a new accent color in Settings.
    return ValueListenableBuilder<Color>(
      valueListenable: accentColor,
      builder: (context, color, _) => MaterialApp(
        title: 'EZ-TuneIn Radio',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: color,
          useMaterial3: true,
          brightness: Brightness.dark,
        ),
        home: const PlayerPage(),
      ),
    );
  }
}

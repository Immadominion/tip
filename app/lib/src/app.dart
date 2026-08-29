import 'package:flutter/material.dart';

import 'links/incoming_links.dart';
import 'screens/boot_screen.dart';
import 'theme/theme.dart';

class TipApp extends StatelessWidget {
  const TipApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'tip',
      debugShowCheckedModeBanner: false,
      theme: TipTheme.light,
      darkTheme: TipTheme.dark,
      // Pinned to light until the dark palette is actually finished. The screens
      // hardcode light-palette colours in about two dozen places, so a phone set
      // to system dark renders near-white text on a light gradient and all three
      // home actions white on white. Shipping `darkTheme` without this line does
      // not give those users dark mode; it gives them an unreadable app.
      themeMode: ThemeMode.light,
      home: BootScreen(links: IncomingLinks()),
    );
  }
}

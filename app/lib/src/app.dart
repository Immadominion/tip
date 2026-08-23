import 'package:flutter/material.dart';

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
      home: const BootScreen(),
    );
  }
}

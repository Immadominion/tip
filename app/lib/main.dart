import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/auth/auth_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Sign-in is optional and the wallet works without it, so a backend that
  // will not start is noted and stepped over rather than allowed to keep the
  // app from opening.
  await AuthService.initialise();

  runApp(const TipApp());
}

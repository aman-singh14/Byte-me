import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'net/glasses_link.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final link = GlassesLink();
  link.start().catchError((Object e) => debugPrint('GlassesLink could not start: $e'));
  runApp(ChangeNotifierProvider.value(value: link, child: const OmniApp()));
}

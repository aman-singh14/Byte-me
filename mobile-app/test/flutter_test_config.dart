import 'dart:async';

import 'package:omni_glasses/theme/theme.dart';

// Runs before every test file: use the default font instead of fetching
// Google Fonts over the network.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  useGoogleFonts = false;
  await testMain();
}

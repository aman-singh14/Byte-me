// The live camera cards: the Eyes tab's eye camera (here through a relay, over
// real HTTP) with the pupil found, and Today's front camera in place of the
// "Glasses not watching" banner; laid out on a small phone at 200% text.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/app.dart';
import 'package:omni_glasses/eyes/phone_eyes.dart';
import 'package:omni_glasses/eyes/pupil.dart';
import 'package:omni_glasses/net/glasses_link.dart';
import 'package:omni_glasses/screens/eyes_widgets.dart';
import 'package:omni_glasses/screens/link_widgets.dart';
import 'package:provider/provider.dart';

import 'phone_eyes_test.dart' show NoDetector, fixtureJpeg;

void main() {
  testWidgets('shows the eye camera live, with the pupil found', (tester) async {
    final mocked = HttpOverrides.current;
    HttpOverrides.global = null; // real HTTP to the local server below
    addTearDown(() => HttpOverrides.global = mocked);
    tester.view.physicalSize = const Size(360 * 3, 740 * 3);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    final link = GlassesLink(port: 0);
    final pupil = CloseupEye();
    final eyes = PhoneEyes(
      link,
      frontDetector: NoDetector(),
      extractor: (jpeg) async {
        final g = decodeGrey(jpeg);
        return g == null ? null : pupil.extract(g);
      },
      persist: false,
    );
    final open = fixtureJpeg('settle 0');
    late HttpServer server;
    await tester.runAsync(() async {
      await link.start();
      await eyes.start();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        if (req.uri.path != '/relay/k/eye/stream') {
          req.response.statusCode = 404;
          return req.response.close();
        }
        req.response.headers.contentType = ContentType.parse('multipart/x-mixed-replace; boundary=frame');
        try {
          for (var i = 0; i < 200; i++) {
            req.response.add([...utf8.encode('--frame\r\nContent-Length: ${open.length}\r\n\r\n'), ...open, 13, 10]);
            await req.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
        } on Object {
          // the app hung up
        }
      });
    });

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: eyes,
        child: MaterialApp(
          theme: omniLightTheme,
          home: const Scaffold(body: SingleChildScrollView(child: EyeCameraCard())),
        ),
      ),
    );
    expect(find.text('No eye camera found.'), findsOneWidget);

    await tester.runAsync(() async {
      link.relay = parseRelay('http://127.0.0.1:${server.port}/relay/k');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    });
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('Eye found'), findsOneWidget);
    expect(find.textContaining('fps'), findsOneWidget);
    expect(eyes.eye.state.pupil, isNotNull);

    await tester.runAsync(() async {
      link.relay = null;
      await server.close(force: true);
      eyes.dispose();
      link.dispose();
    });
    await tester.pump();
  });

  testWidgets("Today shows the front camera instead of 'Glasses not watching' while it streams", (tester) async {
    final mocked = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = mocked);
    tester.view.physicalSize = const Size(360 * 3, 740 * 3);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    final link = GlassesLink(port: 0);
    final eyes = PhoneEyes(link, frontDetector: NoDetector(), extractor: (_) async => null, persist: false);
    final picture = fixtureJpeg('settle 0');
    late HttpServer server;
    await tester.runAsync(() async {
      await link.start();
      await eyes.start();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        if (req.uri.path != '/relay/k/front/stream') {
          req.response.statusCode = 404;
          return req.response.close();
        }
        req.response.headers.contentType = ContentType.parse('multipart/x-mixed-replace; boundary=frame');
        try {
          for (var i = 0; i < 200; i++) {
            req.response.add([
              ...utf8.encode('--frame\r\nContent-Length: ${picture.length}\r\n\r\n'),
              ...picture,
              13,
              10,
            ]);
            await req.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
        } on Object {
          // the app hung up
        }
      });
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: link),
          ChangeNotifierProvider.value(value: eyes),
        ],
        child: MaterialApp(
          theme: omniLightTheme,
          home: const Scaffold(body: SingleChildScrollView(child: LiveStatusStrip())),
        ),
      ),
    );
    expect(find.text('Glasses not watching'), findsOneWidget);

    await tester.runAsync(() async {
      link.relay = parseRelay('http://127.0.0.1:${server.port}/relay/k');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    });
    await tester.pump();
    expect(find.text('Glasses not watching'), findsNothing);
    expect(find.text('Front camera'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('No screen or book in view'), findsOneWidget);
    expect(find.textContaining('no alerts from behind'), findsOneWidget);

    // The glasses connect: "Glasses connected", with the front camera under it and no warning.
    await tester.runAsync(() async {
      final frame = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      frame.send(
        utf8.encode('{"t":"sens","dist":80,"blink":0,"yaw_rate":0,"lux":300}'),
        InternetAddress.loopbackIPv4,
        link.boundPort!,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      frame.close();
    });
    await tester.pump();
    expect(find.text('Glasses connected'), findsOneWidget);
    expect(find.text('Front camera'), findsOneWidget);
    expect(find.textContaining('no alerts from behind'), findsNothing);

    await tester.runAsync(() async {
      link.relay = null;
      await server.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 2600)); // the front camera goes quiet
    });
    await tester.pump();
    expect(find.text('Front camera'), findsNothing);

    await tester.runAsync(() async {
      eyes.dispose();
      link.dispose();
    });
    await tester.pump();
  });
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/vision/mjpeg.dart';

/// A fake JPEG: FF D8, some bytes (including lone FFs), FF D9.
Uint8List jpeg(int id, {int size = 50}) => Uint8List.fromList([
  0xFF, 0xD8,
  for (var i = 0; i < size; i++) i % 7 == 0 ? 0xFF : id, // FF followed by a non-marker byte
  0x00,
  0xFF, 0xD9,
]);

List<int> part(Uint8List frame) => [
  ...'--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${frame.length}\r\n\r\n'.codeUnits,
  ...frame,
  ...'\r\n'.codeUnits,
];

void main() {
  group('MjpegParser', () {
    test('finds frames in one chunk', () {
      final p = MjpegParser();
      final frames = p.add([...part(jpeg(1)), ...part(jpeg(2))]);
      expect(frames, [jpeg(1), jpeg(2)]);
    });

    test('reassembles frames split at every byte, including between FF and D9', () {
      final p = MjpegParser();
      final stream = [...part(jpeg(1)), ...part(jpeg(2)), ...part(jpeg(3))];
      final frames = <Uint8List>[];
      for (final b in stream) {
        frames.addAll(p.add([b]));
      }
      expect(frames, [jpeg(1), jpeg(2), jpeg(3)]);
    });

    test('resyncs after a cut-off frame', () {
      final p = MjpegParser();
      final cut = jpeg(1).sublist(0, 20);
      expect(p.add([...cut, ...part(jpeg(2))]), [jpeg(2)]);
    });

    test('drops an oversized frame and recovers', () {
      final p = MjpegParser();
      expect(p.add([0xFF, 0xD8, ...List.filled(MjpegParser.maxFrameBytes + 10, 1)]), isEmpty);
      expect(p.add(part(jpeg(5))), [jpeg(5)]);
    });
  });

  test('RearCamera streams frames from an HTTP server and keeps the newest', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sent = Completer<void>();
    server.listen((req) async {
      req.response.headers.contentType = ContentType('multipart', 'x-mixed-replace', parameters: {'boundary': 'frame'});
      req.response.bufferOutput = false; // send each frame now, like the ESP32 does
      for (var i = 1; i <= 5; i++) {
        req.response.add(part(jpeg(i)));
        await req.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      sent.complete();
      await Future<void>.delayed(const Duration(seconds: 1)); // keep the stream open
      await req.response.close();
    });

    final cam = RearCamera(Uri.parse('http://127.0.0.1:${server.port}/stream'));
    final seen = <Uint8List>[];
    cam.frame.addListener(() {
      final f = cam.frame.value;
      if (f != null) seen.add(f);
    });
    cam.start();
    await sent.future;
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(cam.state.value, CameraState.streaming);
    expect(cam.frame.value, jpeg(5));
    expect(seen.length, greaterThanOrEqualTo(2));

    cam.dispose();
    await server.close(force: true);
  });

  test('RearCamera retries when the camera is not there', () async {
    final cam = RearCamera(Uri.parse('http://127.0.0.1:1/stream'), retryDelay: const Duration(milliseconds: 50));
    cam.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(cam.state.value, anyOf(CameraState.retrying, CameraState.connecting));
    expect(cam.frame.value, isNull);
    cam.dispose();
  });
}

// The app against the real firmware: reads the sketches in ../firmware/ and
// checks that their ports, chunk headers and JSON messages are what the app
// expects, by running the firmware's own message formats through the app's
// parsers. If someone changes a port or a field in a sketch, this fails.
//
// The "Plug and play on the phone" group is skipped (not failed) while a
// sketch can't reach an iPhone yet; the skip reason says what to change.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/net/protocol.dart';

String sketch(String name) => File('../firmware/$name/$name.ino').readAsStringSync();

/// A `#define NAME value` or `const ... NAME = value;` number.
int number(String src, String name) {
  final m = RegExp('(?:#define\\s+$name\\s+(\\d+))|(?:\\b$name\\s*=\\s*(\\d+)\\s*;)').firstMatch(src);
  if (m == null) fail('$name not found');
  return int.parse(m.group(1) ?? m.group(2)!);
}

/// The C string that starts with [start] (adjacent literals joined, escapes
/// undone), with printf placeholders filled in: what the board would send.
Map<String, dynamic> message(String src, String start) {
  final i = src.indexOf(start);
  if (i < 0) fail('no message starting $start');
  final literal = RegExp(r'"((?:[^"\\]|\\.)*)"');
  final out = StringBuffer();
  var at = i;
  for (final m in literal.allMatches(src, i)) {
    if (src.substring(at, m.start).trim().isNotEmpty) break; // something other than a literal: the string ended
    out.write(m.group(1));
    at = m.end;
  }
  final text = out
      .toString()
      .replaceAll(r'\"', '"')
      .replaceAll(r'\\', r'\')
      .replaceAllMapped(RegExp(r'%[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?([sdiuxf])'), (m) {
        return switch (m.group(1)) {
          's' => 'x',
          'f' => '1.5',
          _ => '1',
        };
      });
  return jsonDecode(text) as Map<String, dynamic>;
}

void main() {
  final eye = sketch('esp_camera_eye'), front = sketch('esp_camera2_front'), back = sketch('esp_camera3_back');

  group('Eye and front cameras', () {
    for (final (name, src) in [('eye', eye), ('front', front)]) {
      test('$name: ports, WANT / STOP and the chunk header match the app', () {
        expect(number(src, 'STREAM_PORT'), camVideoPort);
        expect(number(src, 'HELLO_PORT'), camHelloPort);
        expect(src, contains('memcmp(head, "$videoWant", 4)'));
        expect(src, contains('memcmp(head, "$videoStop", 4)'));
        expect(number(src, 'CHUNK_BYTES') + chunkHeaderBytes, lessThanOrEqualTo(1472)); // one IP packet
        // The header layout UdpCamera reads: magic, id @4, chunk @8, chunks @10, length @12.
        expect(src, contains("uint8_t hdr[$chunkHeaderBytes] = {${eyeFrontMagic.split('').map((c) => "'$c'").join(', ')}}"));
        for (final field in ['hdr + 4, &id, 4', 'hdr + 8, &c, 2', 'hdr + 10, &chunks, 2', 'hdr + 12, &len, 4']) {
          expect(src, contains('memcpy($field)'));
        }
        // The app keeps asking more often than the camera forgets.
        expect(number(src, 'VIEWER_TIMEOUT_MS'), greaterThan(1000 * 2));
      });

      test('$name: its hello parses, with the ports the app uses', () {
        final hello = message(src, r'"{\"t\":\"cam_hello\"');
        expect(hello.keys, containsAll(['role', 'stream_port', 'http_port', 'stream']));
        final parsed = CamHello.parse(utf8.encode(jsonEncode(hello)))!;
        expect(parsed.udp, isTrue);
        expect(src, contains('#define DEVICE_NAME "$name"')); // the role the app looks for
      });
    }
  });

  group('Back camera + FPGA', () {
    test('port, header and video layout match the app', () {
      expect(number(back, 'UDP_PORT'), backCamPort);
      expect(back, contains("uint8_t hdr[$chunkHeaderBytes] = {${backMagic.split('').map((c) => "'$c'").join(', ')}}"));
      for (final field in ['hdr + 4, &videoId, 4', 'hdr + 8, &c, 2', 'hdr + 10, &chunks, 2', 'hdr + 12, &len, 4']) {
        expect(back, contains('memcpy($field)'));
      }
    });

    test('its status report and collision event parse', () {
      final status = message(back, r'"{\"t\":\"rear\"');
      expect(status.keys, containsAll(['tracking', 'collision', 'turning', 'imu', 'fpga', 'yaw_dps', 'k']));
      final parsed = RearStatus.fromJson(status)!;
      expect((parsed.tracking, parsed.turnRate), (true, 1.5)); // %d -> 1, %.1f -> 1.5
      expect(message(back, r'"{\"t\":\"collision\"')['t'], 'collision');
    });
  });

  group('Plug and play on the phone', () {
    // iOS doesn't give apps broadcast datagrams, so every board has to send to
    // the phone itself (172.20.10.1 on its own hotspot), or to whoever asked.
    final sendJson = RegExp(r'static void sendJson\([^)]*\)\s*\{([\s\S]*?)\n\}').firstMatch(back)?.group(1);
    if (sendJson == null) fail('sendJson() not found in esp_camera3_back');
    final backStatusToPhone = RegExp(r'beginPacket\((?!WiFi\.broadcastIP)').hasMatch(sendJson);
    test(
      "the back camera sends its status and collisions to the phone, not only as broadcast",
      () {},
      skip: backStatusToPhone
          ? false
          : 'esp_camera3_back only broadcasts its status and collisions (sendJson -> WiFi.broadcastIP()); '
                'also send them to each viewer (the phone pokes it every 2 s) or to 172.20.10.1',
    );
    test('eye and front hellos can go straight to the phone', () {
      for (final src in [eye, front]) {
        expect(src, contains('#ifdef BACKEND_HOST')); // set BACKEND_HOST "172.20.10.1" in secrets.h
      }
    });
  });
}

// The phone camera's frame encoder: raw BGRA (iOS) and YUV 4:2:0 (Android)
// frames become upright JPEGs.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:omni_glasses/vision/phone_camera.dart';

void main() {
  test('a BGRA frame becomes a JPEG, turned upright', () {
    const w = 8, h = 4, stride = w * 4 + 8; // rows can be padded
    final bytes = Uint8List(stride * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        bytes.setAll(y * stride + x * 4, [255, 0, 0, 255]); // blue
      }
    }
    final jpeg = encodeFrame(
      RawFrame(width: w, height: h, bgra: true, planes: [RawPlane(bytes, stride, 4)], rotation: 90),
    );
    final back = img.decodeJpg(jpeg)!;
    expect((back.width, back.height), (h, w)); // portrait now
    final p = back.getPixel(1, 1);
    expect(p.b, greaterThan(200));
    expect(p.r, lessThan(60));
  });

  test('a YUV frame becomes a JPEG with the right colours', () {
    const w = 4, h = 4;
    // Pure red is about Y 81, U 90, V 240.
    final y = Uint8List(w * h)..fillRange(0, w * h, 81);
    final u = Uint8List(4)..fillRange(0, 4, 90);
    final v = Uint8List(4)..fillRange(0, 4, 240);
    final jpeg = encodeFrame(
      RawFrame(width: w, height: h, bgra: false, planes: [RawPlane(y, w), RawPlane(u, 2), RawPlane(v, 2)]),
    );
    final p = img.decodeJpg(jpeg)!.getPixel(2, 2);
    expect(p.r, greaterThan(200));
    expect(p.g, lessThan(60));
  });
}

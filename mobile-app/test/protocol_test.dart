import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/net/protocol.dart';

GlassesMessage? parse(String s) => GlassesMessage.parse(utf8.encode(s));

void main() {
  group('parse', () {
    test('sens', () {
      final m = parse('{"t":"sens","dist":34,"blink":0,"yaw_rate":12,"lux":850}') as SensMessage;
      expect(m.distCm, 34);
      expect(m.blink, isFalse);
      expect(m.yawRate, 12);
      expect(m.lux, 850);
      expect(m.batteryPercent, isNull);
    });

    test('sens with optional battery and float values', () {
      final m = parse('{"t":"sens","dist":34.6,"blink":1,"yaw_rate":-12.2,"lux":850,"batt":82}') as SensMessage;
      expect(m.distCm, 35);
      expect(m.blink, isTrue);
      expect(m.yawRate, -12);
      expect(m.batteryPercent, 82);
    });

    test('fire', () {
      final m = parse('{"t":"fire","side":"L","k":812}') as FireMessage;
      expect(m.side, WearerSide.left);
      expect(m.k, 812);
    });

    test('hello', () {
      expect((parse('{"t":"hello","id":"frame"}') as HelloMessage).id, DeviceId.frame);
      expect((parse('{"t":"hello","id":"camA"}') as HelloMessage).id, DeviceId.camA);
    });

    test('bad input returns null instead of throwing', () {
      for (final bad in [
        '',
        'not json',
        '[1,2]',
        '{"t":"nope"}',
        '{"t":"hello","id":"camZ"}',
        '{"t":"fire","side":"X","k":1}',
        '{"t":"sens","dist":"far"}',
      ]) {
        expect(parse(bad), isNull, reason: bad);
      }
      expect(GlassesMessage.parse([0xff, 0xfe]), isNull);
    });
  });

  test('encode commands', () {
    String enc(GlassesCommand c) => utf8.decode(c.encode());
    expect(
      enc(const AlertCommand(side: WearerSide.left, level: 2, label: 'car')),
      '{"t":"alert","side":"L","level":2,"label":"car"}',
    );
    expect(enc(const TapCommand(side: WearerSide.right)), '{"t":"tap","side":"R","kind":"social"}');
    expect(enc(const GroupBreakCommand()), '{"t":"groupbreak"}');
    expect(enc(const StopCommand()), '{"t":"stop"}');
    expect(enc(const HeartbeatCommand()), '{"t":"hb"}');
  });

  test('rear image sides are flipped to wearer sides', () {
    // Left of the rear camera's image is on the wearer's right.
    expect(wearerSideFromRearImageX(0.1), WearerSide.right);
    expect(wearerSideFromRearImageX(0.9), WearerSide.left);
  });
}

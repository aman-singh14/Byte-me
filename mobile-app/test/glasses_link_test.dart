// Talks to a GlassesLink over real UDP on localhost, playing the glasses.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/net/glasses_link.dart';
import 'package:omni_glasses/net/protocol.dart';

class FakeDevice {
  FakeDevice._(this.socket) {
    socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d != null) received.add(utf8.decode(d.data));
    });
  }

  static Future<FakeDevice> bind() async => FakeDevice._(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));

  final RawDatagramSocket socket;
  final received = <String>[];

  void sendTo(GlassesLink link, String json) =>
      socket.send(utf8.encode(json), InternetAddress.loopbackIPv4, link.boundPort!);
}

Future<void> wait(int ms) => Future.delayed(Duration(milliseconds: ms));

void main() {
  late GlassesLink link;

  setUp(() async {
    link = GlassesLink(
      port: 0,
      linkTimeout: const Duration(milliseconds: 300),
      heartbeatInterval: const Duration(milliseconds: 50),
    );
    await link.start();
  });

  tearDown(() => link.dispose());

  test('learns the frame from its hello and starts heartbeats', () async {
    final frame = await FakeDevice.bind();
    expect(link.frame, isNull);

    frame.sendTo(link, '{"t":"hello","id":"frame"}');
    await wait(200);

    expect(link.frame?.port, frame.socket.port);
    expect(link.status, LinkStatus.searching); // hello alone is not "watching"
    expect(frame.received.where((m) => m == '{"t":"hb"}').length, greaterThanOrEqualTo(2));
    frame.socket.close();
  });

  test('connects on sensor data, then reports lost when it stops', () async {
    final frame = await FakeDevice.bind();
    final statuses = <LinkStatus>[];
    link.addListener(() => statuses.add(link.status));

    frame.sendTo(link, '{"t":"sens","dist":34,"blink":0,"yaw_rate":12,"lux":850,"batt":77}');
    await wait(50);
    expect(link.status, LinkStatus.connected);
    expect(link.batteryPercent, 77);
    expect(link.frame?.port, frame.socket.port); // learned from the sample too

    await wait(500);
    expect(link.status, LinkStatus.lost);

    frame.sendTo(link, '{"t":"sens","dist":34,"blink":0,"yaw_rate":12,"lux":850}');
    await wait(50);
    expect(link.status, LinkStatus.connected);
    expect(statuses, containsAllInOrder([LinkStatus.connected, LinkStatus.lost, LinkStatus.connected]));
    frame.socket.close();
  });

  test('camera hello gives the stream URL', () async {
    final cam = await FakeDevice.bind();
    cam.sendTo(link, '{"t":"hello","id":"camA"}');
    await wait(50);
    expect(link.streamUrl.toString(), 'http://127.0.0.1:81/stream');
    cam.socket.close();
  });

  test('relays fire events and sends commands to the frame', () async {
    final frame = await FakeDevice.bind();
    final fires = <FireMessage>[];
    link.fires.listen(fires.add);

    frame.sendTo(link, '{"t":"fire","side":"R","k":900}');
    await wait(50);
    expect(fires.single.side, WearerSide.right);

    link.send(const AlertCommand(side: WearerSide.right, level: 2, label: 'car'));
    await wait(50);
    expect(frame.received, contains('{"t":"alert","side":"R","level":2,"label":"car"}'));
    frame.socket.close();
  });

  test('ignores garbage datagrams', () async {
    final frame = await FakeDevice.bind();
    frame.sendTo(link, 'garbage');
    frame.sendTo(link, '{"t":"sens"}');
    await wait(50);
    expect(link.frame, isNull);
    expect(link.status, LinkStatus.searching);
    frame.socket.close();
  });
}

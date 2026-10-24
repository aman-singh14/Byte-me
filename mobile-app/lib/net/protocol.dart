// UDP JSON messages between the app and the glasses. Pure Dart, no I/O.
//
// One JSON object per datagram. Sides ("L"/"R") are always the WEARER's left
// and right; "B" (app to frame only) is straight behind. The rear camera's
// image is mirrored relative to the wearer; the only place that flips image
// sides is [wearerSideFromRearImageX].

import 'dart:convert';

/// The app listens on this UDP port. Devices send "hello" here, and the app
/// replies to the address and port each hello came from.
const int appUdpPort = 4210;

/// The rear camera serves MJPEG on this port at /stream.
const int camStreamPort = 81;

enum WearerSide {
  left('L'),
  right('R'),

  /// Straight behind. Only the app sends it, in "alert", meaning "buzz both
  /// motors". The frame's own messages ("fire") use L and R.
  behind('B');

  const WearerSide(this.wire);
  final String wire;

  static WearerSide? fromWire(Object? s) => switch (s) {
    'L' => WearerSide.left,
    'R' => WearerSide.right,
    'B' => WearerSide.behind,
    _ => null,
  };
}

/// The middle of the rear image counts as straight behind the wearer: this
/// share of its width, centered (about 18 degrees of a 60 degree camera).
const behindZone = 0.3;

/// The rear camera faces backward, so the left of its image is on the
/// wearer's right. [imageX] is the horizontal position in the image, 0..1
/// from the image's left edge. This is the only place sides are flipped.
WearerSide wearerSideFromRearImageX(double imageX) {
  if ((imageX - 0.5).abs() < behindZone / 2) return WearerSide.behind;
  return imageX < 0.5 ? WearerSide.right : WearerSide.left;
}

// ---------------------------------------------------------------------------
// Glasses -> app
// ---------------------------------------------------------------------------

sealed class GlassesMessage {
  const GlassesMessage();

  /// Parses one datagram. Returns null for anything malformed or unknown, so
  /// a bad packet never crashes the app.
  static GlassesMessage? parse(List<int> bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
    if (json is! Map<String, dynamic>) return null;
    return switch (json['t']) {
      'hello' => HelloMessage.fromJson(json),
      'sens' => SensMessage.fromJson(json),
      'fire' => FireMessage.fromJson(json),
      _ => null,
    };
  }
}

/// frame: the frame ESP32. camA: the rear camera the app runs YOLO on.
/// camB: the FPGA collision reflex camera; its video is used to name what
/// set off a fire. Both cameras serve MJPEG on [camStreamPort].
enum DeviceId { frame, camA, camB }

class HelloMessage extends GlassesMessage {
  const HelloMessage(this.id);
  final DeviceId id;

  static HelloMessage? fromJson(Map<String, dynamic> j) => switch (j['id']) {
    'frame' => const HelloMessage(DeviceId.frame),
    'camA' => const HelloMessage(DeviceId.camA),
    'camB' => const HelloMessage(DeviceId.camB),
    _ => null,
  };
}

/// Sensor sample from the frame ESP32, 10 per second.
class SensMessage extends GlassesMessage {
  const SensMessage({
    required this.distCm,
    required this.blink,
    required this.yawRate,
    required this.lux,
    this.batteryPercent,
  });

  final int distCm; // distance to what the wearer is looking at
  final bool blink; // a blink happened since the last sample
  final int yawRate; // head turn rate, degrees per second, positive toward the wearer's left
  final int lux; // ambient light
  final int? batteryPercent; // optional "batt" field, not in the original spec

  static SensMessage? fromJson(Map<String, dynamic> j) {
    final dist = j['dist'], blink = j['blink'], yaw = j['yaw_rate'], lux = j['lux'];
    if (dist is! num || blink is! num || yaw is! num || lux is! num) return null;
    final batt = j['batt'];
    return SensMessage(
      distCm: dist.round(),
      blink: blink != 0,
      yawRate: yaw.round(),
      lux: lux.round(),
      batteryPercent: batt is num ? batt.round().clamp(0, 100) : null,
    );
  }
}

/// Cam B's on-board collision reflex (the FPGA) fired. Relayed by the frame
/// ESP32.
class FireMessage extends GlassesMessage {
  const FireMessage({required this.side, required this.k});
  final WearerSide side;
  final int k; // LGMD potential when it fired

  static FireMessage? fromJson(Map<String, dynamic> j) {
    final side = WearerSide.fromWire(j['side']);
    final k = j['k'];
    if (side == null || k is! num) return null;
    return FireMessage(side: side, k: k.round());
  }
}

// ---------------------------------------------------------------------------
// App -> frame ESP32
// ---------------------------------------------------------------------------

sealed class GlassesCommand {
  const GlassesCommand();
  Map<String, Object> toJson();
  List<int> encode() => utf8.encode(jsonEncode(toJson()));
}

/// Buzz the wearer. [level] 1 = gentle, 2 = urgent.
class AlertCommand extends GlassesCommand {
  const AlertCommand({required this.side, required this.level, required this.label});
  final WearerSide side;
  final int level;
  final String label; // one word, e.g. "car"

  @override
  Map<String, Object> toJson() => {'t': 'alert', 'side': side.wire, 'level': level, 'label': label};
}

/// Social tap: someone stopped to talk. [kind] is "social" or "lookup".
class TapCommand extends GlassesCommand {
  const TapCommand({required this.side, this.kind = 'social'});
  final WearerSide side;
  final String kind;

  @override
  Map<String, Object> toJson() => {'t': 'tap', 'side': side.wire, 'kind': kind};
}

class GroupBreakCommand extends GlassesCommand {
  const GroupBreakCommand();
  @override
  Map<String, Object> toJson() => {'t': 'groupbreak'};
}

class StopCommand extends GlassesCommand {
  const StopCommand();
  @override
  Map<String, Object> toJson() => {'t': 'stop'};
}

class HeartbeatCommand extends GlassesCommand {
  const HeartbeatCommand();
  @override
  Map<String, Object> toJson() => {'t': 'hb'};
}

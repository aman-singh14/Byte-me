// Together time: minutes spent near friends, counted over Bluetooth. Off
// until the wearer turns it on.
//
// Each person has a random "nearby id" from the server that only their
// friends learn. While Together time is on and the app is open, the phone
// advertises its own id and listens for friends' ids; a friend heard with a
// strong enough signal (a few meters) in the last 30 s counts as nearby.
// Minutes are counted on this phone, kept for 30 days to rank best friends,
// and never uploaded.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'social_api.dart';
import 'social_store.dart';

abstract class NearbyRadio {
  /// Advertises [myId] and listens for [watch]. Returns why it can't
  /// ("Bluetooth is off"), or null once running.
  Future<String?> start(String myId, Set<String> watch);

  /// Ids from the watch list heard close by, as they are heard.
  Stream<String> get heard;

  Future<void> stop();
}

/// The real radio: flutter_ble_peripheral to advertise, flutter_blue_plus to
/// scan. The id goes out as a service UUID, the one thing iOS lets an app
/// advertise.
class BleNearbyRadio implements NearbyRadio {
  /// About a few meters. Weaker than this doesn't count as together.
  static const minRssi = -75;

  final _heard = StreamController<String>.broadcast();
  StreamSubscription<List<ScanResult>>? _scan;

  @override
  Stream<String> get heard => _heard.stream;

  @override
  Future<String?> start(String myId, Set<String> watch) async {
    await stop();
    try {
      if (!await FlutterBluePlus.isSupported) return "This phone can't use Bluetooth for this.";
      final peripheral = FlutterBlePeripheral();
      await peripheral.requestPermission();
      if (!await peripheral.isBluetoothOn) return 'Turn on Bluetooth to count time with friends.';
      await peripheral.start(advertiseData: AdvertiseDataCore(serviceUuid: myId));
      if (watch.isEmpty) return null; // nobody to listen for yet
      final ids = {for (final id in watch) id.toLowerCase()};
      _scan = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          if (r.rssi < minRssi) continue;
          for (final uuid in r.advertisementData.serviceUuids) {
            final id = uuid.str128.toLowerCase();
            if (ids.contains(id)) _heard.add(id);
          }
        }
      });
      await FlutterBluePlus.startScan(
        withServices: [for (final id in watch) Guid(id)],
        continuousUpdates: true,
        androidScanMode: AndroidScanMode.lowPower,
      );
      return null;
    } catch (e) {
      debugPrint('BleNearbyRadio: $e');
      return "Couldn't start Bluetooth. Check the app's Bluetooth permission.";
    }
  }

  @override
  Future<void> stop() async {
    await _scan?.cancel();
    _scan = null;
    try {
      await FlutterBluePlus.stopScan();
      await FlutterBlePeripheral().stop();
    } catch (_) {}
  }
}

class TogetherTime extends ChangeNotifier {
  TogetherTime({required this.social, required this.radio, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final SocialStore social;
  final NearbyRadio radio;
  final DateTime Function() _clock;

  static const _key = 'together_time_v1';

  /// Someone heard within this long counts as still nearby.
  static const nearbyFor = Duration(seconds: 30);

  /// Best friends are ranked over this many days.
  static const bestFriendDays = 30;

  SharedPreferences? _prefs;
  StreamSubscription<String>? _heard;
  Timer? _tick;
  String _watching = '';

  bool _enabled = false;
  bool get enabled => _enabled;

  /// Why it isn't running, to show the wearer.
  String? _problem;
  String? get problem => _problem;

  final _lastHeard = <String, DateTime>{}; // nearby id -> when
  DateTime? _lastTick;

  // Seconds per day ("2026-10-24"): with anyone, and per friend id.
  final _anyone = <String, int>{};
  final _byFriend = <String, Map<int, int>>{};

  /// Minutes with at least one friend nearby, today.
  int get minutesToday => (_anyone[_dayKey(_clock())] ?? 0) ~/ 60;

  /// Friends you spent the most time near over the last [bestFriendDays],
  /// most first, with minutes. Only current friends.
  List<(Person, int)> get bestFriends {
    final cutoff = _dayKey(_clock().subtract(const Duration(days: bestFriendDays - 1)));
    final seconds = <int, int>{};
    for (final MapEntry(key: day, value: friends) in _byFriend.entries) {
      if (day.compareTo(cutoff) < 0) continue;
      for (final MapEntry(:key, :value) in friends.entries) {
        seconds[key] = (seconds[key] ?? 0) + value;
      }
    }
    return [
      for (final f in social.friends)
        if ((seconds[f.id] ?? 0) >= 60) (f, seconds[f.id]! ~/ 60),
    ]..sort((a, b) => a.$2 != b.$2 ? b.$2.compareTo(a.$2) : a.$1.name.compareTo(b.$1.name));
  }

  /// Friends heard in the last [nearbyFor].
  List<Person> get nearbyNow {
    final now = _clock();
    return [
      for (final f in social.friends)
        if (_lastHeard[f.nearbyId?.toLowerCase()] case final t? when now.difference(t) <= nearbyFor) f,
    ];
  }

  Future<void> start() async {
    try {
      final prefs = _prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool('${_key}_on') ?? false;
      final saved = prefs.getString(_key);
      if (saved != null) _load(jsonDecode(saved) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('TogetherTime: could not load: $e');
    }
    social.addListener(_syncRadio);
    _heard = radio.heard.listen((id) => _lastHeard[id] = _clock());
    _tick = Timer.periodic(const Duration(seconds: 10), (_) => tick());
    await _syncRadio();
  }

  Future<void> setEnabled(bool on) async {
    _enabled = on;
    await _prefs?.setBool('${_key}_on', on);
    await _syncRadio();
    notifyListeners();
  }

  /// Restarts the radio when it's turned on or off, or the friends change.
  Future<void> _syncRadio() async {
    final me = social.me;
    final ids = {
      for (final f in social.friends)
        if (f.nearbyId != null) f.nearbyId!.toLowerCase(),
    };
    final want = _enabled && me != null ? '${me.nearbyId}|${(ids.toList()..sort()).join(',')}' : '';
    if (want == _watching) return;
    _watching = want;
    if (want.isEmpty) {
      await radio.stop();
      _problem = null;
    } else {
      _problem = await radio.start(me!.nearbyId, ids);
    }
    notifyListeners();
  }

  /// Adds the time since the last tick if a friend is nearby. Public for tests.
  @visibleForTesting
  void tick() {
    final now = _clock();
    final last = _lastTick;
    _lastTick = now;
    if (last == null || !_enabled) return;
    var dt = now.difference(last).inSeconds;
    if (dt > 15) dt = 15; // the app was paused
    final nearby = nearbyNow;
    if (nearby.isEmpty || dt <= 0) return;
    final day = _dayKey(now);
    final before = minutesToday;
    _anyone[day] = (_anyone[day] ?? 0) + dt;
    final friends = _byFriend.putIfAbsent(day, () => {});
    for (final f in nearby) {
      friends[f.id] = (friends[f.id] ?? 0) + dt;
    }
    _prune(now);
    _save();
    if (minutesToday != before) notifyListeners();
  }

  static String _dayKey(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  void _prune(DateTime now) {
    final cutoff = _dayKey(now.subtract(const Duration(days: bestFriendDays)));
    _anyone.removeWhere((day, _) => day.compareTo(cutoff) < 0);
    _byFriend.removeWhere((day, _) => day.compareTo(cutoff) < 0);
  }

  void _load(Map<String, dynamic> j) {
    for (final MapEntry(:key, :value) in (j['anyone'] as Map? ?? const {}).entries) {
      _anyone[key as String] = value as int;
    }
    for (final MapEntry(key: day, value: friends) in (j['by_friend'] as Map? ?? const {}).entries) {
      _byFriend[day as String] = {
        for (final MapEntry(:key, :value) in (friends as Map).entries) int.parse(key as String): value as int,
      };
    }
  }

  void _save() => _prefs?.setString(
    _key,
    jsonEncode({
      'anyone': _anyone,
      'by_friend': {
        for (final MapEntry(key: day, value: friends) in _byFriend.entries)
          day: {for (final MapEntry(:key, :value) in friends.entries) '$key': value},
      },
    }),
  );

  @override
  void dispose() {
    social.removeListener(_syncRadio);
    _heard?.cancel();
    _tick?.cancel();
    radio.stop();
    super.dispose();
  }
}

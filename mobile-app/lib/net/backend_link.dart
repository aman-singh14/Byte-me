// Polls the laptop backend for eye, close-up and ring data.
//
// Address: the one typed in Settings, or else the laptop the glasses' UDP hello came
// from (GlassesLink.frame, the backend plays that device) on port 8001.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backend_api.dart';
import 'backend_models.dart';
import 'glasses_link.dart';

enum BackendStatus {
  /// No address yet: none typed, and no hello from the laptop.
  notConfigured,

  /// Address known, first answer pending.
  connecting,

  /// Answering.
  connected,

  /// Was asked and did not answer.
  unreachable,
}

/// Where the backend address is remembered. Tests use [MemorySettingsStore].
abstract class SettingsStore {
  Future<String?> getBackendUrl();
  Future<void> setBackendUrl(String? url);
}

class PrefsSettingsStore implements SettingsStore {
  static const _key = 'backend_url';

  @override
  Future<String?> getBackendUrl() async => (await SharedPreferences.getInstance()).getString(_key);

  @override
  Future<void> setBackendUrl(String? url) async {
    final p = await SharedPreferences.getInstance();
    url == null ? await p.remove(_key) : await p.setString(_key, url);
  }
}

class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([this.url]);
  String? url;

  @override
  Future<String?> getBackendUrl() async => url;

  @override
  Future<void> setBackendUrl(String? u) async => url = u;
}

typedef ApiFactory = BackendApi Function(Uri base);

/// Normalises what the user typed: "172.20.10.2" -> http://172.20.10.2:8001.
Uri? parseBackendUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'http://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty || (u.scheme != 'http' && u.scheme != 'https')) return null;
  return u.hasPort ? u.replace(path: '') : u.replace(port: 8001, path: '');
}

class BackendLink extends ChangeNotifier {
  BackendLink({
    SettingsStore? store,
    ApiFactory? apiFactory,
    this.liveEvery = const Duration(seconds: 2),
    this.slowEvery = const Duration(seconds: 20),
  }) : _store = store ?? PrefsSettingsStore(),
       _apiFactory = apiFactory ?? ((base) => BackendApi(base));

  final SettingsStore _store;
  final ApiFactory _apiFactory;
  final Duration liveEvery;
  final Duration slowEvery;

  Uri? _manual; // typed in Settings
  Uri? _auto; // from the glasses link
  BackendApi? _api;
  Timer? _liveTimer;
  Timer? _slowTimer;
  GlassesLink? _glasses;
  bool _disposed = false;

  BackendStatus _status = BackendStatus.notConfigured;
  BackendStatus get status => _status;
  String? lastError;
  DateTime? lastUpdate;

  EyesLive? eyes;
  EyesHistory? eyesHistory;
  CloseupDay? closeup;
  RingsDay? rings;
  List<RingsDay> ringsHistory = const [];

  /// The address in use, if any.
  Uri? get baseUrl => _manual ?? _auto;
  Uri? get manualUrl => _manual;
  Uri? get discoveredUrl => _auto;

  Future<void> start({GlassesLink? glasses}) async {
    final saved = await _store.getBackendUrl();
    _manual = saved == null ? null : parseBackendUrl(saved);
    if (glasses != null) {
      _glasses = glasses;
      glasses.addListener(_onGlasses);
      _onGlasses();
    }
    _useBase();
    _liveTimer = Timer.periodic(liveEvery, (_) => refreshLive());
    _slowTimer = Timer.periodic(slowEvery, (_) => refreshSlow());
  }

  void _onGlasses() {
    final frame = _glasses?.frame;
    final next = frame == null ? null : Uri(scheme: 'http', host: frame.address.address, port: 8001);
    if (next != _auto) {
      _auto = next;
      if (_manual == null) _useBase();
    }
  }

  void _useBase() {
    final base = baseUrl;
    final changed = base?.toString() != _api?.base.toString();
    if (!changed) return;
    _api = base == null ? null : _apiFactory(base);
    _set(base == null ? BackendStatus.notConfigured : BackendStatus.connecting);
    if (_api != null) refreshAll();
  }

  /// Save (or clear, with an empty string) the address typed in Settings.
  /// Returns false if it isn't a usable address.
  Future<bool> setManualUrl(String input) async {
    if (input.trim().isEmpty) {
      _manual = null;
      await _store.setBackendUrl(null);
      _useBase();
      return true;
    }
    final u = parseBackendUrl(input);
    if (u == null) return false;
    _manual = u;
    await _store.setBackendUrl(u.toString());
    _useBase();
    return true;
  }

  Future<void> refreshAll() async {
    await refreshLive();
    await refreshSlow();
  }

  Future<void> refreshLive() => _guard((api) async {
    final results = await Future.wait([api.eyesLive(), api.ringsToday()]);
    eyes = results[0] as EyesLive;
    rings = results[1] as RingsDay;
  });

  Future<void> refreshSlow() => _guard((api) async {
    final results = await Future.wait([api.closeupToday(), api.eyesHistory(), api.ringsHistory()]);
    closeup = results[0] as CloseupDay;
    eyesHistory = results[1] as EyesHistory;
    ringsHistory = results[2] as List<RingsDay>;
  });

  Future<void> _guard(Future<void> Function(BackendApi api) work) async {
    final api = _api;
    if (api == null || _disposed) return;
    try {
      await work(api);
      if (_disposed || !identical(api, _api)) return;
      lastError = null;
      lastUpdate = DateTime.now();
      _set(BackendStatus.connected, force: true);
    } on BackendException catch (e) {
      if (_disposed || !identical(api, _api)) return;
      lastError = e.message;
      _set(BackendStatus.unreachable, force: true);
    }
  }

  /// Calibrate one object type at a known distance. Returns an error message, or null.
  Future<String?> calibrateCloseup(String object, double knownCm) async {
    final api = _api;
    if (api == null) return 'Set the backend address in Settings first.';
    try {
      await api.calibrateCloseup(object, knownCm);
      return null;
    } on BackendException catch (e) {
      return e.message;
    }
  }

  /// "What am I looking at?" Throws [BackendException] with a readable message.
  Future<LookResult> look({String? question, String? region}) async {
    final api = _api;
    if (api == null) throw const BackendException('Set the laptop address in Settings first.');
    return api.look(question: question, region: region);
  }

  /// Dev mode only. Returns an error message, or null.
  Future<String?> setOutside(bool? on) async {
    final api = _api;
    if (api == null) return 'Set the backend address in Settings first.';
    try {
      await api.setOutside(on);
      unawaited(refreshLive());
      return null;
    } on BackendException catch (e) {
      return e.message;
    }
  }

  void _set(BackendStatus s, {bool force = false}) {
    if (_disposed) return;
    if (s != _status || force) {
      _status = s;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _liveTimer?.cancel();
    _slowTimer?.cancel();
    _glasses?.removeListener(_onGlasses);
    super.dispose();
  }
}

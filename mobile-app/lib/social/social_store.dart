// Together: who you are on the social server, your friends and groups, and
// their group screen breaks.
//
// Polls the server while the app is open (every 30 s, every 5 s around a
// break), uploads today's ring percentages at most once a minute and side
// quest stars as soon as one is earned, and reminds: when a team's group
// screen break starts, "groupbreak" goes to the glasses and the app says
// so. Nothing about the break is measured. No account or password: the server hands out
// a random token, kept on this phone.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/glasses_link.dart';
import '../net/protocol.dart';
import 'rings_source.dart';
import 'social_api.dart';

/// Where the social server is. Override with
/// `flutter run --dart-define=SOCIAL_URL=https://...` or in Settings.
const defaultSocialUrl = String.fromEnvironment('SOCIAL_URL', defaultValue: 'http://localhost:8000');

/// Things the UI should say or celebrate.
sealed class TogetherEvent {
  const TogetherEvent();
}

/// A team's group screen break just started: time to look up and talk.
class BreakStarted extends TogetherEvent {
  const BreakStarted(this.group, this.brk);
  final Group group;
  final GroupBreak brk;
}

class SocialStore extends ChangeNotifier {
  SocialStore({
    required this.link,
    required this.rings,
    this.questStars,
    SocialApi Function(Uri url, String? token)? api,
    DateTime Function()? clock,
  }) : _makeApi = api ?? ((url, token) => SocialApi(url, token: token)),
       _clock = clock ?? DateTime.now;

  final GlassesLink link;
  final RingsSource rings;

  /// Today's side quest stars by quest id (from SideQuestStore).
  final Map<String, int> Function()? questStars;
  final SocialApi Function(Uri, String?) _makeApi;
  final DateTime Function() _clock;

  static const _tokenKey = 'together_token';
  static const _meKey = 'together_me';
  static const _urlKey = 'together_url';
  static const _remindedKey = 'together_reminded';

  SharedPreferences? _prefs;
  late SocialApi _api = _makeApi(Uri.parse(defaultSocialUrl), null);
  Timer? _poll;
  Timer? _tick;
  DateTime? _lastUpload;
  (String, int, int, String)? _uploaded; // day, heads-up %, outside %, stars by quest
  bool _disposed = false;
  bool _started = false;

  Me? _me;
  Me? get me => _me;
  bool get signedIn => _me != null;

  Uri get serverUrl => _api.baseUrl;

  List<Person> _friends = const [];
  List<Person> get friends => _friends;

  List<Group> _groups = const [];
  List<Group> get groups => _groups;

  /// Public teams and yours, best first.
  List<LeagueTeam> _league = const [];
  List<LeagueTeam> get league => _league;

  /// Couldn't reach the server on the last try.
  bool _offline = false;
  bool get offline => _offline;

  final _reminded = <int>{}; // break ids already announced

  final _events = StreamController<TogetherEvent>.broadcast();
  Stream<TogetherEvent> get events => _events.stream;

  /// The next break worth showing first: running, then the soonest upcoming.
  (Group, GroupBreak)? get nextBreak {
    (Group, GroupBreak)? best;
    for (final g in _groups) {
      for (final b in g.breaks) {
        if (b.isOver) continue;
        if (best == null || b.startsAt.isBefore(best.$2.startsAt)) best = (g, b);
      }
    }
    return best;
  }

  Uri teamPage(Group g) => _api.teamPage(g);

  Future<void> start() async {
    try {
      final prefs = _prefs = await SharedPreferences.getInstance();
      _api = _makeApi(Uri.parse(prefs.getString(_urlKey) ?? defaultSocialUrl), prefs.getString(_tokenKey));
      final saved = prefs.getString(_meKey);
      if (saved != null && _api.token != null) _me = Me.fromJson(jsonDecode(saved) as Map<String, dynamic>);
      _reminded.addAll((prefs.getStringList(_remindedKey) ?? const []).map(int.parse));
    } catch (e) {
      debugPrint('SocialStore: could not load: $e');
    }
    _started = true;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      _runBreaks();
      upload();
    });
    notifyListeners();
    await refresh();
  }

  // --- account ---------------------------------------------------------------

  /// Joins Together with a display name. Returns an error to show, or null.
  Future<String?> signUp(String name) => _guard(() async {
    final (me, token) = await _api.signUp(name);
    _api.token = token;
    _me = me;
    await _prefs?.setString(_tokenKey, token);
    await _saveMe();
    await refresh();
  });

  Future<String?> rename(String name) => _guard(() async {
    _me = await _api.rename(name);
    await _saveMe();
  });

  /// Deletes everything the server has about this person, then forgets
  /// them here.
  Future<String?> deleteAccount() => _guard(() async {
    await _api.deleteMe();
    await _forget();
  });

  /// Points the app at another server (a deployment, or a laptop in dev).
  /// Signs out, since accounts belong to one server.
  Future<void> setServer(Uri url) async {
    await _prefs?.setString(_urlKey, url.toString());
    _api = _makeApi(url, null);
    await _forget();
  }

  Future<void> _forget() async {
    _me = null;
    _api.token = null;
    _friends = const [];
    _groups = const [];
    _league = const [];
    await _prefs?.remove(_tokenKey);
    await _prefs?.remove(_meKey);
    notifyListeners();
  }

  Future<void> _saveMe() async => _prefs?.setString(_meKey, jsonEncode(_me!.toJson()));

  // --- friends and groups ------------------------------------------------------

  Future<String?> addFriend(String code) => _guard(() async {
    await _api.addFriend(code);
    _friends = await _api.friends();
  });

  Future<String?> removeFriend(Person p) => _guard(() async {
    await _api.removeFriend(p.id);
    _friends = await _api.friends();
  });

  Future<String?> createGroup(String name) => _guard(() async {
    await _api.createGroup(name);
    await _reloadGroups();
  });

  Future<String?> joinGroup(String code) => _guard(() async {
    await _api.joinGroup(code);
    await _reloadGroups();
  });

  Future<String?> leaveGroup(Group g) => _guard(() async {
    await _api.leaveGroup(g.id);
    await _reloadGroups();
  });

  Future<String?> setPublic(Group g, bool isPublic) => _guard(() async {
    await _api.setPublic(g.id, isPublic);
    await _reloadGroups();
  });

  /// Groups and the league, after a change that affects both. One after
  /// the other, so a failure stays a SocialError for [_guard].
  Future<void> _reloadGroups() async {
    _groups = await _api.groups();
    _league = await _api.league();
  }

  // --- group breaks --------------------------------------------------------------

  Future<String?> scheduleBreak(Group g, DateTime startsAt, {int minutes = 10}) => _guard(() async {
    await _api.scheduleBreak(g.id, startsAt, minutes);
    _groups = await _api.groups();
    _schedulePoll();
  });

  Future<String?> cancelBreak(GroupBreak b) => _guard(() async {
    await _api.cancelBreak(b.id);
    _groups = await _api.groups();
  });

  // --- sync ------------------------------------------------------------------------

  Future<void> refresh() async {
    if (!signedIn) return;
    try {
      final (friends, groups, league) = await (_api.friends(), _api.groups(), _api.league()).wait;
      _friends = friends;
      _groups = groups;
      _league = league;
      _offline = false;
      _runBreaks();
    } on ParallelWaitError<
      (List<Person>?, List<Group>?, List<LeagueTeam>?),
      (AsyncError?, AsyncError?, AsyncError?)
    > catch (e) {
      final error = e.errors.$1?.error ?? e.errors.$2?.error ?? e.errors.$3?.error;
      if (error is SocialError && error.unauthorized) return _forget();
      _offline = true;
    }
    if (!_disposed) {
      _schedulePoll();
      notifyListeners();
    }
  }

  void _schedulePoll() {
    _poll?.cancel();
    if (_disposed || !_started || !signedIn) return; // polling begins with start()
    final now = _clock();
    final soon = _groups.any(
      (g) => g.breaks.any((b) => !b.isOver && b.startsAt.difference(now) < const Duration(minutes: 2)),
    );
    _poll = Timer(Duration(seconds: soon ? 5 : 30), refresh);
  }

  /// Sends today's ring percentages and stars when they changed: at most
  /// once a minute, except right away for a new star. Runs every second;
  /// public for tests.
  @visibleForTesting
  void upload() {
    if (!signedIn) return;
    final now = _clock();
    final today = rings.today;
    final day = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final quests = questStars?.call() ?? const {};
    final next = (day, today.headsUpPercent, today.outsidePercent, jsonEncode(quests));
    final last = _uploaded, at = _lastUpload;
    if (next == last) return;
    final newStar = last != null && next.$4 != last.$4;
    if (!newStar && at != null && now.difference(at) < const Duration(minutes: 1)) return;
    _uploaded = next;
    _lastUpload = now;
    _api.putRings(next.$1, next.$2, next.$3, quests: quests).catchError((Object e) {
      _uploaded = null; // try again in a minute
      debugPrint('SocialStore: ring upload failed: $e');
    });
  }

  /// Another team's stats and members (public teams, or yours). Returns
  /// the team, or an error to show.
  Future<(TeamDetails?, String?)> team(LeagueTeam t) async {
    try {
      return (await _api.team(t.id), null);
    } on SocialError catch (e) {
      return (null, e.message);
    }
  }

  /// Reminds once when a team break starts (or on opening the app during
  /// one).
  void _runBreaks() {
    if (!signedIn) return;
    final now = _clock();
    for (final g in _groups) {
      for (final b in g.breaks) {
        if (now.isBefore(b.startsAt) || !now.isBefore(b.endsAt) || !_reminded.add(b.id)) continue;
        link.send(const GroupBreakCommand());
        _events.add(BreakStarted(g, b));
        final recent = (_reminded.toList()..sort()).reversed.take(50);
        _prefs?.setStringList(_remindedKey, [for (final id in recent) '$id']);
        notifyListeners();
      }
    }
  }

  Future<String?> _guard(Future<void> Function() action) async {
    try {
      await action();
      _offline = false;
      return null;
    } on SocialError catch (e) {
      if (e.unauthorized) await _forget();
      return e.message;
    } finally {
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _tick?.cancel();
    _events.close();
    super.dispose();
  }
}

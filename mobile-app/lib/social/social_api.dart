// Client for the social server (../social/app.py). It only ever sends a
// display name, ring percentages and side quest stars, friend and group
// codes, and group break times.

import 'dart:convert';

import 'package:http/http.dart' as http;

class Me {
  const Me({required this.id, required this.name, required this.friendCode, required this.nearbyId});

  final int id;
  final String name;
  final String friendCode;

  /// What this phone advertises over Bluetooth for "together time". Only
  /// friends learn it.
  final String nearbyId;

  factory Me.fromJson(Map<String, dynamic> j) => Me(
    id: j['id'] as int,
    name: j['name'] as String,
    friendCode: j['friend_code'] as String,
    nearbyId: j['nearby_id'] as String,
  );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'friend_code': friendCode, 'nearby_id': nearbyId};
}

/// A friend or group member: a name and today's ring percentages.
class Person {
  const Person({
    required this.id,
    required this.name,
    this.headsUp = 0,
    this.outside = 0,
    this.starsThisWeek = 0,
    this.questsThisWeek = const {},
    this.ringWeek = 0,
    this.nearbyId,
  });

  final int id;
  final String name;
  final int headsUp;
  final int outside;

  /// Side quest stars, Monday to now: in all, and by quest id.
  final int starsThisWeek;
  final Map<String, int> questsThisWeek;

  /// Average ring this week (each day: the average of its two rings).
  final int ringWeek;
  final String? nearbyId;

  factory Person.fromJson(Map<String, dynamic> j) => Person(
    id: j['id'] as int,
    name: j['name'] as String,
    headsUp: j['heads_up'] as int? ?? 0,
    outside: j['outside'] as int? ?? 0,
    starsThisWeek: j['stars_week'] as int? ?? 0,
    questsThisWeek: {
      for (final MapEntry(:key, :value) in (j['quests_week'] as Map? ?? const {}).entries) key as String: value as int,
    },
    ringWeek: j['ring_week'] as int? ?? 0,
    nearbyId: j['nearby_id'] as String?,
  );
}

enum BreakStatus { upcoming, running, over }

/// A group screen break: a reminder for the whole team to look up and talk.
/// Nothing about it is measured.
class GroupBreak {
  const GroupBreak({
    required this.id,
    required this.startsAt,
    required this.endsAt,
    required this.minutes,
    required this.status,
    this.by,
  });

  final int id;
  final DateTime startsAt;
  final DateTime endsAt;
  final int minutes;
  final BreakStatus status;

  /// Who scheduled it.
  final String? by;

  bool get isOver => status == BreakStatus.over;

  factory GroupBreak.fromJson(Map<String, dynamic> j) => GroupBreak(
    id: j['id'] as int,
    startsAt: DateTime.parse(j['starts_at'] as String).toLocal(),
    endsAt: DateTime.parse(j['ends_at'] as String).toLocal(),
    minutes: j['minutes'] as int,
    status: BreakStatus.values.asNameMap()[j['status']] ?? BreakStatus.upcoming,
    by: j['by'] as String?,
  );
}

class Group {
  const Group({
    required this.id,
    required this.name,
    required this.inviteCode,
    required this.publicId,
    required this.isPublic,
    required this.team,
    required this.members,
    required this.breaks,
  });

  final int id;
  final String name;
  final String inviteCode;
  final String publicId;
  final bool isPublic;

  /// The team ring: everyone's two rings averaged, 0-100.
  final int team;
  final List<Person> members;
  final List<GroupBreak> breaks;

  factory Group.fromJson(Map<String, dynamic> j) => Group(
    id: j['id'] as int,
    name: j['name'] as String,
    inviteCode: j['invite_code'] as String,
    publicId: j['public_id'] as String,
    isPublic: j['is_public'] as bool,
    team: j['team'] as int,
    members: [for (final m in j['members'] as List) Person.fromJson(m as Map<String, dynamic>)],
    breaks: [for (final b in j['breaks'] as List) GroupBreak.fromJson(b as Map<String, dynamic>)],
  );
}

/// A team's place in the league: public teams (and your own) ranked by
/// points this week (10 per side quest star per member, plus the average
/// ring).
class LeagueTeam {
  const LeagueTeam({
    required this.id,
    required this.name,
    required this.members,
    required this.stars,
    required this.rank,
    this.points = 0,
    this.ringWeek = 0,
    this.ringToday = 0,
    this.headsUp = 0,
    this.outside = 0,
    this.quests = const {},
    this.mine = false,
    this.publicId,
  });

  final int id;
  final String name;
  final int members;

  /// Stars per member this week.
  final double stars;
  final int rank;
  final int points;

  /// Average ring this week, and the team ring today.
  final int ringWeek;
  final int ringToday;

  /// Members' average rings today.
  final int headsUp;
  final int outside;

  /// Team total stars this week, by quest id.
  final Map<String, int> quests;
  final bool mine;

  /// Its public page id, if it has one.
  final String? publicId;

  factory LeagueTeam.fromJson(Map<String, dynamic> j) => LeagueTeam(
    id: j['id'] as int,
    name: j['name'] as String,
    members: j['members'] as int,
    stars: (j['stars'] as num).toDouble(),
    rank: j['rank'] as int,
    points: j['points'] as int? ?? 0,
    ringWeek: j['ring_week'] as int? ?? 0,
    ringToday: j['team'] as int? ?? 0,
    headsUp: j['heads_up'] as int? ?? 0,
    outside: j['outside'] as int? ?? 0,
    quests: {
      for (final MapEntry(:key, :value) in (j['quests'] as Map? ?? const {}).entries) key as String: value as int,
    },
    mine: j['mine'] as bool? ?? false,
    publicId: j['public_id'] as String?,
  );
}

/// A team with its members, for its page in the app.
class TeamDetails {
  const TeamDetails(this.team, this.people);
  final LeagueTeam team;
  final List<Person> people;

  factory TeamDetails.fromJson(Map<String, dynamic> j) => TeamDetails(LeagueTeam.fromJson(j), [
    for (final p in j['people'] as List) Person.fromJson(p as Map<String, dynamic>),
  ]);
}

/// A request the server turned down, with its reason ("No group has that
/// code"), or a network failure.
class SocialError implements Exception {
  const SocialError(this.message, {this.status});
  final String message;
  final int? status;

  bool get unauthorized => status == 401;

  @override
  String toString() => message;
}

class SocialApi {
  SocialApi(this.baseUrl, {http.Client? client, this.token}) : _http = client ?? http.Client();

  final Uri baseUrl;
  final http.Client _http;
  String? token;

  static const _timeout = Duration(seconds: 10);

  Future<(Me, String)> signUp(String name) async {
    final j = await _send('POST', '/v1/users', {'name': name}) as Map<String, dynamic>;
    return (Me.fromJson(j), j['token'] as String);
  }

  Future<Me> me() async => Me.fromJson(await _send('GET', '/v1/me') as Map<String, dynamic>);

  Future<Me> rename(String name) async =>
      Me.fromJson(await _send('PATCH', '/v1/me', {'name': name}) as Map<String, dynamic>);

  Future<void> deleteMe() => _send('DELETE', '/v1/me');

  Future<void> putRings(String day, int headsUp, int outside, {Map<String, int> quests = const {}}) =>
      _send('PUT', '/v1/me/rings', {
        'day': day,
        'heads_up': headsUp,
        'outside': outside,
        'stars': quests.values.fold(0, (a, b) => a + b),
        'quests': quests,
      });

  Future<List<Person>> friends() async => [
    for (final f in await _send('GET', '/v1/friends') as List) Person.fromJson(f as Map<String, dynamic>),
  ];

  Future<Person> addFriend(String code) async =>
      Person.fromJson(await _send('POST', '/v1/friends', {'code': code}) as Map<String, dynamic>);

  Future<void> removeFriend(int id) => _send('DELETE', '/v1/friends/$id');

  Future<List<Group>> groups() async => [
    for (final g in await _send('GET', '/v1/groups') as List) Group.fromJson(g as Map<String, dynamic>),
  ];

  Future<List<LeagueTeam>> league() async => [
    for (final t in await _send('GET', '/v1/league') as List) LeagueTeam.fromJson(t as Map<String, dynamic>),
  ];

  Future<TeamDetails> team(int id) async =>
      TeamDetails.fromJson(await _send('GET', '/v1/teams/$id') as Map<String, dynamic>);

  Future<Group> createGroup(String name) async =>
      Group.fromJson(await _send('POST', '/v1/groups', {'name': name}) as Map<String, dynamic>);

  Future<Group> joinGroup(String code) async =>
      Group.fromJson(await _send('POST', '/v1/groups/join', {'code': code}) as Map<String, dynamic>);

  Future<void> leaveGroup(int id) => _send('POST', '/v1/groups/$id/leave');

  Future<Group> setPublic(int id, bool isPublic) async =>
      Group.fromJson(await _send('PATCH', '/v1/groups/$id', {'is_public': isPublic}) as Map<String, dynamic>);

  Future<void> scheduleBreak(int groupId, DateTime startsAt, int minutes) => _send(
    'POST',
    '/v1/groups/$groupId/breaks',
    {'starts_at': startsAt.toUtc().toIso8601String(), 'minutes': minutes},
  );

  Future<void> cancelBreak(int id) => _send('DELETE', '/v1/breaks/$id');

  /// The read-only team page, if the group made it public.
  Uri teamPage(Group g) => baseUrl.resolve('/t/${g.publicId}');

  Future<Object?> _send(String method, String path, [Object? body]) async {
    final request = http.Request(method, baseUrl.resolve(path));
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request).timeout(_timeout));
    } catch (_) {
      throw const SocialError("Can't reach the Together server. Check your connection.");
    }
    if (response.statusCode >= 400) throw SocialError(_reason(response), status: response.statusCode);
    if (response.body.isEmpty) return null;
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  // FastAPI says {"detail": "..."} for our errors and a list for bad input.
  static String _reason(http.Response r) {
    try {
      final detail = (jsonDecode(r.body) as Map)['detail'];
      if (detail is String) return detail;
    } catch (_) {}
    return switch (r.statusCode) {
      401 => 'Your Together sign-in expired.',
      422 => "That doesn't look right. Check it and try again.",
      _ => 'Something went wrong on the Together server.',
    };
  }
}

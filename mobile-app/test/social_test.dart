// Together on the phone: the store against a fake server, group break
// tracking, the rings stand-in, and side quests.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/net/glasses_link.dart';
import 'package:omni_glasses/net/protocol.dart';
import 'package:omni_glasses/screens/together_screen.dart';
import 'package:omni_glasses/social/rings_source.dart';
import 'package:omni_glasses/social/side_quests.dart';
import 'package:omni_glasses/social/social_api.dart';
import 'package:omni_glasses/social/social_store.dart';
import 'package:omni_glasses/social/together_time.dart';
import 'package:shared_preferences/shared_preferences.dart';

final t0 = DateTime(2026, 10, 24, 15);
DateTime at(double seconds) => t0.add(Duration(milliseconds: (seconds * 1000).round()));

SensMessage sens({int dist = 40, int lux = 400}) => SensMessage(distCm: dist, blink: false, yawRate: 0, lux: lux);

const me = Me(id: 1, name: 'Aman', friendCode: 'ABC234', nearbyId: 'n-1');

GroupBreak breakAt(DateTime start, {int id = 7, int minutes = 10, BreakStatus status = BreakStatus.upcoming}) =>
    GroupBreak(
      id: id,
      startsAt: start,
      endsAt: start.add(Duration(minutes: minutes)),
      minutes: minutes,
      status: status,
      by: 'Maya',
    );

Group sampleGroup({List<GroupBreak> breaks = const []}) => Group(
  id: 3,
  name: 'Byte-me',
  inviteCode: 'TEAM42',
  publicId: 'pub',
  isPublic: true,
  team: 64,
  members: const [
    Person(id: 1, name: 'Aman', headsUp: 70, outside: 30),
    Person(id: 2, name: 'Maya', headsUp: 90, outside: 60),
    Person(id: 4, name: 'Saatvik', headsUp: 40, outside: 80),
  ],
  breaks: breaks,
);

/// The server, in memory.
class FakeSocialApi extends SocialApi {
  FakeSocialApi({this.groupList = const [], this.friendList = const [], this.leagueList = const []})
    : super(Uri.parse('https://social.test'));

  List<Group> groupList;
  List<Person> friendList;
  List<LeagueTeam> leagueList;
  final publicChanges = <(int, bool)>[];
  final rings = <(String, int, int, int)>[];
  bool down = false;

  @override
  Future<(Me, String)> signUp(String name) async => (Me(id: 1, name: name, friendCode: 'ABC234', nearbyId: 'n'), 'tok');

  @override
  Future<List<Person>> friends() async => down ? throw const SocialError('down') : friendList;

  @override
  Future<List<Group>> groups() async => down ? throw const SocialError('down') : groupList;

  @override
  Future<List<LeagueTeam>> league() async => down ? throw const SocialError('down') : leagueList;

  @override
  Future<Group> setPublic(int groupId, bool isPublic) async {
    publicChanges.add((groupId, isPublic));
    return groupList.first;
  }

  @override
  Future<void> putRings(String day, int headsUp, int outside, {Map<String, int> quests = const {}}) async =>
      rings.add((day, headsUp, outside, quests.values.fold(0, (a, b) => a + b)));

  @override
  Future<TeamDetails> team(int id) async =>
      down ? throw const SocialError('down') : TeamDetails(leagueList.firstWhere((t) => t.id == id), friendList);

  @override
  Future<Person> addFriend(String code) async =>
      code == 'NOPE00' ? throw const SocialError('No one has that friend code', status: 404) : friendList.first;
}

/// Rings with fixed minutes.
class FixedRings extends ChangeNotifier implements RingsSource {
  RingsToday value = const RingsToday(headsUpMinutes: 0, outsideMinutes: 0);

  @override
  RingsToday get today => value;

  void set(int headsUp, int outside) {
    value = RingsToday(headsUpMinutes: headsUp, outsideMinutes: outside);
    notifyListeners();
  }
}

/// Bluetooth, faked: the test says who is heard.
class FakeRadio implements NearbyRadio {
  final _heard = StreamController<String>.broadcast(sync: true);
  String? advertising;
  Set<String> watching = {};
  String? refuse;

  @override
  Stream<String> get heard => _heard.stream;

  @override
  Future<String?> start(String myId, Set<String> watch) async {
    if (refuse != null) return refuse;
    advertising = myId;
    watching = watch;
    return null;
  }

  @override
  Future<void> stop() async {
    advertising = null;
    watching = {};
  }

  void hear(String id) => _heard.add(id);
}

/// A signed-in store showing [groups] and [friends], for screen tests.
Future<SocialStore> signedInStore(GlassesLink link, {List<Group>? groups, List<Person>? friends}) async {
  final api = FakeSocialApi(
    groupList:
        groups ??
        [
          sampleGroup(breaks: [breakAt(DateTime.now().add(const Duration(minutes: 12)))]),
        ],
    friendList: friends ?? const [Person(id: 2, name: 'Maya', headsUp: 90, outside: 60, starsThisWeek: 7)],
    leagueList: const [
      LeagueTeam(id: 9, name: 'Night Owls', members: 3, stars: 7, rank: 1, publicId: 'owls'),
      LeagueTeam(id: 3, name: 'Byte-me', members: 2, stars: 2.5, rank: 2, mine: true),
    ],
  );
  final store = SocialStore(link: link, rings: FixedRings(), api: (_, _) => api);
  await store.signUp('Aman');
  return store;
}

void main() {
  late GlassesLink link;
  setUp(() => link = GlassesLink(port: 0));
  tearDown(() => link.dispose());

  group('SocialStore', () {
    test('signing up loads friends and groups', () async {
      final store = await signedInStore(link);
      expect(store.me?.name, 'Aman');
      expect(store.friends.single.name, 'Maya');
      expect(store.groups.single.team, 64);
      expect(store.nextBreak?.$2.id, 7);
      store.dispose();
    });

    test('a team break reminds once when it starts: glasses nudge and an event', () async {
      var now = at(0);
      final api = FakeSocialApi(
        groupList: [
          sampleGroup(breaks: [breakAt(at(60))]),
        ],
      );
      final store = SocialStore(link: link, rings: FixedRings(), api: (_, _) => api, clock: () => now);
      final events = <TogetherEvent>[];
      store.events.listen(events.add);
      await store.signUp('Aman');
      expect(events, isEmpty); // not yet

      now = at(61);
      await store.refresh();
      await pumpEventQueue();
      expect(events.single, isA<BreakStarted>());

      now = at(120);
      await store.refresh();
      await pumpEventQueue();
      expect(events, hasLength(1)); // only once
      store.dispose();
    });

    test('loads the league and can join it', () async {
      final api = FakeSocialApi(
        groupList: [sampleGroup()],
        leagueList: const [
          LeagueTeam(id: 9, name: 'Night Owls', members: 3, stars: 7, rank: 1, publicId: 'owls'),
          LeagueTeam(id: 3, name: 'Byte-me', members: 2, stars: 2.5, rank: 2, mine: true),
        ],
      );
      final store = SocialStore(link: link, rings: FixedRings(), api: (_, _) => api);
      await store.signUp('Aman');
      expect(
        [for (final t in store.league) (t.rank, t.name, t.mine)],
        [(1, 'Night Owls', false), (2, 'Byte-me', true)],
      );
      final (owls, error) = await store.team(store.league.first);
      expect((owls?.team.name, error), ('Night Owls', null));
      api.down = true;
      final (_, offline) = await store.team(store.league.first);
      expect(offline, 'down');
      api.down = false;
      expect(await store.setPublic(store.groups.single, true), isNull);
      expect(api.publicChanges, [(3, true)]);
      store.dispose();
    });

    test('shows server errors and keeps what it had when offline', () async {
      final api = FakeSocialApi(friendList: const [Person(id: 2, name: 'Maya')]);
      final store = SocialStore(link: link, rings: FixedRings(), api: (_, _) => api);
      await store.signUp('Aman');
      expect(await store.addFriend('NOPE00'), 'No one has that friend code');

      api.down = true;
      await store.refresh();
      expect(store.offline, isTrue);
      expect(store.friends.single.name, 'Maya');
      store.dispose();
    });

    test('uploads rings at most once a minute, a new star right away', () async {
      var now = at(0);
      var stars = 0;
      final rings = FixedRings();
      final api = FakeSocialApi();
      SharedPreferences.setMockInitialValues({});
      final store = SocialStore(
        link: link,
        rings: rings,
        questStars: () => {'look_up': stars},
        api: (_, _) => api,
        clock: () => now,
      );
      await store.signUp('Aman');
      rings.set(90, 30); // 50%, 25%
      store.upload();
      now = at(10);
      rings.set(91, 30);
      store.upload();
      expect(api.rings, [('2026-10-24', 50, 25, 0)]);
      stars = 1;
      store.upload();
      expect(api.rings.last, ('2026-10-24', 51, 25, 1));
      now = at(20);
      rings.set(120, 60);
      store.upload();
      expect(api.rings, hasLength(2));
      now = at(80); // the trailing change still goes out
      store.upload();
      expect(api.rings.last, ('2026-10-24', 67, 50, 1));
      store.upload();
      expect(api.rings, hasLength(3));
      store.dispose();
    });
  });

  test('StandInRings counts minutes and starts over each day', () {
    var now = at(0);
    final controller = StreamController<SensMessage>();
    final rings = StandInRings(controller.stream, clock: () => now);
    for (var s = 0.0; s <= 120; s += 0.1) {
      now = at(s);
      rings.add(sens(dist: 250, lux: 5000));
    }
    expect(rings.today.headsUpMinutes, 2);
    expect(rings.today.outsideMinutes, 2);
    expect(rings.today.headsUpPercent, 1); // 2 of 180 min

    now = now.add(const Duration(days: 1));
    rings.add(sens());
    expect(rings.today.headsUpMinutes, 0);
    rings.dispose();
    controller.close();
  });

  group('TogetherTime', () {
    test('off by default; when on, advertises and listens for friends', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await signedInStore(
        link,
        friends: const [
          Person(id: 2, name: 'Maya', nearbyId: 'AAAA-1'),
          Person(id: 3, name: 'Sam'),
        ],
      );
      final radio = FakeRadio();
      final together = TogetherTime(social: store, radio: radio);
      await together.start();
      expect(radio.advertising, isNull);

      await together.setEnabled(true);
      expect(radio.advertising, 'n'); // my nearby id from the fake server
      expect(radio.watching, {'aaaa-1'}); // Sam has no id: not listened for

      await together.setEnabled(false);
      expect(radio.advertising, isNull);
      together.dispose();
      store.dispose();
    });

    test('counts minutes while a friend is nearby, and says why it cannot run', () async {
      SharedPreferences.setMockInitialValues({});
      var now = at(0);
      final store = await signedInStore(
        link,
        friends: const [Person(id: 2, name: 'Maya', nearbyId: 'aaaa-1')],
      );
      final radio = FakeRadio();
      final together = TogetherTime(social: store, radio: radio, clock: () => now);
      await together.start();
      await together.setEnabled(true);

      together.tick();
      for (var s = 10; s <= 300; s += 10) {
        now = at(s.toDouble());
        if (s <= 180) radio.hear('aaaa-1'); // Maya leaves after 3 min
        together.tick();
      }
      expect(together.minutesToday, 3); // 3 min heard + 30 s of grace
      expect([for (final (f, m) in together.bestFriends) (f.name, m)], [('Maya', 3)]);
      expect(together.nearbyNow, isEmpty);
      together.dispose();

      final off = FakeRadio()..refuse = 'Turn on Bluetooth to count time with friends.';
      final blocked = TogetherTime(social: store, radio: off);
      await blocked.start();
      await blocked.setEnabled(true);
      expect(blocked.problem, 'Turn on Bluetooth to count time with friends.');
      blocked.dispose();
      store.dispose();
    });
  });

  test('people and league teams parse their weekly stats', () {
    final maya = Person.fromJson({
      'id': 2,
      'name': 'Maya',
      'heads_up': 80,
      'outside': 40,
      'stars_week': 6,
      'quests_week': {'look_up': 4, 'hang_out': 2},
      'ring_week': 55,
    });
    expect((maya.questsThisWeek['look_up'], maya.ringWeek), (4, 55));
    final team = TeamDetails.fromJson({
      'id': 3,
      'name': 'Byte-me',
      'members': 1,
      'people': [
        {'id': 2, 'name': 'Maya'},
      ],
      'stars': 7.5,
      'rank': 1,
      'points': 118,
      'ring_week': 43,
      'team': 50,
      'quests': {'look_up': 9},
    });
    expect((team.team.points, team.team.ringToday, team.team.members, team.people.single.name), (118, 50, 1, 'Maya'));
  });

  test('leaderboard: most stars first, ties by name, you included', () {
    const me = Me(id: 1, name: 'Aman', friendCode: 'AAAAAA', nearbyId: 'x');
    final board = leaderboard(
      const [
        Person(id: 2, name: 'Maya', starsThisWeek: 7),
        Person(id: 3, name: 'Sam', starsThisWeek: 2),
        Person(id: 4, name: 'Ana', starsThisWeek: 7),
      ],
      me,
      5,
    );
    expect([for (final (p, n) in board) '${p?.name ?? 'me'} $n'], ['Ana 7', 'Maya 7', 'me 5', 'Sam 2']);
  });

  test('quest progress text', () {
    final lookUp = sideQuests.first;
    expect(questProgressText(lookUp, 10), '10 m · first star at 30 m');
    expect(questProgressText(lookUp, 75), '1 h 15 m · next star at 2 h');
    expect(questProgressText(lookUp, 130), '2 h 10 m · all 3 stars');
  });

  test('best friends: most time together over 30 days, kept across restarts', () async {
    SharedPreferences.setMockInitialValues({});
    var now = at(0);
    final store = await signedInStore(
      link,
      friends: const [
        Person(id: 2, name: 'Maya', nearbyId: 'aaaa-1'),
        Person(id: 3, name: 'Sam', nearbyId: 'bbbb-2'),
      ],
    );
    final radio = FakeRadio();
    var together = TogetherTime(social: store, radio: radio, clock: () => now);
    await together.start();
    await together.setEnabled(true);

    /// [minutes] near the friends with [ids], starting [day] days from now.
    void hangOut(int day, int minutes, List<String> ids) {
      final from = at(day * 86400.0);
      now = from;
      together.tick();
      for (var s = 10; s <= minutes * 60; s += 10) {
        now = from.add(Duration(seconds: s));
        ids.forEach(radio.hear);
        together.tick();
      }
    }

    hangOut(0, 20, ['aaaa-1']);
    hangOut(1, 30, ['bbbb-2']);
    hangOut(2, 15, ['aaaa-1', 'bbbb-2']); // both at once: counts for each
    expect([for (final (f, m) in together.bestFriends) (f.name, m)], [('Sam', 45), ('Maya', 35)]);
    expect(together.minutesToday, 15);

    // A restart keeps the history.
    together.dispose();
    together = TogetherTime(social: store, radio: radio, clock: () => now);
    await together.start();
    expect(together.bestFriends.first.$1.name, 'Sam');

    // Sam's day falls out of the 30-day window first.
    now = at(31 * 86400.0);
    expect([for (final (f, m) in together.bestFriends) (f.name, m)], [('Maya', 15), ('Sam', 15)]);
    together.dispose();
    store.dispose();
  });

  test('Hang out counts minutes of Together time', () async {
    SharedPreferences.setMockInitialValues({});
    var now = at(0);
    final store = await signedInStore(
      link,
      friends: const [Person(id: 2, name: 'Maya', nearbyId: 'aaaa-1')],
    );
    final radio = FakeRadio();
    final together = TogetherTime(social: store, radio: radio, clock: () => now);
    await together.start();
    await together.setEnabled(true);
    final sensor = StreamController<SensMessage>.broadcast();
    final quests = SideQuestStore(rings: FixedRings(), sens: sensor.stream, together: together, clock: () => now);
    final hangOut = sideQuests.firstWhere((q) => q.id == 'hang_out');

    together.tick();
    for (var s = 10; s <= 16 * 60; s += 10) {
      now = at(s.toDouble());
      radio.hear('aaaa-1');
      together.tick();
    }
    expect(quests.progress(hangOut), 16);
    expect(quests.stars(hangOut), 1);
    quests.dispose();
    together.dispose();
    store.dispose();
    await sensor.close();
  });

  group('SideQuestStore', () {
    late StreamController<SensMessage> sensor;
    late FixedRings rings;
    late DateTime now;
    late SideQuestStore quests;
    final starred = <StarEarned>[];

    SideQuest quest(String id) => sideQuests.firstWhere((q) => q.id == id);

    /// [seconds] of samples, 10 a second, from [from].
    void feed(DateTime from, int seconds, {int dist = 35, int lux = 300}) {
      for (var i = 0; i <= seconds * 10; i++) {
        now = from.add(Duration(milliseconds: i * 100));
        sensor.add(sens(dist: dist, lux: lux));
      }
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      sensor = StreamController<SensMessage>.broadcast(sync: true);
      rings = FixedRings();
      now = DateTime(2026, 10, 24, 12);
      quests = SideQuestStore(rings: rings, sens: sensor.stream, clock: () => now);
      await quests.start();
      starred.clear();
      quests.starred.listen(starred.add);
    });
    tearDown(() {
      quests.dispose();
      sensor.close();
    });

    test('looking up when someone stops by adds a minute to Look up', () async {
      final q = quest('look_up');
      rings.set(29, 0);
      expect((quests.progress(q), quests.stars(q)), (29, 0));
      quests.creditLookUp();
      expect((quests.progress(q), quests.stars(q)), (30, 1));
      now = now.add(const Duration(days: 1)); // a new day starts over
      expect(quests.progress(q), 29);
    });

    test('stars by quest, for the server', () {
      rings.set(65, 0);
      expect(quests.starsByQuest, {'look_up': 2, 'golden_hour': 0, 'phone_down_lunch': 0, 'hang_out': 0});
    });

    test('four measured quests, three stars each', () {
      expect(sideQuests.map((q) => q.title), ['Look up', 'Golden hour', 'Phone-down lunch', 'Hang out']);
      expect(sideQuests.every((q) => q.goals.length == 3), isTrue);
      expect(maxStarsPerDay, 12);
      expect(quest('look_up').starsFor(59), 1);
      expect(quest('look_up').nextGoal(59), 60);
      expect(quest('look_up').nextGoal(500), isNull);
    });

    test('Look up earns a star at each goal, announced once', () async {
      final q = quest('look_up'); // 30, 60, 120 min
      rings.set(29, 0);
      expect(quests.stars(q), 0);
      rings.set(45, 0);
      rings.set(46, 0);
      rings.set(130, 0);
      await pumpEventQueue();
      expect([for (final e in starred) e.stars], [1, 3]);
      expect(quests.starsToday, 3);
      rings.set(0, 0); // the rings started over (app restart): stars stay
      expect(quests.stars(q), 3);
    });

    test('Golden hour counts outside time between 5 and 8 pm only', () {
      final q = quest('golden_hour');
      feed(DateTime(2026, 10, 24, 12), 120, lux: 20000); // midday sun: not golden hour
      feed(DateTime(2026, 10, 24, 17, 30), 60, lux: 400); // indoors
      feed(DateTime(2026, 10, 24, 18), 180, lux: 8000); // outside at 6 pm
      expect(quests.progress(q), 3);
    });

    test('Phone-down lunch counts lunchtime with nothing at phone distance', () {
      final q = quest('phone_down_lunch');
      feed(DateTime(2026, 10, 24, 10), 120, dist: 250); // before lunch
      feed(DateTime(2026, 10, 24, 12), 120, dist: 30); // on the phone
      feed(DateTime(2026, 10, 24, 12, 5), 180, dist: 60); // eating, looking at the plate
      feed(DateTime(2026, 10, 24, 12, 10), 120, dist: 200); // talking across the table
      expect(quests.progress(q), 5);
    });

    test('stars start over each day and add up over the week', () {
      // 2026-10-24 is a Saturday; the week started Monday the 19th.
      rings.set(60, 0); // 2 stars
      now = DateTime(2026, 10, 25, 9); // Sunday
      rings.set(0, 0); // the rings start over at midnight too
      expect(quests.starsToday, 0);
      rings.set(30, 0); // 1 star
      expect(quests.starsThisWeek, 3);
      now = DateTime(2026, 10, 26, 9); // Monday: a new week
      rings.set(0, 0);
      expect(quests.starsThisWeek, 0);
    });
  });
}

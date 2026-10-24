// What plays next, as every view reads it (Player.nextSongs): the room's queue in a jam, this device's Up Next
// otherwise. Home's card read this device's queue in a jam and showed nothing (24 Oct).
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/jam.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';

Listing listing(String id, String title) =>
    Listing(source: 'jiosaavn', id: id, title: title, artists: const ['Alex'], duration: 200);

Track track(String id, String title) => Track(listing(id, title), [listing(id, title)], choosingVersion: false);

JamState room(List<(String, Listing)> queue) => JamState.fromJson({
      'room_id': 'room1',
      'code': 'abc12',
      'name': null,
      'host_id': 'me',
      'members': [
        {'user_id': 'me', 'username': 'kai'},
      ],
      'current': {'entry_id': 'e1', 'listing': listing('a', 'Playing Now').toJson()},
      'is_playing': true,
      'position_seconds': 0,
      'queue': [for (final (id, l) in queue) {'entry_id': id, 'listing': l.toJson()}],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // Player makes an audio player, which needs Flutter's bindings

  test("in a jam, what plays next is the room's queue, not this device's", () {
    final p = Player();
    addTearDown(p.dispose);
    p.queue.load([track('x', 'Mine 1'), track('y', 'Mine 2'), track('z', 'Mine 3')], 0, shuffled: false);
    p.jam = JamSession()..state = room([('e2', listing('b', 'Room 2')), ('e3', listing('c', 'Room 3'))]);
    expect([for (final s in p.nextSongs) s.track.title], ['Room 2', 'Room 3']);
    expect([for (final s in p.nextSongs) s.id], ['e2', 'e3'], reason: 'each is its place in the room');
  });

  test('outside a jam, it is this device\'s Up Next', () {
    final p = Player();
    addTearDown(p.dispose);
    p.queue.load([track('x', 'Mine 1'), track('y', 'Mine 2'), track('z', 'Mine 3')], 0, shuffled: false);
    expect([for (final s in p.nextSongs) s.track.title], ['Mine 2', 'Mine 3']);
  });

  test('a jam with nothing queued has nothing next, even with songs queued here', () {
    final p = Player();
    addTearDown(p.dispose);
    p.queue.load([track('x', 'Mine 1'), track('y', 'Mine 2')], 0, shuffled: false);
    p.jam = JamSession()..state = room(const []);
    expect(p.nextSongs, isEmpty);
  });
}

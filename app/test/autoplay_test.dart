// Autoplay's trigger (when the queue asks the radio for more) and where its songs go in the queue.
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/autoplay.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/play_queue.dart';

Track song(String name, {String source = 'jiosaavn', List<Listing> others = const []}) => Track(
    Listing(source: source, id: 'id-$name', title: name, artists: const ['Kai'], duration: 200), others);

PlayQueue queueOf(int count, {int at = 0}) =>
    PlayQueue()..load([for (var i = 0; i < count; i++) song('s$i')], at, shuffled: false);

void main() {
  test('asks when two songs or fewer are left, not before', () {
    final autoplay = Autoplay();
    expect(autoplay.due(queueOf(5), enabled: true), isNull, reason: '4 left');
    expect(autoplay.due(queueOf(5, at: 1), enabled: true), isNull, reason: '3 left');
    expect(autoplay.due(queueOf(5, at: 2), enabled: true), isNotNull, reason: '2 left');
  });

  test('once per seed: the same last song is not asked about again, a new last song is', () {
    final autoplay = Autoplay();
    final q = queueOf(3, at: 1);
    expect(autoplay.due(q, enabled: true)!.lastId, 'jiosaavn:id-s2');
    expect(autoplay.due(q, enabled: true), isNull);
    q.appendAutoplay(song('radio'));
    expect(autoplay.due(q, enabled: true)!.lastId, 'jiosaavn:id-radio');
    autoplay.reset();
    expect(autoplay.due(q, enabled: true), isNotNull, reason: 'a new queue starts over');
  });

  test('never with repeat on, with Autoplay off, or while a jam decides', () {
    final autoplay = Autoplay();
    final q = queueOf(2);
    q.repeat = Repeat.all;
    expect(autoplay.due(q, enabled: true), isNull);
    q.repeat = Repeat.one;
    expect(autoplay.due(q, enabled: true), isNull);
    q.repeat = Repeat.off;
    expect(autoplay.due(q, enabled: false), isNull);
    expect(autoplay.due(q, enabled: true, blocked: true), isNull);
    expect(autoplay.due(q, enabled: true), isNotNull, reason: 'the refused calls did not use up the seed');
  });

  test('nothing in an empty queue', () {
    expect(Autoplay().due(PlayQueue(), enabled: true), isNull);
  });

  test('the seed is the jiosaavn or ytmusic copy when there is one, else the playing copy', () {
    final video = const Listing(source: 'youtube', id: 'v', title: 'Video', artists: ['Kai'], duration: 200);
    final music = const Listing(source: 'ytmusic', id: 'm', title: 'Video', artists: ['Kai'], duration: 200);
    final q = PlayQueue()..load([Track(video, [video, music], choosingVersion: false)], 0, shuffled: false);
    expect(Autoplay().due(q, enabled: true)!.seed, music);
    final only = PlayQueue()..load([Track(video, [video])], 0, shuffled: false);
    expect(Autoplay().due(only, enabled: true)!.seed, video);
  });

  test('every listing already in the queue is excluded, once, the newest 100 at most', () {
    final a = song('a', others: [const Listing(source: 'ytmusic', id: 'a2', title: 'a', artists: ['Kai'], duration: 200)]);
    final q = PlayQueue()..load([a, a, song('b')], 0, shuffled: false);
    final exclude = Autoplay().due(q, enabled: true)!.exclude.map((l) => l.key).toList();
    expect(exclude, ['jiosaavn:id-a', 'ytmusic:a2', 'jiosaavn:id-b']);

    final long = PlayQueue()..load([for (var i = 0; i < 150; i++) song('n$i')], 149, shuffled: false);
    final newest = Autoplay().due(long, enabled: true)!.exclude;
    expect((newest.length, newest.last.id, newest.first.id), (100, 'id-n149', 'id-n50'));
  });

  test('songs the user queues go before Autoplay\'s; Autoplay\'s stay last', () {
    final q = queueOf(2)..appendAutoplay(song('r1'))..appendAutoplay(song('r2'));
    q.append(song('mine1'));
    q.append(song('mine2'));
    expect(q.upNext.map((t) => t.title), ['s1', 'mine1', 'mine2', 'r1', 'r2']);
    expect(q.upcoming.map((e) => e.autoplay), [false, false, false, true, true]);
    q.setShuffle(true);
    q.setShuffle(false);
    expect(q.upNext.map((t) => t.title), ['s1', 'mine1', 'mine2', 'r1', 'r2'], reason: 'the order survives shuffle on and off');
  });
}

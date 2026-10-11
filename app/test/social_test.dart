// The social service against a fake server and fake socket messages, and the socket's reconnecting.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/live_socket.dart';
import 'package:nononsense/core/social.dart';

import 'fake_http.dart';

Map<String, dynamic> note(String id, String type, Map<String, dynamic> payload, {bool read = false}) =>
    {'id': id, 'type': type, 'payload': payload, 'seq': 1, 'read': read, 'created_at': '2026-10-12T09:30:00+00:00'};

Map<String, dynamic> person(String id, String name) => {'user_id': id, 'username': name, 'since': '2026-10-01T08:00:00'};

/// The lists the server holds; a test changes them and the fake answers with them.
class World {
  List<Map<String, dynamic>> friends = [person('u1', 'sam')];
  List<Map<String, dynamic>> incoming = [person('u2', 'kai')];
  List<Map<String, dynamic>> outgoing = [];
  List<Map<String, dynamic>> notes = [note('n1', 'friend_request', {'from_user_id': 'u2', 'from_username': 'kai'})];
  int unread = 1;
  Completer<void>? holdRespond;

  FakeServer server() => FakeServer((method, path, body) async {
        switch ('$method $path') {
          case 'GET /friends':
            return (200, friends);
          case 'GET /friends/requests':
            return (200, {'incoming': incoming, 'outgoing': outgoing});
          case 'GET /notifications':
            return (200, {'notifications': notes, 'unread_count': unread});
          case 'POST /friends/respond':
            await holdRespond?.future;
            final name = (body as Map)['username'];
            final who = incoming.firstWhere((p) => p['username'] == name);
            incoming = [...incoming]..remove(who);
            if (body['action'] == 'accept') friends = [...friends, who];
            return (204, null);
          case 'POST /friends/request':
            return (body as Map)['username'] == 'nobody' ? (404, {'detail': 'No account with that username'}) : (201, null);
          case 'POST /notifications/read-all':
            return (204, null);
        }
        return (404, {'detail': 'unexpected $method $path'});
      });
}

void main() {
  tearDown(() {
    Api.client = http.Client();
    Api.token = null;
  });

  test('a notification keeps only text payload values: a null room name or a number is left out', () {
    final n = AppNotification.fromJson(note('n9', 'jam_invite', {
      'room_id': 'r1', 'code': 'abc12', 'room_name': null, 'from_username': 'alex', 'extra': 5, 'flag': true,
    }));
    expect(n.payload, {'room_id': 'r1', 'code': 'abc12', 'from_username': 'alex'});
    expect(n.from, 'alex');
    expect(AppNotification.fromJson({...note('n8', 'friend_accepted', {'by_username': 'sam'}), 'payload': null}).payload, isEmpty);
    expect(AppNotification.fromJson(note('n7', 'friend_accepted', {'by_username': 'sam'})).from, 'sam');
    expect(AppNotification.tryParse({'type': 'friend_request'}), isNull, reason: 'no id');
  });

  test('connected: unread is taken from the message and everything is loaded again', () async {
    final world = World();
    final server = world.server();
    useServer(server);
    final social = Social();
    social.handle(jsonEncode({'type': 'connected', 'unread': 3}));
    expect(social.unread, 3);
    await pumpEventQueue();
    expect([server.count('GET /friends'), server.count('GET /friends/requests'), server.count('GET /notifications')], [1, 1, 1]);
    expect(social.friends.single.username, 'sam');
    expect(social.incoming.single.username, 'kai');
    expect((social.notifications.length, social.unread), (1, 1), reason: "the server's count wins after the load");
  });

  test('notification: inserted first and counted once; a request or an acceptance reloads the lists, a share does not', () async {
    final world = World();
    final server = world.server();
    useServer(server);
    final social = Social(catchUpAfter: Duration.zero);
    String push(Map<String, dynamic> n) => jsonEncode({'type': 'notification', 'data': n});

    social.handle(push(note('n2', 'playlist_invite', {'playlist_id': 'p1', 'playlist_name': 'Road', 'from_username': 'alex'})));
    await pumpEventQueue();
    expect(social.notifications.map((n) => n.id), ['n2']);
    expect(social.unread, 1);
    expect(server.asked, isEmpty, reason: 'a shared playlist changes no list');

    social.handle(push(note('n2', 'playlist_invite', {'from_username': 'alex'})));
    expect(social.notifications.length, 1, reason: 'the same id twice is one notification');
    expect(social.unread, 1);

    social.handle(push(note('n3', 'friend_request', {'from_user_id': 'u2', 'from_username': 'kai'})));
    expect(social.incoming.single.username, 'kai', reason: 'at once, from the notification');
    await pumpEventQueue();
    expect(server.count('GET /friends/requests'), 1, reason: 'and loaded again to confirm');
    expect(social.incoming.single.username, 'kai');

    social.handle(push(note('n4', 'friend_accepted', {'by_user_id': 'u1', 'by_username': 'sam'})));
    await pumpEventQueue();
    expect(server.count('GET /friends/requests'), 2);

    social.handle(push(note('n5', 'jam_invite', {'room_id': 'r', 'code': 'x', 'room_name': null, 'from_username': 'alex'})));
    expect(social.notifications.first.id, 'n5');
  });

  test('notification_read and notifications_cleared set the unread count; other and broken messages change nothing', () {
    useServer(World().server());
    final social = Social()..unread = 4;
    var told = 0;
    social.addListener(() => told++);
    social.handle(jsonEncode({'type': 'notification_read', 'data': {'unread': 2}}));
    expect(social.unread, 2);
    social.handle(jsonEncode({'type': 'notifications_cleared', 'data': {'unread': 0}}));
    expect(social.unread, 0);
    expect(told, 2);
    for (final m in ['pong', '{"type":"pong"}', '[1]', '{"type":"notification","data":{"type":"x"}}', '{"type":"notification_read"}']) {
      social.handle(m);
    }
    expect((social.unread, told), (0, 2));
  });

  test('accept: the request leaves and the friend appears before the server answers; stop empties everything', () async {
    final world = World()..holdRespond = Completer<void>();
    useServer(world.server());
    final social = Social();
    await social.refresh();
    expect(social.incoming.length, 1);

    final done = social.respond('kai', accept: true);
    await pumpEventQueue();
    expect(social.incoming, isEmpty);
    expect(social.friends.map((f) => f.username), ['sam', 'kai']);

    world.holdRespond!.complete();
    expect(await done, isNull);
    expect(social.friends.map((f) => f.username), ['sam', 'kai'], reason: 'the server agrees');

    social.stop();
    expect([social.friends, social.incoming, social.outgoing, social.notifications], everyElement(isEmpty));
    expect(social.unread, 0);
  });

  test('a list fetched before sign-out does not come back after it', () async {
    final world = World();
    useServer(world.server());
    final social = Social();
    final loading = social.refresh();
    social.stop();
    await loading;
    expect(social.friends, isEmpty);
  });

  test("add friend gives back the server's reason; an empty name never leaves", () async {
    final world = World();
    final server = world.server();
    useServer(server);
    final social = Social();
    expect(await social.addFriend('nobody'), 'No account with that username');
    expect(await social.addFriend('  '), 'Enter a username.');
    expect(await social.addFriend(' alex '), isNull);
    expect(server.count('POST /friends/request'), 2);
  });

  test('mark all read: the count and the rows change at once, and the server is told', () async {
    final world = World();
    final server = world.server();
    useServer(server);
    final social = Social();
    await social.refresh();
    await social.markAllRead();
    expect((social.unread, social.notifications.every((n) => n.read)), (0, true));
    expect(server.count('POST /notifications/read-all'), 1);
    await social.markAllRead();
    expect(server.count('POST /notifications/read-all'), 1, reason: 'nothing unread, nothing sent');
  });

  test('avatar colour and day text', () {
    expect(avatarHue('sam'), avatarHue('sam'));
    expect(avatarHue('sam'), inInclusiveRange(0, 359));
    expect(avatarHue('sam') == avatarHue('kai'), isFalse);
    expect(shortDay('2026-10-12T12:00:00+00:00'), matches(RegExp(r'^1[123] Oct 2026$')));
    expect(shortDay('not a time'), '');
  });

  group('LiveSocket', () {
    LiveSocket make(SocketConnector connect, List<String> got, {Future<void> Function()? onDropped}) => LiveSocket(
          path: 'ws/notifications',
          onMessage: got.add,
          onDropped: onDropped,
          connect: connect,
          pingEvery: const Duration(milliseconds: 40),
          firstWait: const Duration(milliseconds: 20),
          longestWait: const Duration(milliseconds: 80),
        );

    test('the address: ws for http, wss for https, with the ticket in the query', () {
      Api.base = 'http://server.test:8768';
      expect(LiveSocket.urlFor('ws/jam', {'ticket': 't', 'room_id': 'r'}).toString(), 'ws://server.test:8768/ws/jam?ticket=t&room_id=r');
      Api.base = 'https://server.test';
      expect(LiveSocket.urlFor('ws/notifications', {'ticket': 't'}).toString(), 'wss://server.test/ws/notifications?ticket=t');
    });

    test('a failed connection is retried with a doubling wait, then a message and a ping arrive and stop ends it', () async {
      useServer(FakeServer((m, p, b) async => (200, {'ticket': 't', 'expires_in': 30})));
      final times = <int>[];
      final clock = Stopwatch()..start();
      final links = <FakeLink>[];
      final got = <String>[];
      final socket = make((url) async {
        times.add(clock.elapsedMilliseconds);
        expect(url.queryParameters['ticket'], 't');
        if (times.length < 3) throw StateError('refused');
        return FakeLink()..also(links.add);
      }, got);
      socket.start();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(times.length, 3, reason: 'two refusals, then it connects');
      expect(times[1] - times[0], greaterThanOrEqualTo(20));
      expect(times[2] - times[1], greaterThanOrEqualTo(40), reason: 'the wait doubled');
      expect(socket.isOpen, isTrue);
      links.single.push('hello');
      await pumpEventQueue();
      expect(got, ['hello']);
      expect(links.single.sent, contains('ping'));
      socket.stop();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect((links.single.closed, socket.isOpen, times.length), (true, false, 3), reason: 'stopped: no more attempts');
    });

    test('a connection that drops is replaced after the wait, and the after-drop check runs first', () async {
      useServer(FakeServer((m, p, b) async => (200, {'ticket': 't', 'expires_in': 30})));
      final links = <FakeLink>[];
      final order = <String>[];
      final socket = make((url) async {
        order.add('connect');
        return FakeLink()..also(links.add);
      }, [], onDropped: () async => order.add('dropped'));
      socket.start();
      await pumpEventQueue();
      links.single.push('first'); // a server that spoke: the next try is quick
      await pumpEventQueue();
      links.single.close();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(order.take(3).toList(), ['connect', 'dropped', 'connect']);
      socket.stop();
    });
  });
}

extension on FakeLink {
  FakeLink also(void Function(FakeLink) f) {
    f(this);
    return this;
  }
}

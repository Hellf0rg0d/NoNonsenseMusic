// Friends, friend requests and notifications. The rules match the Mac app's Services/Social.swift.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'live_socket.dart';

/// A person in the friends lists (`{user_id, username, since}`): a friend, or the other side of a request.
@immutable
class Friend {
  const Friend(this.userId, this.username, this.since);

  final String userId, username;

  /// ISO 8601: when the friendship began, or when the request was sent.
  final String since;

  factory Friend.fromJson(Map<String, dynamic> j) =>
      Friend(j['user_id'] as String, j['username'] as String, (j['since'] as String?) ?? '');

  @override
  bool operator ==(Object other) =>
      other is Friend && other.userId == userId && other.username == username && other.since == since;
  @override
  int get hashCode => Object.hash(userId, username, since);
}

/// One notification. [payload] holds the names and ids its kind needs (`from_username`, `playlist_id`, …).
@immutable
class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.payload,
    required this.seq,
    required this.read,
    required this.createdAt,
  });

  final String id;

  /// `friend_request`, `friend_accepted`, `playlist_invite` or `jam_invite`.
  final String type;
  final Map<String, String> payload;
  final int seq;
  final bool read;
  final String createdAt;

  /// Reads a notification from the server's JSON. A payload value that is null (a jam with no name) or not text is
  /// left out, so a kind that gains a field never makes the whole list unreadable.
  factory AppNotification.fromJson(Map<String, dynamic> j) {
    final raw = j['payload'];
    return AppNotification(
      id: j['id'] as String,
      type: j['type'] as String,
      payload: {
        if (raw is Map)
          for (final e in raw.entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String,
      },
      seq: (j['seq'] as num?)?.toInt() ?? 0,
      read: j['read'] as bool? ?? false,
      createdAt: (j['created_at'] as String?) ?? '',
    );
  }

  /// Reads a notification, or null when it lacks an id or a type.
  static AppNotification? tryParse(Object? json) {
    if (json is! Map<String, dynamic> || json['id'] is! String || json['type'] is! String) return null;
    return AppNotification.fromJson(json);
  }

  AppNotification asRead() => AppNotification(
      id: id, type: type, payload: payload, seq: seq, read: true, createdAt: createdAt);

  /// Who it is from: the other person's username.
  String get from => payload['from_username'] ?? payload['by_username'] ?? 'Someone';

  @override
  bool operator ==(Object other) =>
      other is AppNotification &&
      other.id == id &&
      other.type == type &&
      other.read == read &&
      other.seq == seq &&
      other.createdAt == createdAt &&
      mapEquals(other.payload, payload);
  @override
  int get hashCode => Object.hash(id, type, read, seq, createdAt);
}

/// Returns the day of an ISO 8601 time as "12 Oct 2026" in local time, or '' when it cannot be read.
String shortDay(String iso) {
  final t = DateTime.tryParse(iso);
  if (t == null) return '';
  final local = t.toLocal();
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

/// Returns the avatar hue (0 to 359) for [name]: FNV-1a over its characters, so a person keeps one colour on every
/// device. The Mac app uses the same function.
int avatarHue(String name) {
  var hash = 2166136261;
  for (final c in name.runes) {
    hash = ((hash ^ c) * 16777619) & 0xFFFFFFFF;
  }
  return hash % 360;
}

/// Friends, friend requests and notifications for the signed-in account.
///
/// One WebSocket brings new notifications as they happen and otherwise waits (LiveSocket), so the service costs no
/// CPU between messages. Started after sign-in and stopped on sign-out, which also empties every list so nothing of
/// this account stays for the next one.
class Social extends ChangeNotifier {
  Social({this._connect, this.catchUpAfter = const Duration(seconds: 1)});

  /// The app's one service; the screens read this unless a test gives them another.
  static final shared = Social();

  final SocketConnector? _connect;

  /// How long after a friend request or an acceptance arrives the lists are loaded again. The server pushes the
  /// notification before the change can be read back, so a load made at once can still miss it.
  final Duration catchUpAfter;
  Timer? _catchUp;

  List<Friend> friends = const [];
  List<Friend> incoming = const [];
  List<Friend> outgoing = const [];
  List<AppNotification> notifications = const [];
  int unread = 0;

  LiveSocket? _socket;

  /// Changes with sign-out: an answer to a request made before it is dropped.
  int _account = 0;

  /// Count changes made on screen before the server answered: a list fetched before one is not shown, since it
  /// would undo it (the change's own refresh follows). The friends lists and the notifications count apart.
  int _peopleEdits = 0, _noteEdits = 0;

  bool get isRunning => _socket != null;

  /// Signed in: loads the lists and opens the socket. Calling it again while running does nothing.
  void start() {
    if (_socket != null) return;
    unawaited(refresh());
    _socket = LiveSocket(path: 'ws/notifications', onMessage: handle, connect: _connect)..start();
  }

  /// Signed out: closes the socket and empties every list.
  void stop() {
    _account++;
    _catchUp?.cancel();
    _socket?.stop();
    _socket = null;
    friends = incoming = outgoing = const [];
    notifications = const [];
    unread = 0;
    notifyListeners();
  }

  /// Loads the friends, the requests and the notifications. Each list that cannot be loaded stays as it is.
  Future<void> refresh() async {
    final account = _account, people = _peopleEdits, notes = _noteEdits;
    Future<T?> tryLoad<T>(Future<T> Function() load) async {
      try {
        return await load();
      } catch (_) {
        return null;
      }
    }

    final (list, requests, reply) = await (
      tryLoad(() async => [for (final f in await Api.getJson('friends') as List) Friend.fromJson(f as Map<String, dynamic>)]),
      tryLoad(() async => await Api.getJson('friends/requests') as Map<String, dynamic>),
      tryLoad(() async => await Api.getJson('notifications', {'limit': '50'}) as Map<String, dynamic>),
    ).wait;
    if (account != _account) return;
    var changed = false;
    final peopleCurrent = people == _peopleEdits;
    if (peopleCurrent && list != null && !listEquals(list, friends)) {
      friends = list;
      changed = true;
    }
    if (peopleCurrent && requests != null) {
      List<Friend> people(Object? j) =>
          [for (final f in (j as List?) ?? const []) Friend.fromJson(f as Map<String, dynamic>)];
      final inc = people(requests['incoming']), out = people(requests['outgoing']);
      if (!listEquals(inc, incoming)) {
        incoming = inc;
        changed = true;
      }
      if (!listEquals(out, outgoing)) {
        outgoing = out;
        changed = true;
      }
    }
    if (notes == _noteEdits && reply != null) {
      final found = [for (final n in (reply['notifications'] as List?) ?? const []) ?AppNotification.tryParse(n)];
      final count = (reply['unread_count'] as num?)?.toInt() ?? unread;
      if (!listEquals(found, notifications)) {
        notifications = found;
        changed = true;
      }
      if (count != unread) {
        unread = count;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  String _why(Object e) => e is ApiError ? e.toString() : "Can't connect to the server.";

  /// Sends a friend request. Returns null when it went out, else the server's reason ("No account with that
  /// username", "Already friends").
  Future<String?> addFriend(String username) async {
    final name = username.trim();
    if (name.isEmpty) return 'Enter a username.';
    try {
      await Api.sendJson('POST', 'friends/request', {'username': name});
    } catch (e) {
      return _why(e);
    }
    await refresh();
    return null;
  }

  /// Accepts or declines a request. The request leaves the list at once, and a friend joins it on accept; the
  /// server's answer follows. Returns null, or why the server refused (the lists then return to what it holds).
  Future<String?> respond(String username, {required bool accept}) async {
    _peopleEdits++;
    final person = incoming.where((f) => f.username == username).firstOrNull;
    incoming = [for (final f in incoming) if (f.username != username) f];
    if (accept && person != null) {
      friends = [...friends, Friend(person.userId, person.username, DateTime.now().toUtc().toIso8601String())];
    }
    notifyListeners();
    String? problem;
    try {
      await Api.sendJson('POST', 'friends/respond', {'username': username, 'action': accept ? 'accept' : 'decline'});
    } catch (e) {
      problem = _why(e);
    }
    await refresh();
    return problem;
  }

  /// Removes a friend: gone from the list at once. Returns null, or why the server refused.
  Future<String?> remove(Friend friend) async {
    _peopleEdits++;
    friends = [for (final f in friends) if (f.userId != friend.userId) f];
    notifyListeners();
    String? problem;
    try {
      await Api.sendJson('DELETE', 'friends/${friend.userId}');
    } catch (e) {
      problem = _why(e);
    }
    await refresh();
    return problem;
  }

  /// The notifications list was opened: everything in it counts as read, here and on the user's other devices.
  Future<void> markAllRead() async {
    if (unread == 0) return;
    _noteEdits++;
    unread = 0;
    notifications = [for (final n in notifications) n.asRead()];
    notifyListeners();
    try {
      await Api.sendJson('POST', 'notifications/read-all');
    } catch (_) {}
  }

  /// Acts on one message from the notifications socket.
  ///
  /// `connected` loads everything (what arrived while the socket was down); `notification` puts the new one at the
  /// top, and a friend request or an acceptance also reloads the lists; `notification_read` and
  /// `notifications_cleared` carry the unread count the server holds. Anything else ("pong") is ignored.
  @visibleForTesting
  void handle(String text) {
    final Object? message;
    try {
      message = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (message is! Map<String, dynamic>) return;
    final data = message['data'];
    switch (message['type']) {
      case 'connected':
        final count = message['unread'];
        if (count is num && count.toInt() != unread) {
          unread = count.toInt();
          notifyListeners();
        }
        unawaited(refresh());
      case 'notification':
        final pushed = AppNotification.tryParse(data);
        if (pushed == null) return;
        if (!notifications.any((n) => n.id == pushed.id)) {
          notifications = [pushed, ...notifications];
          if (!pushed.read) unread++;
          notifyListeners();
        }
        _applyToLists(pushed);
      case 'notification_read' || 'notifications_cleared':
        final count = data is Map ? data['unread'] : null;
        if (count is num && count.toInt() != unread) {
          unread = count.toInt();
          notifyListeners();
        }
    }
  }

  /// A friend request or an acceptance changes the lists: the person is put where they belong at once, from the
  /// notification itself, and the lists are loaded again a moment later to confirm.
  void _applyToLists(AppNotification n) {
    if (n.type != 'friend_request' && n.type != 'friend_accepted') return;
    final request = n.type == 'friend_request';
    final id = n.payload[request ? 'from_user_id' : 'by_user_id'];
    final name = n.payload[request ? 'from_username' : 'by_username'];
    if (id != null && name != null) {
      _peopleEdits++;
      if (request) {
        if (!incoming.any((f) => f.username == name)) incoming = [...incoming, Friend(id, name, n.createdAt)];
      } else {
        outgoing = [for (final f in outgoing) if (f.username != name) f];
        if (!friends.any((f) => f.username == name)) friends = [...friends, Friend(id, name, n.createdAt)];
      }
      notifyListeners();
    }
    _catchUp?.cancel();
    _catchUp = Timer(catchUpAfter, () => unawaited(refresh()));
  }

  @override
  void dispose() {
    _catchUp?.cancel();
    _socket?.stop();
    super.dispose();
  }
}

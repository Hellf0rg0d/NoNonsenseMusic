// Accounts and playlist sharing against a test server, run without a window:
//   flutter test test/auth_server_test.dart --dart-define=SERVER=http://127.0.0.1:8765
// Skipped when SERVER is unset or names port 8000, the local library. No search runs: songs come from made-up
// listings, so the suite passes where YouTube and JioSaavn cannot be reached.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/models.dart';

import 'test_account.dart';

const server = String.fromEnvironment('SERVER');

/// Returns a [Track] built from a made-up listing.
///
/// The server stores the song from these details alone, so no lookup is needed.
Track madeUp(String title) {
  final l = Listing(source: 'jiosaavn', id: 'test-${DateTime.now().microsecondsSinceEpoch}', title: title, artists: const ['Tester'], duration: 200);
  return Track(l, [l]);
}

void main() {
  final skip = server.isEmpty || server.contains(':8000') ? 'needs --dart-define=SERVER=<a test server>' : null;

  test('sign up: a library of your own; a session ended elsewhere brings sign-in back; sign in again; sign out', () async {
    final auth = await signUpTestAccount();
    final name = auth.user!.username;
    expect((await Api.me()).username, name);
    final library = Library();
    await library.refresh();
    expect(library.reachable, isTrue);
    expect([...library.liked, ...library.playlists], isEmpty, reason: 'a new account starts empty');

    // The same session signed out on another device: this device learns it at the next request.
    final token = Api.token!;
    expect((await http.post(Uri.parse('$server/auth/signout'), headers: {'authorization': 'Bearer $token'})).statusCode, 204);
    await library.refresh();
    expect((auth.state, Api.token), (AuthState.signedOut, null));
    expect(auth.notice, contains('signed out'));

    expect(await auth.signIn(name, 'a test password'), isNull);
    expect(auth.state, AuthState.signedIn);
    final again = Api.token!;
    await auth.signOut();
    expect((await http.get(Uri.parse('$server/auth/me'), headers: {'authorization': 'Bearer $again'})).statusCode, 401,
        reason: 'signing out ends the session on the server, not only here');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('sharing: a viewer sees it under shared and cannot add; as an editor they can; public; leaving', () async {
    await signUpTestAccount();
    final ownerToken = Api.token;
    final library = Library();
    expect(await library.createPlaylist('Shared test'), isNull);
    final id = library.ownPlaylists.single.id;
    await library.add(madeUp('First'), id);

    final friend = await signUpTestAccount(); // Api.token now holds the friend's session.
    final friendToken = Api.token;
    Api.token = ownerToken;
    expect(await library.share(id, 'test-nobody-has-this-name', 'viewer'), 'No account with that username');
    expect(await library.share(id, friend.user!.username, 'viewer'), isNull);

    Api.token = friendToken;
    final asFriend = Library();
    await asFriend.refresh();
    final shared = asFriend.sharedPlaylists.single;
    expect((shared.id, shared.role, shared.canEdit), (id, 'viewer', false));
    expect(asFriend.ownPlaylists, isEmpty);
    await expectLater(Api.add(madeUp('Second').listings, id),
        throwsA(isA<ApiError>().having((e) => (e.status, e.detail), 'answer', (403, 'Your role on this playlist does not allow that'))));

    Api.token = ownerToken;
    expect(await library.share(id, friend.user!.username, 'editor'), isNull, reason: 'sharing again changes the role');
    final people = await Api.members(id);
    expect(people.map((m) => m.role), ['owner', 'editor'], reason: 'the owner first, then who it is shared with');
    expect(people.last.username, friend.user!.username);
    expect(await library.setPublic(id, true), isNull);

    Api.token = friendToken;
    await Api.add(madeUp('Second').listings, id); // An editor may add songs, where the viewer could not.
    await asFriend.refresh();
    expect((asFriend.sharedPlaylists.single.role, asFriend.sharedPlaylists.single.public, asFriend.sharedPlaylists.single.songCount),
        ('editor', true, 2));
    expect(await asFriend.leave(id, friend.user!.id), isNull);
    expect(asFriend.playlists, isEmpty, reason: 'it left their list');

    Api.token = ownerToken;
    await library.refresh();
    expect(jsonEncode([for (final p in library.playlists) p.id]), jsonEncode([id]), reason: "the owner's stays");
    await library.deletePlaylist(id);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('rename this device: the server takes a name, an empty one is refused before it is sent', () async {
    await signUpTestAccount();
    expect(await Auth(store: MemoryTokenStore()).renameDevice('Test phone'), isNull);
    expect(await Auth(store: MemoryTokenStore()).renameDevice('   '), 'A device needs a name.');
  }, skip: skip);
}

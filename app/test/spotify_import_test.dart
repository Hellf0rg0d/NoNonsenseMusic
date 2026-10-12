import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/spotify_import.dart';

void main() {
  test('an Exportify CSV: a quoted title keeps its comma, artists split, a Liked Songs file goes to Liked Songs', () {
    const csv = '"Track URI","Track Name","Album Name","Artist Name(s)","Release Date","Duration (ms)"\r\n'
        '"spotify:track:1","Blinding Lights","After Hours","The Weeknd","2020-03-20","200040"\r\n'
        '"spotify:track:2","Not A Real Song, Honestly","x","Mithoon;Arijit Singh","2013","262000"\r\n'
        '"spotify:track:3","Take Your Mask Off","x","Tyler, The Creator;Daniel Caesar","2017","240000"\r\n';
    final groups = importGroups('Liked_Songs.csv', csv);
    expect(groups.single.name, isNull);
    expect(groups.single.songs.map((s) => s.title), ['Blinding Lights', 'Not A Real Song, Honestly', 'Take Your Mask Off']);
    expect(groups.single.songs[1].artists, ['Mithoon', 'Arijit Singh']);
    expect(groups.single.songs.last.artists, ['Tyler, The Creator', 'Daniel Caesar'], reason: 'artists split at ";", never at ","');
    expect(groups.single.songs.first.durationMs, 200040);
    expect(importGroups('Road_Trip.csv', csv).single.name, 'Road Trip');
  });

  test("Spotify's data download: YourLibrary.json is liked songs, a playlists file is playlists without podcasts", () {
    final liked = importGroups('YourLibrary.json', '{"tracks":[{"artist":"Ed Sheeran","album":"x","track":"Shape of You"}]}');
    expect((liked.single.name, liked.single.songs.single.title), (null, 'Shape of You'));
    expect(liked.single.songs.single.artists, ['Ed Sheeran']);
    final lists = importGroups('Playlist1.json',
        '{"playlists":[{"name":"Gym","items":[{"track":{"trackName":"Faded","artistName":"Alan Walker"}},{"episode":{"name":"a podcast"}}]}]}');
    expect((lists.single.name, lists.single.songs.length), ('Gym', 1));
  });

  test('a byte-order mark at the start is ignored (Exportify writes one)', () {
    final g = importGroups('box.csv', '\uFEFFTrack Name,Artist Name(s)\nSong,Artist\n');
    expect(g.single.songs.single.title, 'Song');
  });

  test('Google Takeout: a Video ID column, with or without titles; "-videos" leaves the playlist name', () {
    final plain = importGroups('Road Trip-videos.csv', 'Video ID,Playlist Video Creation Timestamp\nkJQP7kiw5Fk,2024-01-01\n');
    expect((plain.single.name, plain.single.songs.single.youtubeId, plain.single.songs.single.title), ('Road Trip', 'kJQP7kiw5Fk', ''));
    final library = importGroups('music library songs.csv', 'Video ID,Song Title,Album Title,Artist Name 1\nkJQP7kiw5Fk,Despacito,Vida,Luis Fonsi\n');
    expect((library.single.songs.single.title, library.single.songs.single.youtubeId), ('Despacito', 'kJQP7kiw5Fk'));
    expect(library.single.songs.single.artists, ['Luis Fonsi']);
  });

  test('into a playlist, and a YouTube link, as the server reads them', () {
    final g = importGroups('box.csv', 'Track Name,Artist Name(s)\nSong,Artist\n').single.into('p-1').toJson();
    expect((g['playlist_id'], g['name'], (g['songs'] as List).length), ('p-1', 'box', 1));
    final link = const ImportGroup(null, [], youtubePlaylist: 'https://music.youtube.com/playlist?list=PLx').toJson();
    expect(link.keys, ['youtube_playlist', 'songs']);
  });

  test('a file from somewhere else is refused by name', () {
    expect(() => importGroups('notes.json', '{"hello":1}'), throwsA(isA<UnreadableFile>()));
    expect(() => importGroups('list.csv', 'a,b\n1,2\n'), throwsA(isA<UnreadableFile>()));
  });
}

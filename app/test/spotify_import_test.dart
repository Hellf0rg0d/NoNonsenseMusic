import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/spotify_import.dart';

void main() {
  test('an Exportify CSV: a quoted title keeps its comma, artists split, a Liked Songs file goes to Liked Songs', () {
    const csv = '"Track URI","Track Name","Album Name","Artist Name(s)","Release Date","Duration (ms)"\r\n'
        '"spotify:track:1","Blinding Lights","After Hours","The Weeknd","2020-03-20","200040"\r\n'
        '"spotify:track:2","Not A Real Song, Honestly","x","Mithoon,Arijit Singh","2013","262000"\r\n';
    final groups = importGroups('Liked_Songs.csv', csv);
    expect(groups.single.name, isNull);
    expect(groups.single.songs.map((s) => s.title), ['Blinding Lights', 'Not A Real Song, Honestly']);
    expect(groups.single.songs.last.artists, ['Mithoon', 'Arijit Singh']);
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

  test('a file from somewhere else is refused by name', () {
    expect(() => importGroups('notes.json', '{"hello":1}'), throwsA(isA<UnreadableFile>()));
    expect(() => importGroups('list.csv', 'a,b\n1,2\n'), throwsA(isA<UnreadableFile>()));
  });
}

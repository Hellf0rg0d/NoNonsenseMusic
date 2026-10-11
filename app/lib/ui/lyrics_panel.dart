import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/player.dart';
import '../core/translation.dart';
import 'in_front.dart';
import 'lyric_layout.dart';
import 'scope.dart';

/// Shows the lyrics for the current track.
///
/// Timed lyrics light the line being sung and keep it centered, and tapping a line plays from it. The panel wakes
/// once per line (a timer until the next line is due), never per frame, and the list moves only on a line change:
/// Flutter draws the movement itself, so a line change costs a 0.6 s animation and nothing runs between. Untimed
/// lyrics scroll as a plain list. The panel shows "Finding lyrics…" while the lookup runs, "Couldn't reach the
/// server" when it fails, and "Couldn't find lyrics" when no source holds any.
class LyricsPanel extends StatelessWidget {
  const LyricsPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    // listen to the track id: as a const child the panel kept the first track's lyrics
    return ValueListenableBuilder<String?>(valueListenable: s.player.currentId, builder: (context, _, _) {
    final t = s.player.current;
    if (t == null) return const SizedBox.shrink();
    s.lyrics.fetch(t);
    return ListenableBuilder(
      listenable: Listenable.merge([s.lyrics, s.lyrics.translations, s.settings]),
      builder: (context, _) {
        final found = s.lyrics.of(t);
        Widget message(String text) => Center(child: Text(text, style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6))));
        if (found == null) return s.lyrics.unreachable.contains(t.id) ? message('Couldn\'t reach the server') : message('Finding lyrics…');
        if (found.lines.isEmpty) return message('Couldn\'t find lyrics');
        final genius = s.lyrics.notesOf(t);
        final notes = genius?.byLine(found.lines) ?? const <int, GeniusNote>{};
        final about = genius?.about;
        final translations = s.lyrics.translations;
        final already = translations.inReadersLanguage(t.id);
        final translating = s.settings.translateLyrics && !already;
        // the choice is kept: the next song in another language opens translated too
        if (translating) scheduleMicrotask(() => translations.translate(t.id, found.lines));
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
            child: Row(children: [
              Text('Lyrics', style: theme.textTheme.titleMedium),
              const SizedBox(width: 8),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(found.synced ? 'from ${found.sourceName}' : 'from ${found.sourceName} · not timed',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                ),
              ),
              if (already)
                Padding(padding: const EdgeInsets.only(left: 8), child: Text('Already in your language', style: theme.textTheme.bodySmall))
              else
                IconButton(
                  tooltip: translating ? 'Show the Lyrics' : 'Translate',
                  isSelected: translating,
                  icon: const Icon(FluentIcons.translate_24_regular, size: 18),
                  selectedIcon: Icon(FluentIcons.translate_24_filled, size: 18, color: theme.colorScheme.primary),
                  onPressed: () => s.settings.setTranslateLyrics(!s.settings.translateLyrics),
                ),
              if (about != null && !about.isEmpty)
                IconButton(
                  tooltip: 'About This Song',
                  icon: const Icon(Icons.info_outline, size: 18),
                  onPressed: () => showGeniusAbout(context, about, genius?.url),
                ),
            ]),
          ),
          Expanded(
            child: translating
                ? TranslatedLyrics(lines: found.lines, songId: t.id, translations: translations)
                : found.synced
                    ? _Timed(key: ValueKey(t.id), track: t, lyrics: found, notes: notes, notesUrl: genius?.url)
                    : _Plain(found, notes: notes, notesUrl: genius?.url),
          ),
        ]);
      },
    );
    });
  }
}

/// The lyrics with each line's translation under it. Asked for when the pane opens for a song: "Translating…"
/// meanwhile, "Couldn't translate these lyrics" with a way to try again when it fails.
class TranslatedLyrics extends StatelessWidget {
  final List<LyricLine> lines;
  final String songId;
  final LyricsTranslations translations;
  const TranslatedLyrics({super.key, required this.lines, required this.songId, required this.translations});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6));
    Widget centered(List<Widget> children) => Center(child: Column(mainAxisSize: MainAxisSize.min, children: children));
    final done = translations.linesOf(songId);
    if (done == null) {
      if (translations.failed(songId)) {
        return centered([
          Icon(FluentIcons.translate_24_regular, size: 34, color: muted.color),
          const SizedBox(height: 10),
          Text("Couldn't translate these lyrics", style: muted),
          TextButton(onPressed: () => translations.retry(songId), child: const Text('Try Again')),
        ]);
      }
      return centered([Text('Translating…', style: muted)]);
    }
    final shown = [for (final (i, l) in lines.indexed) if (l.text.isNotEmpty && i < done.length) i];
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 12),
      itemCount: shown.length,
      itemBuilder: (_, k) {
        final i = shown[k];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(lines[i].text, style: theme.textTheme.bodyMedium?.copyWith(color: muted.color)),
            const SizedBox(height: 3),
            SelectableText(done[i], style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ]),
        );
      },
    );
  }
}

/// Untimed lyrics as a scrolling list of lines.
class _Plain extends StatelessWidget {
  final Lyrics lyrics;
  final Map<int, GeniusNote> notes;
  final String? notesUrl;
  const _Plain(this.lyrics, {this.notes = const {}, this.notesUrl});
  @override
  Widget build(BuildContext context) => ListView.builder(
        padding: const EdgeInsets.all(6),
        itemCount: lyrics.lines.length,
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: NotedLyricLine(text: lyrics.lines[i].text, style: Theme.of(context).textTheme.titleMedium, note: notes[i], url: notesUrl),
        ),
      );
}

/// Timed lyrics: the line being sung is lit and the list keeps it centered.
class _Timed extends StatefulWidget {
  final Track track;
  final Lyrics lyrics;
  final Map<int, GeniusNote> notes;
  final String? notesUrl;
  const _Timed({super.key, required this.track, required this.lyrics, this.notes = const {}, this.notesUrl});
  @override
  State<_Timed> createState() => _TimedState();
}

class _TimedState extends State<_Timed> {
  late final ScrollController _scroll;
  LyricLayout? _layout; // the lines' heights at the width last built
  Object? _layoutKey; // what they were measured for: measured again only when it changes
  Timer? _next;
  int _lit = -1;
  Player? _player; // held so dispose can drop the listener without a context lookup

  @override
  void initState() {
    super.initState();
    // start at the line being sung: the first follow jumps rather than animating
    _scroll = ScrollController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = Scope.of(context).player;
    _player?.removeListener(_follow);
    _player = p;
    p.addListener(_follow); // play, pause or seek: the wait starts again
    inFront.removeListener(_follow);
    inFront.addListener(_follow); // no timers while behind other windows; on return the right line lights at once
    _follow(jump: true);
  }

  Future<void> _follow({bool jump = false}) async {
    final p = _player;
    if (!mounted || p == null) return;
    if (p.current?.id != widget.track.id) return;
    final at = await p.readPosition();
    if (!mounted) return;
    final line = widget.lyrics.lineAt(at + 0.1);
    if (line != _lit) {
      setState(() => _lit = line);
      _center(line, jump: jump);
    }
    _next?.cancel();
    if (!p.isPlaying || !inFront.value) return;
    // schedule the wake for when the next line starts
    final upcoming = widget.lyrics.lines.skip(line + 1).map((l) => l.startMs).whereType<int>().firstOrNull;
    if (upcoming == null) return;
    final wait = Duration(milliseconds: (upcoming - at * 1000).round().clamp(30, 60000));
    _next = Timer(wait, _follow);
  }

  void _center(int line, {required bool jump}) {
    if (!_scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _center(line, jump: true));
      return;
    }
    final layout = _layout;
    if (layout == null) return;
    final view = _scroll.position.viewportDimension;
    final target = (layout.centerOf(line) - view / 2).clamp(0.0, _scroll.position.maxScrollExtent);
    jump ? _scroll.jumpTo(target) : _scroll.animateTo(target, duration: Duration(milliseconds: (Scope.of(context).settings.lyricsMotion * 1000).round()), curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _next?.cancel();
    _player?.removeListener(_follow);
    inFront.removeListener(_follow);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = Scope.of(context).player;
    final base = DefaultTextStyle.of(context).style.merge(theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700));
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    // separate paint layer: a line change repaints the lyrics only, not the page
    return RepaintBoundary(child: LayoutBuilder(builder: (context, box) {
      // each line wraps at the width it is drawn at (the list's width less the 6 px either side)
      final width = (box.maxWidth - 12).clamp(40.0, double.infinity);
      final key = (width, base, direction, scaler);
      final first = _layout == null;
      if (key != _layoutKey) {
        _layoutKey = key;
        _layout = LyricLayout.measure([for (final l in widget.lyrics.lines) l.text],
            style: base, width: width, direction: direction, scaler: scaler);
      }
      final layout = _layout!;
      if (first) WidgetsBinding.instance.addPostFrameCallback((_) => _center(_lit, jump: true));
      return ListView.builder(
        controller: _scroll,
        itemExtentBuilder: (i, _) => layout.extents[i],
        itemCount: widget.lyrics.lines.length,
        itemBuilder: (_, i) {
          final line = widget.lyrics.lines[i];
          final play = line.startMs == null ? null : () => p.seek(line.startMs! / 1000);
          return Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              // a line with a note opens it rather than playing from it: "Play from here" lives inside the note
              child: NotedLyricLine(text: line.text, note: widget.notes[i], url: widget.notesUrl, onTap: play, onPlay: play,
                  style: base.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: i == _lit ? 1 : 0.35))),
            ),
          );
        },
      );
    }));
  }
}

// ---- Genius notes (experimental) ----

/// A single lyric line, underlined in a faint accent when a Genius note is attached.
///
/// A tap opens the note rather than invoking [onTap]; lines without a note play from their own time.
class NotedLyricLine extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final GeniusNote? note;
  final String? url;
  final VoidCallback? onTap; // no note on the line: play from it (timed lyrics)
  final VoidCallback? onPlay; // "Play from here" inside the note dialog
  const NotedLyricLine({super.key, required this.text, this.style, this.note, this.url, this.onTap, this.onPlay});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    // a long line wraps in every script; the panel's line heights are measured for that (LyricLayout)
    final shown = Text(text,
        style: note == null ? style : (style ?? const TextStyle()).copyWith(decoration: TextDecoration.underline, decorationColor: accent.withValues(alpha: 0.6)));
    final tap = note == null ? onTap : () => showGeniusNote(context, note!, url, onPlay: onPlay);
    return InkWell(borderRadius: BorderRadius.circular(8), onTap: tap, child: shown);
  }
}

/// Shows a Genius note in a dialog over the lyrics.
///
/// The dialog holds the note text, credits Genius and, when the line carries a time, offers "Play from here".
Future<void> showGeniusNote(BuildContext context, GeniusNote note, String? url, {VoidCallback? onPlay}) => showDialog(
      context: context,
      builder: (c) => AlertDialog(
        content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: SelectableText(note.text)),
        actions: [
          _GeniusCredit(url: url, verified: note.verified),
          if (onPlay != null) TextButton(onPressed: () { Navigator.pop(c); onPlay(); }, child: const Text('Play from here')),
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
        ],
      ),
    );

/// Shows Genius's "About this song" in a dialog: its description, who produced it and what it samples.
Future<void> showGeniusAbout(BuildContext context, GeniusAbout about, String? url) => showDialog(
      context: context,
      builder: (c) {
        final theme = Theme.of(c);
        Widget fact(String title, String value) => Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                Text(value),
              ]),
            );
        return AlertDialog(
          title: const Text('About This Song'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (about.description != null) SelectableText(about.description!),
              if (about.producedBy.isNotEmpty) fact('Produced by', about.producedBy.join(', ')),
              if (about.samples.isNotEmpty) fact('Samples', about.samples.join('\n')),
            ])),
          ),
          actions: [_GeniusCredit(url: url, verified: false), TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
        );
      },
    );

/// Credits Genius as the source of the notes, marked "verified by the artist" when the artist confirmed them.
///
/// The tooltip carries the song's page address when one exists.
class _GeniusCredit extends StatelessWidget {
  final String? url;
  final bool verified;
  const _GeniusCredit({required this.url, required this.verified});
  @override
  Widget build(BuildContext context) => Tooltip(
        message: url ?? '',
        child: Text(verified ? 'Genius · verified by the artist' : 'Genius', style: Theme.of(context).textTheme.bodySmall),
      );
}

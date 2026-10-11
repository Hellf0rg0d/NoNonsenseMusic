import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/jam.dart';
import '../core/links.dart';
import '../core/social.dart';
import 'friends.dart';
import 'popover.dart';

/// The bell in the top bar, with the number of unread notifications. It opens the list, which marks them read.
class NotificationsButton extends StatelessWidget {
  final Social social;
  final JamSession jam;
  NotificationsButton({super.key, Social? social, JamSession? jam})
      : social = social ?? Social.shared,
        jam = jam ?? JamSession.shared;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: social,
      builder: (context, _) {
        final n = social.unread;
        return Builder(
          builder: (anchor) => IconButton(
            tooltip: n > 0 ? '$n new' : 'Notifications',
            onPressed: () => showPanel(
              anchor,
              builder: (panel) => NotificationsList(social: social, jam: jam, close: () => Navigator.pop(panel)),
            ),
            icon: Badge(
              isLabelVisible: n > 0,
              label: Text(n > 99 ? '99+' : '$n'),
              child: const Icon(FluentIcons.alert_24_regular),
            ),
          ),
        );
      },
    );
  }
}

/// The notifications, newest first: a friend request (Accept and Decline while it waits), an accepted request, a
/// playlist shared with the user (Open Playlist), a jam invitation (Join Jam).
///
/// A moment after it opens, everything in it counts as read; the unread dots stay for that moment.
class NotificationsList extends StatefulWidget {
  final Social social;
  final JamSession jam;
  final VoidCallback close;
  const NotificationsList({super.key, required this.social, required this.jam, required this.close});

  @override
  State<NotificationsList> createState() => _NotificationsListState();
}

class _NotificationsListState extends State<NotificationsList> {
  Timer? _mark;

  @override
  void initState() {
    super.initState();
    _mark = Timer(const Duration(milliseconds: 1500), () => widget.social.markAllRead());
  }

  @override
  void dispose() {
    _mark?.cancel();
    super.dispose();
  }

  void _say(String? problem) {
    if (problem != null) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(problem)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.social, widget.jam]),
      builder: (context, _) {
        final notes = widget.social.notifications;
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text('Notifications', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          ),
          if (notes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(child: Text('Nothing yet', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)))),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: notes.length,
                itemBuilder: (_, i) => _Row(note: notes[i], list: widget, say: _say),
              ),
            ),
        ]);
      },
    );
  }
}

/// The sentence a notification says, with the sender's name in bold.
@visibleForTesting
String notificationText(AppNotification n) => switch (n.type) {
      'friend_request' => '${n.from} wants to be friends.',
      'friend_accepted' => '${n.from} accepted your friend request.',
      'playlist_invite' => '${n.from} shared “${n.payload['playlist_name'] ?? 'a playlist'}” with you.',
      'jam_invite' => '${n.from} invited you to ${n.payload['room_name'] == null ? 'a jam' : '“${n.payload['room_name']}”'}.',
      _ => n.from,
    };

class _Row extends StatelessWidget {
  final AppNotification note;
  final NotificationsList list;
  final void Function(String? problem) say;
  const _Row({required this.note, required this.list, required this.say});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = notificationText(note);
    final name = note.from;
    final day = shortDay(note.createdAt);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Avatar(name: name, size: 30),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.rich(TextSpan(children: [
              // the name is the start of every sentence
              TextSpan(text: name, style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: text.startsWith(name) ? text.substring(name.length) : ''),
            ]), style: const TextStyle(fontSize: 13.5)),
            if (day.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(day, style: theme.textTheme.bodySmall)),
            _actions(context),
          ]),
        ),
        if (!note.read)
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(top: 6, left: 8),
            decoration: BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle),
          ),
      ]),
    );
  }

  Widget _actions(BuildContext context) {
    final theme = Theme.of(context);
    final social = list.social, jam = list.jam;
    Widget wrap(List<Widget> children) =>
        Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 8, runSpacing: 6, children: children));
    if (note.type == 'friend_request' && social.incoming.any((f) => f.username == note.from)) {
      return wrap([
        OutlinedButton(
          style: compactButton,
          onPressed: () async => say(await social.respond(note.from, accept: false)),
          child: const Text('Decline'),
        ),
        FilledButton(
          style: compactButton,
          onPressed: () async => say(await social.respond(note.from, accept: true)),
          child: const Text('Accept'),
        ),
      ]);
    }
    final code = note.payload['code'];
    if (note.type == 'jam_invite' && code != null) {
      if (jam.state?.code == code) {
        return Padding(padding: const EdgeInsets.only(top: 4), child: Text("You're in this jam", style: theme.textTheme.bodySmall));
      }
      return wrap([
        OutlinedButton(
          style: compactButton,
          onPressed: () async {
            final problem = await jam.join(code);
            if (problem == null) {
              list.close();
            } else {
              say(problem);
            }
          },
          child: const Text('Join Jam'),
        ),
      ]);
    }
    final playlist = note.payload['playlist_id'];
    if (note.type == 'playlist_invite' && playlist != null) {
      return wrap([
        OutlinedButton(
          style: compactButton,
          onPressed: () {
            list.close();
            PlaylistLinks.pending.value = playlist; // the shell opens it, the way it opens a link
          },
          child: const Text('Open Playlist'),
        ),
      ]);
    }
    return const SizedBox.shrink();
  }
}

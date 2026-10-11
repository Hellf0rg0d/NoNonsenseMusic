import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/download_store.dart';
import '../core/models.dart';

/// Download for a whole list, beside Play and Shuffle: "Downloading 3 of 20" while it runs, "Downloaded" once every
/// song is on this device. One song at a time.
class DownloadAllButton extends StatefulWidget {
  const DownloadAllButton({super.key, required this.tracks, this.store});
  final List<Track> tracks;
  final DownloadStore? store;

  @override
  State<DownloadAllButton> createState() => _DownloadAllButtonState();
}

class _DownloadAllButtonState extends State<DownloadAllButton> {
  bool _working = false;

  @override
  Widget build(BuildContext context) {
    final store = widget.store ?? DownloadStore.shared;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final tracks = widget.tracks;
        final done = tracks.where(store.isDownloaded).length;
        final all = tracks.isNotEmpty && done == tracks.length;
        final label = all ? 'Downloaded' : _working ? 'Downloading $done of ${tracks.length}' : 'Download';
        return OutlinedButton.icon(
          onPressed: all || _working || tracks.isEmpty || store.folder == null
              ? null
              : () async {
                  setState(() => _working = true);
                  await store.downloadAll(tracks);
                  if (mounted) setState(() => _working = false);
                },
          icon: Icon(all ? FluentIcons.checkmark_circle_24_filled : FluentIcons.arrow_download_24_regular, size: 18),
          label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        );
      },
    );
  }
}

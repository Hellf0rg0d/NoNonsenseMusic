import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/account_api.dart';
import '../core/spotify_import.dart';
import 'recovery_codes.dart';
import 'scope.dart';

/// Settings › Account › Recovery Codes: how many of the ten are unused (orange at three or fewer), and a new set.
class RecoveryCodesSettings extends StatefulWidget {
  const RecoveryCodesSettings({super.key});
  @override
  State<RecoveryCodesSettings> createState() => _RecoveryCodesSettingsState();
}

class _RecoveryCodesSettingsState extends State<RecoveryCodesSettings> {
  int? _left;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final n = await AccountApi.codesLeft();
      if (mounted) setState(() => _left = n);
    } catch (_) {} // the count stays "–" until the next visit
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = _left;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 16),
      Text('Recovery Codes', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Row(children: [
        const Expanded(child: Text('Unused Codes')),
        Text(left == null ? '–' : '$left of 10',
            style: theme.textTheme.bodyMedium?.copyWith(color: left != null && left <= 3 ? Colors.orange : theme.colorScheme.onSurfaceVariant)),
      ]),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          onPressed: () async {
            final s = Scope.of(context);
            final codes = await askNewRecoveryCodes(context);
            if (codes == null || !context.mounted) return;
            setState(() => _left = codes.length);
            await showRecoveryCodes(context, codes, s.auth.user?.username ?? '');
          },
          child: const Text('New Recovery Codes…'),
        ),
      ),
    ]);
  }
}

/// Settings › Account › Import from Spotify: pick Exportify's CSVs or Spotify's data-download files; the server adds
/// the songs it finds, and the songs it cannot find are listed.
class SpotifyImportSettings extends StatelessWidget {
  const SpotifyImportSettings({super.key});

  Future<void> _choose(BuildContext context) async {
    final library = Scope.of(context).library;
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['csv', 'json']);
    if (picked.isEmpty) return;
    final files = [for (final f in picked) (f.name, utf8.decode(await f.readAsBytes(), allowMalformed: true))];
    await SpotifyImporter.shared.start(files, done: library.refresh);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final importer = SpotifyImporter.shared;
    return ListenableBuilder(
      listenable: importer,
      builder: (context, _) {
        final status = importer.status;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 16),
          Text('Import from Spotify', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Liked songs and playlists. Get the files from exportify.net, or from Spotify\'s Privacy settings '
              '(Download your data). Only song names leave this device.', style: TextStyle(color: muted)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: importer.running ? null : () => _choose(context),
              child: Text(importer.running ? 'Importing…' : 'Choose Files…'),
            ),
          ),
          if (status != null && !status.finished) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: status.total == 0 ? null : status.done / status.total),
            const SizedBox(height: 4),
            Text('${status.done} of ${status.total} songs', style: TextStyle(color: muted)),
          ],
          if (status != null && status.finished) ...[
            const SizedBox(height: 8),
            Text('${status.added} of ${status.total} added', style: TextStyle(color: muted)),
            if (status.missing.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Not Found (${status.total - status.added})'),
                children: [for (final m in status.missing) Align(alignment: Alignment.centerLeft, child: Text(m, style: TextStyle(color: muted)))],
              ),
          ],
          if (importer.problem != null) ...[
            const SizedBox(height: 8),
            Text(importer.problem!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ]);
      },
    );
  }
}

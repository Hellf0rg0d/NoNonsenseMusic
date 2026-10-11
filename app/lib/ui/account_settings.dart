import 'package:flutter/material.dart';

import '../core/account_api.dart';
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

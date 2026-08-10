/*
 * This file is part of OmniHealth <https://github.com/wger-project>.
 * Copyright (c) 2026, OmniHealth contributors
 *
 * OmniHealth is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import 'package:flutter/material.dart';

/// Approve-before-write for anything the primitives gathered.
///
/// A **write** component (spec §5.2), and the place the honesty guarantee is
/// most load-bearing. The card renders [values] — the *resolved* arguments the
/// write will use — and the button labels are fixed by this widget, not by the
/// agent. An agent cannot show one number and write another: the token it
/// receives is minted over these same values, so a mismatch fails the digest
/// check in `ConfirmationTokenService`.
///
/// [summary] is agent-supplied prose and may be persuasive; [values] is not.
/// That is why both are shown.
class ConfirmationCard extends StatelessWidget {
  static const acceptButtonKey = Key('confirmation_accept');
  static const rejectButtonKey = Key('confirmation_reject');

  /// Agent-supplied description of what is about to happen.
  final String summary;

  /// The resolved arguments about to be written, rendered verbatim.
  final Map<String, Object?> values;

  final VoidCallback onAccept;
  final VoidCallback onReject;

  const ConfirmationCard({
    super.key,
    required this.summary,
    required this.values,
    required this.onAccept,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(summary, style: theme.textTheme.titleMedium),
            if (values.isNotEmpty) ...[
              const SizedBox(height: 12),
              // Rendered from the same map the token is minted over, so the
              // user is reading the payload rather than a description of it.
              ...values.entries.map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 120,
                        child: Text(e.key, style: theme.textTheme.bodySmall),
                      ),
                      Expanded(
                        child: Text(
                          '${e.value}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Labels are fixed here, not supplied by the agent — a
                // mislabelled control is the failure mode this component exists
                // to prevent.
                TextButton(
                  key: rejectButtonKey,
                  onPressed: onReject,
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: acceptButtonKey,
                  onPressed: onAccept,
                  child: const Text('Confirm'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

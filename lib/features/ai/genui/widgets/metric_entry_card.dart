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

/// Collects a single numeric health metric.
///
/// A **write** component (spec §5.2). The agent may request this card and
/// supply its labels, but it cannot submit it: [onSubmit] fires only from a
/// real tap, and only then is a confirmation token minted.
///
/// The card renders the value the user typed, so what they see is what gets
/// written — the honesty half of the safety model.
class MetricEntryCard extends StatefulWidget {
  static const saveButtonKey = Key('metric_entry_save');
  static const cancelButtonKey = Key('metric_entry_cancel');
  static const fieldKey = Key('metric_entry_field');

  final String metric;
  final String unit;
  final DateTime initialDate;

  /// Fires only on a real tap, with the parsed value and chosen date.
  final void Function(double value, DateTime date) onSubmit;

  final VoidCallback onDismiss;

  const MetricEntryCard({
    super.key,
    required this.metric,
    required this.unit,
    required this.initialDate,
    required this.onSubmit,
    required this.onDismiss,
  });

  @override
  State<MetricEntryCard> createState() => _MetricEntryCardState();
}

class _MetricEntryCardState extends State<MetricEntryCard> {
  final _controller = TextEditingController();
  late DateTime _date = widget.initialDate;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = double.tryParse(_controller.text.trim());
    if (parsed == null) {
      setState(() => _error = 'Enter a number');
      return;
    }
    setState(() => _error = null);
    widget.onSubmit(parsed, _date);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted) {
      setState(() => _date = picked);
    }
  }

  String get _formattedDate =>
      '${_date.year.toString().padLeft(4, '0')}-'
      '${_date.month.toString().padLeft(2, '0')}-'
      '${_date.day.toString().padLeft(2, '0')}';

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
            Text('Log ${widget.metric}', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              key: MetricEntryCard.fieldKey,
              controller: _controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: widget.metric,
                suffixText: widget.unit,
                errorText: _error,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text(_formattedDate),
                ),
                const Spacer(),
                TextButton(
                  key: MetricEntryCard.cancelButtonKey,
                  onPressed: widget.onDismiss,
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: MetricEntryCard.saveButtonKey,
                  onPressed: _submit,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

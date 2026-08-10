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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wger/features/ai/chat/providers/chat_notifier.dart';
import 'package:wger/features/ai/genui/widgets/confirmation_card.dart';
import 'package:wger/features/ai/genui/widgets/exercise_video.dart';
import 'package:wger/features/ai/genui/widgets/metric_chart.dart';
import 'package:wger/features/ai/genui/widgets/metric_entry_card.dart';

class ChatScreen extends ConsumerStatefulWidget {
  static const routeName = '/ai-chat';
  static const inputKey = Key('chat_input');
  static const sendKey = Key('chat_send');
  static const cancelKey = Key('chat_cancel');

  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text;
    if (text.trim().isEmpty) {
      return;
    }
    _controller.clear();
    ref.read(chatProvider.notifier).send(text);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Assistant')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: state.entries.length,
              itemBuilder: (context, index) => _EntryView(entry: state.entries[index]),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: ChatScreen.inputKey,
                      controller: _controller,
                      decoration: const InputDecoration(
                        hintText: 'Ask about your health data',
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (state.busy)
                    IconButton(
                      key: ChatScreen.cancelKey,
                      icon: const Icon(Icons.stop_circle_outlined),
                      tooltip: 'Stop',
                      onPressed: () => ref.read(chatProvider.notifier).cancel(),
                    )
                  else
                    IconButton(
                      key: ChatScreen.sendKey,
                      icon: const Icon(Icons.send),
                      tooltip: 'Send',
                      onPressed: _send,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryView extends ConsumerWidget {
  final ChatEntry entry;

  const _EntryView({required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return switch (entry) {
      UserEntry(:final text) => Align(
        alignment: Alignment.centerRight,
        child: Card(
          color: theme.colorScheme.primaryContainer,
          child: Padding(padding: const EdgeInsets.all(12), child: Text(text)),
        ),
      ),

      AssistantEntry() => Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text((entry as AssistantEntry).text),
        ),
      ),

      ToolEntry(:final name, :final running, :final isError) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            if (running)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                isError ? Icons.error_outline : Icons.check,
                size: 14,
                color: isError ? theme.colorScheme.error : null,
              ),
            const SizedBox(width: 8),
            Text(name, style: theme.textTheme.bodySmall),
          ],
        ),
      ),

      // Errors are stated, never swallowed. Retriable ones say so, because
      // "try again" is useless advice when the key is simply wrong.
      FailureEntry(:final message, :final retriable) => Card(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              if (retriable)
                Text('You can try again.', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),

      SurfaceEntry() => _SurfaceView(entry: entry as SurfaceEntry),
    };
  }
}

/// Renders one agent-requested component inline in the transcript.
class _SurfaceView extends ConsumerWidget {
  final SurfaceEntry entry;

  const _SurfaceView({required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = entry.request;
    final props = request.props;

    void resolve() => ref.read(chatProvider.notifier).markSurfaceResolved(entry);

    if (entry.resolved) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'Submitted.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }

    switch (request.component) {
      case 'MetricEntryCard':
        final rawDate = props['date'] as String?;
        return MetricEntryCard(
          metric: props['metric'] as String? ?? 'value',
          unit: props['unit'] as String? ?? '',
          initialDate: (rawDate == null ? null : DateTime.tryParse(rawDate)) ?? DateTime.now(),
          onSubmit: (value, date) {
            request.complete({
              'value': value,
              'date': date.toIso8601String().split('T').first,
            });
            resolve();
          },
          onDismiss: () {
            request.dismiss();
            resolve();
          },
        );

      case 'ConfirmationCard':
        final values = (props['values'] as Map?)?.cast<String, Object?>() ?? const {};
        return ConfirmationCard(
          summary: props['summary'] as String? ?? 'Confirm this change?',
          values: values,
          onAccept: () {
            request.complete(const {});
            resolve();
          },
          onReject: () {
            request.dismiss();
            resolve();
          },
        );

      case 'MetricChart':
        final points = <MetricPoint>[];
        for (final raw in (props['series'] as List?) ?? const []) {
          if (raw is! Map) {
            continue;
          }
          final date = DateTime.tryParse('${raw['date']}');
          final value = (raw['value'] as num?)?.toDouble();
          // Skip malformed points rather than failing the whole card.
          if (date != null && value != null) {
            points.add(MetricPoint(date: date, value: value));
          }
        }
        return MetricChart(
          series: points,
          unit: props['unit'] as String? ?? '',
          label: props['label'] as String?,
        );

      case 'ExerciseVideo':
        final id = (props['videoId'] as num?)?.toInt();
        if (id == null) {
          return const _UnrenderableCard(component: 'ExerciseVideo');
        }
        return ExerciseVideo(videoId: id);

      default:
        // Spec §7: an unknown or malformed component degrades to a visible
        // card. The chat never crashes on something the model asked for.
        return _UnrenderableCard(component: request.component);
    }
  }
}

class _UnrenderableCard extends StatelessWidget {
  final String component;

  const _UnrenderableCard({required this.component});

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Text("Couldn't display this ($component)."),
    ),
  );
}

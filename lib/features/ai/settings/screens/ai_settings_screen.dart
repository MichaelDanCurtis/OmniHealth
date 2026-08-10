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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wger/features/ai/providers/provider_config.dart';
import 'package:wger/features/ai/settings/providers/ai_settings_notifier.dart';

/// A known endpoint, so the user does not have to look up a base URL.
///
/// Four of these five speak the OpenAI dialect and differ only by base URL and
/// model — which is why there are two adapters, not five.
class ProviderPreset {
  final String id;
  final String displayName;
  final ProviderKind kind;
  final String baseUrl;
  final String defaultModel;

  const ProviderPreset({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.baseUrl,
    required this.defaultModel,
  });

  ProviderConfig toConfig(String model) => ProviderConfig(
    id: id,
    displayName: displayName,
    kind: kind,
    baseUrl: baseUrl,
    modelId: model.isEmpty ? defaultModel : model,
  );
}

const providerPresets = [
  ProviderPreset(
    id: 'openai',
    displayName: 'OpenAI',
    kind: ProviderKind.openaiCompat,
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o',
  ),
  ProviderPreset(
    id: 'anthropic',
    displayName: 'Claude',
    kind: ProviderKind.anthropic,
    baseUrl: 'https://api.anthropic.com/v1',
    defaultModel: 'claude-sonnet-4-5',
  ),
  ProviderPreset(
    id: 'grok',
    displayName: 'Grok',
    kind: ProviderKind.openaiCompat,
    baseUrl: 'https://api.x.ai/v1',
    defaultModel: 'grok-4',
  ),
  ProviderPreset(
    id: 'kimi',
    displayName: 'Kimi',
    kind: ProviderKind.openaiCompat,
    baseUrl: 'https://api.moonshot.ai/v1',
    defaultModel: 'kimi-k2',
  ),
  ProviderPreset(
    id: 'glm',
    displayName: 'GLM',
    kind: ProviderKind.openaiCompat,
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    defaultModel: 'glm-4.6',
  ),
];

/// Configures which AI provider to use and holds its key.
class AiSettingsScreen extends ConsumerStatefulWidget {
  static const routeName = '/ai-settings';

  /// Whether to show the desktop-only ACP section. Injectable so the
  /// mobile-hidden behaviour is testable without a platform channel.
  final bool? showAcpSection;

  const AiSettingsScreen({super.key, this.showAcpSection});

  @override
  ConsumerState<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends ConsumerState<AiSettingsScreen> {
  static const addKeyButtonKey = Key('ai_settings_add_key');
  static const apiKeyFieldKey = Key('ai_settings_api_key');

  ProviderPreset _preset = providerPresets.first;
  final _keyController = TextEditingController();
  final _modelController = TextEditingController();

  bool get _showAcp =>
      widget.showAcpSection ??
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  @override
  void dispose() {
    _keyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      return;
    }

    await ref
        .read(aiSettingsProvider.notifier)
        .addProvider(_preset.toConfig(_modelController.text.trim()), key);

    if (mounted) {
      _keyController.clear();
      _modelController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(aiSettingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('AI assistant')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Add a provider', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),

          DropdownButtonFormField<ProviderPreset>(
            initialValue: _preset,
            decoration: const InputDecoration(labelText: 'Provider'),
            items: [
              for (final p in providerPresets)
                DropdownMenuItem(value: p, child: Text(p.displayName)),
            ],
            onChanged: (value) => setState(() => _preset = value ?? _preset),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _modelController,
            decoration: InputDecoration(
              labelText: 'Model',
              hintText: _preset.defaultModel,
            ),
          ),
          const SizedBox(height: 12),

          TextField(
            key: apiKeyFieldKey,
            controller: _keyController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'API key'),
          ),
          const SizedBox(height: 12),

          // Spec §6.3: the user must be told where their health data goes,
          // naming the destination, before they can enable this.
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Your conversations and the health data the assistant reads will '
                'be sent to ${_preset.displayName}. Your key is stored on this '
                'device only and is never sent anywhere else.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          const SizedBox(height: 12),

          FilledButton(
            key: addKeyButtonKey,
            onPressed: _save,
            child: const Text('Save provider'),
          ),

          const Divider(height: 32),
          Text('Configured providers', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),

          switch (settings) {
            AsyncData(:final value) when value.providers.isEmpty => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('None yet.'),
            ),
            AsyncData(:final value) => RadioGroup<String>(
              groupValue: value.selectedId,
              onChanged: (id) => id == null
                  ? null
                  : ref.read(aiSettingsProvider.notifier).selectProvider(id),
              child: Column(
                children: [
                  for (final p in value.providers)
                    RadioListTile<String>(
                      value: p.id,
                      title: Text(p.displayName),
                      subtitle: Text(p.modelId),
                      secondary: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () =>
                            ref.read(aiSettingsProvider.notifier).removeProvider(p.id),
                      ),
                    ),
                ],
              ),
            ),
            AsyncError() => const Text('Could not load providers.'),
            _ => const Center(child: CircularProgressIndicator()),
          },

          if (_showAcp) ...[
            const Divider(height: 32),
            Text('Local agent (advanced)', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Instead of an API key, OmniHealth can talk to an agent program '
              'already installed on this computer. Enter the path to its '
              'executable.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            // Spec §6.4: no default path, and no vendor named as recommended.
            const TextField(
              decoration: InputDecoration(
                labelText: 'Agent executable path',
                hintText: '/path/to/agent',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Subscription sign-ins are not supported. Several providers '
              'restrict consumer subscriptions to their own applications and '
              'enforce it server-side, so using one here could get your account '
              'suspended. Use an API key from a developer console instead.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

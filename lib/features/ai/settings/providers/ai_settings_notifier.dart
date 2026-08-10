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

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wger/features/ai/credentials/ai_key_storage.dart';
import 'package:wger/features/ai/providers/provider_config.dart';

/// Persisted AI configuration.
///
/// Deliberately holds no secret. Keys live in [AiKeyStorage] and are looked up
/// by provider id at request time, so nothing here can leak one into
/// `shared_preferences`, a log line, or a widget-test dump.
class AiSettings {
  final List<ProviderConfig> providers;
  final String? selectedId;

  const AiSettings({this.providers = const [], this.selectedId});

  ProviderConfig? get selected {
    for (final p in providers) {
      if (p.id == selectedId) {
        return p;
      }
    }
    return null;
  }

  AiSettings copyWith({List<ProviderConfig>? providers, String? selectedId}) => AiSettings(
    providers: providers ?? this.providers,
    selectedId: selectedId ?? this.selectedId,
  );
}

/// Storage keys, namespaced to avoid colliding with wger's own preferences.
const _providersKey = 'omnihealth_ai_providers';
const _selectedKey = 'omnihealth_ai_selected_provider';

class AiSettingsNotifier extends AsyncNotifier<AiSettings> {
  AiKeyStorage get _keys => ref.read(aiKeyStorageProvider);

  @override
  Future<AiSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_providersKey) ?? const [];

    final configs = <ProviderConfig>[];
    for (final entry in raw) {
      try {
        configs.add(ProviderConfig.fromJson(jsonDecode(entry) as Map<String, dynamic>));
      } catch (_) {
        // A malformed entry should cost the user that one provider, not their
        // whole configuration.
        continue;
      }
    }

    return AiSettings(providers: configs, selectedId: prefs.getString(_selectedKey));
  }

  Future<void> addProvider(ProviderConfig config, String apiKey) async {
    await _keys.writeKey(config.id, apiKey);

    final current = state.value ?? const AiSettings();
    final providers = <ProviderConfig>[
      ...current.providers.where((p) => p.id != config.id),
      config,
    ];

    // First provider added becomes the selected one; otherwise the user would
    // configure a key and still have nothing to talk to.
    final selectedId = current.selectedId ?? config.id;

    await _persist(providers, selectedId);
    state = AsyncData(AiSettings(providers: providers, selectedId: selectedId));
  }

  Future<void> removeProvider(String id) async {
    await _keys.deleteKey(id);

    final current = state.value ?? const AiSettings();
    final providers = current.providers.where((p) => p.id != id).toList();

    final selectedId = current.selectedId == id
        ? (providers.isEmpty ? null : providers.first.id)
        : current.selectedId;

    await _persist(providers, selectedId);
    state = AsyncData(AiSettings(providers: providers, selectedId: selectedId));
  }

  Future<void> selectProvider(String id) async {
    final current = state.value ?? const AiSettings();
    if (!current.providers.any((p) => p.id == id)) {
      return;
    }

    await _persist(current.providers, id);
    state = AsyncData(current.copyWith(selectedId: id));
  }

  Future<bool> hasKeyFor(String id) => _keys.hasKey(id);

  Future<void> _persist(List<ProviderConfig> providers, String? selectedId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _providersKey,
      providers.map((p) => jsonEncode(p.toJson())).toList(),
    );
    if (selectedId == null) {
      await prefs.remove(_selectedKey);
    } else {
      await prefs.setString(_selectedKey, selectedId);
    }
  }
}

final aiSettingsProvider = AsyncNotifierProvider<AiSettingsNotifier, AiSettings>(
  AiSettingsNotifier.new,
);

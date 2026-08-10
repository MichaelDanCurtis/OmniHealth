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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wger/features/ai/credentials/ai_key_storage.dart';
import 'package:wger/features/ai/providers/provider_config.dart';
import 'package:wger/features/ai/settings/providers/ai_settings_notifier.dart';

class InMemoryAiKeyStorage implements AiKeyStorage {
  final Map<String, String> store = {};

  @override
  Future<void> writeKey(String providerId, String key) async => store[providerId] = key;

  @override
  Future<String?> readKey(String providerId) async => store[providerId];

  @override
  Future<void> deleteKey(String providerId) async => store.remove(providerId);

  @override
  Future<bool> hasKey(String providerId) async => store.containsKey(providerId);
}

const _openai = ProviderConfig(
  id: 'openai',
  displayName: 'OpenAI',
  kind: ProviderKind.openaiCompat,
  baseUrl: 'https://api.openai.com/v1',
  modelId: 'gpt-test',
);

const _claude = ProviderConfig(
  id: 'claude',
  displayName: 'Claude',
  kind: ProviderKind.anthropic,
  baseUrl: 'https://api.anthropic.com/v1',
  modelId: 'claude-test',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryAiKeyStorage keys;
  late ProviderContainer container;

  AiSettingsNotifier notifier() => container.read(aiSettingsProvider.notifier);
  Future<AiSettings> settings() => container.read(aiSettingsProvider.future);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    keys = InMemoryAiKeyStorage();
    container = ProviderContainer(
      overrides: [aiKeyStorageProvider.overrideWithValue(keys)],
    );
    await settings();
  });

  tearDown(() => container.dispose());

  test('starts empty', () async {
    final s = await settings();
    expect(s.providers, isEmpty);
    expect(s.selectedId, isNull);
  });

  test('adding a provider persists its config and stores the key', () async {
    await notifier().addProvider(_openai, 'sk-secret');

    final s = container.read(aiSettingsProvider).requireValue;
    expect(s.providers.single.id, 'openai');
    expect(keys.store['openai'], 'sk-secret');
  });

  test('the key never appears in the exposed state', () async {
    // The config is persisted to plain shared_preferences; the key must live
    // only in secure storage.
    await notifier().addProvider(_openai, 'sk-secret');

    final s = container.read(aiSettingsProvider).requireValue;
    final rendered = s.providers.map((p) => '${p.toJson()}$p').join();
    expect(rendered, isNot(contains('sk-secret')));
  });

  test('the key never reaches shared_preferences', () async {
    await notifier().addProvider(_openai, 'sk-secret');

    final prefs = await SharedPreferences.getInstance();
    final everything = prefs
        .getKeys()
        .map((k) => '${prefs.get(k)}')
        .join();
    expect(everything, isNot(contains('sk-secret')));
  });

  test('the first provider added becomes the selected one', () async {
    // Otherwise the user configures a key and still has nothing to talk to.
    await notifier().addProvider(_openai, 'sk-a');

    expect(container.read(aiSettingsProvider).requireValue.selectedId, 'openai');
  });

  test('adding a second provider does not steal the selection', () async {
    await notifier().addProvider(_openai, 'sk-a');
    await notifier().addProvider(_claude, 'sk-b');

    expect(container.read(aiSettingsProvider).requireValue.selectedId, 'openai');
  });

  test('re-adding the same id replaces rather than duplicates', () async {
    await notifier().addProvider(_openai, 'sk-a');
    await notifier().addProvider(_openai, 'sk-b');

    final s = container.read(aiSettingsProvider).requireValue;
    expect(s.providers, hasLength(1));
    expect(keys.store['openai'], 'sk-b');
  });

  test('removing a provider deletes both its config and its key', () async {
    await notifier().addProvider(_openai, 'sk-a');
    await notifier().removeProvider('openai');

    expect(container.read(aiSettingsProvider).requireValue.providers, isEmpty);
    expect(keys.store.containsKey('openai'), isFalse);
  });

  test('removing the selected provider falls back to another', () async {
    await notifier().addProvider(_openai, 'sk-a');
    await notifier().addProvider(_claude, 'sk-b');
    await notifier().removeProvider('openai');

    expect(container.read(aiSettingsProvider).requireValue.selectedId, 'claude');
  });

  test('removing the last provider clears the selection', () async {
    await notifier().addProvider(_openai, 'sk-a');
    await notifier().removeProvider('openai');

    expect(container.read(aiSettingsProvider).requireValue.selectedId, isNull);
  });

  test('selecting a known provider switches to it', () async {
    await notifier().addProvider(_openai, 'sk-a');
    await notifier().addProvider(_claude, 'sk-b');
    await notifier().selectProvider('claude');

    expect(container.read(aiSettingsProvider).requireValue.selected?.id, 'claude');
  });

  test('selecting an unknown provider is ignored', () async {
    await notifier().addProvider(_openai, 'sk-a');
    await notifier().selectProvider('nonexistent');

    expect(container.read(aiSettingsProvider).requireValue.selectedId, 'openai');
  });

  test('settings survive a reload', () async {
    await notifier().addProvider(_openai, 'sk-a');
    container.dispose();

    container = ProviderContainer(
      overrides: [aiKeyStorageProvider.overrideWithValue(keys)],
    );
    final reloaded = await settings();

    expect(reloaded.providers.single.id, 'openai');
    expect(reloaded.selectedId, 'openai');
  });

  test('one malformed stored entry does not destroy the rest', () async {
    const validEntry =
        '{"id":"openai","displayName":"OpenAI","kind":"openaiCompat",'
        '"baseUrl":"https://x","modelId":"m"}';

    SharedPreferences.setMockInitialValues({
      'omnihealth_ai_providers': ['{not json', validEntry],
    });
    container.dispose();
    container = ProviderContainer(
      overrides: [aiKeyStorageProvider.overrideWithValue(keys)],
    );

    final s = await settings();
    expect(s.providers, hasLength(1));
    expect(s.providers.single.id, 'openai');
  });
}

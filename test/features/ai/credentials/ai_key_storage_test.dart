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

import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/credentials/ai_key_storage.dart';
import 'package:wger/features/ai/providers/provider_config.dart';

/// In-memory double so tests never touch platform channels.
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

void main() {
  late InMemoryAiKeyStorage storage;

  setUp(() => storage = InMemoryAiKeyStorage());

  test('round-trips a key by provider id', () async {
    await storage.writeKey('openai', 'sk-test');
    expect(await storage.readKey('openai'), 'sk-test');
    expect(await storage.hasKey('openai'), isTrue);
  });

  test('keys are namespaced per provider', () async {
    await storage.writeKey('openai', 'sk-a');
    await storage.writeKey('grok', 'sk-b');
    expect(await storage.readKey('openai'), 'sk-a');
    expect(await storage.readKey('grok'), 'sk-b');
  });

  test('delete removes only the named key', () async {
    await storage.writeKey('openai', 'sk-a');
    await storage.writeKey('grok', 'sk-b');
    await storage.deleteKey('openai');
    expect(await storage.readKey('openai'), isNull);
    expect(await storage.readKey('grok'), 'sk-b');
  });

  test('reading an unknown provider returns null rather than throwing', () async {
    expect(await storage.readKey('never-configured'), isNull);
    expect(await storage.hasKey('never-configured'), isFalse);
  });

  test('storage keys are namespaced so they cannot collide with wger auth', () {
    final key = FlutterAiKeyStorage.storageKeyFor('openai');
    expect(key, 'omnihealth_ai_key_openai');
    // wger stores its own refresh token in the same keychain.
    expect(key, isNot(contains('refresh')));
  });

  test('a ProviderConfig never carries the key, and never prints one', () {
    // The config is persisted in plain shared_preferences, so the key must live
    // only in secure storage and be looked up by id.
    const config = ProviderConfig(
      id: 'openai',
      displayName: 'OpenAI',
      kind: ProviderKind.openaiCompat,
      baseUrl: 'https://api.openai.com/v1',
      modelId: 'gpt-test',
    );

    expect(config.toJson().values.join(), isNot(contains('sk-')));
    expect(config.toString(), isNot(contains('sk-')));
    expect(config.toJson().containsKey('apiKey'), isFalse);
  });
}

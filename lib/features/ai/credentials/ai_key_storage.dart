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

import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores per-provider LLM API keys in platform secure storage: Keychain on
/// iOS and macOS, EncryptedSharedPreferences on Android, DPAPI on Windows.
///
/// The keys never appear in logs, chat transcripts, crash reports, or any
/// object's `toString()`. They leave the device only in the authorization
/// header of a request to the provider the user chose — see `ProviderConfig`,
/// which holds the endpoint description and deliberately never the secret.
///
/// Wrapped behind an interface so tests substitute an in-memory double without
/// touching platform channels. Mirrors `core/network/secure_token_storage.dart`.
abstract interface class AiKeyStorage {
  Future<void> writeKey(String providerId, String key);
  Future<String?> readKey(String providerId);
  Future<void> deleteKey(String providerId);
  Future<bool> hasKey(String providerId);
}

class FlutterAiKeyStorage implements AiKeyStorage {
  /// Namespaced so an AI key can never collide with wger's own auth tokens,
  /// which share this keychain.
  static String storageKeyFor(String providerId) => 'omnihealth_ai_key_$providerId';

  final FlutterSecureStorage _storage;

  const FlutterAiKeyStorage([this._storage = const FlutterSecureStorage()]);

  @override
  Future<void> writeKey(String providerId, String key) =>
      _storage.write(key: storageKeyFor(providerId), value: key);

  @override
  Future<String?> readKey(String providerId) => _storage.read(key: storageKeyFor(providerId));

  @override
  Future<void> deleteKey(String providerId) => _storage.delete(key: storageKeyFor(providerId));

  @override
  Future<bool> hasKey(String providerId) async =>
      await _storage.read(key: storageKeyFor(providerId)) != null;
}

final aiKeyStorageProvider = Provider<AiKeyStorage>((ref) => const FlutterAiKeyStorage());

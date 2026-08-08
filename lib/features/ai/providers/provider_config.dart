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

/// Which wire dialect an endpoint speaks.
///
/// [openaiCompat] covers OpenAI, Grok, Kimi and GLM: they differ only by base
/// URL and model id, so adding another is a config entry rather than code.
enum ProviderKind { openaiCompat, anthropic }

/// Persisted description of one configured endpoint.
///
/// Deliberately holds no secret. The API key lives in platform secure storage
/// and is looked up by [id]; see `credentials/ai_key_storage.dart`.
class ProviderConfig {
  final String id;
  final String displayName;
  final ProviderKind kind;
  final String baseUrl;
  final String modelId;

  const ProviderConfig({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.baseUrl,
    required this.modelId,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'kind': kind.name,
    'baseUrl': baseUrl,
    'modelId': modelId,
  };

  factory ProviderConfig.fromJson(Map<String, dynamic> json) => ProviderConfig(
    id: json['id'] as String,
    displayName: json['displayName'] as String,
    kind: ProviderKind.values.byName(json['kind'] as String),
    baseUrl: json['baseUrl'] as String,
    modelId: json['modelId'] as String,
  );

  /// Never includes a key, because no instance holds one. Stated explicitly so
  /// the guarantee survives anyone adding a field later.
  @override
  String toString() => 'ProviderConfig($id, $displayName, ${kind.name}, $modelId)';
}

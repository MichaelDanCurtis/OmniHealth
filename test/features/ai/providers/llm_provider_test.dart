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
import 'package:wger/features/ai/providers/llm_provider.dart';

void main() {
  test('LlmEvent variants carry their payloads', () {
    const delta = TextDelta('hi');
    expect(delta.text, 'hi');

    const call = ToolCall(id: 'c1', name: 'log_weight', arguments: {'value': 82.4});
    expect(const ToolCallRequested(call).call.name, 'log_weight');

    const err = ProviderError('rate limited', retriable: true);
    expect(err.retriable, isTrue);
  });

  test('ProviderError defaults to non-retriable', () {
    expect(const ProviderError('bad key').retriable, isFalse);
  });

  test('Message serialises role as a wire string', () {
    const m = Message(role: MessageRole.assistant, content: 'ok');
    expect(m.role.wireName, 'assistant');
  });

  test('every MessageRole has a wire name', () {
    for (final role in MessageRole.values) {
      expect(role.wireName, isNotEmpty);
    }
  });

  test('a Message defaults to carrying no tool calls', () {
    const m = Message(role: MessageRole.user, content: 'hi');
    expect(m.toolCalls, isEmpty);
    expect(m.toolCallId, isNull);
  });
}

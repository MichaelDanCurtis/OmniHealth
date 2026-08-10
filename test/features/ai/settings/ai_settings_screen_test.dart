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
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wger/features/ai/credentials/ai_key_storage.dart';
import 'package:wger/features/ai/settings/screens/ai_settings_screen.dart';

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
  late InMemoryAiKeyStorage keys;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    keys = InMemoryAiKeyStorage();
  });

  Future<void> pump(WidgetTester tester, {bool? showAcp}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [aiKeyStorageProvider.overrideWithValue(keys)],
        child: MaterialApp(home: AiSettingsScreen(showAcpSection: showAcp)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('names the destination before a key can be saved', (tester) async {
    // Spec §6.3: sending health data to a third party is the whole feature, so
    // the user must be told which one, in plain language, at the point of
    // consent.
    await pump(tester, showAcp: false);

    expect(find.textContaining('will be sent to OpenAI'), findsOneWidget);
    expect(find.textContaining('stored on this device only'), findsOneWidget);
  });

  testWidgets('saving a key stores it and lists the provider', (tester) async {
    await pump(tester, showAcp: false);

    await tester.enterText(find.byKey(const Key('ai_settings_api_key')), 'sk-secret');
    await tester.tap(find.byKey(const Key('ai_settings_add_key')));
    await tester.pumpAndSettle();

    expect(keys.store['openai'], 'sk-secret');
    expect(find.text('OpenAI'), findsWidgets);
  });

  testWidgets('an empty key is not saved', (tester) async {
    await pump(tester, showAcp: false);

    await tester.tap(find.byKey(const Key('ai_settings_add_key')));
    await tester.pumpAndSettle();

    expect(keys.store, isEmpty);
  });

  testWidgets('the key field is obscured', (tester) async {
    await pump(tester, showAcp: false);

    final field = tester.widget<TextField>(find.byKey(const Key('ai_settings_api_key')));
    expect(field.obscureText, isTrue);
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
  });

  testWidgets('the entered key is cleared from the field after saving', (tester) async {
    await pump(tester, showAcp: false);

    await tester.enterText(find.byKey(const Key('ai_settings_api_key')), 'sk-secret');
    await tester.tap(find.byKey(const Key('ai_settings_add_key')));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byKey(const Key('ai_settings_api_key')));
    expect(field.controller?.text, isEmpty);
  });

  testWidgets('shows an empty state before anything is configured', (tester) async {
    await pump(tester, showAcp: false);
    expect(find.text('None yet.'), findsOneWidget);
  });

  group('spec §6.4 — the ACP section', () {
    testWidgets('is hidden on mobile', (tester) async {
      // ACP spawns a local subprocess, which iOS and Android do not permit.
      await pump(tester, showAcp: false);
      expect(find.textContaining('Local agent'), findsNothing);
    });

    testWidgets('on desktop, ships no default path and names no vendor', (tester) async {
      await pump(tester, showAcp: true);

      expect(find.textContaining('Local agent'), findsOneWidget);

      // No vendor may be presented as the recommended target.
      for (final vendor in ['Claude Code', 'Gemini CLI', 'Codex']) {
        expect(find.textContaining(vendor), findsNothing, reason: '$vendor must not be named');
      }
    });

    testWidgets('warns that subscription sign-ins are unsupported', (tester) async {
      // Presenting a subscription as usable here would put the user's account
      // at risk, so the screen says so where they would try it.
      await pump(tester, showAcp: true);

      // The warning sits at the bottom of a lazily-built ListView.
      await tester.scrollUntilVisible(
        find.textContaining('Subscription sign-ins are not supported'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Subscription sign-ins are not supported'), findsOneWidget);
      expect(find.textContaining('suspended'), findsOneWidget);
    });
  });
}

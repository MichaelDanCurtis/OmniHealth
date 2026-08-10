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

import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';
import 'package:wger/features/ai/genui/widgets/confirmation_card.dart';
import 'package:wger/features/ai/genui/widgets/metric_entry_card.dart';

/// The set of components the agent may render, and the rules that govern them.
///
/// Composition (spec §5.1): A2UI's Basic Catalog **minus its three URL-taking
/// media items**, plus OmniHealth's own. Primitives gather; our components
/// commit.
abstract final class OmniCatalog {
  OmniCatalog._();

  /// Components permitted to mint confirmation tokens.
  ///
  /// `render_ui` keys token minting off this set, so a `Button` from the Basic
  /// Catalog gets no token however it labels itself (spec §5.2).
  static const writeComponents = {'MetricEntryCard', 'ConfirmationCard'};

  /// Media components excluded per spec §5.5.
  ///
  /// Each takes a URL, and rendering one issues a GET to it — a silent egress
  /// channel needing no user tap. genui's own `asNoAssetCatalog()` removes
  /// exactly these three; this constant exists so a test can pin that rather
  /// than trust it to stay true upstream.
  static const excludedMediaComponents = {'Image', 'Video', 'AudioPlayer'};

  /// Prompt rules that travel with the catalog, so they cannot drift away from
  /// the components they describe.
  static const rules = '''
This app records health data. Two rules govern every change you make:

1. You cannot write data directly. To record anything, render MetricEntryCard
   (for a single number) or ConfirmationCard (for anything else) and let the
   user submit it. The tool result gives you a confirmationToken; pass it to
   the write tool. Never invent a token.
2. Show what you are about to write. ConfirmationCard renders the exact values
   that will be saved, so state them there rather than only in prose.

To show a form video, call get_exercise_detail and render ExerciseVideo with a
returned video id. You cannot supply URLs; there is no component that accepts
one.''';

  static final _metricEntrySchema = S.object(
    description:
        'Collects one numeric health metric from the user, with a date. '
        'Use for weight, body fat, blood pressure and similar single values.',
    properties: {
      'metric': S.string(description: 'What is being measured, e.g. "weight".'),
      'unit': S.string(description: 'Unit shown beside the field, e.g. "kg".'),
      'date': S.string(description: 'Initial date, YYYY-MM-DD. Defaults to today.'),
    },
    required: ['metric', 'unit'],
  );

  static final _confirmationSchema = S.object(
    description:
        'Asks the user to approve a change before it is written. Renders the '
        'exact values that will be saved.',
    properties: {
      'summary': S.string(description: 'One line describing the change.'),
      'values': S.object(
        description:
            'The exact values that will be written, as label/value pairs. '
            'These are shown to the user verbatim.',
      ),
    },
    required: ['summary'],
  );

  static final metricEntryCard = CatalogItem(
    name: 'MetricEntryCard',
    dataSchema: _metricEntrySchema,
    widgetBuilder: (itemContext) {
      final data = itemContext.data as JsonMap;
      final rawDate = data['date'] as String?;

      return MetricEntryCard(
        metric: data['metric'] as String? ?? 'value',
        unit: data['unit'] as String? ?? '',
        initialDate: (rawDate == null ? null : DateTime.tryParse(rawDate)) ?? DateTime.now(),
        onSubmit: (value, date) => itemContext.dispatchEvent(
          UserActionEvent(
            surfaceId: itemContext.surfaceId,
            name: 'submit',
            sourceComponentId: itemContext.id,
            context: {
              'value': value,
              'date': date.toIso8601String().split('T').first,
            },
          ),
        ),
        onDismiss: () => itemContext.dispatchEvent(
          UserActionEvent(
            surfaceId: itemContext.surfaceId,
            name: 'dismiss',
            sourceComponentId: itemContext.id,
          ),
        ),
      );
    },
  );

  static final confirmationCard = CatalogItem(
    name: 'ConfirmationCard',
    dataSchema: _confirmationSchema,
    widgetBuilder: (itemContext) {
      final data = itemContext.data as JsonMap;

      return ConfirmationCard(
        summary: data['summary'] as String? ?? 'Confirm this change?',
        values: (data['values'] as JsonMap?) ?? const {},
        onAccept: () => itemContext.dispatchEvent(
          UserActionEvent(
            surfaceId: itemContext.surfaceId,
            name: 'submit',
            sourceComponentId: itemContext.id,
          ),
        ),
        onReject: () => itemContext.dispatchEvent(
          UserActionEvent(
            surfaceId: itemContext.surfaceId,
            name: 'dismiss',
            sourceComponentId: itemContext.id,
          ),
        ),
      );
    },
  );

  /// OmniHealth's own components. Read components are added by later tasks.
  static List<CatalogItem> get omniItems => [metricEntryCard, confirmationCard];

  /// The catalog the renderer is given.
  static Catalog build() {
    final base = BasicCatalogItems.asNoAssetCatalog();
    return Catalog(
      [...base.items, ...omniItems],
      functions: base.functions,
      catalogId: 'omnihealth/v1',
      systemPromptFragments: [...base.systemPromptFragments, rules],
    );
  }

  /// Names the agent may render. `render_ui` validates against this.
  static Set<String> get knownComponentNames =>
      build().items.map((i) => i.name).toSet();
}

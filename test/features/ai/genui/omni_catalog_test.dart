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
import 'package:wger/features/ai/genui/omni_catalog.dart';

void main() {
  group('composition', () {
    test('adopts the Basic Catalog primitives', () {
      final names = OmniCatalog.knownComponentNames;
      expect(
        names,
        containsAll(['Column', 'Row', 'Card', 'Text', 'Button', 'TextField', 'Slider']),
      );
    });

    test('includes OmniHealth’s own write components', () {
      expect(
        OmniCatalog.knownComponentNames,
        containsAll(['MetricEntryCard', 'ConfirmationCard']),
      );
    });

    test('includes OmniHealth’s own read components', () {
      // MetricChart because the Basic Catalog has no chart; ExerciseVideo
      // because its Video takes a URL and §5.5 forbids that.
      expect(
        OmniCatalog.knownComponentNames,
        containsAll(['MetricChart', 'ExerciseVideo']),
      );
    });

    test('adding read components did not widen the write surface', () {
      expect(OmniCatalog.writeComponents, isNot(contains('MetricChart')));
      expect(OmniCatalog.writeComponents, isNot(contains('ExerciseVideo')));
    });

    test('a name in neither set is absent', () {
      expect(OmniCatalog.knownComponentNames, isNot(contains('ArbitraryHtml')));
    });

    test('declares a stable catalog id', () {
      expect(OmniCatalog.build().catalogId, 'omnihealth/v1');
    });
  });

  group('spec §5.5 — no component may take a URL', () {
    test('the three URL-taking media components are absent', () {
      // Rendering any of these issues a GET to an agent-chosen host, with no
      // user tap and no trace in the transcript. genui's asNoAssetCatalog()
      // removes exactly these three today; this test pins it so an upstream
      // change cannot silently re-add them.
      for (final banned in OmniCatalog.excludedMediaComponents) {
        expect(
          OmniCatalog.knownComponentNames,
          isNot(contains(banned)),
          reason: '$banned takes a URL and must never be renderable',
        );
      }
    });

    test('the excluded set is exactly Image, Video and AudioPlayer', () {
      expect(
        OmniCatalog.excludedMediaComponents,
        {'Image', 'Video', 'AudioPlayer'},
      );
    });
  });

  group('spec §5.2 — the write surface', () {
    test('writeComponents is exactly the two committing components', () {
      // render_ui keys token minting off this set. Widening it widens what can
      // obtain a confirmation token, so it gets its own test.
      expect(OmniCatalog.writeComponents, {'MetricEntryCard', 'ConfirmationCard'});
    });

    test('every write component is actually in the catalog', () {
      expect(OmniCatalog.knownComponentNames, containsAll(OmniCatalog.writeComponents));
    });

    test('no Basic Catalog primitive is in the write set', () {
      for (final primitive in ['Button', 'TextField', 'Card', 'Slider', 'ChoicePicker']) {
        expect(OmniCatalog.writeComponents, isNot(contains(primitive)));
      }
    });
  });

  group('prompt rules travel with the catalog', () {
    test('the catalog contributes its own rules', () {
      // Keeping these on the Catalog rather than in a system prompt means they
      // cannot drift away from the components they describe.
      final fragments = OmniCatalog.build().systemPromptFragments;
      expect(fragments, contains(OmniCatalog.rules));
    });

    test('the rules state the render-then-confirm flow and the no-URL fact', () {
      expect(OmniCatalog.rules, contains('confirmationToken'));
      expect(OmniCatalog.rules, contains('MetricEntryCard'));
      expect(OmniCatalog.rules, contains('ConfirmationCard'));
      expect(OmniCatalog.rules.toLowerCase(), contains('never invent'));
      expect(OmniCatalog.rules, contains('cannot supply URLs'));
    });
  });
}

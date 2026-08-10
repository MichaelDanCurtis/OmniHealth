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

import 'package:wger/features/ai/tools/tool.dart';
import 'package:wger/features/nutrition/models/ingredient.dart';
import 'package:wger/features/nutrition/models/log.dart';

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Projects an [Ingredient] to the fields the agent may see.
///
/// Spec 5.5: the model carries `sourceUrl`, `licenseObjectURl` and an `image`,
/// and anything the agent can see it can echo into a render request. This is an
/// allowlist rather than a blocklist so a field added upstream cannot leak by
/// default.
Map<String, dynamic> _publicIngredient(Ingredient i) => {
  'id': i.id,
  'name': i.name,
  if (i.brand != null) 'brand': i.brand,
  'energy': i.energy,
  'carbohydrates': i.carbohydrates,
  'protein': i.protein,
  'fat': i.fat,
  'per': '100g',
};

/// Searches the ingredient database.
///
/// The repository's own `search` already picks server or local transport, so
/// this stays a thin adapter over whatever the app would have done.
class SearchIngredientTool implements Tool {
  final Future<List<Ingredient>> Function(String term) search;

  SearchIngredientTool({required this.search});

  @override
  String get name => 'search_ingredient';

  @override
  String get description =>
      'Searches foods by name. Returns ids and nutrition per 100g. '
      'Use the returned id with log_nutrition_entry.';

  @override
  bool get isWrite => false;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'description': 'Food name to search for.'},
      'limit': {'type': 'integer', 'description': 'Maximum results. Defaults to 20.', 'minimum': 1},
    },
    'required': ['query'],
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final query = (args['query'] as String).trim();
    if (query.isEmpty) {
      return ToolResult.error('Provide a non-empty search term.');
    }
    final limit = (args['limit'] as int?) ?? 20;
    final results = await search(query);
    return ToolResult.ok(results.take(limit).map(_publicIngredient).toList());
  }
}

/// Reads the food diary from the local Drift store.
class GetNutritionLogTool implements Tool {
  final Stream<List<LogItem>> Function() watch;

  GetNutritionLogTool({required this.watch});

  @override
  String get name => 'get_nutrition_log';

  @override
  String get description => "Returns the user's logged food entries, most recent first.";

  @override
  bool get isWrite => false;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'limit': {'type': 'integer', 'description': 'Maximum entries. Defaults to 50.', 'minimum': 1},
      'date': {'type': 'string', 'description': 'Optional YYYY-MM-DD filter.'},
    },
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final limit = (args['limit'] as int?) ?? 50;
    final dateFilter = args['date'] as String?;

    var entries = await watch().first;
    if (dateFilter != null) {
      final wanted = DateTime.tryParse(dateFilter);
      if (wanted == null) {
        return ToolResult.error('Could not parse date "$dateFilter". Use YYYY-MM-DD.');
      }
      entries = entries.where((e) => _isoDate(e.datetime) == _isoDate(wanted)).toList();
    }

    return ToolResult.ok(
      entries
          .take(limit)
          .map(
            (e) => {
              'date': _isoDate(e.datetime),
              'ingredientId': e.ingredientId,
              // The hydrated ingredient may still be arriving from sync; a name
              // is nice to have, not required.
              if (e.ingredient != null) 'name': e.ingredient!.name,
              'amount': e.amount,
            },
          )
          .toList(),
    );
  }
}

/// Records a food diary entry.
class LogNutritionEntryTool implements Tool {
  final Future<void> Function(LogItem) addLog;

  /// Resolves the plan a free-form diary entry belongs to. `LogItem` requires
  /// one, so without a plan there is nothing to write to.
  final Future<String?> Function() currentPlanId;

  LogNutritionEntryTool({required this.addLog, required this.currentPlanId});

  @override
  String get name => 'log_nutrition_entry';

  @override
  String get description =>
      'Records a food entry in the diary. Requires user confirmation. '
      'Get the ingredientId from search_ingredient first.';

  @override
  bool get isWrite => true;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'ingredientId': {
        'type': 'integer',
        'description': 'Ingredient id, as returned by search_ingredient.',
      },
      'amount': {'type': 'number', 'description': 'Amount in grams.'},
      'date': {'type': 'string', 'description': 'Date in YYYY-MM-DD format.'},
      'confirmationToken': {
        'type': 'string',
        'description':
            'Token returned by render_ui when the user confirmed. Never invent this.',
      },
    },
    'required': ['ingredientId', 'amount', 'date', 'confirmationToken'],
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final amount = (args['amount'] as num).toDouble();
    if (amount <= 0) {
      return ToolResult.error('Amount must be greater than zero, got $amount.');
    }

    final rawDate = args['date'] as String;
    final date = DateTime.tryParse(rawDate);
    if (date == null) {
      return ToolResult.error('Could not parse date "$rawDate". Use YYYY-MM-DD.');
    }

    final planId = await currentPlanId();
    if (planId == null) {
      return ToolResult.error(
        'The user has no nutrition plan yet, so there is nothing to log against. '
        'Ask them to create one first.',
      );
    }

    await addLog(
      LogItem(
        ingredientId: args['ingredientId'] as int,
        amount: amount,
        planId: planId,
        datetime: date,
      ),
    );

    return ToolResult.ok({
      'logged': {
        'ingredientId': args['ingredientId'],
        'amount': amount,
        'date': _isoDate(date),
      },
    });
  }
}

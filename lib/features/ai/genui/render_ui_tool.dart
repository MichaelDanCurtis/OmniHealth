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

import 'dart:async';

import 'package:wger/features/ai/tools/confirmation_token.dart';
import 'package:wger/features/ai/tools/tool.dart';

/// One surface the agent has asked to render, awaiting the user.
///
/// The chat UI draws [component] with [props] and then calls exactly one of
/// [complete] or [dismiss]. Both are idempotent: a double-fire from the UI is
/// ignored rather than crashing the turn.
class SurfaceRequest {
  final String component;
  final Map<String, dynamic> props;

  final Completer<SurfaceOutcome> _completer = Completer<SurfaceOutcome>();

  SurfaceRequest({required this.component, required this.props});

  Future<SurfaceOutcome> get outcome => _completer.future;

  /// The user submitted, with [values] being what they actually entered.
  void complete(Map<String, dynamic> values) {
    if (_completer.isCompleted) {
      return;
    }
    _completer.complete(SurfaceOutcome(submitted: true, values: values));
  }

  /// The user dismissed the surface. Mints nothing, ever.
  void dismiss() {
    if (_completer.isCompleted) {
      return;
    }
    _completer.complete(const SurfaceOutcome(submitted: false, values: {}));
  }
}

class SurfaceOutcome {
  final bool submitted;
  final Map<String, dynamic> values;

  const SurfaceOutcome({required this.submitted, required this.values});
}

/// Renders a component from the catalog and waits for the user to act.
///
/// This is the only place confirmation tokens are minted, and the rules are
/// deliberately narrow (spec §5.2):
///
/// 1. The component must be in [knownComponents], else the call errors without
///    anything reaching a surface.
/// 2. A token is minted **only** when the component is in [writeComponents]
///    **and** an `intent` naming a tool and arguments was declared.
/// 3. Dismissal mints nothing.
///
/// Rule 2 is why a `Button` from the Basic Catalog can declare any intent it
/// likes and still get nothing: the registry then rejects the write for want of
/// a token. The registry is the security boundary; this keeps the confirmation
/// the user sees honest alongside it.
///
/// Note the deviation recorded in spec §5.3: A2UI's native model is an event
/// flow, and this suspends-and-returns instead. It composes with a tool-calling
/// loop far more simply and works unchanged for an external ACP agent, which
/// has no access to our completers but can call a blocking tool.
class RenderUiTool implements Tool {
  final ConfirmationTokenService tokenService;
  final Set<String> knownComponents;
  final Set<String> writeComponents;
  final void Function(SurfaceRequest) surfaceSink;

  RenderUiTool({
    required this.tokenService,
    required this.knownComponents,
    required this.writeComponents,
    required this.surfaceSink,
  });

  @override
  String get name => 'render_ui';

  @override
  String get description =>
      'Renders a UI component in the chat and waits for the user to act. '
      'Returns what they submitted. To record data, render MetricEntryCard or '
      'ConfirmationCard with an "intent" naming the write tool and its '
      'arguments; the result carries a confirmationToken to pass to that tool.';

  /// Rendering is not itself a write — it only asks.
  @override
  bool get isWrite => false;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'component': {
        'type': 'string',
        'description': 'Component name from the catalog.',
      },
      'props': {
        'type': 'object',
        'description': "The component's properties.",
      },
      'intent': {
        'type': 'object',
        'description':
            'The write this confirmation is for. Only honoured for '
            'MetricEntryCard and ConfirmationCard.',
        'properties': {
          'tool': {'type': 'string'},
          'arguments': {'type': 'object'},
        },
        'required': ['tool', 'arguments'],
      },
    },
    'required': ['component'],
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final component = args['component'] as String;
    if (!knownComponents.contains(component)) {
      return ToolResult.error(
        'No component named "$component" is available. '
        'Use one from the catalog.',
      );
    }

    final request = SurfaceRequest(
      component: component,
      props: (args['props'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    surfaceSink(request);

    // Only write components have something to wait for. A MetricChart has no
    // control to tap, so suspending on one would hang the turn forever — the
    // agent could never say anything after drawing a graph.
    if (!writeComponents.contains(component)) {
      return ToolResult.ok({'action': 'rendered'});
    }

    final outcome = await request.outcome;

    if (!outcome.submitted) {
      return ToolResult.ok({'action': 'dismissed'});
    }

    final result = <String, dynamic>{'action': 'submit', 'values': outcome.values};

    final intent = (args['intent'] as Map?)?.cast<String, dynamic>();
    if (writeComponents.contains(component) && intent != null) {
      final declared = (intent['arguments'] as Map?)?.cast<String, dynamic>() ?? const {};

      // The user may have edited the values before submitting, so what they
      // sent wins over what the agent proposed. Minting over the declared
      // template instead would leave the token describing something the user
      // never saw.
      final resolved = <String, dynamic>{...declared, ...outcome.values};

      result['confirmationToken'] = tokenService.mint(
        toolName: intent['tool'] as String,
        arguments: resolved,
      );
      result['confirmedArguments'] = resolved;
    }

    return ToolResult.ok(result);
  }
}

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

import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;

enum TokenCheck { valid, unknown, expired, alreadyUsed, argumentMismatch }

/// Enforces the core safety invariant: a write runs only because the user
/// physically tapped a control that told them what it would do.
///
/// Tokens are minted **only** by the A2UI renderer, in direct response to a
/// tap, and only by components in `OmniCatalog.writeComponents`. They are
/// single-use, bound to one tool name and one exact argument set, and expire
/// after [_ttl].
///
/// Prompt instructions are not a security boundary. This is.
class ConfirmationTokenService {
  static const _ttl = Duration(minutes: 5);

  final _random = Random.secure();
  final Map<String, _Grant> _grants = {};

  /// Called by the renderer when the user taps a submit or confirm control.
  ///
  /// [arguments] must be the **resolved** values the user actually saw, not a
  /// template containing data-model paths — otherwise the digest would not
  /// describe what was on screen.
  String mint({required String toolName, required Map<String, dynamic> arguments}) {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final token = base64Url.encode(bytes);
    _grants[token] = _Grant(
      toolName: toolName,
      argumentsDigest: _digest(arguments),
      issuedAt: clock.now(),
    );
    _evictExpired();
    return token;
  }

  /// Called by the registry before executing a write tool.
  TokenCheck consume({
    required String token,
    required String toolName,
    required Map<String, dynamic> arguments,
  }) {
    final grant = _grants[token];
    if (grant == null) {
      return TokenCheck.unknown;
    }
    // The tool name is part of the token's identity, so a token presented for
    // a different tool reads as unknown rather than merely invalid.
    if (grant.toolName != toolName) {
      return TokenCheck.unknown;
    }
    if (grant.consumed) {
      return TokenCheck.alreadyUsed;
    }
    if (clock.now().difference(grant.issuedAt) > _ttl) {
      return TokenCheck.expired;
    }
    if (grant.argumentsDigest != _digest(arguments)) {
      return TokenCheck.argumentMismatch;
    }

    grant.consumed = true;
    return TokenCheck.valid;
  }

  /// Order-independent digest, so re-serialising arguments between mint and
  /// consume cannot invalidate an otherwise good token. Recurses into nested
  /// maps, since a payload's meaning can hide several levels down.
  String _digest(Map<String, dynamic> arguments) =>
      sha256.convert(utf8.encode(jsonEncode(_canonical(arguments)))).toString();

  Object? _canonical(Object? value) => switch (value) {
    final Map<String, dynamic> map => {
      for (final key in map.keys.toList()..sort()) key: _canonical(map[key]),
    },
    final List<dynamic> list => list.map(_canonical).toList(),
    _ => value,
  };

  void _evictExpired() {
    final now = clock.now();
    _grants.removeWhere((_, g) => now.difference(g.issuedAt) > _ttl);
  }
}

class _Grant {
  final String toolName;
  final String argumentsDigest;
  final DateTime issuedAt;
  bool consumed = false;

  _Grant({
    required this.toolName,
    required this.argumentsDigest,
    required this.issuedAt,
  });
}

final confirmationTokenServiceProvider = Provider<ConfirmationTokenService>(
  (ref) => ConfirmationTokenService(),
);

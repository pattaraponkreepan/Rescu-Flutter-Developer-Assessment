import 'dart:async';

import 'package:get/get.dart';

import 'analytics_service.dart';

/// Logs a `deal_impression` when a deal card has been at least
/// [minVisibleFraction] visible for [minDwell] without interruption, at most
/// once per deal per app session, whichever list it appears in.
///
/// Cards report their visibility here; the service owns the "already seen"
/// set and the dwell timers, so the rule holds across screens.
class ImpressionTracker extends GetxService {
  ImpressionTracker({
    this.minVisibleFraction = 0.5,
    this.minDwell = const Duration(seconds: 1),
  });

  final double minVisibleFraction;
  final Duration minDwell;

  late final AnalyticsService _analytics = Get.find<AnalyticsService>();

  /// Deals that already produced an impression this session.
  final _logged = <int>{};

  /// Dwell timers for cards currently visible enough, by "source:dealId".
  final _pending = <String, Timer>{};

  void onVisibilityChanged({
    required int dealId,
    required String source,
    required int position,
    required double visibleFraction,
  }) {
    if (_logged.contains(dealId)) return;
    final key = '$source:$dealId';
    if (visibleFraction >= minVisibleFraction) {
      // Keep an already running timer: the visibility has been continuous.
      _pending[key] ??= Timer(minDwell, () {
        _pending.remove(key);
        if (!_logged.add(dealId)) return; // another list got there first
        _analytics.logEvent('deal_impression', {
          'deal_id': dealId,
          'source': source,
          'position': position,
        });
      });
    } else {
      // Dropped below the threshold (or scrolled away / disposed): restart.
      _pending.remove(key)?.cancel();
    }
  }

  @override
  void onClose() {
    for (final timer in _pending.values) {
      timer.cancel();
    }
    _pending.clear();
    super.onClose();
  }
}

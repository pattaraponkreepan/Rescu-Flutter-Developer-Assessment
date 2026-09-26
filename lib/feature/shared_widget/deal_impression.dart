import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../model/deal_model.dart';
import '../../service/impression_tracker.dart';

/// Reports how much of [child] is on screen to the [ImpressionTracker].
///
/// VisibilityDetector only calls back (throttled) when the visible fraction
/// changes; it never rebuilds [child], so wrapping cards doesn't add work to
/// the scrolling list itself.
class DealImpression extends StatelessWidget {
  final DealModel deal;

  /// `home_feed`, `flash_rail` or `search`.
  final String source;

  /// Index of the card in its list.
  final int position;
  final Widget child;

  const DealImpression({
    super.key,
    required this.deal,
    required this.source,
    required this.position,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final tracker = Get.find<ImpressionTracker>();
    return VisibilityDetector(
      // Must be unique among detectors; a deal can be in several lists.
      key: ValueKey('impression:$source:${deal.id}'),
      onVisibilityChanged: (info) => tracker.onVisibilityChanged(
        dealId: deal.id,
        source: source,
        position: position,
        visibleFraction: info.visibleFraction,
      ),
      child: child,
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../service/clock_service.dart';

/// "mm:ss", or "hh:mm:ss" from one hour up. Rounds up, so the last second
/// reads 00:01 and 00:00 only shows once the deal has actually ended.
String formatCountdown(Duration remaining) {
  final ms = remaining.inMilliseconds;
  final total = ms <= 0 ? 0 : (ms / 1000).ceil();
  final h = total ~/ 3600;
  final m = total % 3600 ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Live "time left" text (flash sales, bag reservations).
///
/// Only this Text is inside the Obx, so the per-second tick rebuilds the text
/// and nothing around it. Tabular figures keep its width constant, so the
/// ticking digits don't re-lay out the badge they sit in.
class CountdownText extends StatelessWidget {
  final DateTime endsAt;
  final TextStyle? style;

  const CountdownText({super.key, required this.endsAt, this.style});

  @override
  Widget build(BuildContext context) {
    final clock = Get.find<ClockService>();
    final textStyle = (style ?? const TextStyle())
        .copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    return Obx(() => Text(
          formatCountdown(endsAt.difference(clock.now.value)),
          style: textStyle,
        ));
  }
}

/// Red "FLASH SALE · 12:34" badge for deal cards, or a grey "EXPIRED" badge
/// once the sale has ended.
class FlashSaleBadge extends StatelessWidget {
  final DateTime endsAt;
  final bool expired;

  const FlashSaleBadge(
      {super.key, required this.endsAt, required this.expired});

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(
        color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: expired ? Colors.grey.shade600 : Colors.red.shade600,
        borderRadius: BorderRadius.circular(6),
      ),
      child: expired
          ? const Text('EXPIRED', style: textStyle)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('FLASH SALE · ', style: textStyle),
                CountdownText(endsAt: endsAt, style: textStyle),
              ],
            ),
    );
  }
}

/// Builds its child with `expired == false` until [endsAt] passes, then
/// rebuilds exactly once with `expired == true`.
///
/// It schedules one Timer for the expiry moment instead of listening to the
/// per-second tick, so a card switches to its expired state without being
/// rebuilt every second. A null [endsAt] (not a flash deal) never expires.
class ExpiryBuilder extends StatefulWidget {
  final DateTime? endsAt;
  final Widget Function(BuildContext context, bool expired) builder;

  const ExpiryBuilder({
    super.key,
    required this.endsAt,
    required this.builder,
  });

  @override
  State<ExpiryBuilder> createState() => _ExpiryBuilderState();
}

class _ExpiryBuilderState extends State<ExpiryBuilder> {
  final _clock = Get.find<ClockService>();
  Timer? _timer;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(ExpiryBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.endsAt != widget.endsAt) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    final endsAt = widget.endsAt;
    if (endsAt == null) {
      _expired = false;
      return;
    }
    final left = endsAt.difference(_clock.current());
    _expired = left <= Duration.zero;
    if (!_expired) {
      _timer = Timer(left, () => setState(() => _expired = true));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _expired);
}

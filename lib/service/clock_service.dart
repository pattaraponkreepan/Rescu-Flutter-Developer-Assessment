import 'dart:async';

import 'package:get/get.dart';

/// App-wide one-second ticker for live countdowns.
///
/// Every countdown listens to this single [now] instead of running its own
/// Timer, so the app does one tick per second no matter how many countdowns
/// are on screen, and each listener rebuilds only the widget showing the time.
class ClockService extends GetxService {
  ClockService({DateTime Function()? currentTime})
      : _currentTime = currentTime ?? DateTime.now;

  final DateTime Function() _currentTime;
  late final Rx<DateTime> now = _currentTime().obs;
  Timer? _timer;

  /// The current time, read directly (not reactive).
  DateTime current() => _currentTime();

  @override
  void onInit() {
    super.onInit();
    _timer = Timer.periodic(
        const Duration(seconds: 1), (_) => now.value = _currentTime());
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }
}

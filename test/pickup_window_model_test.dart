import 'package:flutter_test/flutter_test.dart';
import 'package:rescu/model/pickup_window_model.dart';

/// Builds a window the way the API sends it: local wall-clock times converted
/// to ISO-8601 UTC instants.
PickupWindowModel _window(DateTime localStart, DateTime localEnd) =>
    PickupWindowModel.fromJson({
      'start': localStart.toUtc().toIso8601String(),
      'end': localEnd.toUtc().toIso8601String(),
    });

// These assertions only catch the UTC-vs-local bug when the test process is not
// running in UTC, e.g. `TZ=Asia/Bangkok flutter test` on Linux/macOS CI.
void main() {
  test('label shows local wall-clock time, not UTC', () {
    final w = _window(DateTime(2026, 1, 15, 6, 0), DateTime(2026, 1, 15, 9, 30));

    expect(w.label, '06:00 – 09:30');
  });

  test('overnight window keeps local times', () {
    final w =
        _window(DateTime(2026, 1, 15, 22, 0), DateTime(2026, 1, 16, 1, 0));

    expect(w.label, '22:00 – 01:00');
  });

  group('isToday uses the local calendar date', () {
    final now = DateTime.now();

    test('early-morning window today counts as today', () {
      // 00:30 local is the previous day in UTC for any zone east of UTC.
      final start = DateTime(now.year, now.month, now.day, 0, 30);
      final w = _window(start, start.add(const Duration(hours: 2)));

      expect(w.isToday, isTrue);
    });

    test('late-evening window today counts as today', () {
      // 23:30 local is the next day in UTC for any zone west of UTC.
      final start = DateTime(now.year, now.month, now.day, 23, 30);
      final w = _window(start, start.add(const Duration(hours: 2)));

      expect(w.isToday, isTrue);
    });

    test('tomorrow is not today', () {
      final start = DateTime(now.year, now.month, now.day + 1, 12);
      final w = _window(start, start.add(const Duration(hours: 2)));

      expect(w.isToday, isFalse);
    });

    test('same day-of-month in another month is not today', () {
      final start = DateTime(now.year, now.month + 1, now.day, 12);
      final w = _window(start, start.add(const Duration(hours: 2)));

      expect(w.isToday, isFalse);
    });
  });
}

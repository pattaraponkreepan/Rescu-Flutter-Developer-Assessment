import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:rescu/service/fake_api_service.dart';
import 'package:rescu/service/impression_tracker.dart';

/// Records the batches the analytics service sends; can be told to fail.
class _RecordingApi extends FakeApiService {
  final batches = <List<Map<String, dynamic>>>[];
  int failuresLeft = 0;

  @override
  Future<void> sendAnalyticsBatch(List<Map<String, dynamic>> events) async {
    if (failuresLeft > 0) {
      failuresLeft--;
      throw Exception('503');
    }
    batches.add(events);
  }
}

void main() {
  late _RecordingApi api;
  late AnalyticsService analytics;

  // Services are created inside each testWidgets body so their Timers live
  // in the test's fake-async zone and are driven by pump().
  void setUpServices() {
    api = Get.put<FakeApiService>(_RecordingApi()) as _RecordingApi;
    analytics = Get.put(AnalyticsService());
  }

  tearDown(Get.reset);

  List<int> batchSizes() => api.batches.map((b) => b.length).toList();

  group('AnalyticsService batching', () {
    testWidgets('sends as soon as 10 events are waiting', (tester) async {
      setUpServices();
      for (var i = 0; i < 9; i++) {
        analytics.logEvent('e$i');
      }
      await tester.pump();
      expect(api.batches, isEmpty);

      analytics.logEvent('e9');
      await tester.pump();
      expect(batchSizes(), [10]);
      await tester.pump(const Duration(seconds: 20));
      expect(batchSizes(), [10], reason: 'nothing left to send');
    });

    testWidgets('sends 15 s after the first unsent event', (tester) async {
      setUpServices();
      analytics.logEvent('a');
      await tester.pump(const Duration(seconds: 10));
      analytics.logEvent('b'); // must not restart the 15 s window
      await tester.pump(const Duration(seconds: 4, milliseconds: 900));
      expect(api.batches, isEmpty);

      await tester.pump(const Duration(milliseconds: 100)); // t = 15 s
      expect(batchSizes(), [2]);
    });

    testWidgets('keeps events when a batch fails and retries later',
        (tester) async {
      setUpServices();
      api.failuresLeft = 1;
      analytics.logEvent('a');
      analytics.logEvent('b');
      await tester.pump(const Duration(seconds: 15)); // first attempt fails
      expect(api.batches, isEmpty);

      analytics.logEvent('c');
      await tester.pump(const Duration(seconds: 15)); // retry
      expect(api.batches.single.map((e) => e['name']), ['a', 'b', 'c']);
    });
  });

  group('ImpressionTracker', () {
    late ImpressionTracker tracker;

    void setUpTracker() {
      setUpServices();
      tracker = Get.put(ImpressionTracker());
    }

    void report(int dealId, double fraction,
            {String source = 'home_feed', int position = 0}) =>
        tracker.onVisibilityChanged(
          dealId: dealId,
          source: source,
          position: position,
          visibleFraction: fraction,
        );

    // Cancels the tracker's dwell timers and the analytics flush timer.
    void disposeServices() {
      Get.delete<ImpressionTracker>(force: true);
      Get.delete<AnalyticsService>(force: true);
    }

    List<Map<String, dynamic>> impressions() => analytics.events
        .where((e) => e.name == 'deal_impression')
        .map((e) => e.properties)
        .toList();

    testWidgets('logs after 1 s at >= 50% visible, with its properties',
        (tester) async {
      setUpTracker();
      report(7, 0.5, source: 'flash_rail', position: 3);
      await tester.pump(const Duration(milliseconds: 999));
      expect(impressions(), isEmpty);

      await tester.pump(const Duration(milliseconds: 1));
      expect(impressions(), [
        {'deal_id': 7, 'source': 'flash_rail', 'position': 3}
      ]);
      disposeServices();
    });

    testWidgets('needs continuous visibility and at least 50%',
        (tester) async {
      setUpTracker();
      report(1, 0.49);
      report(2, 0.8);
      await tester.pump(const Duration(milliseconds: 900));
      report(2, 0.2); // scrolled away just before the second was up
      await tester.pump(const Duration(seconds: 2));
      expect(impressions(), isEmpty);

      report(2, 0.9); // visible again: the dwell starts over
      await tester.pump(const Duration(milliseconds: 500));
      expect(impressions(), isEmpty);
      await tester.pump(const Duration(milliseconds: 500));
      expect(impressions().map((p) => p['deal_id']), [2]);
      disposeServices();
    });

    testWidgets('at most once per deal per session, across lists',
        (tester) async {
      setUpTracker();
      report(5, 1.0, source: 'flash_rail');
      await tester.pump(const Duration(seconds: 1));
      report(5, 0.0, source: 'flash_rail');
      report(5, 1.0, source: 'flash_rail'); // seen again in the same list
      report(5, 1.0, source: 'home_feed', position: 12); // and elsewhere
      await tester.pump(const Duration(seconds: 3));

      expect(impressions().map((p) => p['deal_id']), [5]);
      disposeServices();
    });

    testWidgets('both lists showing a deal at once still log it once',
        (tester) async {
      setUpTracker();
      report(9, 1.0, source: 'flash_rail');
      report(9, 1.0, source: 'home_feed');
      await tester.pump(const Duration(seconds: 2));

      expect(impressions().map((p) => p['source']), ['flash_rail']);
      disposeServices();
    });
  });
}

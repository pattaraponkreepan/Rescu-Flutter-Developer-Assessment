import 'dart:async';

import 'package:get/get.dart';

import '../util/log_service.dart';
import 'fake_api_service.dart';

class AnalyticsEvent {
  final String name;
  final Map<String, dynamic> properties;
  final DateTime at;

  AnalyticsEvent(this.name, this.properties) : at = DateTime.now();

  Map<String, dynamic> toJson() => {
        'name': name,
        'properties': properties,
        'at': at.toIso8601String(),
      };
}

/// Analytics sink. Events are visible on the debug screen (overflow menu on
/// Home -> "Analytics debug") and in the console, and are delivered to the
/// backend in batches via [FakeApiService.sendAnalyticsBatch]: as soon as
/// [batchSize] events are waiting, or [maxBatchDelay] after the first unsent
/// event, whichever comes first.
class AnalyticsService extends GetxService {
  AnalyticsService({
    this.batchSize = 10,
    this.maxBatchDelay = const Duration(seconds: 15),
  });

  final int batchSize;
  final Duration maxBatchDelay;

  /// Every event logged this session (for the debug screen).
  final events = <AnalyticsEvent>[].obs;

  late final FakeApiService _api = Get.find<FakeApiService>();
  final _unsent = <AnalyticsEvent>[];
  Timer? _flushTimer;
  bool _sending = false;
  bool _flushWhenDone = false;

  void logEvent(String name, [Map<String, dynamic> properties = const {}]) {
    final event = AnalyticsEvent(name, properties);
    events.add(event);
    LogService.log('analytics: $name $properties');

    _unsent.add(event);
    if (_unsent.length >= batchSize) {
      _flush();
    } else {
      // Started by the first unsent event only, so the delay is measured from
      // it, not from the latest one.
      _flushTimer ??= Timer(maxBatchDelay, _flush);
    }
  }

  Future<void> _flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_unsent.isEmpty) return;
    if (_sending) {
      // One request at a time; send what's due as soon as this one finishes.
      _flushWhenDone = true;
      return;
    }

    _sending = true;
    final batch = List.of(_unsent);
    _unsent.clear();
    var failed = false;
    try {
      await _api.sendAnalyticsBatch(batch.map((e) => e.toJson()).toList());
    } catch (e) {
      // Don't lose events: put them back in front and retry later.
      LogService.error('analytics batch failed, will retry', e);
      _unsent.insertAll(0, batch);
      failed = true;
    } finally {
      _sending = false;
    }

    if (_unsent.isEmpty) return;
    final dueNow = _flushWhenDone || _unsent.length >= batchSize;
    _flushWhenDone = false;
    if (dueNow && !failed) {
      await _flush();
    } else {
      // After a failure, wait instead of retrying in a tight loop.
      _flushTimer ??= Timer(maxBatchDelay, _flush);
    }
  }

  @override
  void onClose() {
    _flushTimer?.cancel();
    super.onClose();
  }
}

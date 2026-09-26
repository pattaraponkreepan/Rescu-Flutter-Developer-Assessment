import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/shared_widget/flash_countdown.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/clock_service.dart';

DealModel _flashDeal(int id, DateTime endsAt) => DealModel.fromJson({
      'id': id,
      'name': 'Deal $id',
      'price': 50,
      'originalPrice': 100,
      'quantityLeft': 5,
      'pickupWindow': {
        'start': '2026-01-01T10:00:00.000Z',
        'end': '2026-01-01T12:00:00.000Z',
      },
      'flashSaleEndsAt': endsAt.toUtc().toIso8601String(),
    });

void main() {
  group('formatCountdown', () {
    test('mm:ss under an hour', () {
      expect(formatCountdown(const Duration(minutes: 1, seconds: 5)), '01:05');
      expect(formatCountdown(const Duration(minutes: 59, seconds: 59)),
          '59:59');
    });

    test('hh:mm:ss from an hour up', () {
      expect(formatCountdown(const Duration(hours: 1)), '01:00:00');
      expect(formatCountdown(const Duration(hours: 1, minutes: 2, seconds: 5)),
          '01:02:05');
    });

    test('rounds up, and never goes below zero', () {
      expect(formatCountdown(const Duration(milliseconds: 200)), '00:01');
      expect(formatCountdown(Duration.zero), '00:00');
      expect(formatCountdown(const Duration(seconds: -3)), '00:00');
    });
  });

  group('with a fake clock', () {
    late DateTime now;

    // Called inside each testWidgets body (not setUp), so the clock's periodic
    // Timer is created in the test's fake-async zone and fires on pump().
    void startClock() {
      now = DateTime(2026, 1, 1, 12);
      Get.put(ClockService(currentTime: () => now));
    }

    tearDown(Get.reset);

    Future<void> tick(WidgetTester tester, [int seconds = 1]) async {
      for (var i = 0; i < seconds; i++) {
        now = now.add(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
      }
    }

    Future<void> disposeClock(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      Get.delete<ClockService>(force: true); // cancels the periodic timer
    }

    testWidgets('countdown ticks without rebuilding its parent',
        (tester) async {
      startClock();
      var parentBuilds = 0;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          parentBuilds++;
          return FlashCountdownText(
              endsAt: now.add(const Duration(minutes: 1, seconds: 5)));
        }),
      ));
      expect(find.text('01:05'), findsOneWidget);

      await tick(tester);
      expect(find.text('01:04'), findsOneWidget);
      await tick(tester, 4);
      expect(find.text('01:00'), findsOneWidget);

      expect(parentBuilds, 1, reason: 'only the Text may rebuild per tick');
      await disposeClock(tester);
    });

    testWidgets('expiry builder rebuilds exactly once, when the sale ends',
        (tester) async {
      startClock();
      final states = <bool>[];
      await tester.pumpWidget(MaterialApp(
        home: FlashExpiryBuilder(
          endsAt: now.add(const Duration(seconds: 3)),
          builder: (context, expired) {
            states.add(expired);
            return Text(expired ? 'expired' : 'live');
          },
        ),
      ));

      await tick(tester, 2);
      expect(states, [false], reason: 'no rebuilds while the sale runs');
      await tick(tester);
      expect(states, [false, true]);
      await tick(tester, 3);
      expect(states, [false, true]);
      await disposeClock(tester);
    });

    testWidgets('bag drops a flash deal when it ends, with a notice',
        (tester) async {
      startClock();
      final cart = Get.put(CartService());
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));

      cart.add(_flashDeal(1, now.add(const Duration(seconds: 2))));
      cart.add(_flashDeal(2, now.add(const Duration(minutes: 10))));
      expect(cart.items.map((i) => i.deal.id), [1, 2]);

      await tick(tester, 2);
      await tester.pump(const Duration(milliseconds: 500)); // snackbar in
      expect(cart.items.map((i) => i.deal.id), [2]);
      expect(cart.itemCount.value, 1);
      expect(find.text('Removed from your bag'), findsOneWidget);

      // An ended deal can't be added back.
      cart.add(_flashDeal(1, now.subtract(const Duration(seconds: 1))));
      expect(cart.items.map((i) => i.deal.id), [2]);

      await tester.pump(const Duration(seconds: 5)); // let the snackbar close
      await tester.pumpAndSettle();
      Get.delete<CartService>(force: true);
      await disposeClock(tester);
    });
  });
}

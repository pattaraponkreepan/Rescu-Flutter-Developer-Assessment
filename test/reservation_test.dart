import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/cart/cart_controller.dart';
import 'package:rescu/feature/cart/cart_screen.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/repository/order_repo.dart';
import 'package:rescu/service/api_exception.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/clock_service.dart';

import 'support/fake_order_repo.dart';

DealModel _deal(int id, {int stock = 5}) => DealModel.fromJson({
      'id': id,
      'name': 'Deal $id',
      'price': 50,
      'originalPrice': 100,
      'quantityLeft': stock,
      'pickupWindow': {
        'start': '2026-01-01T10:00:00.000Z',
        'end': '2026-01-01T12:00:00.000Z',
      },
      'flashSaleEndsAt': null,
    });

const _soldOut = ApiException('someone grabbed the last one', statusCode: 409);

void main() {
  late DateTime now;
  late FakeOrderRepo repo;
  late CartService cart;

  // Created inside each testWidgets body so timers run on the fake clock.
  Future<void> setUpCart(WidgetTester tester) async {
    now = DateTime(2026, 1, 1, 12);
    Get.put(ClockService(currentTime: () => now));
    repo = Get.put<OrderRepo>(FakeOrderRepo(now: () => now)) as FakeOrderRepo;
    cart = Get.put(CartService());
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6)); // let snackbars close
    await tester.pumpAndSettle();
    Get.delete<CartService>(force: true);
    Get.delete<ClockService>(force: true);
  }

  tearDown(Get.reset);

  int? heldQuantity(int dealId) => cart.items
      .firstWhereOrNull((i) => i.deal.id == dealId)
      ?.reservation
      ?.quantity;

  List<int> quantities() => cart.items.map((i) => i.quantity).toList();

  testWidgets('adding is optimistic, then the hold arrives', (tester) async {
    await setUpCart(tester);
    repo.autoReserve = false;

    cart.add(_deal(1));
    expect(quantities(), [1], reason: 'in the bag before the server answers');
    expect(heldQuantity(1), isNull);

    repo.succeed(0);
    await tester.pump();
    expect(heldQuantity(1), 1);
    await finish(tester);
  });

  testWidgets('a failed first reservation rolls the line back with a message',
      (tester) async {
    await setUpCart(tester);
    repo.autoReserve = false;

    cart.add(_deal(1));
    repo.fail(0, _soldOut);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(cart.items, isEmpty);
    expect(cart.itemCount.value, 0);
    expect(find.text("Deal 1 wasn't added to your bag"), findsOneWidget);
    expect(find.text('Someone just grabbed the last one.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a failed increase rolls back to the quantity actually held',
      (tester) async {
    await setUpCart(tester);
    cart.add(_deal(1)); // res_1 for 1
    await tester.pump();

    repo.autoReserve = false;
    cart.add(_deal(1));
    expect(quantities(), [2]);
    repo.fail(1, _soldOut);
    await tester.pump();

    expect(quantities(), [1]);
    expect(cart.items.single.reservation!.id, 'res_1', reason: 'kept');
    expect(repo.released, isEmpty);
    await finish(tester);
  });

  testWidgets('rapid taps: one request at a time, final hold matches the bag',
      (tester) async {
    await setUpCart(tester);
    repo.autoReserve = false;

    cart.add(_deal(1));
    cart.add(_deal(1));
    cart.add(_deal(1));
    expect(quantities(), [3]);
    expect(repo.reserveCalls, hasLength(1), reason: 'serialised per line');

    repo.succeed(0); // hold for 1 arrives, bag already wants 3
    await tester.pump();
    expect(repo.reserveCalls.map((c) => c.quantity), [1, 3]);
    repo.succeed(1);
    await tester.pump();

    expect(heldQuantity(1), 3);
    expect(repo.released, ['res_1'], reason: 'old hold released after new');
    await finish(tester);
  });

  testWidgets('reducing the quantity adjusts the hold', (tester) async {
    await setUpCart(tester);
    cart.add(_deal(1)); // res_1 (1)
    await tester.pump();
    cart.add(_deal(1)); // res_2 (2), releases res_1
    await tester.pump();

    cart.decrement(1); // res_3 (1), releases res_2
    await tester.pump();

    expect(heldQuantity(1), 1);
    expect(repo.released, ['res_1', 'res_2']);
    await finish(tester);
  });

  testWidgets('removing a line releases its hold, even one still in flight',
      (tester) async {
    await setUpCart(tester);
    repo.autoReserve = false;

    cart.add(_deal(1));
    cart.decrement(1); // quantity 1 -> removed while reserving
    expect(cart.items, isEmpty);

    repo.succeed(0); // the late hold must not leak
    await tester.pump();
    expect(repo.released, ['res_1']);
    await finish(tester);
  });

  testWidgets('a lapsed hold keeps the item, notifies once, can be renewed',
      (tester) async {
    await setUpCart(tester);
    cart.add(_deal(1));
    await tester.pump();

    now = now.add(const Duration(minutes: 5));
    await tester.pump(const Duration(seconds: 1)); // clock tick
    await tester.pump(const Duration(milliseconds: 500));

    expect(quantities(), [1], reason: 'still in the bag');
    expect(cart.isHoldLapsed(cart.items.single), isTrue);
    expect(find.text('Your reservation ran out'), findsOneWidget);

    cart.renewHold(1);
    await tester.pump();
    expect(cart.isHoldLapsed(cart.items.single), isFalse);
    expect(cart.items.single.reservation!.id, 'res_2');
    expect(repo.released, ['res_1']);
    await finish(tester);
  });

  testWidgets('bag line shows the hold, and the lapsed state fits a phone',
      (tester) async {
    // Pixel 8 (the emulator used for manual checks): 1080 px at 2.625 dpr.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await setUpCart(tester);
    Get.put(CartController(cartService: cart, orderRepo: repo));
    cart.add(_deal(1));
    await tester.pump();

    await tester.pumpWidget(const GetMaterialApp(home: CartScreen()));
    expect(find.text('Held for '), findsOneWidget);
    expect(find.text('05:00'), findsOneWidget);

    // Let the full 5 minutes pass on the fake clock, so the line's one-shot
    // expiry timer fires too.
    now = now.add(const Duration(minutes: 5));
    await tester.pump(const Duration(minutes: 5));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Reservation ran out'), findsOneWidget);
    expect(find.text('Reserve again'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow');
    // The image placeholder shimmers forever (no network in tests).
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    await finish(tester);
  });

  group('checkout', () {
    late CartController controller;

    Future<void> setUpCheckout(WidgetTester tester) async {
      await setUpCart(tester);
      controller = CartController(cartService: cart, orderRepo: repo);
      cart.add(_deal(1));
      cart.add(_deal(2));
      await tester.pump();
    }

    testWidgets('sends the reservation ids and empties the bag',
        (tester) async {
      await setUpCheckout(tester);
      await controller.checkout();

      expect(repo.checkouts, [
        ['res_1', 'res_2']
      ]);
      expect(cart.items, isEmpty);
      expect(repo.released, isEmpty, reason: 'holds were used by the order');
      await finish(tester);
    });

    testWidgets('renews holds that ran out (or are about to) before paying',
        (tester) async {
      await setUpCheckout(tester);
      now = now.add(const Duration(minutes: 4, seconds: 45)); // 15 s left

      await controller.checkout();

      expect(repo.checkouts.single, ['res_3', 'res_4']);
      expect(repo.released, ['res_1', 'res_2']);
      await finish(tester);
    });

    testWidgets('410: takes fresh holds on everything and retries once',
        (tester) async {
      await setUpCheckout(tester);
      repo.checkoutOutcomes
          .add(const ApiException('Reservation expired', statusCode: 410));

      await controller.checkout();

      expect(repo.checkouts, [
        ['res_1', 'res_2'],
        ['res_3', 'res_4'],
      ]);
      expect(cart.items, isEmpty, reason: 'second attempt succeeded');
      await finish(tester);
    });

    testWidgets("sold out on renewal: removes it and doesn't pay",
        (tester) async {
      await setUpCheckout(tester);
      now = now.add(const Duration(minutes: 5)); // both holds lapsed
      repo.autoReserve = false;

      final done = controller.checkout();
      await tester.pump();
      repo.succeed(2); // deal 1 re-reserved
      await tester.pump();
      repo.fail(3, _soldOut); // deal 2: contention...
      await tester.pump();
      repo.fail(4, _soldOut); // ...and still gone on the retry
      await done;
      await tester.pump(const Duration(milliseconds: 500));

      expect(repo.checkouts, isEmpty, reason: 'user reviews the bag first');
      expect(cart.items.map((i) => i.deal.id), [1]);
      expect(find.text('An item sold out'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('502: keeps the bag and says nothing was charged',
        (tester) async {
      await setUpCheckout(tester);
      repo.checkoutOutcomes.add(const ApiException('timeout', statusCode: 502));

      await controller.checkout();
      await tester.pump(const Duration(milliseconds: 500));

      expect(cart.items, hasLength(2));
      expect(find.text("Payment didn't go through"), findsOneWidget);
      expect(controller.isCheckingOut.value, isFalse);
      await finish(tester);
    });
  });
}

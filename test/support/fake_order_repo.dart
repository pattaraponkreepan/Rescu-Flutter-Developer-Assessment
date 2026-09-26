import 'dart:async';

import 'package:rescu/model/cart_item_model.dart';
import 'package:rescu/model/order_model.dart';
import 'package:rescu/model/reservation_model.dart';
import 'package:rescu/repository/order_repo.dart';
import 'package:rescu/service/fake_api_service.dart';

/// A pending `reserve` call the test can complete or fail.
class ReserveCall {
  final int dealId;
  final int quantity;
  final Completer<ReservationModel> completer;

  ReserveCall(this.dealId, this.quantity) : completer = Completer();
}

/// OrderRepo double: records reservations/releases/checkouts and lets the test
/// decide when (and how) each reservation request completes.
class FakeOrderRepo extends OrderRepo {
  FakeOrderRepo({required this.now}) : super(api: FakeApiService());

  final DateTime Function() now;

  /// Complete reserve calls immediately with a fresh 5 minute hold.
  bool autoReserve = true;

  final reserveCalls = <ReserveCall>[];
  final released = <String>[];

  /// What each checkout sent: reservation id per line.
  final checkouts = <List<String?>>[];

  /// Outcomes for the next checkout calls (an exception to throw, or null
  /// for success), consumed in order. Empty means success.
  final checkoutOutcomes = <Exception?>[];

  int _seq = 0;

  ReservationModel hold(int dealId, int quantity) => ReservationModel(
        id: 'res_${++_seq}',
        dealId: dealId,
        quantity: quantity,
        expiresAt: now().add(const Duration(minutes: 5)),
      );

  /// Completes pending reserve call [index] successfully.
  void succeed(int index) {
    final call = reserveCalls[index];
    call.completer.complete(hold(call.dealId, call.quantity));
  }

  /// Fails pending reserve call [index].
  void fail(int index, Exception error) =>
      reserveCalls[index].completer.completeError(error);

  @override
  Future<ReservationModel> reserve(int dealId, {int quantity = 1}) {
    final call = ReserveCall(dealId, quantity);
    reserveCalls.add(call);
    if (autoReserve) call.completer.complete(hold(dealId, quantity));
    return call.completer.future;
  }

  @override
  Future<void> releaseReservation(String reservationId) async {
    released.add(reservationId);
  }

  @override
  Future<OrderModel> checkout(List<CartItemModel> items) async {
    checkouts.add(items.map((i) => i.reservation?.id).toList());
    if (checkoutOutcomes.isNotEmpty) {
      final outcome = checkoutOutcomes.removeAt(0);
      if (outcome != null) throw outcome;
    }
    return OrderModel(
      id: 9001,
      dealId: items.first.deal.id,
      dealName: 'Order',
      storeName: 'Store',
      imageUrl: '',
      status: 'CONFIRMED',
      quantity: items.fold(0, (a, i) => a + i.quantity),
      total: 0,
      currencyCode: 'THB',
      pickupStart: now(),
      pickupEnd: now().add(const Duration(hours: 2)),
    );
  }
}

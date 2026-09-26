import 'dart:async';

import 'package:get/get.dart';

import '../model/cart_item_model.dart';
import '../model/deal_model.dart';
import '../model/reservation_model.dart';
import '../repository/order_repo.dart';
import '../util/log_service.dart';
import 'api_exception.dart';
import 'clock_service.dart';

/// App-wide cart. Lives for the whole session.
///
/// Every line is backed by a stock reservation (a 5 minute hold). Changes are
/// optimistic: the bag updates immediately and the hold is reconciled in the
/// background, rolling the line back if the reservation fails.
class CartService extends GetxService {
  final items = <CartItemModel>[].obs;
  final itemCount = 0.obs;

  late final ClockService _clock = Get.find<ClockService>();
  late final OrderRepo _orderRepo = Get.find<OrderRepo>();
  Worker? _tickWorker;

  /// Lines with a reservation request in flight, by deal id.
  final _syncing = <int, Future<void>>{};

  /// Reservations whose expiry the user has already been told about.
  final _lapsedNotified = <String>{};

  @override
  void onInit() {
    super.onInit();
    _tickWorker = ever<DateTime>(_clock.now, (now) {
      _removeEndedFlashDeals(now);
      _noticeLapsedHolds(now);
    });
  }

  @override
  void onClose() {
    _tickWorker?.dispose();
    super.onClose();
  }

  /// Whether [deal]'s flash sale has ended, so it can no longer be added.
  bool isExpired(DealModel deal) => deal.isFlashExpiredAt(_clock.current());

  /// Whether [line]'s hold has run out (it is still in the bag, not reserved).
  bool isHoldLapsed(CartItemModel line) =>
      line.reservation?.isExpiredAt(_clock.current()) ?? false;

  /// Adds one of [deal] to the bag right away and reserves it in the
  /// background.
  void add(DealModel deal) {
    if (isExpired(deal)) {
      LogService.log('cart: flash sale for deal ${deal.id} has ended');
      return;
    }
    final existing = _line(deal.id);
    if (existing != null) {
      if (existing.quantity >= deal.quantityLeft) {
        LogService.log('cart: cannot add more of deal ${deal.id}');
        return;
      }
      existing.quantity++;
      items.refresh();
    } else {
      items.add(CartItemModel(deal: deal));
    }
    _recount();
    _syncHold(deal.id);
  }

  void decrement(int dealId) {
    final line = _line(dealId);
    if (line == null) return;
    if (line.quantity <= 1) {
      remove(dealId);
      return;
    }
    line.quantity--;
    items.refresh();
    _recount();
    _syncHold(dealId);
  }

  /// Removes a line and releases its hold. A reservation still in flight for
  /// it is released when it arrives (see [_runSync]).
  void remove(int dealId) {
    final line = _line(dealId);
    if (line == null) return;
    items.remove(line);
    _recount();
    _release(line.reservation);
  }

  /// Reserves a lapsed line again (the "Reserve again" button).
  void renewHold(int dealId) => _syncHold(dealId);

  /// Empties the bag after a successful checkout. The holds were used by the
  /// order, so they are not released.
  void clear() {
    items.clear();
    _recount();
  }

  num get total => items.fold(0, (sum, i) => sum + i.lineTotal);

  /// Before checkout: waits for pending reservation changes, then makes sure
  /// every line is held for at least [margin] from now (so the hold can't
  /// lapse during the request), reserving again where needed. With
  /// [renewAll], every line gets a fresh hold.
  ///
  /// Lines that can't be held any more are removed and returned.
  Future<List<CartItemModel>> ensureHolds({
    Duration margin = const Duration(seconds: 30),
    bool renewAll = false,
  }) async {
    await Future.wait(_syncing.values.toList());
    final lost = <CartItemModel>[];
    for (final line in items.toList()) {
      final r = line.reservation;
      final heldLongEnough = r != null &&
          r.quantity == line.quantity &&
          r.expiresAt.isAfter(_clock.current().add(margin));
      if (heldLongEnough && !renewAll) continue;

      final hold = await _reserveForCheckout(line);
      if (!items.contains(line)) {
        _release(hold); // removed meanwhile (e.g. its flash sale ended)
        continue;
      }
      if (hold == null) {
        items.remove(line);
        lost.add(line);
        _release(line.reservation);
      } else {
        _release(line.reservation);
        line.reservation = hold;
      }
    }
    items.refresh();
    _recount();
    return lost;
  }

  // ---------------------------------------------------------------------------

  CartItemModel? _line(int dealId) =>
      items.firstWhereOrNull((i) => i.deal.id == dealId);

  /// Brings the hold for a line in line with its quantity. One request per
  /// line at a time; changes made meanwhile are picked up when it finishes, so
  /// responses can't be applied out of order.
  void _syncHold(int dealId) {
    if (_syncing.containsKey(dealId)) return;
    _syncing[dealId] =
        _runSync(dealId).whenComplete(() => _syncing.remove(dealId));
  }

  Future<void> _runSync(int dealId) async {
    while (true) {
      final line = _line(dealId);
      if (line == null || line.isHeldAt(_clock.current())) return;

      final ReservationModel hold;
      try {
        hold = await _orderRepo.reserve(dealId, quantity: line.quantity);
      } catch (e) {
        _rollBack(dealId, e);
        return;
      }

      final current = _line(dealId);
      if (current == null) {
        _release(hold); // removed while we were waiting
        return;
      }
      // Reserve the new amount first, then release the old hold, so the line
      // is never left without one.
      _release(current.reservation);
      current.reservation = hold;
      items.refresh();
      // Loop: if the quantity changed while we waited, reserve again.
    }
  }

  /// A reservation failed: put the line back to what is actually held.
  void _rollBack(int dealId, Object error) {
    LogService.error('cart: reserve deal $dealId failed', error);
    final line = _line(dealId);
    if (line == null) return;
    final name = line.deal.name;
    final reason = _reason(error);
    final held = line.reservation;
    if (held == null) {
      items.remove(line);
      _notify('$name wasn\'t added to your bag', reason);
    } else {
      line.quantity = held.quantity;
      items.refresh();
      if (held.isExpiredAt(_clock.current())) {
        _notify('Couldn\'t reserve $name again', reason);
      } else {
        _notify('Couldn\'t change the quantity of $name',
            '$reason You still have ${held.quantity} reserved.');
      }
    }
    _recount();
  }

  /// Reserves a line at checkout, retrying a stock-contention 409 once.
  /// Returns null if it can't be held (sold out / gone).
  Future<ReservationModel?> _reserveForCheckout(CartItemModel line) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _orderRepo.reserve(line.deal.id, quantity: line.quantity);
      } on ApiException catch (e) {
        LogService.error('cart: reserve deal ${line.deal.id} at checkout', e);
        if (e.statusCode != 409) return null;
      }
    }
    return null;
  }

  void _release(ReservationModel? reservation) {
    if (reservation == null) return;
    _lapsedNotified.remove(reservation.id);
    unawaited(_orderRepo.releaseReservation(reservation.id).catchError(
        (Object e) => LogService.error('cart: release failed', e)));
  }

  void _removeEndedFlashDeals(DateTime now) {
    final ended = items.where((i) => i.deal.isFlashExpiredAt(now)).toList();
    if (ended.isEmpty) return;
    items.removeWhere(ended.contains);
    for (final line in ended) {
      _release(line.reservation);
    }
    _recount();
    final names = ended.map((i) => i.deal.name).join(', ');
    LogService.log('cart: removed ${ended.map((i) => i.deal.id).toList()}, '
        'flash sale ended');
    _notify('Removed from your bag', 'The flash sale for $names has ended.');
  }

  /// A hold ran out while the item sits in the bag: keep the item, tell the
  /// user once, and let them (or checkout) reserve it again.
  void _noticeLapsedHolds(DateTime now) {
    final lapsed = items.where((l) {
      final r = l.reservation;
      return r != null && r.isExpiredAt(now) && !_lapsedNotified.contains(r.id);
    }).toList();
    if (lapsed.isEmpty) return;
    _lapsedNotified.addAll(lapsed.map((l) => l.reservation!.id));
    items.refresh();
    final names = lapsed.map((l) => l.deal.name).join(', ');
    LogService.log('cart: hold lapsed for '
        '${lapsed.map((l) => l.deal.id).toList()}');
    _notify(
      'Your reservation ran out',
      '$names ${lapsed.length == 1 ? 'is' : 'are'} still in your bag but no '
          'longer held for you. We\'ll try to reserve again when you check out.',
    );
  }

  String _reason(Object error) {
    if (error is ApiException && error.statusCode == 409) {
      return 'Someone just grabbed the last one.';
    }
    return 'Please try again in a moment.';
  }

  void _notify(String title, String message) => Get.snackbar(
        title,
        message,
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 4),
      );

  void _recount() {
    itemCount.value = items.fold(0, (sum, i) => sum + i.quantity);
  }
}

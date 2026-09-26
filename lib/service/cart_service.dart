import 'package:get/get.dart';

import '../model/cart_item_model.dart';
import '../model/deal_model.dart';
import '../util/log_service.dart';
import 'clock_service.dart';

/// App-wide cart. Lives for the whole session.
///
/// NOTE: the starter cart is purely local — it does not reserve stock on the
/// backend. See the "Reservations" feature task in PROBLEM.md.
class CartService extends GetxService {
  final items = <CartItemModel>[].obs;
  final itemCount = 0.obs;

  late final ClockService _clock = Get.find<ClockService>();
  Worker? _expiryWorker;

  @override
  void onInit() {
    super.onInit();
    // A flash deal can end while it sits in the bag: drop it as soon as it does.
    _expiryWorker = ever<DateTime>(_clock.now, _removeExpired);
  }

  @override
  void onClose() {
    _expiryWorker?.dispose();
    super.onClose();
  }

  /// Whether [deal]'s flash sale has ended, so it can no longer be added.
  bool isExpired(DealModel deal) => deal.isFlashExpiredAt(_clock.current());

  void add(DealModel deal) {
    if (isExpired(deal)) {
      LogService.log('cart: flash sale for deal ${deal.id} has ended');
      return;
    }
    final existing = items.firstWhereOrNull((i) => i.deal.id == deal.id);
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
  }

  void decrement(int dealId) {
    final existing = items.firstWhereOrNull((i) => i.deal.id == dealId);
    if (existing == null) return;
    existing.quantity--;
    if (existing.quantity <= 0) {
      items.removeWhere((i) => i.deal.id == dealId);
    } else {
      items.refresh();
    }
    _recount();
  }

  void remove(int dealId) {
    items.removeWhere((i) => i.deal.id == dealId);
    _recount();
  }

  void clear() {
    items.clear();
    _recount();
  }

  num get total => items.fold(0, (sum, i) => sum + i.lineTotal);

  void _removeExpired(DateTime now) {
    final expired =
        items.where((i) => i.deal.isFlashExpiredAt(now)).toList();
    if (expired.isEmpty) return;
    items.removeWhere(expired.contains);
    _recount();
    final names = expired.map((i) => i.deal.name).join(', ');
    LogService.log('cart: removed ${expired.map((i) => i.deal.id).toList()}, '
        'flash sale ended');
    Get.snackbar(
      'Removed from your bag',
      'The flash sale for $names has ended.',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 4),
    );
  }

  void _recount() {
    itemCount.value = items.fold(0, (sum, i) => sum + i.quantity);
  }
}

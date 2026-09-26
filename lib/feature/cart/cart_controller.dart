import 'package:get/get.dart';

import '../../model/cart_item_model.dart';
import '../../repository/order_repo.dart';
import '../../service/api_exception.dart';
import '../../service/cart_service.dart';
import '../../util/log_service.dart';

class CartController extends GetxController {
  final CartService cartService;
  final OrderRepo orderRepo;

  CartController({required this.cartService, required this.orderRepo});

  final isCheckingOut = false.obs;

  Future<void> checkout() async {
    if (cartService.items.isEmpty || isCheckingOut.value) return;
    isCheckingOut.value = true;
    try {
      // Holds that ran out, or would run out during the request, are
      // reserved again first. If something can't be held any more, stop and
      // let the user review the bag rather than buying a different set of
      // items than they saw.
      if (!await _holdEverything(renewAll: false)) return;
      try {
        await _submit();
      } on ApiException catch (e) {
        if (e.statusCode != 410) rethrow;
        // A hold lapsed server-side anyway (the 410 doesn't say which).
        // Checkout is rejected before payment, so it's safe to take fresh
        // holds on everything and retry once.
        LogService.error('checkout: reservation expired, retrying once', e);
        if (!await _holdEverything(renewAll: true)) return;
        await _submit();
      }
    } on ApiException catch (e) {
      LogService.error('checkout failed', e);
      _showCheckoutError(e);
    } finally {
      isCheckingOut.value = false;
    }
  }

  Future<void> _submit() async {
    final order = await orderRepo.checkout(cartService.items.toList());
    cartService.clear();
    Get.snackbar(
      'Order confirmed',
      'Order #${order.id} — pick up soon!',
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  /// Returns false (and tells the user) if some items couldn't be held.
  Future<bool> _holdEverything({required bool renewAll}) async {
    final lost = await cartService.ensureHolds(renewAll: renewAll);
    if (lost.isEmpty) return true;
    _showSoldOut(lost);
    return false;
  }

  void _showSoldOut(List<CartItemModel> lost) {
    final names = lost.map((l) => l.deal.name).join(', ');
    Get.snackbar(
      lost.length == 1 ? 'An item sold out' : 'Some items sold out',
      '$names ${lost.length == 1 ? 'was' : 'were'} removed from your bag. '
          'Nothing was charged — check your bag and tap Checkout again.',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 5),
    );
  }

  void _showCheckoutError(ApiException e) {
    final (title, message) = switch (e.statusCode) {
      410 => (
          'Your reservation ran out',
          'We couldn\'t hold your items long enough. Nothing was charged — '
              'please try again.'
        ),
      502 => (
          'Payment didn\'t go through',
          'You weren\'t charged. Please try again.'
        ),
      _ => ('Checkout failed', 'Something went wrong. Please try again.'),
    };
    Get.snackbar(title, message, snackPosition: SnackPosition.BOTTOM);
  }
}

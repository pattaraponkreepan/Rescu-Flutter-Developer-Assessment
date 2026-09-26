import 'package:get/get.dart';

import '../../model/deal_model.dart';
import '../../repository/deal_repo.dart';
import '../../service/analytics_service.dart';
import '../../service/cart_service.dart';
import '../../util/log_service.dart';

class DealDetailsController extends GetxController {
  final DealRepo dealRepo;
  final CartService cartService;
  final AnalyticsService analytics;

  DealDetailsController({
    required this.dealRepo,
    required this.cartService,
    required this.analytics,
  });

  /// Null until the deal is known: immediately when opened from a list, after
  /// a fetch when opened from a deep link.
  final _deal = Rxn<DealModel>();
  DealModel? get deal => _deal.value;

  final loadFailed = false.obs;
  int? _dealId;

  final _quantityLeft = RxnInt();
  int? get quantityLeft => _quantityLeft.value;

  late final Worker _cartWorker;

  @override
  void onInit() {
    super.onInit();
    // Lists pass the DealModel as an argument, but a deep link
    // (rescu://open/deal?id=42) only carries the id in the route, so the deal
    // has to be fetched.
    final args = Get.arguments;
    if (args is DealModel) {
      _dealId = args.id;
      _setDeal(args);
    } else {
      _dealId = int.tryParse(Get.parameters['id'] ?? '');
      loadDeal();
    }
    analytics.logEvent('deal_details_view', {
      'deal_id': _dealId,
      'source': Get.parameters['source'] ?? 'unknown',
    });
    // Whenever the cart changes, re-check this deal's remaining stock so the
    // details screen never shows stale availability.
    _cartWorker = ever(cartService.itemCount, (_) => _recheckAvailability());
  }

  @override
  void onClose() {
    // CartService outlives this screen; without this, the subscription keeps
    // the controller alive and re-fetches this deal on every future cart change.
    _cartWorker.dispose();
    super.onClose();
  }

  void _setDeal(DealModel deal) {
    _deal.value = deal;
    _quantityLeft.value = deal.quantityLeft;
  }

  Future<void> loadDeal() async {
    final id = _dealId;
    if (id == null) {
      LogService.error('deal route without a valid id: ${Get.parameters}');
      loadFailed.value = true;
      return;
    }
    loadFailed.value = false;
    try {
      _setDeal(await dealRepo.fetchById(id));
    } catch (e) {
      LogService.error('load deal $id failed', e);
      loadFailed.value = true;
    }
  }

  Future<void> _recheckAvailability() async {
    final id = _dealId;
    if (id == null) return;
    LogService.log('re-checking availability for deal $id');
    final fresh = await dealRepo.fetchById(id);
    _quantityLeft.value = fresh.quantityLeft;
  }

  void addToCart() {
    final deal = this.deal;
    if (deal == null) return;
    cartService.add(deal);
    Get.snackbar(
      'Added to bag',
      '${deal.name} — pick up ${deal.pickupWindow.label}',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }
}

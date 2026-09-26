import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pull_to_refresh/pull_to_refresh.dart';

import '../../model/deal_model.dart';
import '../../repository/deal_repo.dart';
import '../../util/log_service.dart';

class HomeController extends GetxController {
  final DealRepo dealRepo;

  HomeController({required this.dealRepo});

  final deals = <DealModel>[].obs;
  final flashDeals = <DealModel>[].obs;
  final isLoading = true.obs;
  final todayOnly = false.obs;
  // The UI only cares whether the feed is past these thresholds, not the exact
  // offset. RxBool only notifies when the value flips, so scrolling doesn't
  // trigger a rebuild per pixel.
  final isScrolled = false.obs;
  final showScrollToTop = false.obs;

  final scrollController = ScrollController();
  final refreshController = RefreshController();

  int _page = 1;
  int _totalPages = 1;
  bool _isFetchingMore = false;

  /// Bumped whenever a refresh replaces the feed. A page request started
  /// before that belongs to the old feed and must not be applied to the new one.
  int _feedGeneration = 0;

  bool get hasMore => _page < _totalPages;

  List<DealModel> get visibleDeals => todayOnly.value
      ? deals.where((d) => d.pickupWindow.isToday).toList()
      : deals.toList();

  @override
  void onInit() {
    super.onInit();
    scrollController.addListener(_onScroll);
    _initialLoad();
  }

  void _onScroll() {
    final offset = scrollController.offset;
    isScrolled.value = offset > 4;
    showScrollToTop.value = offset > 800;
  }

  Future<void> _initialLoad() async {
    isLoading.value = true;
    try {
      await Future.wait([refreshDeals(), _loadFlashDeals()]);
    } catch (e) {
      LogService.error('initial load failed', e);
    }
    isLoading.value = false;
  }

  Future<void> _loadFlashDeals() async {
    flashDeals.assignAll(await dealRepo.fetchFlashDeals());
  }

  Future<void> refreshDeals() async {
    final res = await dealRepo.fetchDeals(page: 1);
    // The feed is being replaced: a page still in flight was requested for the
    // old feed, so it will be dropped. End its footer spinner here since it won't.
    _feedGeneration++;
    if (_isFetchingMore) {
      _isFetchingMore = false;
      refreshController.loadComplete();
    }
    _page = 1;
    _totalPages = res.totalPages;
    deals.assignAll(res.items);
    refreshController.refreshCompleted();
  }

  Future<void> loadMore() async {
    if (_isFetchingMore) return;
    if (!hasMore) {
      refreshController.loadNoData();
      return;
    }
    final generation = _feedGeneration;
    final nextPage = _page + 1;
    _isFetchingMore = true;
    try {
      final res = await dealRepo.fetchDeals(page: nextPage);
      if (generation != _feedGeneration) return;
      _page = nextPage;
      _totalPages = res.totalPages;
      deals.addAll(res.items);
    } catch (e) {
      if (generation != _feedGeneration) return;
      LogService.error('loadMore failed', e);
    }
    _isFetchingMore = false;
    refreshController.loadComplete();
  }

  void scrollToTop() {
    scrollController.animateTo(0,
        duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
  }

  @override
  void onClose() {
    scrollController.dispose();
    refreshController.dispose();
    super.onClose();
  }
}

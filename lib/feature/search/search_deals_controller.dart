import 'package:get/get.dart';

import '../../model/deal_model.dart';
import '../../repository/deal_repo.dart';
import '../../util/log_service.dart';

class SearchDealsController extends GetxController {
  final DealRepo dealRepo;

  SearchDealsController({required this.dealRepo});

  final results = <DealModel>[].obs;
  final isLoading = false.obs;
  final hasSearched = false.obs;
  
  int _latestRequestId = 0;

  void onQueryChanged(String query) {
    _search(query);
  }

  Future<void> _search(String query) async {
    final requestId = ++_latestRequestId;
    if (query.trim().isEmpty) {
      results.clear();
      hasSearched.value = false;
      isLoading.value = false;
      return;
    }
    isLoading.value = true;
    hasSearched.value = true;
    try {
      final found = await dealRepo.search(query);
      if (requestId != _latestRequestId) return;
      results.assignAll(found);
    } catch (e) {
      if (requestId != _latestRequestId) return;
      LogService.error('search failed', e);
    }
    isLoading.value = false;
  }
}

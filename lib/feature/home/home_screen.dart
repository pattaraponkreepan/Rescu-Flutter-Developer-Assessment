import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pull_to_refresh/pull_to_refresh.dart';

import '../../app_config.dart';
import '../../routes/routes.dart';
import '../shared_widget/deal_card.dart';
import '../shared_widget/deal_impression.dart';
import '../shared_widget/shimmer_deal_card.dart';
import 'home_controller.dart';
import 'widget/flash_deals_section.dart';

class HomeScreen extends GetView<HomeController> {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Each Obx wraps only what depends on its observables, so scrolling (which
    // only flips isScrolled / showScrollToTop) never rebuilds the feed.
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Obx(() => AppBar(
              elevation: controller.isScrolled.value ? 2 : 0,
              shadowColor: Colors.black26,
              title: const Row(
                children: [
                  Icon(Icons.eco, color: AppConfig.primaryGreen),
                  SizedBox(width: 8),
                  Text('Rescu',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
                ],
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () => Get.toNamed(Routes.search),
                ),
                IconButton(
                  icon: const Icon(Icons.map_outlined),
                  onPressed: () => Get.toNamed(Routes.map),
                ),
                IconButton(
                  icon: const Icon(Icons.receipt_long_outlined),
                  onPressed: () => Get.toNamed(Routes.orders),
                ),
                IconButton(
                  icon: const Icon(Icons.shopping_bag_outlined),
                  onPressed: () => Get.toNamed(Routes.cart),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'deeplink') _showDeepLinkDialog(context);
                    if (value == 'analytics') {
                      Get.toNamed(Routes.analyticsDebug);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                        value: 'deeplink', child: Text('Simulate deep link…')),
                    PopupMenuItem(
                        value: 'analytics', child: Text('Analytics debug')),
                  ],
                ),
              ],
            )),
      ),
      body: Obx(() {
        if (controller.isLoading.value) {
          return ListView(
            children: const [
              ShimmerDealCard(),
              ShimmerDealCard(),
              ShimmerDealCard(),
            ],
          );
        }
        // Read every observable here, inside Obx's scope: the item builder
        // below runs lazily during layout, where reads aren't tracked.
        final flashDeals = controller.flashDeals.toList();
        final todayOnly = controller.todayOnly.value;
        final deals = controller.visibleDeals;
        final hasFlash = flashDeals.isNotEmpty;
        final headerCount = hasFlash ? 2 : 1;
        return SmartRefresher(
          controller: controller.refreshController,
          enablePullDown: true,
          enablePullUp: true,
          onRefresh: controller.refreshDeals,
          onLoading: controller.loadMore,
          // Builder, not a children list: only cards near the viewport are
          // created, instead of every loaded deal on each rebuild.
          child: ListView.builder(
            controller: controller.scrollController,
            itemCount: headerCount + deals.length + 1,
            itemBuilder: (context, index) {
              if (hasFlash && index == 0) {
                return FlashDealsSection(deals: flashDeals);
              }
              if (index == headerCount - 1) {
                return _NearbyHeader(
                  todayOnly: todayOnly,
                  onTodayOnlyChanged: (v) => controller.todayOnly.value = v,
                );
              }
              if (index == headerCount + deals.length) {
                return const SizedBox(height: 24);
              }
              final position = index - headerCount;
              final deal = deals[position];
              return DealImpression(
                deal: deal,
                source: 'home_feed',
                position: position,
                child: DealCard(deal: deal),
              );
            },
          ),
        );
      }),
      floatingActionButton: Obx(() => controller.showScrollToTop.value
          ? FloatingActionButton.small(
              onPressed: controller.scrollToTop,
              child: const Icon(Icons.arrow_upward),
            )
          : const SizedBox.shrink()),
    );
  }

  void _showDeepLinkDialog(BuildContext context) {
    final textController =
        TextEditingController(text: 'rescu://open/deal?id=42&source=push');
    Get.dialog(
      AlertDialog(
        title: const Text('Simulate deep link'),
        content: TextField(
          controller: textController,
          decoration: const InputDecoration(
            helperText: 'e.g. rescu://open/deal?id=42&source=push',
          ),
        ),
        actions: [
          TextButton(onPressed: Get.back, child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final uri = Uri.tryParse(textController.text.trim());
              Get.back();
              if (uri == null) return;
              final route = uri.hasQuery
                  ? '${uri.path}?${uri.query}'
                  : uri.path;
              Get.toNamed(route);
            },
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }
}

class _NearbyHeader extends StatelessWidget {
  final bool todayOnly;
  final ValueChanged<bool> onTodayOnlyChanged;

  const _NearbyHeader({
    required this.todayOnly,
    required this.onTodayOnlyChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          const Text('Nearby deals',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          const Spacer(),
          FilterChip(
            label: const Text('Pickup today'),
            selected: todayOnly,
            onSelected: onTodayOnlyChanged,
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app_config.dart';
import '../../model/deal_model.dart';
import '../shared_widget/countdown.dart';
import '../shared_widget/the_network_image.dart';
import 'deal_details_controller.dart';

class DealDetailsScreen extends GetView<DealDetailsController> {
  const DealDetailsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final deal = controller.deal;
      if (deal == null) {
        // Opened from a deep link: the deal is still being fetched.
        return Scaffold(
          appBar: AppBar(),
          body: Center(
            child: controller.loadFailed.value
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text("Couldn't load this deal."),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: controller.loadDeal,
                        child: const Text('Try again'),
                      ),
                    ],
                  )
                : const CircularProgressIndicator(),
          ),
        );
      }
      return _buildDeal(deal);
    });
  }

  Widget _buildDeal(DealModel deal) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 240,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background:
                  TheNetworkImage(url: deal.imageUrl, fit: BoxFit.cover),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(deal.name,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(deal.storeName,
                      style: TextStyle(
                          fontSize: 15, color: Colors.grey.shade700)),
                  Text(deal.storeAddress,
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade500)),
                  if (deal.isFlashSale) ...[
                    const SizedBox(height: 12),
                    _FlashSaleBanner(endsAt: deal.flashSaleEndsAt!),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text('฿${deal.price.toStringAsFixed(0)}',
                          style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: AppConfig.primaryGreen)),
                      const SizedBox(width: 8),
                      Text('฿${deal.originalPrice.toStringAsFixed(0)}',
                          style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey.shade500,
                              decoration: TextDecoration.lineThrough)),
                      const Spacer(),
                      Obx(() => Chip(
                            avatar: const Icon(Icons.inventory_2_outlined,
                                size: 16),
                            label: Text('${controller.quantityLeft ?? '-'} left'),
                          )),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE0E5E2)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.schedule,
                            color: AppConfig.primaryGreen),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Pickup window',
                                style: TextStyle(
                                    fontSize: 13, color: Colors.grey)),
                            Text(
                              '${deal.pickupWindow.label}'
                              '${deal.pickupWindow.isToday ? ' · today' : ''}',
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        const Spacer(),
                        if (deal.pickupWindow.isOpenNow)
                          const Chip(
                            label: Text('Open now'),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('What you get',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text(deal.description,
                      style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: Colors.grey.shade800)),
                  if (deal.tags.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: deal.tags
                          .map((t) => Chip(
                                label: Text(t),
                                visualDensity: VisualDensity.compact,
                              ))
                          .toList(),
                    ),
                  ],
                  const SizedBox(height: 100),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomSheet: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        color: Colors.white,
        child: SizedBox(
          width: double.infinity,
          child: ExpiryBuilder(
            endsAt: deal.flashSaleEndsAt,
            builder: (context, expired) => FilledButton.icon(
              onPressed: expired ? null : controller.addToCart,
              icon: const Icon(Icons.add_shopping_cart),
              label: Text(expired ? 'Flash sale ended' : 'Add to bag'),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Flash sale ends in 12:34", switching to "Flash sale ended" at zero.
class _FlashSaleBanner extends StatelessWidget {
  final DateTime endsAt;

  const _FlashSaleBanner({required this.endsAt});

  @override
  Widget build(BuildContext context) {
    return ExpiryBuilder(
      endsAt: endsAt,
      builder: (context, expired) {
        final color = expired ? Colors.grey.shade700 : Colors.red.shade700;
        final style = TextStyle(
            fontSize: 14, fontWeight: FontWeight.w600, color: color);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: expired ? Colors.grey.shade200 : Colors.red.shade50,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bolt, size: 18, color: color),
              const SizedBox(width: 4),
              if (expired)
                Text('Flash sale ended', style: style)
              else ...[
                Text('Flash sale ends in ', style: style),
                CountdownText(endsAt: endsAt, style: style),
              ],
            ],
          ),
        );
      },
    );
  }
}

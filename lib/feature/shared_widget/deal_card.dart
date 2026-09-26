import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app_config.dart';
import '../../model/deal_model.dart';
import '../../routes/routes.dart';
import 'countdown.dart';
import 'the_network_image.dart';

/// Deal card used in the home feed and search results.
class DealCard extends StatelessWidget {
  final DealModel deal;
  final String source;

  const DealCard({super.key, required this.deal, this.source = 'home'});

  @override
  Widget build(BuildContext context) {
    if (!deal.isFlashSale) return _buildCard(context, expired: false);
    // Rebuilds the card once, when the sale ends; the ticking countdown itself
    // only rebuilds its own Text.
    return ExpiryBuilder(
      endsAt: deal.flashSaleEndsAt,
      builder: (context, expired) => _buildCard(context, expired: expired),
    );
  }

  Widget _buildCard(BuildContext context, {required bool expired}) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      clipBehavior: Clip.antiAlias,
      color: Colors.white,
      elevation: 0.5,
      child: InkWell(
        // An ended flash deal is disabled: it can't be opened or added.
        onTap: expired
            ? null
            : () => Get.toNamed(
                  Routes.dealRoute(deal.id, source: source),
                  arguments: deal,
                ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                TheNetworkImage(url: deal.imageUrl, height: 160, width: double.infinity),
                if (expired)
                  Positioned.fill(
                    child: ColoredBox(
                        color: Colors.white.withValues(alpha: 0.6)),
                  ),
                if (deal.isFlashSale)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: FlashSaleBadge(
                        endsAt: deal.flashSaleEndsAt!, expired: expired),
                  ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${deal.quantityLeft} left',
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(deal.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(deal.storeName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5, color: Colors.grey.shade600)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.schedule,
                          size: 14, color: Colors.grey.shade600),
                      const SizedBox(width: 4),
                      Text('Pick up ${deal.pickupWindow.label}',
                          style: TextStyle(
                              fontSize: 12.5, color: Colors.grey.shade700)),
                      const Spacer(),
                      if (deal.rating != null) ...[
                        const Icon(Icons.star_rounded,
                            size: 15, color: Colors.amber),
                        Text(deal.rating!.toStringAsFixed(1),
                            style: const TextStyle(fontSize: 12.5)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text('฿${deal.price.toStringAsFixed(0)}',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: expired
                                  ? Colors.grey.shade500
                                  : AppConfig.primaryGreen)),
                      const SizedBox(width: 6),
                      Text('฿${deal.originalPrice.toStringAsFixed(0)}',
                          style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade500,
                              decoration: TextDecoration.lineThrough)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppConfig.primaryGreen.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('-${deal.discountPercent}%',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppConfig.primaryGreen)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

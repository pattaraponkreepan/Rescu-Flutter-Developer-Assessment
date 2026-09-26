import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app_config.dart';
import '../../model/cart_item_model.dart';
import '../../service/cart_service.dart';
import '../shared_widget/countdown.dart';
import '../shared_widget/the_network_image.dart';
import 'cart_controller.dart';

class CartScreen extends GetView<CartController> {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = controller.cartService;
    return Scaffold(
      appBar: AppBar(title: const Text('My bag')),
      body: Obx(() {
        if (cart.items.isEmpty) {
          return const Center(child: Text('Your bag is empty'));
        }
        final checkingOut = controller.isCheckingOut.value;
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: cart.items.length,
          itemBuilder: (context, index) {
            final item = cart.items[index];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: Colors.white,
              elevation: 0.5,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    TheNetworkImage(
                      url: item.deal.imageUrl,
                      width: 64,
                      height: 64,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.deal.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600)),
                          Text(item.deal.storeName,
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: Colors.grey.shade600)),
                          Text('฿${item.deal.price.toStringAsFixed(0)} each',
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppConfig.primaryGreen,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          _HoldStatus(item: item, cart: cart),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        // Locked during checkout so the bag can't change
                        // under the order being placed.
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: checkingOut
                              ? null
                              : () => cart.decrement(item.deal.id),
                        ),
                        Text('${item.quantity}',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed:
                              checkingOut ? null : () => cart.add(item.deal),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      }),
      bottomNavigationBar: Obx(() {
        if (cart.items.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          color: Colors.white,
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Total', style: TextStyle(fontSize: 13)),
                  Text('฿${cart.total.toStringAsFixed(0)}',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(width: 24),
              Expanded(
                child: FilledButton(
                  onPressed: controller.isCheckingOut.value
                      ? null
                      : controller.checkout,
                  child: controller.isCheckingOut.value
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Checkout'),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

/// How long this line is held for: "Reserving…", "Held for 04:32", or
/// "Reservation ran out" with a way to reserve again.
class _HoldStatus extends StatelessWidget {
  final CartItemModel item;
  final CartService cart;

  const _HoldStatus({required this.item, required this.cart});

  @override
  Widget build(BuildContext context) {
    final grey = TextStyle(fontSize: 12, color: Colors.grey.shade600);
    final hold = item.reservation;
    if (hold == null || hold.quantity != item.quantity) {
      return Text(hold == null ? 'Reserving…' : 'Updating reservation…',
          style: grey);
    }
    return ExpiryBuilder(
      endsAt: hold.expiresAt,
      builder: (context, lapsed) {
        if (lapsed) {
          // Wrap, not Row (here and below): next to the quantity buttons
          // there isn't always room on one line, e.g. with larger system
          // font sizes.
          return Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Reservation ran out',
                  style: grey.copyWith(color: Colors.orange.shade800)),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: () => cart.renewHold(item.deal.id),
                child: const Text('Reserve again'),
              ),
            ],
          );
        }
        return Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(Icons.lock_clock_outlined,
                size: 14, color: Colors.grey.shade600),
            const SizedBox(width: 4),
            Text('Held for ', style: grey),
            CountdownText(endsAt: hold.expiresAt, style: grey),
          ],
        );
      },
    );
  }
}

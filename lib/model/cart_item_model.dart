import 'deal_model.dart';
import 'reservation_model.dart';

class CartItemModel {
  final DealModel deal;
  int quantity;

  /// The server-side stock hold for this line, or null while the first
  /// reservation is still in flight. [quantity] is what the user sees
  /// (updated optimistically); this is what is actually held.
  ReservationModel? reservation;

  CartItemModel({required this.deal, this.quantity = 1, this.reservation});

  num get lineTotal => deal.price * quantity;

  /// Whether the server holds exactly [quantity], unexpired, at [now].
  bool isHeldAt(DateTime now) {
    final r = reservation;
    return r != null && r.quantity == quantity && !r.isExpiredAt(now);
  }
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rescu/feature/home/home_controller.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/model/paged_response_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/service/fake_api_service.dart';

const _pageSize = 20;
const _totalPages = 7;

DealModel _deal(int id) => DealModel.fromJson({
      'id': id,
      'name': 'Deal $id',
      'description': '',
      'imageUrl': 'https://example.com/$id.jpg',
      'originalPrice': 100,
      'price': 50,
      'currencyCode': 'THB',
      'quantityLeft': 3,
      'storeId': 1,
      'storeName': 'Store',
      'storeAddress': 'Bangkok',
      'lat': 13.75,
      'lng': 100.5,
      'rating': null,
      'tags': <String>[],
      'pickupWindow': {
        'start': '2026-01-01T10:00:00.000Z',
        'end': '2026-01-01T12:00:00.000Z',
      },
      'flashSaleEndsAt': null,
    });

PagedResponseModel<DealModel> _page(int page) => PagedResponseModel(
      items: List.generate(
          _pageSize, (i) => _deal((page - 1) * _pageSize + i + 1)),
      page: page,
      totalPages: _totalPages,
    );

/// A DealRepo whose page requests stay pending until the test completes them,
/// so the test decides the order in which responses arrive.
class _ControlledDealRepo extends DealRepo {
  _ControlledDealRepo() : super(api: FakeApiService());

  final requests = <({int page, Completer<PagedResponseModel<DealModel>> c})>[];

  @override
  Future<PagedResponseModel<DealModel>> fetchDeals({int page = 1}) {
    final c = Completer<PagedResponseModel<DealModel>>();
    requests.add((page: page, c: c));
    return c.future;
  }

  void respond(int index) =>
      requests[index].c.complete(_page(requests[index].page));

  void fail(int index) => requests[index].c.completeError(Exception('500'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ControlledDealRepo repo;
  late HomeController controller;

  List<int> ids() => controller.deals.map((d) => d.id).toList();

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    repo = _ControlledDealRepo();
    controller = HomeController(dealRepo: repo);
    // Feed shows page 1.
    final first = controller.refreshDeals();
    repo.respond(0);
    await first;
  });

  test('refresh while the next page is loading does not duplicate deals',
      () async {
    // Scroll to the bottom: page 2 starts loading...
    final load = controller.loadMore();
    // ...and the user pulls to refresh before it returns.
    final refresh = controller.refreshDeals();

    repo.respond(2); // the refresh's page 1 arrives first
    await refresh;
    repo.respond(1); // then the stale page 2 from before the refresh
    await load;

    expect(ids(), List.generate(20, (i) => i + 1),
        reason: 'the stale page 2 must not be appended to the fresh feed');

    // Keep scrolling: the next page after a refresh is page 2 again.
    final next = controller.loadMore();
    await settle();
    expect(repo.requests.last.page, 2);
    repo.respond(3);
    await next;

    expect(ids(), List.generate(40, (i) => i + 1));
    expect(ids().toSet().length, ids().length, reason: 'no duplicate cards');
  });

  test('a page that lands before the refresh is replaced by the refresh',
      () async {
    final load = controller.loadMore();
    final refresh = controller.refreshDeals();

    repo.respond(1); // page 2 arrives while the refresh is still in flight
    await load;
    repo.respond(2);
    await refresh;

    expect(ids(), List.generate(20, (i) => i + 1));

    final next = controller.loadMore();
    await settle();
    expect(repo.requests.last.page, 2);
    repo.respond(3);
    await next;

    expect(ids(), List.generate(40, (i) => i + 1));
  });

  test('a stale page failing after a refresh does not rewind pagination',
      () async {
    final load = controller.loadMore();
    final refresh = controller.refreshDeals();

    repo.respond(2);
    await refresh;
    repo.fail(1);
    await load;

    final next = controller.loadMore();
    await settle();
    expect(repo.requests.last.page, 2,
        reason: 'must not re-request page 1 and duplicate it');
    repo.respond(3);
    await next;

    expect(ids(), List.generate(40, (i) => i + 1));
  });
}

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'app_config.dart';
import 'repository/deal_repo.dart';
import 'repository/order_repo.dart';
import 'repository/store_repo.dart';
import 'routes/routes.dart';
import 'service/analytics_service.dart';
import 'service/cart_service.dart';
import 'service/clock_service.dart';
import 'service/fake_api_service.dart';
import 'service/impression_tracker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initDependencies();
  runApp(const RescuApp());
}

Future<void> initDependencies() async {
  await Get.putAsync(() => FakeApiService().init(), permanent: true);
  Get.put(AnalyticsService(), permanent: true);
  Get.put(ImpressionTracker(), permanent: true);
  // Visibility callbacks are throttled to this interval (default 500 ms). The
  // impression rule needs 1 s of continuous visibility, so a coarse interval
  // could count a card seen for only ~0.6 s; 100 ms keeps the error small.
  VisibilityDetectorController.instance.updateInterval =
      const Duration(milliseconds: 100);
  Get.put(ClockService(), permanent: true);
  Get.put(CartService(), permanent: true);
  Get.lazyPut(() => DealRepo(api: Get.find()), fenix: true);
  Get.lazyPut(() => StoreRepo(api: Get.find()), fenix: true);
  Get.lazyPut(() => OrderRepo(api: Get.find()), fenix: true);
}

class RescuApp extends StatelessWidget {
  const RescuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: AppConfig.theme,
      initialRoute: Routes.home,
      getPages: Routes.pages,
    );
  }
}

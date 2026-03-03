import 'dart:io';
import 'dart:ui';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'logger.dart';

class AppReferDeviceInfo {
  final AppReferLogger _logger;

  AppReferDeviceInfo({required AppReferLogger logger}) : _logger = logger;

  Future<Map<String, dynamic>> getDeviceInfo() async {
    try {
      final deviceInfoPlugin = DeviceInfoPlugin();
      final packageInfo = await PackageInfo.fromPlatform();
      final locale = PlatformDispatcher.instance.locale;
      final timezone = DateTime.now().timeZoneName;

      final info = <String, dynamic>{
        'app_version': packageInfo.version,
        'app_build': packageInfo.buildNumber,
        'bundle_id': packageInfo.packageName,
        'locale': locale.toString(),
        'timezone': timezone,
      };

      if (Platform.isIOS) {
        final iosInfo = await deviceInfoPlugin.iosInfo;
        info.addAll({
          'platform': 'ios',
          'os_version': iosInfo.systemVersion,
          'model': iosInfo.utsname.machine,
          'device_name': iosInfo.name,
          'is_physical_device': iosInfo.isPhysicalDevice,
        });
      } else if (Platform.isAndroid) {
        final androidInfo = await deviceInfoPlugin.androidInfo;
        info.addAll({
          'platform': 'android',
          'os_version': androidInfo.version.release,
          'sdk_int': androidInfo.version.sdkInt,
          'model': androidInfo.model,
          'manufacturer': androidInfo.manufacturer,
          'is_physical_device': androidInfo.isPhysicalDevice,
        });
      }

      return info;
    } catch (e) {
      _logger.error('Failed to collect device info: $e');
      return {'platform': Platform.isIOS ? 'ios' : 'android'};
    }
  }
}

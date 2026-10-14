import 'dart:developer' as developer;

class AppReferLogger {
  final bool _debugEnabled;
  final int logLevel;

  static const _tag = '[AppRefer]';

  const AppReferLogger({
    bool debug = false,
    this.logLevel = 1,
  }) : _debugEnabled = debug;

  void error(String message) {
    if (_debugEnabled && logLevel >= 1) {
      developer.log('$_tag ERROR: $message', name: 'AppRefer');
    }
  }

  void warn(String message) {
    if (_debugEnabled && logLevel >= 2) {
      developer.log('$_tag WARN: $message', name: 'AppRefer');
    }
  }

  void info(String message) {
    if (_debugEnabled && logLevel >= 3) {
      developer.log('$_tag INFO: $message', name: 'AppRefer');
    }
  }

  void debug(String message) {
    if (_debugEnabled && logLevel >= 3) {
      developer.log('$_tag DEBUG: $message', name: 'AppRefer');
    }
  }
}

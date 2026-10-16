import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/device_info.dart';
import '../services/registry.dart';
import '../services/logger.dart';
import 'support_api.dart';
import 'support_style.dart';

export 'support_api.dart' show AppReferSupportPersona;

/// Shared support configuration and presentation API.
class AppReferSupport {
  AppReferSupport._();
  static final instance = AppReferSupport._();
  final SupportAPI api = SupportAPI();
  final ValueNotifier<int> accountGeneration = ValueNotifier(0);
  Route<void>? _presented;
  NavigatorState? _presentingNavigator;
  void configure({required String apiKey}) {
    AppReferRegistry.apiKey = apiKey;
  }

  Future<void> reset() async {
    final route = _presented;
    if (route != null && route.isActive)
      _presentingNavigator?.removeRoute(route);
    _presented = null;
    await api.reset();
    accountGeneration.value++;
  }

  /// Set this to the host MaterialApp navigatorKey for context-free push routing.
  GlobalKey<NavigatorState>? navigatorKey;

  /// Bubble and button colour. Defaults to the host theme's primary colour.
  Color? accentColor;

  /// Hero title. Defaults to "<App name> support".
  String? title;

  /// How fast the team usually answers, completing "We usually reply in …".
  String replyTime = 'under an hour';

  /// First names of the people who answer (e.g. `['Jay']`), shown on the help home.
  List<String> teamNames = const [];

  /// The quick-help tiles on the home screen. Empty hides them.
  List<AppReferSupportTopic> topics = AppReferSupportTopic.defaults;

  /// The icon on the home screen. Defaults to the app's launcher icon.
  ImageProvider? appIcon;

  Future<Uint8List?>? _launcherIcon;
  Future<Uint8List?> launcherIcon() => _launcherIcon ??= supportChannel
      .invokeMethod<Uint8List>('appIcon')
      .then<Uint8List?>((v) => v, onError: (_) => null);

  Future<void> identify({String? name, String? email}) async {
    api.name = name?.trim().isEmpty == true ? null : name?.trim();
    api.email = email?.trim().isEmpty == true ? null : email?.trim();
    await api.ensureSession();
  }

  Future<void> open({BuildContext? context, String? conversationId}) =>
      _present(context, AppReferSupportView(conversationId: conversationId));

  /// Opens the help home with the message field pre-filled and focused.
  Future<void> compose(String prefill, {BuildContext? context}) =>
      _present(context, AppReferSupportView(composing: prefill));
  Future<void> _present(BuildContext? context, Widget view) async {
    final nav = context == null
        ? navigatorKey?.currentState
        : Navigator.of(context);
    if (nav == null) {
      throw StateError('Pass context or set AppRefer.support.navigatorKey.');
    }
    final route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => view,
    );
    _presented = route;
    _presentingNavigator = nav;
    await nav.push(route);
    if (identical(_presented, route)) _presented = null;
  }

  Future<void> registerPushToken(
    String token, {
    String environment = 'production',
  }) async {
    await supportChannel.invokeMethod<void>('notificationChannel');
    await api.call('POST', '/push-token', {
      'platform': Platform.isIOS ? 'ios' : 'android',
      'token': token,
      'environment': environment,
    });
    await api.write('support_${AppReferRegistry.apiKey}.push', token);
  }

  Future<void> removePushToken(String token) async {
    await api.call('DELETE', '/push-token', {'token': token});
    await api.write('support_${AppReferRegistry.apiKey}.push', null);
  }

  bool handleNotification(Map<String, dynamic> data, {BuildContext? context}) {
    final payload = data['apprefer'] is Map
        ? Map<String, dynamic>.from(data['apprefer'])
        : data;
    if (payload['type'] != 'support_reply') return false;
    unawaited(
      open(
        context: context,
        conversationId: payload['conversationId'] as String?,
      ),
    );
    return true;
  }

  Future<int> unreadCount() async => (await api.conversations()).fold<int>(
    0,
    (n, c) => n + (c['unread'] as int? ?? 0),
  );
}

/// A quick-help tile on the home screen. Tapping it starts a message on that
/// topic (the title becomes the conversation subject), or runs [action]
/// instead (e.g. your own restore-purchases flow).
class AppReferSupportTopic {
  const AppReferSupportTopic({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.tint,
    required this.prompt,
    this.action,
  });
  final String title, subtitle;
  final IconData icon;
  final Color tint;

  /// The hint in the message field once the tile is picked.
  final String prompt;
  final VoidCallback? action;

  static const billing = AppReferSupportTopic(
    title: 'Billing & refunds',
    subtitle: 'Charges, plans, receipts',
    icon: Icons.credit_card_rounded,
    tint: Color(0xff6e4aff),
    prompt: 'What happened with the charge?',
  );
  static const restore = AppReferSupportTopic(
    title: 'Restore purchase',
    subtitle: 'Get your plan back',
    icon: Icons.refresh_rounded,
    tint: Color(0xff2e8ffa),
    prompt: 'Which plan did you buy, and on which account?',
  );
  static const bug = AppReferSupportTopic(
    title: 'Report a bug',
    subtitle: 'Screenshots welcome',
    icon: Icons.bug_report_rounded,
    tint: Color(0xfff04554),
    prompt: 'What went wrong? A screenshot helps.',
  );
  static const idea = AppReferSupportTopic(
    title: 'Suggest an idea',
    subtitle: 'We read every one',
    icon: Icons.lightbulb_rounded,
    tint: Color(0xff1fb866),
    prompt: 'What would make the app better for you?',
  );
  static const defaults = [billing, restore, bug, idea];
}

/// Embeddable help chat: the home and conversations.
class AppReferSupportView extends StatefulWidget {
  const AppReferSupportView({
    super.key,
    this.conversationId,
    this.composing,
    this.api,
  });
  final String? conversationId;

  /// Opens the home with the message field pre-filled and focused.
  final String? composing;
  final SupportAPI? api;
  @override
  State<AppReferSupportView> createState() => _SupportViewState();
}

class _Pending {
  _Pending(this.text, this.images, this.conversation, {this.subject});
  final String clientMessageId = newSupportMessageId();
  final String text;
  final String? conversation, subject;
  bool inFlight = false;
  final List<Uint8List> images;
  bool failed = false;
  final List<String> ids = [];
}

bool _sameImages(List<Uint8List> a, List<Uint8List> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => identical(a[i], b[i])).every((x) => x);

class _SupportViewState extends State<AppReferSupportView>
    with WidgetsBindingObserver {
  final homeText = TextEditingController(),
      threadText = TextEditingController();
  final homeFocus = FocusNode(), threadFocus = FocusNode();
  final homeScroll = ScrollController(), scroll = ScrollController();
  final config = AppReferSupport.instance;
  late final SupportAPI api = widget.api ?? config.api;
  String? id, pollCursor;
  int generation = 0;
  _Pending? firstSend;
  AppReferSupportTopic? topic;
  String appName = 'App', sendError = '', loadError = '';
  MemoryImage? launcherImage;
  late final Future<void> metadataReady;
  Map<String, dynamic> metadata = {
    'appVersion': 'unknown',
    'device': 'unknown',
    'os': Platform.operatingSystemVersion,
    'platform': Platform.isIOS ? 'ios' : 'android',
    'locale': PlatformDispatcher.instance.locale.toString(),
  };
  List<Map<String, dynamic>> conversations = [], messages = [];
  List<Uint8List> homeImages = [], threadImages = [];
  final List<_Pending> pending = [];
  bool sending = false, loading = true, refreshing = false, active = true;
  double composerHeight = 90;
  Timer? timer;
  late SupportPalette palette;
  late SupportColors colors;
  ThemeData? _theme;
  Object? _themeKey;
  String get title => config.title ?? '$appName support';

  /// The app's AI assistant, as last seen from AppRefer.
  AppReferSupportPersona? get _persona => api.persona.value;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    id = widget.conversationId;
    homeText.text = widget.composing ?? '';
    homeText.addListener(_changed);
    threadText.addListener(_changed);
    api.persona.addListener(_changed);
    config.accountGeneration.addListener(_accountReset);
    metadataReady = _context();
    config.launcherIcon().then((bytes) {
      if (mounted && bytes != null && bytes.isNotEmpty) {
        setState(() => launcherImage = MemoryImage(bytes));
      }
    });
    if (widget.composing != null && id == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) homeFocus.requestFocus();
      });
    }
    _refresh();
    _timer();
  }

  void _accountReset() {
    if (!mounted) return;
    timer?.cancel();
    generation++;
    setState(() {
      id = null;
      pollCursor = null;
      firstSend = null;
      topic = null;
      conversations = [];
      messages = [];
      homeImages = [];
      threadImages = [];
      pending.clear();
      homeText.clear();
      threadText.clear();
      sending = false;
      loading = false;
      refreshing = false;
      sendError = '';
      loadError = '';
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _context() async {
    try {
      final p = await PackageInfo.fromPlatform();
      final d = await AppReferDeviceInfo(
        logger: AppReferLogger(debug: false),
      ).getDeviceInfo();
      if (mounted) {
        setState(() {
          appName = p.appName;
          metadata = {
            'appVersion': p.version,
            'device': d['model'] ?? 'unknown',
            'os':
                '${Platform.isIOS ? 'iOS' : 'Android'} ${d['os_version'] ?? ''}',
            'locale': PlatformDispatcher.instance.locale.toString(),
            'platform': Platform.isIOS ? 'ios' : 'android',
          };
        });
      }
    } catch (_) {
      /* Metadata is best effort. */
    }
  }

  void _timer() {
    timer?.cancel();
    if (active) {
      timer = Timer.periodic(Duration(seconds: id == null ? 15 : 4), (_) {
        if (mounted &&
            TickerMode.valuesOf(context).enabled &&
            (ModalRoute.of(context)?.isCurrent ?? true)) {
          _refresh();
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    _timer();
    if (active) _refresh();
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    api.persona.removeListener(_changed);
    config.accountGeneration.removeListener(_accountReset);
    for (final c in [homeText, threadText]) {
      c.removeListener(_changed);
      c.dispose();
    }
    homeFocus.dispose();
    threadFocus.dispose();
    homeScroll.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (refreshing) return;
    refreshing = true;
    final current = id;
    final currentGeneration = generation;
    try {
      if (current == null) {
        final result = await api.conversations();
        result.sort((a, b) {
          final x = (a['status'] == 'closed' ? 1 : 0).compareTo(
            b['status'] == 'closed' ? 1 : 0,
          );
          return x != 0
              ? x
              : '${b['lastMessageAt']}'.compareTo('${a['lastMessageAt']}');
        });
        if (mounted && id == current && generation == currentGeneration) {
          setState(() => conversations = result);
        }
      } else {
        final result = await api.thread(current, after: pollCursor);
        if (mounted && id == current && generation == currentGeneration) {
          final count = messages.length;
          setState(() {
            for (final m in List<Map<String, dynamic>>.from(
              result['messages'],
            )) {
              final timestamp = m['createdAt'] as String?;
              if (timestamp != null &&
                  (pollCursor == null ||
                      timestamp.compareTo(pollCursor!) > 0)) {
                pollCursor = timestamp;
              }
              if (!messages.any((old) => old['id'] == m['id'])) messages.add(m);
            }
            messages.sort(
              (a, b) => '${a['createdAt']}'.compareTo('${b['createdAt']}'),
            );
          });
          if (messages.length != count) _bottom();
        }
      }
      if (mounted) setState(() => loadError = '');
    } catch (e) {
      if (mounted) setState(() => loadError = '$e');
    } finally {
      refreshing = false;
      if (mounted) {
        setState(() => loading = false);
        if (id != current) _refresh();
      }
    }
  }

  void _bottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients) {
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _openConversation(String conversation) {
    setState(() {
      generation++;
      pollCursor = null;
      messages = [];
      id = conversation;
      loading = true;
      loadError = '';
      threadText.clear();
      threadImages = [];
    });
    _timer();
    _refresh();
  }

  void _back() {
    if (id == null) {
      Navigator.maybePop(context);
      return;
    }
    setState(() {
      generation++;
      pollCursor = null;
      id = null;
      messages = [];
      loadError = '';
      threadText.clear();
      threadImages = [];
    });
    _timer();
    _refresh();
  }

  Future<void> _pick(bool home) async {
    final target = home ? homeImages : threadImages;
    if (target.length >= 4) return;
    try {
      final picked = await supportChannel.invokeListMethod<Uint8List>(
        'pick',
        4 - target.length,
      );
      if (!mounted) return;
      setState(() {
        final list = home ? homeImages : threadImages;
        list.addAll((picked ?? []).take(4 - list.length));
      });
    } catch (e) {
      if (mounted) setState(() => sendError = '$e');
    }
  }

  void _pickTopic(AppReferSupportTopic t) {
    if (t.action != null) {
      t.action!();
      return;
    }
    setState(() => topic = t);
    homeFocus.requestFocus();
  }

  /// Starts a conversation from the home; a retry reuses the clientMessageId.
  Future<void> _start() async {
    final body = homeText.text.trim();
    if (sending || (body.isEmpty && homeImages.isEmpty)) return;
    final subject = topic?.title;
    final currentGeneration = generation;
    final p =
        firstSend != null &&
            firstSend!.text == body &&
            firstSend!.subject == subject &&
            _sameImages(firstSend!.images, homeImages)
        ? firstSend!
        : _Pending(body, List.of(homeImages), null, subject: subject);
    firstSend = p;
    setState(() {
      sending = true;
      sendError = '';
    });
    try {
      p.ids.clear();
      for (final image in p.images) {
        p.ids.add(await api.upload(image));
      }
      // Device details are nice to have; never hold a message back for them.
      await metadataReady.timeout(const Duration(seconds: 2), onTimeout: () {});
      final result = await api.start(
        p.text,
        p.ids,
        metadata,
        clientMessageId: p.clientMessageId,
        subject: p.subject,
      );
      if (!mounted) return;
      setState(() {
        firstSend = null;
        if (homeText.text.trim() == p.text) homeText.clear();
        if (_sameImages(p.images, homeImages)) homeImages = [];
        if (topic?.title == p.subject) topic = null;
      });
      homeFocus.unfocus();
      if (generation != currentGeneration || id != null) {
        // The customer moved on meanwhile: the message is sent, don't jump.
        if (id == null) _refresh();
        return;
      }
      setState(() {
        generation++;
        pollCursor = null;
        id = result['conversation']['id'] as String;
        messages = List<Map<String, dynamic>>.from(result['messages']);
        loading = false;
        threadText.clear();
        threadImages = [];
      });
      _timer();
      _bottom();
    } catch (e) {
      if (mounted) setState(() => sendError = '$e');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> _sendThread([String? quick]) async {
    final conversation = id;
    final body = quick ?? threadText.text.trim();
    final images = quick == null ? List.of(threadImages) : <Uint8List>[];
    if (conversation == null || (body.isEmpty && images.isEmpty)) return;
    final p = _Pending(body, images, conversation);
    setState(() {
      pending.add(p);
      if (quick == null) {
        threadText.clear();
        threadImages = [];
      }
    });
    _bottom();
    await _deliver(p, conversation);
  }

  Future<void> _deliver(_Pending p, String conversation) async {
    if (p.inFlight) return;
    p.inFlight = true;
    setState(() => p.failed = false);
    try {
      p.ids.clear();
      while (p.ids.length < p.images.length) {
        p.ids.add(await api.upload(p.images[p.ids.length]));
      }
      final m = await api.send(
        conversation,
        p.text,
        p.ids,
        clientMessageId: p.clientMessageId,
      );
      if (mounted) {
        setState(() {
          pending.remove(p);
          if (id == conversation &&
              !messages.any((old) => old['id'] == m['id'])) {
            messages.add(m);
          }
          sendError = '';
        });
      }
      _bottom();
    } catch (e) {
      if (mounted) {
        setState(() {
          p.failed = true;
          sendError = '$e';
        });
      }
    } finally {
      p.inFlight = false;
    }
  }

  // MARK: Formatting

  DateTime? _date(dynamic value) => DateTime.tryParse('$value')?.toLocal();
  String _clock(DateTime date) =>
      MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(date),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      );
  String _time(dynamic value) {
    final date = _date(value);
    if (date == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final label = day == today
        ? 'Today'
        : day == today.subtract(const Duration(days: 1))
        ? 'Yesterday'
        : MaterialLocalizations.of(context).formatShortDate(date);
    return '$label, ${_clock(date)}';
  }

  // MARK: Shared pieces

  List<BoxShadow> _shadow(double opacity, double blur, double y) => [
    BoxShadow(
      color: SupportColors.shadow.withValues(alpha: opacity),
      blurRadius: blur,
      offset: Offset(0, y),
    ),
  ];

  Widget _button(
    String label,
    VoidCallback? onTap,
    Widget child, {
    ShapeBorder shape = const CircleBorder(),
  }) => Tooltip(
    message: label,
    excludeFromSemantics: true,
    child: Semantics(
      button: true,
      label: label,
      enabled: onTap != null,
      child: Material(
        type: MaterialType.transparency,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, customBorder: shape, child: child),
      ),
    ),
  );

  /// Translucent bar: blurred backdrop under a card-coloured wash.
  Widget _glass({
    required double radius,
    required Widget child,
    List<BoxShadow>? shadow,
  }) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      boxShadow: shadow,
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.card.withValues(alpha: colors.dark ? 0.8 : 0.85),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: colors.dark
                  ? Colors.white.withValues(alpha: 0.07)
                  : Colors.white.withValues(alpha: 0.6),
            ),
          ),
          child: child,
        ),
      ),
    ),
  );

  Widget _label(String text) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.6,
      color: colors.muted,
    ),
  );

  Widget _badgeOrTime(Map<String, dynamic> c) {
    final unread = c['unread'] as int? ?? 0;
    if (unread > 0) {
      return Semantics(
        label: '$unread unread',
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: ShapeDecoration(
            color: palette.accent,
            shape: const StadiumBorder(),
          ),
          child: Text(
            '$unread',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: palette.onAccent,
            ),
          ),
        ),
      );
    }
    return Text(
      _time(c['lastMessageAt']),
      style: TextStyle(fontSize: 12, color: colors.muted),
    );
  }

  Widget _errorLine(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: ShapeDecoration(
          color: colors.card,
          shape: const StadiumBorder(),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Color(0xffe5383b),
          ),
        ),
      ),
    ),
  );

  // MARK: Composer

  Widget _composer({required bool home, required List<Widget> above}) {
    final controller = home ? homeText : threadText;
    final images = home ? homeImages : threadImages;
    final busy = home && sending;
    final canSend =
        !busy && (controller.text.trim().isNotEmpty || images.isNotEmpty);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom + 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final w in above) ...[w, const SizedBox(height: 8)],
          if (images.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: _attachments(home, images, busy),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: _glass(
              radius: 29,
              shadow: _shadow(0.18, 20, 10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 7, 7, 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _button(
                      'Add screenshot',
                      busy || images.length >= 4 ? null : () => _pick(home),
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(
                          home ? Icons.photo_camera_rounded : Icons.add_rounded,
                          size: home ? 24 : 26,
                          color: colors.muted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        focusNode: home ? homeFocus : threadFocus,
                        minLines: 1,
                        maxLines: 5,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        cursorColor: palette.accent,
                        style: TextStyle(fontSize: 17, color: colors.primary),
                        decoration: InputDecoration(
                          isCollapsed: true,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 11,
                          ),
                          hintText: home
                              ? topic?.prompt ??
                                    (_persona == null
                                        ? 'Ask us anything…'
                                        : 'Message ${_persona!.name}…')
                              : 'Message',
                          hintMaxLines: 1,
                          hintStyle: TextStyle(
                            fontSize: 17,
                            color: colors.muted.withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _button(
                      'Send',
                      canSend ? (home ? _start : () => _sendThread()) : null,
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: canSend ? palette.bubble : null,
                          color: canSend
                              ? null
                              : Colors.grey.withValues(alpha: 0.3),
                        ),
                        child: busy
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: palette.onAccent,
                                ),
                              )
                            : Icon(
                                Icons.arrow_upward_rounded,
                                size: 24,
                                color: canSend
                                    ? palette.onAccent
                                    : Colors.white,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _attachments(bool home, List<Uint8List> images, bool busy) =>
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
          child: Row(
            children: [
              for (var i = 0; i < images.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 62,
                        height: 88,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.12),
                              blurRadius: 6,
                              offset: const Offset(0, 3),
                            ),
                          ],
                          image: DecorationImage(
                            image: MemoryImage(images[i]),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      Positioned(
                        top: -6,
                        right: -6,
                        child: _button(
                          'Remove screenshot',
                          busy
                              ? null
                              : () => setState(() {
                                  (home ? homeImages : threadImages).removeAt(
                                    i,
                                  );
                                }),
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black.withValues(alpha: 0.6),
                            ),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (images.length < 4)
                _button(
                  'Add another screenshot',
                  busy ? null : () => _pick(home),
                  Container(
                    width: 62,
                    height: 88,
                    decoration: BoxDecoration(
                      color: colors.card.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.add_rounded, color: palette.accent),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
            ],
          ),
        ),
      );

  // MARK: Home

  String get _greeting {
    final first = supportFirstName(api.name);
    return first == null ? 'Hi there 👋' : 'Hi $first 👋';
  }

  Widget _home() {
    final selection = supportContinueSelection(conversations);
    final current = selection.current;
    final topics = config.topics;
    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            controller: homeScroll,
            physics: const AlwaysScrollableScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _hero(),
                // Pulled up so the first card overlaps the hero's lower edge.
                Transform.translate(
                  offset: const Offset(0, -62),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 78),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final section in [
                          if (current != null) _continueCard(current),
                          if (topics.isNotEmpty)
                            _quickHelp(topics, labelled: current != null),
                          if (selection.others.isNotEmpty)
                            _pastConversations(selection.others),
                          if (loading && conversations.isEmpty)
                            const Center(child: CircularProgressIndicator()),
                          if (loadError.isNotEmpty && conversations.isEmpty)
                            Text(
                              loadError,
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.muted,
                              ),
                            ),
                        ]) ...[section, const SizedBox(height: 24)],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _composer(
            home: true,
            above: [
              if (sendError.isNotEmpty) _errorLine(sendError),
              if (topic != null) _topicChip(topic!),
            ],
          ),
        ),
      ],
    );
  }

  Widget _hero() {
    final on = palette.onAccent;
    return CustomPaint(
      painter: SupportHeroPainter(palette, homeScroll),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          22,
          MediaQuery.paddingOf(context).top + 18,
          22,
          88,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _appIcon(),
                const Spacer(),
                _button(
                  'Close',
                  () => Navigator.maybePop(context),
                  ClipOval(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: palette.darkOnAccent
                              ? Colors.black.withValues(alpha: 0.06)
                              : Colors.white.withValues(alpha: 0.24),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Icon(Icons.close_rounded, size: 22, color: on),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: on.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                _greeting,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 38,
                  height: 1.15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                  color: on,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'How can we help today?',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w500,
                color: on.withValues(alpha: 0.92),
              ),
            ),
            const SizedBox(height: 18),
            _presence(),
          ],
        ),
      ),
    );
  }

  Widget _appIcon() {
    final image = config.appIcon ?? launcherImage;
    final initials = appName.trim().isEmpty
        ? '•'
        : appName.trim().characters.take(2).toString().toUpperCase();
    return ExcludeSemantics(
      child: Container(
        width: 46,
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
          gradient: image == null
              ? const LinearGradient(
                  colors: [Color(0xff29205c), Color(0xff0f0a1f)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          image: image == null
              ? null
              : DecorationImage(image: image, fit: BoxFit.cover),
        ),
        child: image == null
            ? Text(
                initials,
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: palette.light,
                ),
              )
            : null,
      ),
    );
  }

  List<Color> _avatarColors(int i) => switch (i % 3) {
    0 => [palette.warm, palette.hot],
    1 => const [Color(0xff5cadff), Color(0xff2e73f2)],
    _ => const [Color(0xff4d4d4d), Color(0xff141414)],
  };

  Widget _presence() {
    final persona = _persona;
    final all = config.teamNames.where((n) => n.trim().isNotEmpty).toList();
    final names = all.take(persona == null ? 3 : 2).toList();
    final line = supportPresenceLine(
      persona: persona?.name,
      teamNames: all,
      replyTime: config.replyTime,
    );
    // The assistant comes first, then the team, overlapping by 8.
    final offset = persona == null ? 0 : 1;
    final count = names.length + offset;
    final on = palette.onAccent;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 7, 14, 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(
          alpha: palette.darkOnAccent ? 0.06 : 0.16,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: on.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28 + 20.0 * (count == 0 ? 0 : count - 1),
            height: 28,
            child: Stack(
              clipBehavior: Clip.none,
              children: count == 0
                  ? [
                      SupportAvatar(
                        size: 28,
                        colors: [palette.warm, palette.hot],
                        icon: Icons.chat_bubble_rounded,
                        ring: true,
                      ),
                    ]
                  : [
                      for (var i = names.length - 1; i >= 0; i--)
                        Positioned(
                          left: 20.0 * (i + offset),
                          child: SupportAvatar(
                            name: names[i],
                            size: 28,
                            colors: _avatarColors(i),
                            ring: true,
                          ),
                        ),
                      if (persona != null)
                        Positioned(
                          left: 0,
                          child: SupportAvatar(
                            name: persona.name,
                            size: 28,
                            colors: [palette.warm, palette.hot],
                            imageUrl: persona.avatarUrl,
                            ring: true,
                          ),
                        ),
                    ],
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              line,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: on,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _continueCard(Map<String, dynamic> c) {
    final firstTeam = config.teamNames.where((n) => n.trim().isNotEmpty);
    final persona = c['lastFrom'] == 'bot' ? _persona : null;
    return _Pressable(
      onTap: () => _openConversation(c['id'] as String),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(26),
          boxShadow: _shadow(0.22, 22, 14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _label('Continue'),
            const SizedBox(height: 12),
            Row(
              children: [
                if (persona != null)
                  SupportAvatar(
                    name: persona.name,
                    size: 46,
                    colors: [palette.warm, palette.hot],
                    imageUrl: persona.avatarUrl,
                  )
                else
                  SupportAvatar(
                    name: firstTeam.firstOrNull,
                    size: 46,
                    colors: [palette.warm, palette.hot],
                    icon: firstTeam.isEmpty ? Icons.forum_rounded : null,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${c['subject'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        c['lastFrom'] == 'customer'
                            ? 'You: ${c['preview'] ?? ''}'
                            : '${c['preview'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: colors.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                _badgeOrTime(c),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickHelp(
    List<AppReferSupportTopic> topics, {
    required bool labelled,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (labelled) ...[
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: _label('Quick help'),
        ),
        const SizedBox(height: 10),
      ],
      for (var i = 0; i < topics.length; i += 2) ...[
        if (i > 0) const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _tile(topics[i])),
            const SizedBox(width: 10),
            Expanded(
              child: i + 1 < topics.length
                  ? _tile(topics[i + 1])
                  : const SizedBox(),
            ),
          ],
        ),
      ],
    ],
  );

  Widget _tile(AppReferSupportTopic t) => _Pressable(
    onTap: () => _pickTopic(t),
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(20),
        boxShadow: _shadow(0.07, 10, 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: t.tint.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(t.icon, size: 19, color: t.tint),
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              t.title,
              maxLines: 1,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: colors.primary,
              ),
            ),
          ),
          Text(
            t.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: colors.muted),
          ),
        ],
      ),
    ),
  );

  Widget _pastConversations(List<Map<String, dynamic>> others) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 6),
        child: _label('Your conversations'),
      ),
      const SizedBox(height: 10),
      DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: _shadow(0.07, 10, 2),
        ),
        child: Material(
          color: colors.card,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final c in others) ...[
                _row(c),
                if (!identical(c, others.last))
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    indent: 64,
                    color: colors.muted.withValues(alpha: 0.3),
                  ),
              ],
            ],
          ),
        ),
      ),
    ],
  );

  Widget _row(Map<String, dynamic> c) {
    final unread = (c['unread'] as int? ?? 0) > 0;
    return InkWell(
      onTap: () => _openConversation(c['id'] as String),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: palette.accent.withValues(alpha: 0.13),
              ),
              child: Icon(
                c['status'] == 'closed'
                    ? Icons.check_rounded
                    : Icons.chat_bubble_rounded,
                size: 17,
                color: palette.accent,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${c['subject'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${c['preview'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, color: colors.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _badgeOrTime(c),
          ],
        ),
      ),
    );
  }

  Widget _topicChip(AppReferSupportTopic t) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        decoration: ShapeDecoration(
          color: colors.card,
          shape: StadiumBorder(
            side: BorderSide(color: t.tint.withValues(alpha: 0.25)),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(t.icon, size: 15, color: t.tint),
            const SizedBox(width: 6),
            Text(
              t.title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: t.tint,
              ),
            ),
            const SizedBox(width: 2),
            _button(
              'Remove topic',
              () => setState(() => topic = null),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.close_rounded, size: 14, color: t.tint),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  // MARK: Conversation

  /// The person answering: the newest team reply's author (never an email).
  String? get _agent {
    for (final m in messages.reversed) {
      if (m['from'] != 'team') continue;
      final name = supportFirstName(m['authorName'] as String?);
      if (name != null) return name;
    }
    return null;
  }

  bool _fromCustomer(int i) => messages[i]['from'] == 'customer';
  bool _sameSide(int a, int b) =>
      a >= 0 &&
      b < messages.length &&
      _fromCustomer(a) == _fromCustomer(b) &&
      messages[a]['from'] == messages[b]['from'];
  bool _showsTime(int i) {
    if (i < 0 || i >= messages.length) return false;
    if (i == 0) return true;
    final a = _date(messages[i - 1]['createdAt']);
    final b = _date(messages[i]['createdAt']);
    return a != null && b != null && b.difference(a).inSeconds > 3600;
  }

  Widget _thread() {
    final top = MediaQuery.paddingOf(context).top;
    final mine = pending.where((p) => p.conversation == id).toList();
    final last = messages.lastOrNull;
    final quickReplies =
        !loading &&
        mine.isEmpty &&
        threadText.text.isEmpty &&
        threadImages.isEmpty &&
        supportShowsQuickReplies(last);
    final lastDate = _date(last?['createdAt']);
    final error = sendError.isNotEmpty ? sendError : loadError;
    return Stack(
      children: [
        Positioned.fill(
          child: ListView(
            controller: scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(14, top + 86, 14, composerHeight + 12),
            children: [
              if (loading && messages.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 30),
                  child: Center(child: CircularProgressIndicator()),
                ),
              for (var i = 0; i < messages.length; i++) ...[
                if (_showsTime(i))
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 4 : 16, bottom: 8),
                    child: Center(
                      child: Text(
                        _time(messages[i]['createdAt']),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colors.muted,
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.only(
                    top: i > 0 && !_showsTime(i)
                        ? (_sameSide(i - 1, i) ? 3 : 10)
                        : 0,
                  ),
                  child: _message(i),
                ),
              ],
              for (final p in mine)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _pendingBubble(p),
                ),
              if (!loading && mine.isEmpty && last?['from'] == 'customer')
                Padding(
                  padding: const EdgeInsets.only(top: 5, right: 4),
                  child: Text(
                    "${lastDate == null ? 'Sent' : 'Sent ${_clock(lastDate)}'} · we'll notify you when the team replies",
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: colors.muted,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Positioned(top: top + 10, left: 12, right: 12, child: _threadHeader()),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _MeasureSize(
            onChange: (size) {
              if (mounted && size.height != composerHeight) {
                setState(() => composerHeight = size.height);
              }
            },
            child: _composer(
              home: false,
              above: [
                if (error.isNotEmpty) _errorLine(error),
                if (quickReplies) _quickReplies(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _threadHeader() {
    final agent = _agent;
    final persona = agent == null ? _persona : null;
    return _glass(
      radius: 32,
      shadow: _shadow(0.14, 16, 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              _button(
                'Back',
                _back,
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.primary.withValues(alpha: 0.05),
                  ),
                  child: Icon(
                    Icons.chevron_left_rounded,
                    size: 30,
                    color: palette.accent,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Nobody on the team has joined yet: the AI assistant is who's answering.
              SupportAvatar(
                name: persona?.name ?? agent,
                size: 42,
                colors: [palette.warm, palette.hot],
                icon: persona == null && agent == null
                    ? Icons.forum_rounded
                    : null,
                imageUrl: persona?.avatarUrl,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            persona?.name ?? agent ?? '$appName team',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: colors.primary,
                            ),
                          ),
                        ),
                        if (persona != null) ...[
                          const SizedBox(width: 6),
                          SupportAITag(palette: palette),
                        ],
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      persona != null
                          ? '$appName team · replies instantly'
                          : 'Usually replies in ${config.replyTime}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: colors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _message(int i) {
    final m = messages[i];
    final lastOfGroup =
        i == messages.length - 1 || !_sameSide(i, i + 1) || _showsTime(i + 1);
    if (m['from'] == 'customer') return _customerBubble(m, lastOfGroup);
    final botName = m['from'] == 'bot'
        ? supportFirstName(m['authorName'] as String?)
        : null;
    if (botName != null) {
      final persona = _persona;
      final handoff = supportIsHandoff(m);
      final bubble = _personaBubble(
        m,
        botName,
        persona?.name == botName ? persona?.avatarUrl : null,
        lastOfGroup || handoff,
      );
      if (!handoff) return bubble;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          bubble,
          const SizedBox(height: 10),
          _handoffPill(persona?.handoffTo),
        ],
      );
    }
    if (m['from'] == 'bot') return _botCard(m);
    return _teamBubble(m, lastOfGroup);
  }

  /// A message from the AI assistant: its portrait, name and "AI" tag, then the text.
  Widget _personaBubble(
    Map<String, dynamic> m,
    String name,
    String? imageUrl,
    bool avatar,
  ) => Padding(
    padding: const EdgeInsets.only(right: 40),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SizedBox(
          width: 30,
          height: 30,
          child: avatar
              ? SupportAvatar(
                  name: name,
                  size: 30,
                  colors: [palette.warm, palette.hot],
                  imageUrl: imageUrl,
                )
              : null,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: MergeSemantics(
            child: Container(
              padding: const EdgeInsets.fromLTRB(15, 10, 15, 12),
              decoration: BoxDecoration(
                color: colors.card,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(22),
                  topRight: const Radius.circular(22),
                  bottomRight: const Radius.circular(22),
                  bottomLeft: Radius.circular(avatar ? 6 : 22),
                ),
                boxShadow: _shadow(0.06, 8, 2),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: colors.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SupportAITag(palette: palette),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${m['text'] ?? ''}',
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.3,
                      color: colors.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );

  /// Under the hand-over: who has the conversation now.
  Widget _handoffPill(String? to) => Center(
    child: MergeSemantics(
      child: Container(
        padding: const EdgeInsets.fromLTRB(5, 5, 12, 5),
        decoration: ShapeDecoration(
          color: colors.card,
          shape: StadiumBorder(
            side: BorderSide(color: colors.muted.withValues(alpha: 0.18)),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SupportAvatar(
              name: to,
              size: 22,
              colors: [palette.warm, palette.hot],
              icon: to == null ? Icons.people_alt_rounded : null,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Passed to ${to ?? 'the team'} · usually replies in ${config.replyTime}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: colors.muted,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  List<String> _imageUrls(Map<String, dynamic> m) => [
    for (final a in (m['attachments'] as List? ?? []))
      if (a is Map &&
          '${a['contentType']}'.startsWith('image/') &&
          a['url'] != null)
        '${a['url']}',
  ];

  Widget _thumb({String? url, Uint8List? bytes}) {
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white, width: 3),
      color: colors.muted.withValues(alpha: 0.2),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.12),
          blurRadius: 6,
          offset: const Offset(0, 4),
        ),
      ],
    );
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: bytes != null
          ? Image.memory(bytes, fit: BoxFit.cover)
          : Image.network(
              url!,
              fit: BoxFit.cover,
              errorBuilder: (_, e, s) => Icon(
                Icons.broken_image_outlined,
                color: colors.muted,
                semanticLabel: 'Image unavailable',
              ),
            ),
    );
    final box = Container(
      width: 74,
      height: 112,
      decoration: decoration,
      child: image,
    );
    if (url == null) return box;
    return _button(
      'Screenshot',
      () => _view(url),
      box,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );
  }

  Widget _thumbs(List<Widget> thumbs, {bool end = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: end ? WrapAlignment.end : WrapAlignment.start,
      children: thumbs,
    ),
  );

  Widget _customerBubble(Map<String, dynamic> m, bool tail) {
    final urls = _imageUrls(m);
    final text = '${m['text'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(left: 60),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (urls.isNotEmpty)
            _thumbs([for (final u in urls) _thumb(url: u)], end: true),
          if (text.isNotEmpty) _gradientBubble(text, tail),
        ],
      ),
    );
  }

  Widget _gradientBubble(String text, bool tail) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
    decoration: BoxDecoration(
      gradient: palette.bubble,
      borderRadius: BorderRadius.only(
        topLeft: const Radius.circular(22),
        topRight: const Radius.circular(22),
        bottomLeft: const Radius.circular(22),
        bottomRight: Radius.circular(tail ? 6 : 22),
      ),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 16, height: 1.3, color: palette.onAccent),
    ),
  );

  Widget _teamBubble(Map<String, dynamic> m, bool avatar) {
    final urls = _imageUrls(m);
    final text = '${m['text'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(right: 40),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            width: 30,
            height: 30,
            child: avatar
                ? SupportAvatar(
                    name: supportFirstName(m['authorName'] as String?),
                    size: 30,
                    colors: [palette.warm, palette.hot],
                    icon: supportFirstName(m['authorName'] as String?) == null
                        ? Icons.forum_rounded
                        : null,
                  )
                : null,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (urls.isNotEmpty)
                  _thumbs([for (final u in urls) _thumb(url: u)]),
                if (text.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: colors.card,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(22),
                        topRight: const Radius.circular(22),
                        bottomRight: const Radius.circular(22),
                        bottomLeft: Radius.circular(avatar ? 6 : 22),
                      ),
                      boxShadow: _shadow(0.06, 8, 2),
                    ),
                    child: Text(
                      text,
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.3,
                        color: colors.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _botCard(Map<String, dynamic> m) => Padding(
    padding: const EdgeInsets.only(right: 50),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(20),
          boxShadow: _shadow(0.06, 10, 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '✦ INSTANT ANSWER',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: palette.accent,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${m['text'] ?? ''}',
              style: TextStyle(
                fontSize: 15.5,
                height: 1.3,
                color: colors.primary,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _pendingBubble(_Pending p) => Padding(
    padding: const EdgeInsets.only(left: 60),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Opacity(
          opacity: 0.6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (p.images.isNotEmpty)
                _thumbs([
                  for (final b in p.images) _thumb(bytes: b),
                ], end: true),
              if (p.text.isNotEmpty) _gradientBubble(p.text, true),
            ],
          ),
        ),
        const SizedBox(height: 5),
        if (p.failed)
          GestureDetector(
            onTap: id == null ? null : () => _deliver(p, id!),
            child: const Text(
              'Not sent · Tap to retry',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xffe5383b),
              ),
            ),
          )
        else
          Text(
            'Sending…',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: colors.muted,
            ),
          ),
      ],
    ),
  );

  Widget _quickReplies() {
    Widget chip(String label, VoidCallback onTap) => _button(
      label,
      onTap,
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: ShapeDecoration(
          color: colors.card,
          shape: StadiumBorder(
            side: BorderSide(color: palette.accent.withValues(alpha: 0.18)),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: palette.accent,
          ),
        ),
      ),
      shape: const StadiumBorder(),
    );
    const thanks = "👍 Thanks, that's sorted";
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          chip(thanks, () => _sendThread(thanks)),
          const SizedBox(width: 8),
          chip('I have another question', threadFocus.requestFocus),
        ],
      ),
    );
  }

  void _view(String url) => Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: true,
      pageBuilder: (_, _, _) => _SupportImageViewer(url: url),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final host = Theme.of(context);
    final accent = config.accentColor ?? host.colorScheme.primary;
    final dark =
        host.brightness == Brightness.dark ||
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final brightness = dark ? Brightness.dark : Brightness.light;
    palette = SupportPalette(accent);
    colors = SupportColors(dark);
    final overlay = id == null
        ? (palette.darkOnAccent
              ? SystemUiOverlayStyle.dark
              : SystemUiOverlayStyle.light)
        : (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark);
    final themeKey = (
      accent,
      brightness,
      host.textTheme.bodyMedium?.fontFamily,
    );
    if (themeKey != _themeKey) {
      _themeKey = themeKey;
      _theme = ThemeData(
        brightness: brightness,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
          primary: accent,
        ),
        fontFamily: themeKey.$3,
        scaffoldBackgroundColor: colors.background,
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: accent,
          selectionColor: accent.withValues(alpha: 0.3),
          selectionHandleColor: accent,
        ),
      );
    }
    return Theme(
      data: _theme!,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlay,
        child: PopScope(
          canPop: id == null,
          onPopInvokedWithResult: (popped, result) {
            if (!popped) _back();
          },
          child: Scaffold(
            backgroundColor: colors.background,
            body: id == null ? _home() : _thread(),
          ),
        ),
      ),
    );
  }
}

/// Shrinks slightly while pressed, like the iOS cards.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;
  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool down = false;
  void _set(bool value) {
    if (down != value) setState(() => down = value);
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: down ? 0.97 : 1,
        duration: const Duration(milliseconds: 120),
        child: widget.child,
      ),
    ),
  );
}

/// Reports its child's size after layout (the floating composer's height).
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required super.child});
  final ValueChanged<Size> onChange;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureSize(onChange);
  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMeasureSize renderObject,
  ) => renderObject.onChange = onChange;
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onChange);
  ValueChanged<Size> onChange;
  Size? _last;
  @override
  void performLayout() {
    super.performLayout();
    if (size == _last) return;
    _last = size;
    final reported = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(reported));
  }
}

class _SupportImageViewer extends StatelessWidget {
  const _SupportImageViewer({required this.url});
  final String url;
  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: SystemUiOverlayStyle.light,
    child: Material(
      color: Colors.black,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.maybePop(context),
        child: Stack(
          children: [
            Positioned.fill(
              child: Image.network(
                url,
                fit: BoxFit.contain,
                loadingBuilder: (_, child, progress) => progress == null
                    ? child
                    : const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                errorBuilder: (_, e, s) => const Center(
                  child: Icon(Icons.broken_image_outlined, color: Colors.white),
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.paddingOf(context).top + 16,
              right: 16,
              child: IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.maybePop(context),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.18),
                ),
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

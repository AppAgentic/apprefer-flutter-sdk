import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/device_info.dart';
import '../services/logger.dart';
import 'support_api.dart';

/// Shared support configuration and presentation API.
class AppReferSupport {
  AppReferSupport._();
  static final instance = AppReferSupport._();
  final SupportAPI api = SupportAPI();

  /// Set this to the host MaterialApp navigatorKey for context-free push routing.
  GlobalKey<NavigatorState>? navigatorKey;
  Color? accentColor;
  String? title;
  String replyTimeText = 'Ask us anything. We usually reply in under an hour.';
  Future<void> identify({String? name, String? email}) async {
    api.name = name?.trim().isEmpty == true ? null : name?.trim();
    api.email = email?.trim().isEmpty == true ? null : email?.trim();
    await api.ensureSession();
  }

  Future<void> open({BuildContext? context, String? conversationId}) =>
      _present(context, AppReferSupportView(conversationId: conversationId));
  Future<void> compose(String prefill, {BuildContext? context}) =>
      _present(context, AppReferSupportView(composing: prefill));
  Future<void> _present(BuildContext? context, Widget view) async {
    final nav = context == null
        ? navigatorKey?.currentState
        : Navigator.of(context);
    if (nav == null)
      throw StateError('Pass context or set AppRefer.support.navigatorKey.');
    await nav.push(
      MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => view),
    );
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
  }

  Future<void> removePushToken(String token) async {
    await api.call('DELETE', '/push-token', {'token': token});
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

/// Embeddable home, compose and conversation screens.
class AppReferSupportView extends StatefulWidget {
  const AppReferSupportView({
    super.key,
    this.conversationId,
    this.composing,
    this.api,
  });
  final String? conversationId, composing;
  final SupportAPI? api;
  @override
  State<AppReferSupportView> createState() => _SupportViewState();
}

class _Pending {
  _Pending(this.text, this.images, this.conversation);
  final String clientMessageId = newSupportMessageId();
  final String text;
  final String? conversation;
  bool inFlight = false;
  final List<Uint8List> images;
  bool failed = false;
  final List<String> ids = [];
}

class _SupportViewState extends State<AppReferSupportView>
    with WidgetsBindingObserver {
  final text = TextEditingController();
  final scroll = ScrollController();
  final config = AppReferSupport.instance;
  late final SupportAPI api = widget.api ?? config.api;
  String? id, pollCursor;
  int generation = 0;
  _Pending? firstSend;
  String subject = '', appName = 'App', error = '';
  late final Future<void> metadataReady;
  Map<String, dynamic> metadata = {
    'appVersion': 'unknown',
    'device': 'unknown',
    'os': Platform.operatingSystemVersion,
    'platform': Platform.isIOS ? 'ios' : 'android',
    'locale': PlatformDispatcher.instance.locale.toString(),
  };
  List<Map<String, dynamic>> conversations = [], messages = [];
  List<Uint8List> images = [];
  final List<_Pending> pending = [];
  bool composing = false,
      sending = false,
      loading = true,
      refreshing = false,
      active = true;
  Timer? timer;
  bool get dark => Theme.of(context).brightness == Brightness.dark;
  Color get surface => dark ? const Color(0xff1c1c1e) : const Color(0xfff2f2f7);
  Color get accent =>
      config.accentColor ?? Theme.of(context).colorScheme.primary;
  String get title => config.title ?? '$appName support';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    id = widget.conversationId;
    composing = widget.composing != null;
    text.text = widget.composing ?? '';
    text.addListener(_changed);
    metadataReady = _context();
    _refresh();
    _timer();
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
      if (mounted)
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
    } catch (_) {
      /* Metadata is best effort. */
    }
  }

  void _timer() {
    timer?.cancel();
    if (active)
      timer = Timer.periodic(Duration(seconds: id == null ? 15 : 4), (_) {
        if (!composing &&
            mounted &&
            TickerMode.valuesOf(context).enabled &&
            (ModalRoute.of(context)?.isCurrent ?? true))
          _refresh();
      });
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
    text.removeListener(_changed);
    text.dispose();
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
        if (mounted && id == current && generation == currentGeneration)
          setState(() => conversations = result);
      } else {
        final result = await api.thread(current, after: pollCursor);
        if (mounted && id == current && generation == currentGeneration) {
          final count = messages.length;
          setState(() {
            subject = '${result['conversation']['subject']}';
            for (final m in List<Map<String, dynamic>>.from(
              result['messages'],
            )) {
              final timestamp = m['createdAt'] as String?;
              if (timestamp != null &&
                  (pollCursor == null || timestamp.compareTo(pollCursor!) > 0))
                pollCursor = timestamp;
              if (!messages.any((old) => old['id'] == m['id'])) messages.add(m);
            }
            messages.sort(
              (a, b) => '${a['createdAt']}'.compareTo('${b['createdAt']}'),
            );
          });
          if (messages.length != count) _bottom();
        }
      }
      if (mounted) setState(() => error = '');
    } catch (e) {
      if (mounted) setState(() => error = '$e');
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
      if (mounted && scroll.hasClients)
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
    });
  }

  void _back() {
    if (id != null || composing) {
      setState(() {
        generation++;
        sending = false;
        firstSend = null;
        pollCursor = null;
        id = null;
        composing = false;
        messages = [];
        subject = '';
        text.clear();
        images = [];
      });
      _timer();
      _refresh();
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<void> _pick() async {
    if (images.length >= 4) return;
    try {
      final picked = await supportChannel.invokeListMethod<Uint8List>(
        'pick',
        4 - images.length,
      );
      if (mounted)
        setState(() => images.addAll((picked ?? []).take(4 - images.length)));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _send() async {
    if (sending || (text.text.trim().isEmpty && images.isEmpty)) return;
    final currentGeneration = generation;
    final p =
        id == null &&
            firstSend != null &&
            firstSend!.text == text.text.trim() &&
            firstSend!.images.length == images.length &&
            List.generate(
              images.length,
              (i) => identical(firstSend!.images[i], images[i]),
            ).every((same) => same)
        ? firstSend!
        : _Pending(text.text.trim(), List.of(images), id);
    if (id == null) {
      firstSend = p;
      setState(() => sending = true);
      try {
        p.ids.clear();
        for (final image in p.images) {
          p.ids.add(await api.upload(image));
        }
        // Device details are nice to have; never hold a message back for them.
        await metadataReady.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
        final result = await api.start(
          p.text,
          p.ids,
          metadata,
          clientMessageId: p.clientMessageId,
        );
        if (!mounted || generation != currentGeneration) return;
        setState(() {
          firstSend = null;
          pollCursor = null;
          id = result['conversation']['id'] as String;
          subject = '${result['conversation']['subject']}';
          messages = List<Map<String, dynamic>>.from(result['messages']);
          composing = false;
          images = [];
          text.clear();
          error = '';
        });
        _timer();
        _bottom();
      } catch (e) {
        if (mounted && generation == currentGeneration)
          setState(() => error = '$e');
      } finally {
        if (mounted && generation == currentGeneration)
          setState(() => sending = false);
      }
    } else {
      setState(() {
        pending.add(p);
        text.clear();
        images = [];
      });
      _bottom();
      await _deliver(p, id!);
    }
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
      if (mounted)
        setState(() {
          pending.remove(p);
          if (id == conversation &&
              !messages.any((old) => old['id'] == m['id']))
            messages.add(m);
          error = '';
        });
      _bottom();
    } catch (e) {
      if (mounted)
        setState(() {
          p.failed = true;
          error = '$e';
        });
    } finally {
      p.inFlight = false;
    }
  }

  Widget _glass(Widget child) => ClipRRect(
    borderRadius: BorderRadius.circular(32),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: Container(
        decoration: BoxDecoration(
          color: surface.withValues(alpha: .75),
          borderRadius: BorderRadius.circular(32),
          border: Border.all(
            color: Theme.of(context).dividerColor.withValues(alpha: .12),
          ),
        ),
        child: child,
      ),
    ),
  );
  Widget _sendButton() => IconButton.filled(
    onPressed: sending || (text.text.trim().isEmpty && images.isEmpty)
        ? null
        : _send,
    style: IconButton.styleFrom(
      backgroundColor: accent,
      foregroundColor: Colors.white,
    ),
    tooltip: 'Send',
    icon: sending
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.arrow_upward),
  );
  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
    child: Row(
      children: [
        _glass(
          IconButton(
            onPressed: _back,
            tooltip: id == null && !composing ? 'Close' : 'Back',
            icon: Icon(
              id == null && !composing ? Icons.close : Icons.chevron_left,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Center(
            child: _glass(
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      composing
                          ? 'New message'
                          : id != null
                          ? subject
                          : 'Help',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 17,
                      ),
                    ),
                    if (composing || id != null)
                      Text(
                        title,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        composing ? _sendButton() : const SizedBox(width: 40),
      ],
    ),
  );
  Widget _attachments() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (var i = 0; i < images.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    images[i],
                    width: 72,
                    height: 96,
                    fit: BoxFit.cover,
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: IconButton(
                    tooltip: 'Remove screenshot',
                    onPressed: sending
                        ? null
                        : () => setState(() => images.removeAt(i)),
                    icon: const Icon(Icons.cancel, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        if (images.length < 4)
          InkWell(
            onTap: sending ? null : _pick,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 104,
              constraints: const BoxConstraints(minHeight: 96),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  Icon(Icons.add_photo_alternate_outlined, color: accent),
                  const SizedBox(height: 6),
                  Text('Screenshot', style: TextStyle(color: accent)),
                ],
              ),
            ),
          ),
      ],
    ),
  );
  String _time(dynamic value) {
    final date = DateTime.tryParse('$value')?.toLocal();
    if (date == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final label = day == today
        ? 'Today'
        : day == today.subtract(const Duration(days: 1))
        ? 'Yesterday'
        : MaterialLocalizations.of(context).formatShortDate(date);
    return '$label, ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
  }

  Widget _home() => Expanded(
    child: Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  title,
                  style: TextStyle(color: accent, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Hi ${api.name?.split(' ').firstOrNull ?? 'there'} 👋',
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  config.replyTimeText,
                  style: TextStyle(
                    fontSize: 17,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                if (loading) const Center(child: CircularProgressIndicator()),
                if (conversations.isNotEmpty)
                  Text(
                    conversations.length == 1
                        ? 'Your conversation'
                        : 'Your conversations',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                const SizedBox(height: 8),
                for (final c in conversations)
                  Container(
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: accent.withValues(alpha: .15),
                        child: Icon(
                          c['status'] == 'closed'
                              ? Icons.check
                              : Icons.chat_bubble,
                          color: accent,
                        ),
                      ),
                      title: Text(
                        '${c['subject']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${c['preview']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: (c['unread'] as int? ?? 0) > 0
                          ? Badge(
                              backgroundColor: accent,
                              label: Text('${c['unread']}'),
                            )
                          : Text(
                              _time(c['lastMessageAt']),
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                      onTap: () {
                        setState(() {
                          generation++;
                          pollCursor = null;
                          messages = [];
                          id = c['id'] as String;
                          subject = '${c['subject']}';
                          loading = true;
                        });
                        _timer();
                        _refresh();
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.all(20),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
            ),
            onPressed: () => setState(() {
              generation++;
              composing = true;
            }),
            child: const Row(
              children: [
                Icon(Icons.forum),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Send us a message',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Screenshots welcome',
                        style: TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ],
    ),
  );
  Widget _bubble(Map<String, dynamic> m, bool author) {
    final customer = m['from'] == 'customer';
    final name = '${m['authorName'] ?? 'Team'}';
    return Align(
      alignment: customer ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .82,
        ),
        margin: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!customer && author)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                child: Text(
                  m['from'] == 'bot'
                      ? '$title · instant answer'
                      : name.contains('@')
                      ? 'Team'
                      : name.split(' ').first,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: customer ? accent : surface,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if ('${m['text']}'.isNotEmpty)
                    Text(
                      '${m['text']}',
                      style: TextStyle(
                        fontSize: 17,
                        color: customer ? Colors.white : null,
                      ),
                    ),
                  for (final a in (m['attachments'] as List? ?? []))
                    if ('${a['contentType']}'.startsWith('image/') &&
                        a['url'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            '${a['url']}',
                            width: 200,
                            fit: BoxFit.contain,
                            errorBuilder: (_, e, s) =>
                                const Text('Image unavailable'),
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thread() => Expanded(
    child: Column(
      children: [
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            children: [
              if (loading) const Center(child: CircularProgressIndicator()),
              for (var i = 0; i < messages.length; i++) ...[
                if (i == 0 ||
                    (DateTime.tryParse('${messages[i]['createdAt']}')
                                ?.difference(
                                  DateTime.tryParse(
                                        '${messages[i - 1]['createdAt']}',
                                      ) ??
                                      DateTime.now(),
                                )
                                .inMinutes ??
                            0) >
                        60)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Center(
                      child: Text(
                        _time(messages[i]['createdAt']),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                _bubble(
                  messages[i],
                  i == 0 ||
                      messages[i - 1]['from'] != messages[i]['from'] ||
                      messages[i - 1]['authorName'] !=
                          messages[i]['authorName'],
                ),
              ],
              for (final p in pending.where((p) => p.conversation == id))
                Align(
                  alignment: Alignment.centerRight,
                  child: InkWell(
                    onTap: p.failed ? () => _deliver(p, id!) : null,
                    child: Opacity(
                      opacity: .5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: accent,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  p.text,
                                  style: const TextStyle(color: Colors.white),
                                ),
                                for (final image in p.images)
                                  Image.memory(
                                    image,
                                    width: 120,
                                    height: 120,
                                    fit: BoxFit.cover,
                                  ),
                              ],
                            ),
                          ),
                          Text(
                            p.failed ? 'Not sent · Tap to retry' : 'Sending…',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if ((messages.isNotEmpty &&
                      messages.last['from'] == 'customer') ||
                  pending.any((p) => p.conversation == id))
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    "We'll notify you when the team replies.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
            ],
          ),
        ),
        if (images.isNotEmpty)
          Padding(padding: const EdgeInsets.all(12), child: _attachments()),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _glass(
                IconButton(
                  onPressed: images.length < 4 ? _pick : null,
                  tooltip: 'Add screenshot',
                  icon: const Icon(Icons.add),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _glass(
                  TextField(
                    controller: text,
                    minLines: 1,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      hintText: 'Message',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _sendButton(),
            ],
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: id == null && !composing,
    onPopInvokedWithResult: (popped, result) {
      if (!popped) _back();
    },
    child: Scaffold(
      backgroundColor: dark ? const Color(0xff121214) : Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (composing)
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    TextField(
                      controller: text,
                      autofocus: true,
                      minLines: 6,
                      maxLines: null,
                      enabled: !sending,
                      decoration: const InputDecoration(
                        hintText: 'How can we help? Tell us what happened.',
                        border: InputBorder.none,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _attachments(),
                    const SizedBox(height: 16),
                    Text(
                      'Sent with: app ${metadata['appVersion'] ?? '?'} · ${metadata['device'] ?? '?'} · ${metadata['os'] ?? '?'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              )
            else if (id != null)
              _thread()
            else
              _home(),
          ],
        ),
      ),
    ),
  );
}

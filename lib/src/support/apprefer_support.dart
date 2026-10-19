import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart'
    show listEquals, mapEquals, visibleForTesting;
import '../billing/apprefer_billing.dart' show AppReferBilling;
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/device_info.dart';
import '../services/registry.dart';
import '../services/storage.dart';
import '../services/logger.dart';
import 'support_api.dart';
import 'support_help.dart';
import 'support_offers.dart';
import 'support_reviews.dart';
import 'support_strings.dart';
import 'support_style.dart';

export 'support_api.dart'
    show
        AppReferSupportPersona,
        AppReferSupportIdentityVerification,
        SupportException,
        SupportErrorReason;
export 'support_offers.dart'
    show
        AppReferSupportOffer,
        AppReferSupportOfferCard,
        AppReferSupportOfferPackage;
export 'support_reviews.dart' show AppReferSupportReviewCard;
export 'support_help.dart'
    show
        AppReferHelpArticle,
        AppReferHelpArticleDetail,
        AppReferSupportStatus,
        AppReferSupportPushChannel;

/// Shared support configuration and presentation API.
class AppReferSupport with WidgetsBindingObserver {
  AppReferSupport._() {
    WidgetsFlutterBinding.ensureInitialized().addObserver(this);
    api.resumeRevocations();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      api.resumeRevocations();
      // Offer-card receipts made offline go out when the app is back.
      if (api.apiKey() != null)
        unawaited(api.flushOfferReceipts().catchError((_) {}));
    }
  }

  static final instance = AppReferSupport._();
  final SupportAPI api = SupportAPI();
  final ValueNotifier<int> accountGeneration = ValueNotifier(0);
  Route<void>? _presented;
  NavigatorState? _presentingNavigator;
  void configure({required String apiKey}) {
    AppReferRegistry.explicitSupportKey = apiKey;
    api.resumeRevocations();
  }

  Future<void> reset() async {
    await api.reset();
    // Offer-card receipts belong to the retired session; never sent for another account.
    await _clearOfferReceipts();
    final route = _presented;
    if (route != null && route.isActive)
      _presentingNavigator?.removeRoute(route);
    _presented = null;
    accountGeneration.value++;
  }

  /// Removes the account from Support without a full reset, e.g. when the
  /// user withdraws consent: forgets the name, email and app user id, revokes
  /// the current Support session and starts a new anonymous one that sends no
  /// app user id or device id. A registered push token moves to the new
  /// session once the old one is revoked, and an open help screen closes.
  /// Conversations from the old session stay in your team inbox but are no
  /// longer shown in the app. The app user id is not sent to Support again
  /// until it changes (another account signs in, which then gets a fresh
  /// session) or `AppReferSDK.reset()` runs. Attribution, Billing and the
  /// stored user id are untouched.
  Future<void> clearIdentity() async {
    final storage = AppReferStorage();
    await storage.init();
    await storage.setSupportIdentityCleared(true);
    await api.clearIdentity();
    await _clearOfferReceipts();
    final route = _presented;
    if (route != null && route.isActive)
      _presentingNavigator?.removeRoute(route);
    _presented = null;
    accountGeneration.value++;
    if (api.apiKey() == null) return;
    try {
      await api.ensureSession();
    } catch (_) {
      // Minted on the next request instead.
    }
  }

  /// Clearing receipts never blocks reset() or clearIdentity(): a store that
  /// can't be written leaves at most a few receipts the server refuses (404),
  /// since they name the retired session's conversations.
  Future<void> _clearOfferReceipts() async {
    try {
      await api.offerReceipts.clear();
    } catch (_) {}
  }

  /// Set this to the host MaterialApp navigatorKey for context-free push routing.
  GlobalKey<NavigatorState>? navigatorKey;

  /// Opens your app's own paywall when the customer taps an offer card your
  /// team (or AI assistant) sent in the chat. Set it once at startup:
  ///
  /// ```dart
  /// AppReferSDK.support.onOffer = (offer) =>
  ///     navigatorKey.currentState?.push(PaywallRoute(offer.offeringId, offer.packageId));
  /// ```
  ///
  /// The card shows your offering's packages with the store's own prices; the
  /// SDK never shows a paywall or starts a purchase itself. Without `onOffer`,
  /// cards say they can't be opened in this version of the app. With
  /// [closesChatOnOffer] (the default) the chat opened with `open()` or
  /// `compose()` closes first.
  void Function(AppReferSupportOffer offer)? get onOffer => _onOffer;
  set onOffer(void Function(AppReferSupportOffer offer)? value) {
    _onOffer = value;
    SupportOffers.hasHandler = value != null;
  }

  void Function(AppReferSupportOffer offer)? _onOffer;

  /// Close the chat before [onOffer] runs (default true). Set false when your
  /// paywall can show over the chat, or you embed `AppReferSupportView`.
  bool closesChatOnOffer = true;

  /// Hands a tapped card to [onOffer], closing the chat first when it was
  /// opened by the SDK and [closesChatOnOffer] is on. False when the app set
  /// no `onOffer`.
  @visibleForTesting
  bool deliverOffer(AppReferSupportOffer offer) {
    final handler = _onOffer;
    if (handler == null) return false;
    final route = _presented;
    if (closesChatOnOffer && route != null && route.isActive) {
      _presentingNavigator?.removeRoute(route);
      _presented = null;
    }
    handler(offer);
    return true;
  }

  /// Bubble and button colour. Defaults to the host theme's primary colour.
  Color? accentColor;

  /// The home screen's header. [AppReferSupportHeaderStyle.accent] (the
  /// default) fills it with the accent and soft coloured glows;
  /// [AppReferSupportHeaderStyle.plain] is a flat neutral grey with the page's
  /// text colour, for apps whose design has no colour accents. Bubbles and
  /// buttons keep [accentColor] either way.
  AppReferSupportHeaderStyle headerStyle = AppReferSupportHeaderStyle.accent;

  /// Hero title. Defaults to "<App name> support" in the chat's language.
  String? title;

  /// How fast the team usually answers, completing "We usually reply in …".
  /// Defaults to "under an hour" in the chat's language. A value you set is
  /// used as written in every language, so set it for the language your app
  /// is showing; in most languages the sentence around it leaves out "in"
  /// (e.g. German "innerhalb einer Stunde").
  String get replyTime =>
      _replyTime ?? SupportStrings.text('support.replyTime.default');
  set replyTime(String value) => _replyTime = value;
  String? _replyTime;

  /// Your own text for any of the chat's strings, by key (e.g.
  /// `{'support.home.subtitle': "What's up?"}`). Used before the SDK's
  /// translations, in every language. Placeholders such as `{name}` are
  /// filled in; plural keys take `'key#one'`, `'key#few'`, … or just `'key'`
  /// for every count. Keys: `Localization/support-strings.json` in the SDK
  /// repo.
  Map<String, String> get strings => SupportStrings.overrides;
  set strings(Map<String, String> value) =>
      SupportStrings.overrides = Map.of(value);

  /// Forces the chat's language (e.g. "de", "pt-BR", "zh-Hant"). By default
  /// it follows the locale your app is running in, then the device's
  /// languages, then English. Null follows the app again.
  String? get language => SupportStrings.forcedLanguage;
  set language(String? value) => SupportStrings.forcedLanguage = value;

  /// Every language the chat ships.
  static const List<String> supportedLanguages =
      SupportStrings.supportedLanguages;

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

  /// Opens the help chat on one help article (e.g. from a "How does this
  /// work?" link). Back leads to the help home; "Message us" starts a
  /// conversation about the article.
  Future<void> openArticle(String slug, {BuildContext? context}) => _present(
    context,
    AppReferSupportView(opening: AppReferSupportDestination.article(slug)),
  );

  /// Opens the help chat on the help centre: every article, with search.
  Future<void> openHelpCentre({BuildContext? context}) => _present(
    context,
    const AppReferSupportView(opening: AppReferSupportDestination.helpCentre),
  );

  /// The app's published help articles in the chat's language ([language],
  /// else the app's language), best first; with [query], search results
  /// (titles, summaries and bodies, up to 20). Test SDK keys (`pk_test_`) also
  /// get drafts (`isDraft`). Lists are kept in memory for five minutes; if a
  /// request fails, the last list for the same query is returned, and only
  /// without one is the error thrown.
  Future<List<AppReferHelpArticle>> articles({String? query}) =>
      api.help.list(query, SupportStrings.language);

  /// One help article with its markdown body, in the chat's language. Throws
  /// a [SupportException] with `status` 404 when the article doesn't exist or
  /// isn't published.
  Future<AppReferHelpArticleDetail> article(String slug) =>
      api.help.article(slug, SupportStrings.language);

  /// Confirms who the customer is, so your team and the AI assistant may use
  /// the account's private details (plan, orders, credits). Your backend,
  /// after signing the user in, asks AppRefer for a short-lived single-use
  /// token (`POST /api/v1/apps/{appId}/support/identity-tokens` with your
  /// private key; never ship that key in the app) and passes it here. It
  /// verifies the current Support session, so conversations already started
  /// on it count too. Call it after `AppReferSDK.setUserId` with the same
  /// user; `reset()`, `clearIdentity()` or another account ends it. Network
  /// failures are retried with the same token and then thrown (retrying the
  /// same token later is safe); a refusal returns `verified == false` with a
  /// reason. `identify(name:, email:)` is unchanged.
  Future<AppReferSupportIdentityVerification> verifyIdentity(
    String identityToken,
  ) => api.verifyIdentity(identityToken);

  /// What Support can do for this app: whether reply notifications work on
  /// this platform (`pushReady`), whether customers can answer by email
  /// (`emailReplies`) and how many help articles are published. Register push
  /// tokens only when `pushReady` is true. Cached as long as the server allows
  /// (5 minutes once everything is verified, else 30 s).
  Future<AppReferSupportStatus> status() => api.help.status();
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

  /// Forces the APNs environment ('production' or 'sandbox') push tokens are
  /// registered for and [status] checks. null (the default) reads it on iOS
  /// from the app's signing: sandbox for development-signed builds (Debug or
  /// Release) and the Simulator; production for App Store, TestFlight, Ad Hoc
  /// and Enterprise builds.
  String? get pushEnvironment => api.pushEnvironmentOverride;
  set pushEnvironment(String? value) {
    if (value != null && value != 'production' && value != 'sandbox') {
      throw ArgumentError.value(value, 'pushEnvironment');
    }
    api.pushEnvironmentOverride = value;
  }

  /// [environment] ('production' or 'sandbox') overrides [pushEnvironment]
  /// for this token; without it the effective environment is used.
  Future<void> registerPushToken(String token, {String? environment}) async {
    final epoch = api.actionGeneration;
    await supportChannel.invokeMethod<void>(
      'notificationChannel',
      SupportStrings.text('support.notification.channel'),
    );
    await api.registerPushToken(token, epoch, environment: environment);
  }

  Future<void> removePushToken(String token) async {
    final epoch = api.actionGeneration;
    await api.call('DELETE', '/push-token', {'token': token}, epoch);
    await api.persistPushToken(null, epoch);
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
///
/// The built-in tiles ([billing], [restore], [bug], [idea]) read their text
/// in the chat's language when shown; text you pass is shown as written.
class AppReferSupportTopic {
  const AppReferSupportTopic({
    required String title,
    required String subtitle,
    required this.icon,
    required this.tint,
    required String prompt,
    this.action,
  }) : _title = title,
       _subtitle = subtitle,
       _prompt = prompt,
       _builtIn = null;

  const AppReferSupportTopic._builtIn(
    String id, {
    required this.icon,
    required this.tint,
  }) : _builtIn = id,
       _title = null,
       _subtitle = null,
       _prompt = null,
       action = null;

  final String? _builtIn, _title, _subtitle, _prompt;
  final IconData icon;
  final Color tint;
  final VoidCallback? action;

  /// `billing`, `restore`, `bug` or `idea` for the built-in tiles; the title
  /// for your own.
  String get id => _builtIn ?? _title!;

  /// The tile's title; also the new conversation's subject.
  String get title =>
      _title ?? SupportStrings.text('support.topic.$_builtIn.title');
  String get subtitle =>
      _subtitle ?? SupportStrings.text('support.topic.$_builtIn.subtitle');

  /// The hint in the message field once the tile is picked.
  String get prompt =>
      _prompt ?? SupportStrings.text('support.topic.$_builtIn.prompt');

  static const billing = AppReferSupportTopic._builtIn(
    'billing',
    icon: Icons.credit_card_rounded,
    tint: Color(0xff6e4aff),
  );
  static const restore = AppReferSupportTopic._builtIn(
    'restore',
    icon: Icons.refresh_rounded,
    tint: Color(0xff2e8ffa),
  );
  static const bug = AppReferSupportTopic._builtIn(
    'bug',
    icon: Icons.bug_report_rounded,
    tint: Color(0xfff04554),
  );
  static const idea = AppReferSupportTopic._builtIn(
    'idea',
    icon: Icons.lightbulb_rounded,
    tint: Color(0xff1fb866),
  );
  static const defaults = [billing, restore, bug, idea];
}

/// The screen the help chat opens on. Back always leads to the help home.
@immutable
class AppReferSupportDestination {
  const AppReferSupportDestination._(this.kind, [this.value]);
  static const home = AppReferSupportDestination._('home');

  /// Every help article, with search.
  static const helpCentre = AppReferSupportDestination._('helpCentre');

  /// One help article by slug (any translation's slug works).
  const AppReferSupportDestination.article(String slug)
    : this._('article', slug);
  const AppReferSupportDestination.conversation(String id)
    : this._('conversation', id);

  /// `home`, `helpCentre`, `article` or `conversation`.
  final String kind;

  /// The article slug or conversation id.
  final String? value;
}

/// Embeddable help chat: the home (with help articles), the help centre,
/// articles and conversations.
class AppReferSupportView extends StatefulWidget {
  const AppReferSupportView({
    super.key,
    this.conversationId,
    this.composing,
    this.opening,
    this.api,
  });
  final String? conversationId;

  /// Where to open; overrides [conversationId] when set.
  final AppReferSupportDestination? opening;

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

/// A help screen over the home: the help centre, or one article.
class _HelpPage {
  const _HelpPage.centre({this.focusSearch = false}) : slug = null, title = '';
  const _HelpPage.article(String this.slug, this.title) : focusSearch = false;
  final String? slug;
  final String title;
  final bool focusSearch;
  bool get isArticle => slug != null;
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
  late SupportHeaderLook header;
  ThemeData? _theme;
  Object? _themeKey;
  String get title =>
      config.title ??
      SupportStrings.text('support.home.title', {'app': appName});

  /// The app's AI assistant, as last seen from AppRefer.
  AppReferSupportPersona? get _persona => api.persona.value;

  // Help centre: the home section, the help centre screen and the reader.
  List<AppReferHelpArticle> articles = [];
  bool _articlesLoading = false;
  final List<_HelpPage> helpStack = [];
  List<AppReferHelpArticle> helpAll = [];
  List<AppReferHelpArticle>? helpResults;
  bool helpLoaded = false, helpFailed = false, helpSearching = false;
  final helpSearch = TextEditingController();
  final helpSearchFocus = FocusNode();
  final helpScroll = ScrollController();
  Timer? _helpDebounce;
  AppReferHelpArticleDetail? articleDetail;
  List<SupportMarkdownBlock> articleBlocks = [];
  bool articleFailed = false;
  final Map<String, TapGestureRecognizer> _linkTaps = {};

  /// How the team's reply will reach the customer.
  SupportReplyNotice notice = SupportReplyNotice.push;

  // Offer cards: each card's latest state, store prices by offering then
  // package, the card being opened and the cards already reported as shown.
  final Map<String, AppReferSupportOfferCard> offerCards = {};
  Map<String, Map<String, SupportOfferPrice>> offerPrices = const {};
  String? openingCard;
  final Set<String> shownCards = {};
  DateTime _lastOfferRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<Object?>? _billingChanges;
  late final SupportOfferOpener offerOpener = SupportOfferOpener(
    queue: api.offerReceipts,
    send: api.sendOfferReceipt,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final opening = widget.opening;
    id = opening == null
        ? widget.conversationId
        : (opening.kind == 'conversation' ? opening.value : null);
    if (opening?.kind == 'helpCentre') {
      helpStack.add(const _HelpPage.centre());
      _loadHelp();
    } else if (opening?.kind == 'article' && opening?.value != null) {
      helpStack.add(_HelpPage.article(opening!.value!, ''));
      _loadArticle(opening.value!);
    }
    _loadNotice();
    homeText.text = widget.composing ?? '';
    homeText.addListener(_changed);
    threadText.addListener(_changed);
    helpSearchFocus.addListener(_changed);
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
    // Offer cards follow purchases, restores and sign-ins as Billing reports them.
    if (AppReferBilling.isConfigured) {
      _billingChanges = AppReferBilling.customerInfoStream.listen(
        (_) => _refreshOffers(),
      );
    }
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
      helpStack.clear();
      helpSearch.clear();
      helpResults = null;
      articleDetail = null;
      articleBlocks = [];
      notice = SupportReplyNotice.push;
      offerCards.clear();
      offerPrices = const {};
      openingCard = null;
      shownCards.clear();
      reviewCards.clear();
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
    if (active) {
      _refresh();
      _refreshOffers();
    }
  }

  /// Prices for the offerings on screen, from AppRefer Billing when the app
  /// uses it.
  Future<void> _loadOfferPrices() async {
    final ids = {for (final c in offerCards.values) c.offeringId};
    final loaded = await supportOfferPrices(ids);
    if (!mounted || mapEquals(loaded, offerPrices)) return;
    final same =
        loaded.length == offerPrices.length &&
        loaded.entries.every((e) => mapEquals(e.value, offerPrices[e.key]));
    if (!same) setState(() => offerPrices = loaded);
  }

  /// Fresh states for every card here, after a purchase, restore, sign-in,
  /// catalogue change or coming back to the app (and every 30 s while the
  /// chat is open); also re-reads store prices.
  Future<void> _refreshOffers({bool force = true}) async {
    final current = id;
    if (current == null || (offerCards.isEmpty && reviewCards.isEmpty)) return;
    if (!force &&
        DateTime.now().difference(_lastOfferRefresh) <
            const Duration(seconds: 30))
      return;
    _lastOfferRefresh = DateTime.now();
    await _refreshReviews();
    if (offerCards.isEmpty) return;
    final epoch = generation;
    try {
      final cards = await api.offerCards(current);
      if (!mounted || id != current || generation != epoch) return;
      setState(() {
        for (final c in cards) {
          offerCards[c.cardId] = c;
        }
      });
      await _loadOfferPrices();
    } catch (_) {
      // Shown as last read; the next refresh tries again.
    }
  }

  /// "View offer": checked with the server, then handed to the app's paywall.
  /// A refusal redraws the card instead.
  Future<void> _openOffer(AppReferSupportOfferCard card) async {
    final conversation = id;
    if (conversation == null ||
        openingCard != null ||
        !card.isAvailable ||
        !SupportOffers.hasHandler)
      return;
    final epoch = generation, account = api.actionGeneration;
    setState(() => openingCard = card.cardId);
    final SupportOfferOpenCheck outcome;
    try {
      outcome = await offerOpener.check(
        offerOpener.receipt(card, conversation),
      );
    } finally {
      if (mounted) setState(() => openingCard = null);
    }
    if (!mounted ||
        generation != epoch ||
        account != api.actionGeneration ||
        id != conversation)
      return;
    switch (outcome) {
      case SupportOfferRefused():
        await _refreshOffers();
        return;
      case SupportOfferRecorded(:final card?):
        setState(() => offerCards[card.cardId] = card);
      case _:
        break;
    }
    config.deliverOffer(
      AppReferSupportOffer(
        cardId: card.cardId,
        conversationId: conversation,
        offeringId: card.offeringId,
        packageId: card.packageId,
      ),
    );
  }

  // Review cards: each card's latest state by card id.
  final Map<String, AppReferSupportReviewCard> reviewCards = {};

  /// Fresh review card states (withdrawn, expired, store page changed).
  Future<void> _refreshReviews() async {
    final current = id;
    if (current == null || reviewCards.isEmpty) return;
    final epoch = generation;
    try {
      final cards = await api.reviewCards(current);
      if (!mounted || id != current || generation != epoch) return;
      setState(() {
        for (final c in cards) {
          reviewCards[c.cardId] = c;
        }
      });
    } catch (_) {
      // Shown as last read; the next refresh tries again.
    }
  }

  /// "Write a review": checked with the server (at most 3 s), then the store
  /// page opens through the system URL opener. A refusal redraws instead.
  Future<void> _openReview(AppReferSupportReviewCard card) async {
    final conversation = id;
    final look = SupportReviewLook.of(card, ios: api.isIOS);
    if (conversation == null ||
        openingCard != null ||
        look is! SupportReviewOpen)
      return;
    final epoch = generation, account = api.actionGeneration;
    setState(() => openingCard = card.cardId);
    final SupportOfferOpenCheck outcome;
    try {
      outcome = await offerOpener.check(
        offerOpener.receiptFor(card.cardId, conversation),
      );
    } finally {
      if (mounted) setState(() => openingCard = null);
    }
    if (!mounted ||
        generation != epoch ||
        account != api.actionGeneration ||
        id != conversation)
      return;
    if (outcome is SupportOfferRefused) {
      await _refreshReviews();
      return;
    }
    unawaited(
      supportChannel
          .invokeMethod<bool>('openUrl', look.url)
          .then<void>((_) {}, onError: (_) {}),
    );
  }

  void _reviewShown(AppReferSupportReviewCard card) {
    final conversation = id;
    if (conversation == null || !shownCards.add(card.cardId)) return;
    unawaited(() async {
      try {
        await api.offerReceipts.enqueue(
          SupportOfferReceipt(
            conversationId: conversation,
            cardId: card.cardId,
            kind: 'shown',
            clientEventId: SupportReviewLink.shownId(card.cardId),
            occurredAt: SupportOfferReceipt.iso(DateTime.now()),
          ),
        );
        await api.flushOfferReceipts();
      } catch (_) {
        // A receipt is reporting only; the card works without it.
      }
    }());
  }

  /// A review card under a team message: heading, one neutral line naming the
  /// store, and "Write a review". No stars, no rating question.
  Widget _reviewCard(AppReferSupportReviewCard card) {
    final look = SupportReviewLook.of(card, ios: api.isIOS);
    final active = look is SupportReviewOpen;
    final tint = active ? palette.accent : colors.muted;
    final store = SupportReviewLink.storeKey(
      card.store ?? (api.isIOS ? 'app_store' : 'play_store'),
    );
    final opening = openingCard == card.cardId;
    if (!shownCards.contains(card.cardId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reviewShown(card);
      });
    }
    return Opacity(
      opacity: active ? 1 : 0.85,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: active
                ? palette.accent.withValues(alpha: 0.22)
                : colors.primary.withValues(alpha: 0.06),
          ),
          boxShadow: _shadow(0.07, 10, 3),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.13),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.rate_review_outlined,
                      size: 14,
                      color: tint,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      SupportStrings.text('support.review.title'),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: colors.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (active) ...[
              Text(
                SupportStrings.text('support.review.body.$store'),
                style: TextStyle(
                  fontSize: 14.5,
                  color: colors.primary.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                button: true,
                enabled: !opening,
                hint: SupportStrings.text('support.review.a11y.hint.$store'),
                child: _Pressable(
                  onTap: opening ? () {} : () => _openReview(card),
                  child: Container(
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: palette.bubble,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (opening) ...[
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: palette.onAccent,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          SupportStrings.text('support.review.open'),
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                            color: palette.onAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.info_outline_rounded,
                        size: 14,
                        color: colors.muted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      SupportStrings.text(
                        look is SupportReviewUnavailable
                            ? 'support.review.unavailable'
                            : 'support.review.unsupported',
                      ),
                      style: TextStyle(fontSize: 13.5, color: colors.muted),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  void _cardShown(AppReferSupportOfferCard card) {
    final conversation = id;
    if (conversation == null || !shownCards.add(card.cardId)) return;
    unawaited(() async {
      try {
        await api.offerReceipts.enqueue(
          SupportOfferReceipt(
            conversationId: conversation,
            cardId: card.cardId,
            kind: 'shown',
            clientEventId: SupportOfferReceipt.shownId(card.cardId),
            occurredAt: SupportOfferReceipt.iso(DateTime.now()),
          ),
        );
        await api.flushOfferReceipts();
      } catch (_) {
        // A receipt is reporting only; the card works without it.
      }
    }());
  }

  /// An offer card under a team or AI message: heading, the packages with
  /// the store's prices (and "Current plan"), and one button that hands the
  /// offer to the app's paywall. Disabled cards say why.
  Widget _offerCard(AppReferSupportOfferCard card) {
    final look = SupportOfferLook.of(card, SupportOffers.hasHandler);
    final active = look == SupportOfferLook.open;
    final tint = active ? palette.accent : colors.muted;
    final rows = card.status == 'unavailable'
        ? const <AppReferSupportOfferPackage>[]
        : card.shownPackages;
    final prices = offerPrices[card.offeringId] ?? const {};
    final opening = openingCard == card.cardId;
    if (!shownCards.contains(card.cardId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _cardShown(card);
      });
    }
    return Opacity(
      opacity: look == SupportOfferLook.unavailable ? 0.85 : 1,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: active
                ? palette.accent.withValues(alpha: 0.22)
                : colors.primary.withValues(alpha: 0.06),
          ),
          boxShadow: _shadow(0.07, 10, 3),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.13),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.local_offer_rounded,
                      size: 14,
                      color: tint,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      SupportStrings.text('support.offer.title'),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: colors.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (rows.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(
                    alpha: colors.dark ? 0.06 : 0.035,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: [
                    for (final (i, p) in rows.indexed) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: colors.primary.withValues(alpha: 0.08),
                        ),
                      _offerRow(p, prices[p.id]),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (look.notice case final notice?)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        look == SupportOfferLook.owned
                            ? Icons.check_circle_rounded
                            : Icons.info_outline_rounded,
                        size: 14,
                        color: colors.muted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      notice,
                      style: TextStyle(fontSize: 13.5, color: colors.muted),
                    ),
                  ),
                ],
              )
            else
              Semantics(
                button: true,
                enabled: !opening,
                hint: SupportStrings.text('support.offer.a11y.hint'),
                child: _Pressable(
                  onTap: opening ? () {} : () => _openOffer(card),
                  child: Container(
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: palette.bubble,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (opening) ...[
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: palette.onAccent,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          SupportStrings.text('support.offer.open'),
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                            color: palette.onAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _offerRow(AppReferSupportOfferPackage p, SupportOfferPrice? price) {
    final label = supportOfferLabel(p, price?.name);
    final tag = supportOfferOwnedTag(p, price);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: colors.primary,
                ),
              ),
            ),
            if (tag != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: palette.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  tag,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: palette.accent,
                  ),
                ),
              ),
            ],
            if (price != null) ...[
              const SizedBox(width: 8),
              Text(
                supportOfferPriceText(price),
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colors.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _billingChanges?.cancel();
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
    _helpDebounce?.cancel();
    helpSearch.dispose();
    helpSearchFocus.dispose();
    helpScroll.dispose();
    for (final tap in _linkTaps.values) {
      tap.dispose();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    if (id == null) unawaited(_refreshArticles());
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
              final card = AppReferSupportOfferCard.fromJson(m['offer']);
              if (card != null) offerCards[card.cardId] = card;
              final review = AppReferSupportReviewCard.fromJson(m['review']);
              if (review != null) reviewCards[review.cardId] = review;
            }
            messages.sort(
              (a, b) => '${a['createdAt']}'.compareTo('${b['createdAt']}'),
            );
          });
          if (messages.length != count) _bottom();
          if (count == 0) unawaited(api.flushOfferReceipts());
          if (offerCards.isNotEmpty) unawaited(_loadOfferPrices());
          if (offerCards.isNotEmpty || reviewCards.isNotEmpty) {
            unawaited(_refreshOffers(force: false));
          }
        }
      }
      if (mounted) setState(() => loadError = '');
    } catch (e) {
      if (mounted && !_isReset(e)) {
        setState(
          () => loadError = SupportStrings.errorText(
            e,
            fallback: current == null
                ? 'support.error.loadFailed'
                : 'support.thread.loadFailed',
          ),
        );
      }
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
    _loadNotice();
  }

  void _back() {
    if (id == null && helpStack.isNotEmpty) {
      FocusScope.of(context).unfocus();
      setState(() {
        helpStack.removeLast();
        if (helpStack.isEmpty) helpSearch.clear();
        helpResults = helpSearch.text.trim().isEmpty ? null : helpResults;
      });
      return;
    }
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
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              sendError = SupportStrings.text('support.error.imageUnreadable'),
        );
      }
    }
  }

  /// A request dropped because the account was reset meanwhile: nothing to show.
  bool _isReset(Object e) =>
      e is SupportException && e.reason == SupportErrorReason.reset;

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
    final epoch = api.actionGeneration;
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
        p.ids.add(await api.upload(image, generation: epoch));
      }
      // Device details are nice to have; never hold a message back for them.
      await metadataReady.timeout(const Duration(seconds: 2), onTimeout: () {});
      final result = await api.start(
        p.text,
        p.ids,
        metadata,
        clientMessageId: p.clientMessageId,
        generation: epoch,
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
      if (mounted && !_isReset(e)) {
        setState(
          () => sendError = SupportStrings.errorText(
            e,
            fallback: 'support.error.notSent',
          ),
        );
      }
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
    final epoch = api.actionGeneration;
    if (p.inFlight) return;
    p.inFlight = true;
    setState(() => p.failed = false);
    try {
      p.ids.clear();
      while (p.ids.length < p.images.length) {
        p.ids.add(await api.upload(p.images[p.ids.length], generation: epoch));
      }
      final m = await api.send(
        conversation,
        p.text,
        p.ids,
        clientMessageId: p.clientMessageId,
        generation: epoch,
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
          if (!_isReset(e)) sendError = SupportStrings.errorText(e);
        });
      }
    } finally {
      p.inFlight = false;
    }
  }

  // MARK: Formatting

  DateTime? _date(dynamic value) => DateTime.tryParse('$value')?.toLocal();
  String _clock(DateTime date) => SupportStrings.clock(
    date,
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  String _time(dynamic value) {
    final date = _date(value);
    if (date == null) return '';
    return SupportStrings.timestamp(
      date,
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }

  String _subject(Map<String, dynamic> c) {
    final subject = '${c['subject'] ?? ''}'.trim();
    return subject.isEmpty
        ? SupportStrings.text('support.conversation.defaultSubject')
        : subject;
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
    SupportStrings.upper(text),
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
        label: SupportStrings.plural('support.a11y.unread', unread),
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
                padding: const EdgeInsetsDirectional.fromSTEB(6, 7, 7, 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _button(
                      SupportStrings.text('support.a11y.addScreenshot'),
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
                                        ? SupportStrings.text(
                                            'support.composer.placeholder.home',
                                          )
                                        : SupportStrings.text(
                                            'support.composer.placeholder.persona',
                                            {'name': _persona!.name},
                                          ))
                              : SupportStrings.text(
                                  'support.composer.placeholder.thread',
                                ),
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
                      SupportStrings.text('support.a11y.send'),
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
          padding: const EdgeInsetsDirectional.fromSTEB(0, 8, 8, 8),
          child: Row(
            children: [
              for (var i = 0; i < images.length; i++)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 10),
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
                      PositionedDirectional(
                        top: -6,
                        end: -6,
                        child: _button(
                          SupportStrings.text('support.a11y.removeScreenshot'),
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
                  SupportStrings.text('support.a11y.addAnotherScreenshot'),
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
    return first == null
        ? SupportStrings.text('support.home.greeting')
        : SupportStrings.text('support.home.greeting.named', {'name': first});
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
                          // Hidden entirely when the app has no published articles.
                          if (articles.isNotEmpty)
                            _helpSection(prominent: current == null),
                          if (topics.isNotEmpty)
                            _quickHelp(
                              topics,
                              labelled: current != null || articles.isNotEmpty,
                            ),
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
    final on = header.foreground;
    return CustomPaint(
      painter: SupportHeroPainter(palette, homeScroll, header),
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
                  SupportStrings.text('support.a11y.close'),
                  () => Navigator.maybePop(context),
                  ClipOval(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: header.closeFill,
                          border: Border.all(color: header.closeBorder),
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
              alignment: AlignmentDirectional.centerStart,
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
              SupportStrings.text('support.home.subtitle'),
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
              ? LinearGradient(
                  colors: header.iconTile,
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
                  color: header.iconText,
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
    final on = header.foreground;
    final faces = header.avatars;
    final ring = header.avatarRing;
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(8, 7, 14, 7),
      decoration: BoxDecoration(
        color: header.pillFill,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: header.pillBorder),
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
                        colors: faces ?? [palette.warm, palette.hot],
                        icon: Icons.chat_bubble_rounded,
                        ring: true,
                        ringColor: ring,
                      ),
                    ]
                  : [
                      for (var i = names.length - 1; i >= 0; i--)
                        PositionedDirectional(
                          start: 20.0 * (i + offset),
                          child: SupportAvatar(
                            name: names[i],
                            size: 28,
                            colors: faces ?? _avatarColors(i),
                            ring: true,
                            ringColor: ring,
                          ),
                        ),
                      if (persona != null)
                        PositionedDirectional(
                          start: 0,
                          child: SupportAvatar(
                            name: persona.name,
                            size: 28,
                            colors: faces ?? [palette.warm, palette.hot],
                            imageUrl: persona.avatarUrl,
                            ring: true,
                            ringColor: ring,
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
    void open() => _openConversation(c['id'] as String);
    return Semantics(
      button: true,
      label: SupportStrings.text('support.a11y.continueConversation', {
        'subject': _subject(c),
      }),
      onTap: open,
      excludeSemantics: true,
      child: _Pressable(
        onTap: open,
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
              _label(SupportStrings.text('support.home.continue')),
              const SizedBox(height: 12),
              Row(
                children: [
                  // Plain draws it in the header's neutral greys; a portrait still covers them.
                  if (persona != null)
                    SupportAvatar(
                      key: supportContinueAvatarKey,
                      name: persona.name,
                      size: 46,
                      colors: header.avatars ?? [palette.warm, palette.hot],
                      imageUrl: persona.avatarUrl,
                    )
                  else
                    SupportAvatar(
                      key: supportContinueAvatarKey,
                      name: firstTeam.firstOrNull,
                      size: 46,
                      colors: header.avatars ?? [palette.warm, palette.hot],
                      icon: firstTeam.isEmpty ? Icons.forum_rounded : null,
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _subject(c),
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
                              ? SupportStrings.text('support.home.youPrefix', {
                                  'text': '${c['preview'] ?? ''}',
                                })
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
          padding: const EdgeInsetsDirectional.only(start: 6),
          child: _label(SupportStrings.text('support.home.quickHelp')),
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
            alignment: AlignmentDirectional.centerStart,
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
        padding: const EdgeInsetsDirectional.only(start: 6),
        child: _label(SupportStrings.text('support.home.conversations')),
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
                    _subject(c),
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
    alignment: AlignmentDirectional.centerStart,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Container(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 4, 4),
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
              SupportStrings.text('support.a11y.removeTopic'),
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

  // MARK: Help centre

  /// The home's article list: memory cache first (five minutes); offline
  /// keeps what was shown, or nothing, never an error.
  Future<void> _refreshArticles() async {
    if (_articlesLoading) return;
    _articlesLoading = true;
    final language = SupportStrings.language;
    final before = articles;
    // A cached list shows at once (this can run from initState, so no setState here).
    if (articles.isEmpty) articles = api.help.cachedList(language) ?? const [];
    List<AppReferHelpArticle>? fresh;
    try {
      fresh = await api.help.list(null, language);
    } catch (_) {
      // Offline or unavailable: the section keeps what it showed.
    } finally {
      _articlesLoading = false;
    }
    final next = fresh ?? articles;
    if (mounted && !listEquals(next, before)) setState(() => articles = next);
  }

  /// How the team's reply will reach the customer: notification, email or
  /// only in the chat.
  Future<void> _loadNotice() async {
    AppReferSupportStatus? status;
    try {
      status = await api.help.status();
    } catch (_) {
      // Unknown: keep the notification line, as before 0.10.0.
    }
    final hasPush = await api.hasPushToken();
    final next = SupportReplyNotice.choose(
      status,
      hasPushToken: hasPush,
      hasEmail: api.email != null,
    );
    if (mounted && next != notice) setState(() => notice = next);
  }

  void _openHelp({bool search = false}) {
    if (sending) return;
    FocusScope.of(context).unfocus();
    setState(() => helpStack.add(_HelpPage.centre(focusSearch: search)));
    _loadHelp();
    if (search) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) helpSearchFocus.requestFocus();
      });
    }
  }

  void _openArticle(AppReferHelpArticle article) {
    if (sending) return;
    FocusScope.of(context).unfocus();
    setState(() {
      helpStack.add(_HelpPage.article(article.slug, article.title));
      articleDetail = null;
      articleBlocks = [];
      articleFailed = false;
    });
    _loadArticle(article.slug);
  }

  /// Back to the home's message field; from an article its title becomes the
  /// conversation subject.
  void _messageUs(String? subject) {
    setState(() {
      helpStack.clear();
      helpSearch.clear();
      helpResults = null;
      topic = subject == null || subject.trim().isEmpty
          ? null
          : AppReferSupportTopic(
              title: subject,
              subtitle: '',
              icon: Icons.description_rounded,
              tint: palette.accent,
              prompt: SupportStrings.text('support.help.prompt'),
            );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) homeFocus.requestFocus();
    });
  }

  Future<void> _loadHelp() async {
    final language = SupportStrings.language;
    // Shown with the next frame (this can run from initState, so no setState here).
    if (helpAll.isEmpty) helpAll = api.help.cachedList(language) ?? const [];
    try {
      final all = await api.help.list(null, language);
      if (mounted) {
        setState(() {
          helpAll = all;
          helpFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => helpFailed = helpAll.isEmpty);
    } finally {
      if (mounted) setState(() => helpLoaded = true);
    }
  }

  /// Filters what's on screen at once, then asks the server (which also
  /// searches bodies) 300 ms after the last keystroke.
  void _searchHelp(String text) {
    _helpDebounce?.cancel();
    final q = SupportHelpClient.normalizedQuery(text);
    if (q == null) {
      setState(() {
        helpResults = null;
        helpSearching = false;
      });
      return;
    }
    setState(() {
      helpResults = supportHelpLocalMatches(helpAll, q);
      helpSearching = true;
    });
    final language = SupportStrings.language;
    _helpDebounce = Timer(const Duration(milliseconds: 300), () async {
      List<AppReferHelpArticle>? found;
      try {
        found = await api.help.list(q, language);
      } catch (_) {
        // Offline: the local matches stay.
      }
      if (!mounted || SupportHelpClient.normalizedQuery(helpSearch.text) != q) {
        return;
      }
      setState(() {
        if (found != null) helpResults = found;
        helpSearching = false;
      });
    });
  }

  Future<void> _loadArticle(String slug) async {
    articleFailed = false; // can run from initState
    try {
      final detail = await api.help.article(slug, SupportStrings.language);
      final blocks = SupportMarkdown.blocks(detail.body);
      if (!mounted || helpStack.lastOrNull?.slug != slug) return;
      setState(() {
        for (final tap in _linkTaps.values) {
          tap.dispose();
        }
        _linkTaps.clear();
        articleDetail = detail;
        articleBlocks = blocks;
      });
    } catch (_) {
      if (mounted && helpStack.lastOrNull?.slug == slug) {
        setState(() => articleFailed = articleDetail == null);
      }
    }
  }

  /// Opens an http(s) or mailto link outside the app; anything else is ignored.
  void _openLink(String url) {
    final safe = SupportMarkdown.safeUrl(url);
    if (safe == null) return;
    unawaited(
      supportChannel
          .invokeMethod<bool>('openUrl', safe)
          .then<void>((_) {}, onError: (_) {}),
    );
  }

  /// "Help articles" on the help home: a search entry and the first three articles.
  Widget _helpSection({required bool prominent}) {
    final top = articles.take(3).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(26),
        boxShadow: prominent ? _shadow(0.22, 22, 14) : _shadow(0.07, 10, 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _label(SupportStrings.text('support.help.title')),
              ),
              if (articles.length > 3)
                _button(
                  SupportStrings.text('support.help.seeAll'),
                  () => _openHelp(),
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 2, 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          SupportStrings.text('support.help.seeAll'),
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: palette.accent,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: palette.accent,
                        ),
                      ],
                    ),
                  ),
                  shape: const StadiumBorder(),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Semantics(
            button: true,
            textField: true,
            label: SupportStrings.text('support.help.search.placeholder'),
            excludeSemantics: true,
            child: _Pressable(
              onTap: () => _openHelp(search: true),
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: colors.background,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, size: 20, color: colors.muted),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        SupportStrings.text('support.help.search.placeholder'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15.5, color: colors.muted),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          for (final article in top) ...[
            _articleRow(article, summaryLines: 1, horizontal: 0),
            if (!identical(article, top.last))
              Divider(
                height: 1,
                thickness: 0.5,
                indent: 48,
                color: colors.muted.withValues(alpha: 0.3),
              ),
          ],
        ],
      ),
    );
  }

  /// One article in a list: a document tile, the title and its summary.
  Widget _articleRow(
    AppReferHelpArticle article, {
    int summaryLines = 2,
    double horizontal = 14,
  }) => Semantics(
    button: true,
    label: SupportStrings.text('support.help.a11y.article', {
      'title': article.title,
    }),
    hint: article.summary.isEmpty ? null : article.summary,
    excludeSemantics: true,
    child: InkWell(
      onTap: () => _openArticle(article),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontal, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.description_rounded,
                size: 18,
                color: palette.accent,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    article.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: colors.primary,
                    ),
                  ),
                  if (article.isDraft) ...[
                    const SizedBox(height: 3),
                    _draftBadge(),
                  ],
                  if (article.summary.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      article.summary,
                      maxLines: summaryLines,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, color: colors.muted),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: colors.muted.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _draftBadge() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: const Color(0xffff9500).withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      SupportStrings.upper(SupportStrings.text('support.help.draft')),
      style: const TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.4,
        color: Color(0xffe07b00),
      ),
    ),
  );

  /// The floating glass bar at the top of the help screens (same as a
  /// conversation's).
  Widget _helpHeader({Widget? trailing}) => _glass(
    radius: 32,
    shadow: _shadow(0.14, 16, 8),
    child: SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            _button(
              SupportStrings.text('support.a11y.back'),
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
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  SupportStrings.text('support.help.title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: colors.primary,
                  ),
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    ),
  );

  /// A help screen: the scrolling content under the floating header.
  Widget _helpFrame({required List<Widget> children, Widget? trailing}) {
    final top = MediaQuery.paddingOf(context).top;
    return Stack(
      children: [
        Positioned.fill(
          child: ListView(
            controller: helpScroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              16,
              top + 86,
              16,
              MediaQuery.paddingOf(context).bottom + 32,
            ),
            children: children,
          ),
        ),
        Positioned(
          top: top + 10,
          left: 12,
          right: 12,
          child: _helpHeader(trailing: trailing),
        ),
      ],
    );
  }

  /// "Still need help?" with the team's reply time and a "Message us" button.
  Widget _stillNeedHelp(String? subject) {
    final persona = _persona;
    final first = config.teamNames.where((n) => n.trim().isNotEmpty);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(26),
        boxShadow: _shadow(0.07, 10, 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (persona != null)
                SupportAvatar(
                  name: persona.name,
                  size: 44,
                  colors: [palette.warm, palette.hot],
                  imageUrl: persona.avatarUrl,
                )
              else
                SupportAvatar(
                  name: first.firstOrNull,
                  size: 44,
                  colors: [palette.warm, palette.hot],
                  icon: first.isEmpty ? Icons.forum_rounded : null,
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        SupportStrings.text('support.help.stillNeedHelp'),
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: colors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      persona != null
                          ? SupportStrings.text('support.presence.persona', {
                              'persona': persona.name,
                              'time': config.replyTime,
                            })
                          : SupportStrings.text('support.presence.team', {
                              'time': config.replyTime,
                            }),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, color: colors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Semantics(
            button: true,
            label: SupportStrings.text('support.help.messageUs'),
            excludeSemantics: true,
            child: _Pressable(
              onTap: () => _messageUs(subject),
              child: Container(
                height: 50,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: palette.bubble,
                  borderRadius: BorderRadius.circular(25),
                  boxShadow: [
                    BoxShadow(
                      color: palette.accent.withValues(alpha: 0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.chat_bubble_rounded,
                      size: 17,
                      color: palette.onAccent,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      SupportStrings.text('support.help.messageUs'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: palette.onAccent,
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

  Widget _helpSpinner(String? message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
        if (message != null) ...[
          const SizedBox(width: 10),
          Text(message, style: TextStyle(fontSize: 14, color: colors.muted)),
        ],
      ],
    ),
  );

  /// A centred message with an icon tile and, optionally, a Try again button.
  Widget _helpMessage(
    IconData icon,
    String title, {
    String? hint,
    VoidCallback? retry,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 12),
    child: Column(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: palette.accent.withValues(alpha: 0.12),
          ),
          child: Icon(icon, size: 24, color: palette.accent),
        ),
        const SizedBox(height: 10),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: colors.primary,
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 6),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: colors.muted),
          ),
        ],
        if (retry != null) ...[
          const SizedBox(height: 12),
          TextButton(
            onPressed: retry,
            child: Text(
              SupportStrings.text('support.action.tryAgain'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _articleList(List<AppReferHelpArticle> list) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      boxShadow: _shadow(0.07, 10, 2),
    ),
    child: Material(
      color: colors.card,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            for (final article in list) ...[
              _articleRow(article),
              if (!identical(article, list.last))
                Divider(
                  height: 1,
                  thickness: 0.5,
                  indent: 62,
                  color: colors.muted.withValues(alpha: 0.3),
                ),
            ],
          ],
        ),
      ),
    ),
  );

  /// The help centre: every article grouped by category, and search.
  Widget _helpCentre() {
    final results = helpResults;
    final query = SupportHelpClient.normalizedQuery(helpSearch.text) ?? '';
    final content = <Widget>[
      if (results != null)
        if (results.isNotEmpty)
          _articleList(results)
        else if (helpSearching)
          _helpSpinner(SupportStrings.text('support.help.searching'))
        else
          _helpMessage(
            Icons.search_rounded,
            SupportStrings.text('support.help.search.noResults', {
              'query': query,
            }),
            hint: SupportStrings.text('support.help.search.noResultsHint'),
          )
      else if (helpAll.isEmpty)
        if (helpLoaded && helpFailed)
          _helpMessage(
            Icons.description_rounded,
            SupportStrings.text('support.help.listFailed'),
            retry: () {
              setState(() => helpLoaded = false);
              _loadHelp();
            },
          )
        else if (!helpLoaded)
          _helpSpinner(null)
        else
          const SizedBox.shrink()
      else
        for (final (title, list) in supportHelpGroups(helpAll))
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null) ...[
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 6),
                  child: _label(title),
                ),
                const SizedBox(height: 10),
              ],
              _articleList(list),
            ],
          ),
      if (helpLoaded || helpAll.isNotEmpty) _stillNeedHelp(null),
    ];
    return _helpFrame(
      children: [
        Container(
          height: 50,
          padding: const EdgeInsetsDirectional.fromSTEB(14, 0, 4, 0),
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(18),
            boxShadow: _shadow(0.07, 10, 2),
            border: Border.all(
              color: palette.accent.withValues(
                alpha: helpSearchFocus.hasFocus ? 0.45 : 0,
              ),
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.search_rounded, size: 20, color: colors.muted),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: helpSearch,
                  focusNode: helpSearchFocus,
                  onChanged: _searchHelp,
                  textInputAction: TextInputAction.search,
                  autocorrect: false,
                  cursorColor: palette.accent,
                  style: TextStyle(fontSize: 16, color: colors.primary),
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    hintText: SupportStrings.text(
                      'support.help.search.placeholder',
                    ),
                    hintMaxLines: 1,
                    hintStyle: TextStyle(
                      fontSize: 16,
                      color: colors.muted.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ),
              if (helpSearch.text.isNotEmpty)
                _button(
                  SupportStrings.text('support.help.a11y.clearSearch'),
                  () {
                    helpSearch.clear();
                    _searchHelp('');
                  },
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.cancel_rounded,
                      size: 18,
                      color: colors.muted.withValues(alpha: 0.8),
                    ),
                  ),
                ),
            ],
          ),
        ),
        for (final w in content) ...[const SizedBox(height: 22), w],
      ],
    );
  }

  /// One article: its title, when it was updated, the rendered body and
  /// "Still need help?".
  Widget _articleScreen(_HelpPage page) {
    final detail = articleDetail?.slug == page.slug ? articleDetail : null;
    final title = detail?.title ?? page.title;
    final web = detail?.article.webUrl;
    final updated = detail?.article.updatedDate;
    return _helpFrame(
      trailing: web == null
          ? null
          : _button(
              SupportStrings.text('support.help.openInBrowser'),
              () => _openLink(web),
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.primary.withValues(alpha: 0.05),
                ),
                child: Icon(
                  Icons.open_in_new_rounded,
                  size: 20,
                  color: colors.primary,
                ),
              ),
            ),
      children: [
        if (detail?.category != null) ...[
          Text(
            SupportStrings.upper(detail!.category!),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: palette.accent,
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (title.isNotEmpty)
          Semantics(
            header: true,
            child: Text(
              title,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
                height: 1.15,
                color: colors.primary,
              ),
            ),
          ),
        if (detail != null && (updated != null || detail.isDraft)) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              if (updated != null) ...[
                Text(
                  SupportStrings.text('support.help.updated', {
                    'date': SupportStrings.day(updated),
                  }),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: colors.muted,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (detail.isDraft) _draftBadge(),
            ],
          ),
        ],
        const SizedBox(height: 20),
        if (detail != null)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colors.card,
              borderRadius: BorderRadius.circular(26),
              boxShadow: _shadow(0.07, 10, 2),
            ),
            child: _markdown(articleBlocks),
          )
        else if (articleFailed)
          Container(
            decoration: BoxDecoration(
              color: colors.card,
              borderRadius: BorderRadius.circular(26),
            ),
            child: _helpMessage(
              Icons.find_in_page_rounded,
              SupportStrings.text('support.help.loadFailed'),
              retry: () {
                setState(() => articleFailed = false);
                _loadArticle(page.slug!);
              },
            ),
          )
        else
          _helpSpinner(SupportStrings.text('support.help.loading')),
        const SizedBox(height: 24),
        _stillNeedHelp(title.isEmpty ? null : title),
      ],
    );
  }

  // MARK: Markdown

  /// Renders parsed article blocks. Links open in the browser (only http(s)
  /// and mailto survive parsing); nothing in an article can run code.
  Widget _markdown(List<SupportMarkdownBlock> blocks) {
    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final previous = i == 0 ? null : blocks[i - 1];
      final gap = previous == null
          ? 0.0
          : previous is SupportListItemBlock && block is SupportListItemBlock
          ? 7.0
          : previous is SupportHeadingBlock
          ? 8.0
          : block is SupportHeadingBlock
          ? 22.0
          : 14.0;
      children.add(
        Padding(
          padding: EdgeInsets.only(top: gap),
          child: _markdownBlock(block, i),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  TextSpan _rich(SupportRichText value, TextStyle style, int block) {
    // Boundaries where any style starts or ends; each piece gets every style covering it.
    final length = value.text.length;
    int bound(int v) => v < 0 ? 0 : (v > length ? length : v);
    final cuts = <int>{0, length};
    for (final s in value.spans) {
      cuts
        ..add(bound(s.start))
        ..add(bound(s.end));
    }
    final points = cuts.toList()..sort();
    final pieces = <InlineSpan>[];
    for (var p = 0; p + 1 < points.length; p++) {
      final from = points[p], to = points[p + 1];
      if (from >= to) continue;
      var piece = const TextStyle();
      String? link;
      for (var k = 0; k < value.spans.length; k++) {
        final s = value.spans[k];
        if (s.start > from || s.end < to) continue;
        switch (s.style) {
          case SupportInlineStyle.bold:
            piece = piece.copyWith(fontWeight: FontWeight.w700);
          case SupportInlineStyle.italic:
            piece = piece.copyWith(fontStyle: FontStyle.italic);
          case SupportInlineStyle.strike:
            piece = piece.copyWith(decoration: TextDecoration.lineThrough);
          case SupportInlineStyle.code:
            piece = piece.copyWith(
              fontFamily: 'monospace',
              fontFamilyFallback: const ['Menlo', 'Courier'],
              backgroundColor: colors.primary.withValues(alpha: 0.07),
            );
          case SupportInlineStyle.link:
            link = s.url;
            piece = piece.copyWith(
              color: palette.accent,
              decoration: TextDecoration.underline,
              decorationColor: palette.accent,
            );
        }
      }
      final url = link;
      pieces.add(
        TextSpan(
          text: value.text.substring(from, to),
          style: piece,
          recognizer: url == null
              ? null
              : ((_linkTaps['$block:$from'] ??= TapGestureRecognizer())
                  ..onTap = () => _openLink(url)),
        ),
      );
    }
    return TextSpan(style: style, children: pieces);
  }

  Widget _markdownBlock(SupportMarkdownBlock block, int index) {
    final body = TextStyle(fontSize: 16, height: 1.4, color: colors.primary);
    switch (block) {
      case SupportHeadingBlock(:final level, :final text):
        return Semantics(
          header: true,
          child: Text.rich(
            _rich(
              text,
              TextStyle(
                fontSize: switch (level) {
                  1 => 23.0,
                  2 => 20.0,
                  3 => 17.0,
                  _ => 15.5,
                },
                fontWeight: level <= 2 ? FontWeight.w700 : FontWeight.w600,
                height: 1.25,
                color: colors.primary,
              ),
              index,
            ),
          ),
        );
      case SupportParagraphBlock(:final text):
        return Text.rich(_rich(text, body, index));
      case SupportListItemBlock(:final number, :final depth, :final text):
        return Padding(
          padding: EdgeInsetsDirectional.only(start: depth * 20.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: number == null ? 12 : 24,
                child: number == null
                    ? Padding(
                        padding: const EdgeInsets.only(top: 9),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: palette.accent.withValues(
                                alpha: depth == 0 ? 1 : 0.5,
                              ),
                            ),
                          ),
                        ),
                      )
                    : Text(
                        '$number.',
                        textAlign: TextAlign.end,
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          fontWeight: FontWeight.w600,
                          color: palette.accent,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text.rich(_rich(text, body, index))),
            ],
          ),
        );
      case SupportQuoteBlock(:final text):
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 4,
                decoration: BoxDecoration(
                  color: palette.accent.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text.rich(
                  _rich(
                    text,
                    TextStyle(
                      fontSize: 15.5,
                      height: 1.4,
                      fontStyle: FontStyle.italic,
                      color: colors.muted,
                    ),
                    index,
                  ),
                ),
              ),
            ],
          ),
        );
      case SupportCodeBlock(:final code):
        return Directionality(
          textDirection: TextDirection.ltr,
          child: Container(
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(14),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(14),
              child: SelectableText(
                code,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.35,
                  fontFamily: 'monospace',
                  fontFamilyFallback: const ['Menlo', 'Courier'],
                  color: colors.primary,
                ),
              ),
            ),
          ),
        );
      case SupportRuleBlock():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Divider(
            height: 1,
            thickness: 0.5,
            color: colors.muted.withValues(alpha: 0.3),
          ),
        );
      case SupportImageBlock(:final url, :final alt):
        return Semantics(
          image: true,
          label: alt.isEmpty
              ? SupportStrings.text('support.a11y.screenshot')
              : alt,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: Image.network(
                url,
                fit: BoxFit.contain,
                excludeFromSemantics: true,
                loadingBuilder: (_, child, progress) => progress == null
                    ? child
                    : Container(
                        height: 160,
                        color: colors.primary.withValues(alpha: 0.05),
                      ),
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        );
    }
  }

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
                  padding: const EdgeInsetsDirectional.only(top: 5, end: 4),
                  child: Text(
                    notice.text(lastDate == null ? null : _clock(lastDate)),
                    textAlign: TextAlign.end,
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
                SupportStrings.text('support.a11y.back'),
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
                            persona?.name ??
                                agent ??
                                SupportStrings.text('support.thread.team', {
                                  'app': appName,
                                }),
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
                          ? SupportStrings.text(
                              'support.thread.personaSubtitle',
                              {'app': appName},
                            )
                          : SupportStrings.text('support.thread.replyTime', {
                              'time': config.replyTime,
                            }),
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
    final raw = AppReferSupportOfferCard.fromJson(m['offer']);
    final rawReview = raw == null
        ? AppReferSupportReviewCard.fromJson(m['review'])
        : null;
    if (raw == null && rawReview == null) return _bubble(i);
    if (rawReview != null) {
      final review = reviewCards[rawReview.cardId] ?? rawReview;
      final words = '${m['text'] ?? ''}';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (words.isNotEmpty) ...[_bubble(i), const SizedBox(height: 8)],
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 38),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: _reviewCard(review),
              ),
            ),
          ),
        ],
      );
    }
    final card = offerCards[raw!.cardId] ?? raw;
    final text = '${m['text'] ?? ''}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (text.isNotEmpty || m['from'] == 'bot') ...[
          _bubble(i),
          const SizedBox(height: 8),
        ],
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 38),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: _offerCard(card),
            ),
          ),
        ),
      ],
    );
  }

  Widget _bubble(int i) {
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
    padding: const EdgeInsetsDirectional.only(end: 40),
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
                borderRadius: BorderRadiusDirectional.only(
                  topStart: const Radius.circular(22),
                  topEnd: const Radius.circular(22),
                  bottomEnd: const Radius.circular(22),
                  bottomStart: Radius.circular(avatar ? 6 : 22),
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
        padding: const EdgeInsetsDirectional.fromSTEB(5, 5, 12, 5),
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
                to == null
                    ? SupportStrings.text('support.thread.handoff.team', {
                        'time': config.replyTime,
                      })
                    : SupportStrings.text('support.thread.handoff.person', {
                        'name': to,
                        'time': config.replyTime,
                      }),
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
                semanticLabel: SupportStrings.text(
                  'support.a11y.imageUnavailable',
                ),
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
      SupportStrings.text('support.a11y.screenshot'),
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
      padding: const EdgeInsetsDirectional.only(start: 60),
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
      borderRadius: BorderRadiusDirectional.only(
        topStart: const Radius.circular(22),
        topEnd: const Radius.circular(22),
        bottomStart: const Radius.circular(22),
        bottomEnd: Radius.circular(tail ? 6 : 22),
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
      padding: const EdgeInsetsDirectional.only(end: 40),
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
                      borderRadius: BorderRadiusDirectional.only(
                        topStart: const Radius.circular(22),
                        topEnd: const Radius.circular(22),
                        bottomEnd: const Radius.circular(22),
                        bottomStart: Radius.circular(avatar ? 6 : 22),
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
    padding: const EdgeInsetsDirectional.only(end: 50),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
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
              '✦ ${SupportStrings.upper(SupportStrings.text('support.thread.instantAnswer'))}',
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
    padding: const EdgeInsetsDirectional.only(start: 60),
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
            child: Text(
              SupportStrings.text('support.thread.notSent'),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xffe5383b),
              ),
            ),
          )
        else
          Text(
            SupportStrings.text('support.thread.sending'),
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
    final thanks = SupportStrings.text('support.thread.quickReply.thanks');
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          chip(thanks, () => _sendThread(thanks)),
          const SizedBox(width: 8),
          chip(
            SupportStrings.text('support.thread.quickReply.another'),
            threadFocus.requestFocus,
          ),
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
    // The chat speaks the language the app is running in (see SupportStrings).
    final appLocale = Localizations.maybeLocaleOf(context);
    SupportStrings.appLocales = appLocale == null ? null : [appLocale];
    final host = Theme.of(context);
    final accent = config.accentColor ?? host.colorScheme.primary;
    final dark =
        host.brightness == Brightness.dark ||
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final brightness = dark ? Brightness.dark : Brightness.light;
    palette = SupportPalette(accent);
    colors = SupportColors(dark);
    header = SupportHeaderLook(config.headerStyle, palette, dark: dark);
    final overlay = id == null && helpStack.isEmpty
        ? (header.foregroundIsDark
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
      child: Directionality(
        textDirection: SupportStrings.textDirection,
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: overlay,
          child: PopScope(
            canPop: id == null && helpStack.isEmpty,
            onPopInvokedWithResult: (popped, result) {
              if (!popped) _back();
            },
            child: Scaffold(
              backgroundColor: colors.background,
              body: id != null
                  ? _thread()
                  : helpStack.isEmpty
                  ? _home()
                  : helpStack.last.isArticle
                  ? _articleScreen(helpStack.last)
                  : _helpCentre(),
            ),
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
  Widget build(BuildContext context) => Directionality(
    textDirection: SupportStrings.textDirection,
    child: AnnotatedRegion<SystemUiOverlayStyle>(
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
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              PositionedDirectional(
                top: MediaQuery.paddingOf(context).top + 16,
                end: 16,
                child: IconButton(
                  tooltip: SupportStrings.text('support.a11y.close'),
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
    ),
  );
}

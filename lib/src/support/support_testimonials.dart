import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'apprefer_support.dart' show AppReferSupport;
import 'support_api.dart';
import 'support_strings.dart';
import 'support_style.dart';

// Photo/video testimonials (server: lib/support/testimonials.ts). A request is
// always made by something the app trusts (its backend, its coach tool, a
// person in Support, the AI within the app's policy, or automation); this SDK
// only answers one, for the account the support session is verified for
// (`AppReferSDK.support.verifyIdentity`). The reward and the publication
// permission text come from the request: the SDK never chooses a reward and
// never ties it to what is said. Taking part earns the reward; public use is a
// separate switch that starts on and the customer can turn off. Only the final
// Share sends its value, with the permission version shown.

/// A photo/video request as the server sends it.
@immutable
class AppReferTestimonialRequest {
  const AppReferTestimonialRequest({
    required this.requestId,
    required this.status,
    this.campaignId,
    this.title,
    this.prompt,
    this.media = const [],
    this.maxVideoSeconds,
    this.rewardType,
    this.rewardDescription,
    this.permissionText,
    this.permissionScopes = const [],
    this.permissionVersion,
    this.expiresAt,
    this.submittedAt,
    this.publication,
    this.rewardStatus,
  });

  final String requestId;

  /// open, submitted, declined, expired, withdrawn or unavailable.
  final String status;
  final String? campaignId;
  final String? title;
  final String? prompt;

  /// "image" and/or "video".
  final List<String> media;
  final int? maxVideoSeconds;

  /// credits, coach_usage, subscription_time, discount, gift, merch or manual;
  /// null when the campaign has no reward.
  final String? rewardType;

  /// What the customer gets, as the app wrote it (e.g. "50 bonus credits").
  final String? rewardDescription;

  /// Exactly what a "yes" to public use allows, shown word for word.
  final String? permissionText;
  final List<String> permissionScopes;
  final String? permissionVersion;
  final String? expiresAt;
  final String? submittedAt;

  /// granted, declined, revoked, or null before an answer.
  final String? publication;

  /// none (nothing earned yet), pending, delivered, fulfilled, failed,
  /// timed_out or not_eligible.
  final String? rewardStatus;

  bool get isOpen => status == 'open';
  bool get allowsImages => media.contains('image');
  bool get allowsVideos => media.contains('video');

  /// The table key for the reward line after sharing. Confirmed only once the
  /// app's backend reported its receipt (`fulfilled`); in-account rewards say
  /// "added to your account", anything else just "confirmed" (no delivery or
  /// email promise).
  String get rewardStatusKey => switch (rewardStatus) {
    'fulfilled' =>
      const {'credits', 'coach_usage', 'subscription_time'}.contains(rewardType)
          ? 'support.testimonial.rewardDone.account'
          : 'support.testimonial.rewardDone',
    'failed' || 'timed_out' => 'support.testimonial.rewardDelayed',
    'not_eligible' => 'support.testimonial.rewardNotEligible',
    _ => 'support.testimonial.rewardPending',
  };

  /// Null when the value isn't a request: no broken card is drawn.
  static AppReferTestimonialRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['requestId'], status = raw['status'];
    if (id is! String || status is! String) return null;
    final reward = raw['reward'] is Map ? raw['reward'] as Map : null;
    final permission = raw['permission'] is Map
        ? raw['permission'] as Map
        : null;
    String? str(Object? v) => v is String ? v : null;
    return AppReferTestimonialRequest(
      requestId: id,
      status: status,
      campaignId: str(raw['campaignId']),
      title: str(raw['title']),
      prompt: str(raw['prompt']),
      media: raw['media'] is List
          ? (raw['media'] as List).whereType<String>().toList()
          : const [],
      maxVideoSeconds: raw['maxVideoSeconds'] is num
          ? (raw['maxVideoSeconds'] as num).toInt()
          : null,
      rewardType: str(reward?['type']),
      rewardDescription: str(reward?['description']),
      permissionText: str(permission?['text']),
      permissionScopes: permission?['scopes'] is List
          ? (permission!['scopes'] as List).whereType<String>().toList()
          : const [],
      permissionVersion: str(permission?['version']),
      expiresAt: str(raw['expiresAt']),
      submittedAt: str(raw['submittedAt']),
      publication: str(raw['publication']),
      rewardStatus: str(raw['rewardStatus']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppReferTestimonialRequest &&
      other.requestId == requestId &&
      other.status == status &&
      other.publication == publication &&
      other.rewardStatus == rewardStatus;
  @override
  int get hashCode => Object.hash(requestId, status, publication, rewardStatus);
}

/// How a capture screen ended (submitted, declined, cancelled or
/// unavailable), and the reward's state then.
@immutable
class AppReferTestimonialResult {
  const AppReferTestimonialResult(
    this.requestId,
    this.outcome,
    this.rewardStatus,
    this.publication,
  );
  final String requestId;
  final String outcome;
  final String? rewardStatus;
  final String? publication;
  @override
  bool operator ==(Object other) =>
      other is AppReferTestimonialResult &&
      other.requestId == requestId &&
      other.outcome == outcome &&
      other.rewardStatus == rewardStatus &&
      other.publication == publication;
  @override
  int get hashCode =>
      Object.hash(requestId, outcome, rewardStatus, publication);
}

/// A reward state change the SDK saw. On `fulfilled` your backend confirmed
/// it: refresh the user's credits or usage.
@immutable
class AppReferTestimonialRewardUpdate {
  const AppReferTestimonialRewardUpdate(this.requestId, this.rewardStatus);
  final String requestId;
  final String rewardStatus;
}

/// A photo or video ready to upload (a file in the app's cache).
@immutable
class TestimonialFile {
  const TestimonialFile({
    required this.path,
    required this.contentType,
    required this.kind,
    required this.size,
    this.durationMs,
  });
  final String path;
  final String contentType;
  final String kind;
  final int size;
  final int? durationMs;
  static TestimonialFile? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'], type = raw['contentType'], kind = raw['kind'];
    final size = raw['size'];
    if (path is! String || type is! String || kind is! String || size is! num)
      return null;
    return TestimonialFile(
      path: path,
      contentType: type,
      kind: kind,
      size: size.toInt(),
      durationMs: raw['durationMs'] is num
          ? (raw['durationMs'] as num).toInt()
          : null,
    );
  }
}

class TestimonialSlot {
  TestimonialSlot(this.uploadId, this.uploadUrl, this.headers);
  final String uploadId;
  final String uploadUrl;
  final Map<String, String> headers;
}

/// What the capture flow needs from the network (tests stand in for it).
abstract class TestimonialTransport {
  Future<AppReferTestimonialRequest> request(String id);
  Future<TestimonialSlot> slot(String id, String contentType, int size);
  Future<void> put(
    TestimonialFile file,
    TestimonialSlot slot,
    void Function(double) progress,
  );
  Future<AppReferTestimonialRequest> submit(
    String id,
    String uploadId,
    String clientSubmissionId,
    bool publication,
    String version,
  );
  Future<AppReferTestimonialRequest?> decline(String id, bool dontAskAgain);
}

AppReferTestimonialRequest _request(Map<String, dynamic> data) =>
    AppReferTestimonialRequest.fromJson(data['request']) ??
    (throw SupportException(0, 'Unreadable request'));

/// The live transport, pinned to the account generation it was made in: a
/// reset or account switch makes every later call fail instead of reaching
/// another account.
class LiveTestimonialTransport implements TestimonialTransport {
  LiveTestimonialTransport(this.api) : epoch = api.actionGeneration;
  final SupportAPI api;
  final int epoch;
  String _path(String id, [String tail = '']) =>
      '/testimonials/${Uri.encodeComponent(id)}$tail';

  @override
  Future<AppReferTestimonialRequest> request(String id) async =>
      _request(await api.call('GET', _path(id), null, epoch));

  @override
  Future<TestimonialSlot> slot(String id, String contentType, int size) async {
    final data = await api.call('POST', _path(id, '/uploads'), {
      'contentType': contentType,
      'size': size,
    }, epoch);
    final url = data['uploadUrl'];
    if (url is! String || !url.startsWith('https://'))
      throw SupportException(
        0,
        'Bad upload address',
        reason: SupportErrorReason.upload,
      );
    return TestimonialSlot(
      '${data['uploadId']}',
      url,
      (data['headers'] is Map ? data['headers'] as Map : const {}).map(
        (k, v) => MapEntry('$k', '$v'),
      ),
    );
  }

  @override
  Future<void> put(
    TestimonialFile file,
    TestimonialSlot slot,
    void Function(double) progress,
  ) async {
    if (epoch != api.actionGeneration)
      throw SupportException(
        0,
        'Support reset',
        reason: SupportErrorReason.reset,
      );
    final request = http.StreamedRequest('PUT', Uri.parse(slot.uploadUrl));
    request.headers.addAll(slot.headers);
    request.contentLength = file.size;
    final response = api.client.send(request);
    var sent = 0;
    await for (final chunk in File(file.path).openRead()) {
      request.sink.add(chunk);
      sent += chunk.length;
      progress(file.size == 0 ? 1 : min(1, sent / file.size));
    }
    await request.sink.close();
    final status = (await response).statusCode;
    if (epoch != api.actionGeneration)
      throw SupportException(
        0,
        'Support reset',
        reason: SupportErrorReason.reset,
      );
    if (status < 200 || status >= 300)
      throw SupportException(
        status,
        "The upload didn't finish ($status)",
        reason: SupportErrorReason.upload,
      );
  }

  @override
  Future<AppReferTestimonialRequest> submit(
    String id,
    String uploadId,
    String clientSubmissionId,
    bool publication,
    String version,
  ) async => _request(
    await api.call('POST', _path(id, '/submit'), {
      'uploadId': uploadId,
      'clientSubmissionId': clientSubmissionId,
      'publication': publication,
      'permissionVersion': version,
    }, epoch),
  );

  @override
  Future<AppReferTestimonialRequest?> decline(
    String id,
    bool dontAskAgain,
  ) async => AppReferTestimonialRequest.fromJson(
    (await api.call('POST', _path(id, '/decline'), {
      'dontAskAgain': dontAskAgain,
    }, epoch))['request'],
  );
}

enum TestimonialPhase {
  loading,
  ready,
  uploading,
  checking,
  done,
  unavailable,
  failed,
}

/// The capture flow's state, separate from the widgets so it can be tested
/// without UI.
class TestimonialFlow extends ChangeNotifier {
  TestimonialFlow(this.requestId, this._transport);
  final String requestId;
  final TestimonialTransport _transport;
  TestimonialPhase phase = TestimonialPhase.loading;
  double progress = 0;
  AppReferTestimonialRequest? request;
  TestimonialFile? file;

  /// Public use starts on; the customer can turn it off. Nothing is recorded
  /// until [submit] (opening, picking or cancelling sends no answer), and a
  /// request without permission text (an older server) can't be submitted,
  /// so no permission is ever assumed.
  bool publish = true;

  /// The localized message for the last problem (null when none).
  String? notice;

  /// The same on every retry: a lost answer never shares twice.
  final String _clientSubmissionId =
      'flt_${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  /// The upload of [file] that already reached storage (a retry only resubmits).
  ({String path, String uploadId})? _uploaded;

  void _changed() => notifyListeners();

  Future<void> load() async {
    try {
      final r = await _transport.request(requestId);
      request = r;
      phase = r.isOpen
          ? TestimonialPhase.ready
          : r.status == 'submitted'
          ? TestimonialPhase.done
          : TestimonialPhase.unavailable;
      if (r.status == 'submitted')
        AppReferTestimonials.instance.note(requestId, r.rewardStatus ?? 'none');
    } catch (e) {
      final refused =
          e is SupportException &&
          (e.status == 404 || e.code == 'IDENTITY_REQUIRED');
      notice = SupportStrings.text(
        refused
            ? 'support.testimonial.unavailable'
            : 'support.testimonial.failed',
      );
      phase = refused ? TestimonialPhase.unavailable : TestimonialPhase.failed;
    }
    _changed();
  }

  void picked(TestimonialFile f) {
    file = f;
    notice = null;
    _uploaded = null;
    if (phase == TestimonialPhase.failed) phase = TestimonialPhase.ready;
    _changed();
  }

  void pickFailed(String code, int seconds) {
    // Nothing chosen, or the camera went away between showing the button and
    // the tap: no message (the library is still offered).
    if (code == 'cancelled' || code == 'unavailable') return;
    notice = switch (code) {
      'too_long' => SupportStrings.text('support.testimonial.tooLong', {
        'seconds': '$seconds',
      }),
      'too_large' => SupportStrings.text('support.testimonial.tooLarge'),
      'camera_denied' => SupportStrings.text(
        'support.testimonial.cameraDenied',
      ),
      _ => SupportStrings.text('support.error.imageUnreadable'),
    };
    _changed();
  }

  static const _refusedFile = {
    'TYPE_MISMATCH',
    'UNREADABLE_VIDEO',
    'VIDEO_TOO_LONG',
    'UPLOAD_INCOMPLETE',
    'UPLOAD_CHANGED',
    'UNKNOWN_UPLOAD',
  };
  static const _closed = {
    'REQUEST_CLOSED',
    'CAMPAIGN_ENDED',
    'IDENTITY_REQUIRED',
    'ALREADY_SUBMITTED',
  };

  /// Uploads (unless this file already reached storage) and shares. Safe to
  /// call again after a failure.
  Future<void> submit() async {
    final r = request, f = file, version = request?.permissionVersion;
    if (r == null || f == null || version == null) return;
    notice = null;
    try {
      String uploadId;
      final done = _uploaded;
      if (done != null && done.path == f.path) {
        uploadId = done.uploadId;
      } else {
        phase = TestimonialPhase.uploading;
        progress = 0;
        _changed();
        final slot = await _transport.slot(requestId, f.contentType, f.size);
        await _transport.put(f, slot, (p) {
          progress = p;
          _changed();
        });
        _uploaded = (path: f.path, uploadId: slot.uploadId);
        uploadId = slot.uploadId;
      }
      phase = TestimonialPhase.checking;
      _changed();
      final shared = await _transport.submit(
        requestId,
        uploadId,
        _clientSubmissionId,
        publish,
        version,
      );
      request = shared;
      phase = TestimonialPhase.done;
      AppReferTestimonials.instance.note(
        requestId,
        shared.rewardStatus ?? 'none',
      );
    } catch (e) {
      final code = e is SupportException ? e.code : null;
      if (e is SupportException && e.reason == SupportErrorReason.reset) {
        phase = TestimonialPhase.unavailable;
        notice = SupportStrings.text('support.testimonial.unavailable');
      } else {
        if (_refusedFile.contains(code)) _uploaded = null;
        if (_closed.contains(code) ||
            (e is SupportException && e.status == 404)) {
          notice = SupportStrings.text('support.testimonial.unavailable');
          phase = TestimonialPhase.unavailable;
        } else {
          notice = code == 'VIDEO_TOO_LONG'
              ? SupportStrings.text('support.testimonial.tooLong', {
                  'seconds': '${r.maxVideoSeconds ?? 0}',
                })
              : code == 'TOO_LARGE'
              ? SupportStrings.text('support.testimonial.tooLarge')
              : SupportStrings.text('support.testimonial.failed');
          phase = TestimonialPhase.failed;
        }
      }
    }
    _changed();
  }

  Future<AppReferTestimonialResult> decline(bool dontAskAgain) async {
    AppReferTestimonialRequest? r;
    try {
      r = await _transport.decline(requestId, dontAskAgain);
    } catch (_) {}
    return AppReferTestimonialResult(
      requestId,
      'declined',
      r?.rewardStatus,
      null,
    );
  }

  /// While the done screen is open: check the reward a few times (the app's
  /// backend applies it).
  Future<void> followReward({
    List<Duration> delays = const [
      Duration(seconds: 3),
      Duration(seconds: 5),
      Duration(seconds: 8),
      Duration(seconds: 13),
      Duration(seconds: 21),
    ],
  }) async {
    for (final delay in delays) {
      final status = request?.rewardStatus;
      if (phase != TestimonialPhase.done ||
          (status != 'pending' && status != 'delivered'))
        return;
      await Future<void>.delayed(delay);
      try {
        request = await _transport.request(requestId);
      } catch (_) {
        return;
      }
      AppReferTestimonials.instance.note(
        requestId,
        request?.rewardStatus ?? 'none',
      );
      _changed();
    }
  }

  AppReferTestimonialResult get result => AppReferTestimonialResult(
    requestId,
    phase == TestimonialPhase.done
        ? 'submitted'
        : phase == TestimonialPhase.unavailable
        ? 'unavailable'
        : 'cancelled',
    request?.rewardStatus,
    request?.publication,
  );
}

/// `AppReferSDK.support.testimonials`: show a photo/video request your backend
/// (or its coach tool) made (`POST /api/v1/apps/{appId}/support/testimonials/requests`
/// returns the request id), list open ones, and refresh credits in
/// [onRewardUpdate] once your backend confirms the reward.
class AppReferTestimonials {
  AppReferTestimonials._();
  static final instance = AppReferTestimonials._();

  /// Set by the support module; the testimonial calls use the Support session.
  SupportAPI Function()? api;

  /// Called when the SDK sees a reward state change. On `fulfilled`, refresh
  /// the user's credits or usage.
  void Function(AppReferTestimonialRewardUpdate update)? onRewardUpdate;
  final Map<String, String> _lastReward = {};

  SupportAPI get _api =>
      (api ?? (throw StateError('Configure AppRefer first')))();

  /// Whether the camera can take a photo (`video: false`) or record a video
  /// (`video: true`) now. The photo library is always offered. On Android a
  /// CAMERA permission the app declares is asked for at the moment of capture.
  Future<bool> cameraAvailable({bool video = true}) async =>
      await supportChannel.invokeMethod<bool>('testimonialCameraAvailable', {
        'video': video,
      }) ??
      false;

  /// Open requests for the verified account (empty when the session isn't
  /// verified).
  Future<List<AppReferTestimonialRequest>> pending() => pendingWith(_api);

  /// The same through a given Support API (the chat view's own).
  Future<List<AppReferTestimonialRequest>> pendingWith(SupportAPI api) async {
    final data = await api.call('GET', '/testimonials');
    return [
      for (final r
          in (data['requests'] is List ? data['requests'] as List : const []))
        if (AppReferTestimonialRequest.fromJson(r) case final request?) request,
    ];
  }

  /// One request; throws [SupportException] (code `IDENTITY_REQUIRED`) until
  /// the app verified this account.
  Future<AppReferTestimonialRequest> request(String requestId) =>
      LiveTestimonialTransport(_api).request(requestId);

  /// The reward's state now; calls [onRewardUpdate] when it changed.
  Future<String> rewardStatus(String requestId) async {
    final status = (await request(requestId)).rewardStatus ?? 'none';
    note(requestId, status);
    return status;
  }

  /// Withdraws permission for public use of something already shared. The
  /// reward is unaffected.
  Future<void> withdrawPublication(String requestId) async {
    await _api.call(
      'POST',
      '/testimonials/${Uri.encodeComponent(requestId)}/permission',
      {'publication': 'revoked'},
    );
  }

  /// Shows the capture screen for a request your backend made.
  Future<AppReferTestimonialResult?> present(
    BuildContext context,
    String requestId,
  ) => presentOn(Navigator.of(context), requestId);

  /// The same on a navigator (used for invitation notifications, through
  /// `AppReferSDK.support.navigatorKey`).
  Future<AppReferTestimonialResult?> presentOn(
    NavigatorState navigator,
    String requestId,
  ) => navigator.push<AppReferTestimonialResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => AppReferTestimonialScreen(requestId: requestId),
    ),
  );

  @visibleForTesting
  void note(String requestId, String rewardStatus) {
    final previous = _lastReward[requestId];
    _lastReward[requestId] = rewardStatus;
    if (previous == rewardStatus ||
        (previous == null && rewardStatus == 'none'))
      return;
    onRewardUpdate?.call(
      AppReferTestimonialRewardUpdate(requestId, rewardStatus),
    );
  }

  void reset() => _lastReward.clear();
}

/// Native photo/video picking (system photo picker or camera), normalised by
/// the plugin: JPEG without metadata for photos, metadata-free MP4 for
/// videos, refused when longer than allowed. With the camera, [capture] is
/// `image` (a still photo) or `video`.
Future<TestimonialFile?> pickTestimonialMedia({
  required bool camera,
  required bool images,
  required bool videos,
  required int maxSeconds,
  required void Function(String code, int seconds) failed,
  String? capture,
}) async {
  try {
    final raw = await supportChannel
        .invokeMethod<Map<Object?, Object?>>('testimonialPick', {
          'source': camera ? 'camera' : 'library',
          'images': capture == null ? images : capture == 'image',
          'videos': capture == null ? videos : capture == 'video',
          'maxSeconds': maxSeconds,
          if (capture != null) 'capture': capture,
        });
    return TestimonialFile.fromMap(raw);
  } on PlatformException catch (e) {
    final seconds = e.details is int ? e.details as int : 0;
    failed(e.code, seconds);
    return null;
  }
}

/// The capture screen: what's asked, the reward, pick or record, preview,
/// public use (on unless the customer turns it off) with the app's exact
/// permission text, honest
/// progress, then the result. Pops with an [AppReferTestimonialResult].
class AppReferTestimonialScreen extends StatefulWidget {
  const AppReferTestimonialScreen({
    super.key,
    required this.requestId,
    this.transport,
    this.cameraAvailable,
  });
  final String requestId;
  @visibleForTesting
  final TestimonialTransport? transport;
  @visibleForTesting
  final bool? cameraAvailable;
  @override
  State<AppReferTestimonialScreen> createState() =>
      _AppReferTestimonialScreenState();
}

class _AppReferTestimonialScreenState extends State<AppReferTestimonialScreen> {
  late final TestimonialFlow flow = TestimonialFlow(
    widget.requestId,
    widget.transport ??
        LiveTestimonialTransport(AppReferTestimonials.instance._api),
  )..addListener(_update);

  /// The camera can take a still photo / record a video on this device.
  bool cameraPhoto = false, cameraVideo = false;
  bool _following = false;

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    unawaited(flow.load());
    final known = widget.cameraAvailable;
    if (known != null) {
      cameraPhoto = cameraVideo = known;
    } else {
      for (final video in [false, true]) {
        AppReferTestimonials.instance
            .cameraAvailable(video: video)
            .then((v) {
              if (!mounted) return;
              setState(() => video ? cameraVideo = v : cameraPhoto = v);
            })
            .catchError((_) {});
      }
    }
  }

  @override
  void dispose() {
    flow.removeListener(_update);
    final f = flow.file;
    if (f != null && flow.phase != TestimonialPhase.done) {
      unawaited(
        supportChannel
            .invokeMethod<void>('testimonialDiscard', f.path)
            .catchError((_) {}),
      );
    }
    super.dispose();
  }

  bool get _busy =>
      flow.phase == TestimonialPhase.uploading ||
      flow.phase == TestimonialPhase.checking;

  void _close([AppReferTestimonialResult? result]) =>
      Navigator.of(context).pop(result ?? flow.result);

  /// [capture]: null = the photo library; `camera` = the iOS camera (photo or
  /// video in one screen); `image` / `video` = Android's camera app for one kind.
  Future<void> _pick([String? capture]) async {
    final r = flow.request;
    if (r == null) return;
    final f = await pickTestimonialMedia(
      camera: capture != null,
      images: r.allowsImages && (capture != 'camera' || cameraPhoto),
      videos: r.allowsVideos && (capture != 'camera' || cameraVideo),
      maxSeconds: r.maxVideoSeconds ?? 30,
      failed: flow.pickFailed,
      capture: capture == 'image' || capture == 'video' ? capture : null,
    );
    if (f != null) flow.picked(f);
  }

  /// Camera buttons: Android's camera app takes either a photo or a video, so
  /// each allowed kind gets its own; iOS offers both in one camera screen.
  List<Widget> _cameraButtons(
    AppReferTestimonialRequest r,
    SupportPalette palette,
  ) {
    final photo = r.allowsImages && cameraPhoto;
    final video = r.allowsVideos && cameraVideo;
    Widget gap(Widget w) =>
        Padding(padding: const EdgeInsets.only(top: 10), child: w);
    if (defaultTargetPlatform != TargetPlatform.android) {
      return [
        if (photo || video)
          gap(
            _button(
              SupportStrings.text('support.testimonial.camera'),
              palette,
              false,
              () => _pick('camera'),
              Icons.photo_camera_outlined,
            ),
          ),
      ];
    }
    return [
      if (photo)
        gap(
          _button(
            SupportStrings.text('support.testimonial.takePhoto'),
            palette,
            false,
            () => _pick('image'),
            Icons.photo_camera_outlined,
          ),
        ),
      if (video)
        gap(
          _button(
            SupportStrings.text('support.testimonial.recordVideo'),
            palette,
            false,
            () => _pick('video'),
            Icons.videocam_outlined,
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final colors = SupportColors(dark);
    final palette = SupportPalette(
      AppReferSupport.instance.accentColor ??
          Theme.of(context).colorScheme.primary,
    );
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            children: [
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: IconButton(
                  tooltip: SupportStrings.text('support.testimonial.cancel'),
                  onPressed: _busy ? null : () => _close(),
                  icon: const Icon(Icons.close),
                ),
              ),
              ..._content(colors, palette),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _content(SupportColors colors, SupportPalette palette) {
    final r = flow.request;
    switch (flow.phase) {
      case TestimonialPhase.loading:
        return const [
          SizedBox(height: 120),
          Center(child: CircularProgressIndicator()),
        ];
      case TestimonialPhase.unavailable:
        return [
          const SizedBox(height: 24),
          _muted(
            SupportStrings.text('support.testimonial.unavailable'),
            colors,
          ),
          const SizedBox(height: 16),
          _button(
            SupportStrings.text('support.testimonial.cancel'),
            palette,
            true,
            () => _close(),
          ),
        ];
      case TestimonialPhase.done:
        if (!_following) {
          _following = true;
          unawaited(flow.followReward());
        }
        return [
          Icon(Icons.check_circle, size: 44, color: palette.accent),
          const SizedBox(height: 12),
          Semantics(
            header: true,
            child: Text(
              SupportStrings.text('support.testimonial.done'),
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
            ),
          ),
          if (r?.rewardDescription case final reward?) ...[
            const SizedBox(height: 14),
            _rewardBox(reward, colors),
            const SizedBox(height: 10),
            Text(
              SupportStrings.text(r!.rewardStatusKey),
              key: const ValueKey('supportTestimonialRewardStatus'),
              style: const TextStyle(fontSize: 15),
            ),
          ],
          const SizedBox(height: 20),
          _button(
            SupportStrings.text('support.a11y.close'),
            palette,
            true,
            () => _close(),
          ),
        ];
      default:
        if (r == null) {
          return [
            const SizedBox(height: 24),
            _muted(
              flow.notice ?? SupportStrings.text('support.testimonial.failed'),
              colors,
            ),
            const SizedBox(height: 16),
            _button(
              SupportStrings.text('support.action.tryAgain'),
              palette,
              true,
              () => flow.load(),
            ),
          ];
        }
        return _form(r, colors, palette);
    }
  }

  List<Widget> _form(
    AppReferTestimonialRequest r,
    SupportColors colors,
    SupportPalette palette,
  ) {
    final f = flow.file;
    return [
      Semantics(
        header: true,
        child: Text(
          r.title ?? SupportStrings.text('support.testimonial.open'),
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
        ),
      ),
      if (r.prompt case final prompt?) ...[
        const SizedBox(height: 8),
        Text(prompt, style: const TextStyle(fontSize: 16)),
      ],
      const SizedBox(height: 6),
      _muted(SupportStrings.text('support.testimonial.honest'), colors, 14),
      if (r.rewardDescription case final reward?) ...[
        const SizedBox(height: 14),
        _rewardBox(reward, colors),
      ],
      const SizedBox(height: 14),
      if (f != null) ...[
        Semantics(
          label: SupportStrings.text('support.testimonial.a11y.preview'),
          image: true,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Container(
              height: 280,
              color: Colors.black,
              alignment: Alignment.center,
              child: f.kind == 'image'
                  ? Image.file(File(f.path), fit: BoxFit.contain)
                  : const Icon(
                      Icons.play_circle_fill,
                      size: 56,
                      color: Colors.white,
                    ),
            ),
          ),
        ),
        if (!_busy) ...[
          const SizedBox(height: 10),
          _button(
            SupportStrings.text('support.testimonial.retake'),
            palette,
            false,
            () => _pick(),
          ),
        ],
        if (r.permissionText case final text?) ...[
          const SizedBox(height: 14),
          _box(colors, [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: flow.publish,
              activeTrackColor: palette.accent,
              onChanged: _busy ? null : (v) => setState(() => flow.publish = v),
              title: Text(
                SupportStrings.text('support.testimonial.publish'),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(text, style: const TextStyle(fontSize: 13.5)),
            const SizedBox(height: 6),
            _muted(
              SupportStrings.text('support.testimonial.publishHint'),
              colors,
              12.5,
            ),
          ]),
        ],
      ] else ...[
        _button(
          SupportStrings.text('support.testimonial.choose'),
          palette,
          true,
          () => _pick(),
          Icons.photo_library_outlined,
        ),
        ..._cameraButtons(r, palette),
        if (r.allowsVideos && r.maxVideoSeconds != null) ...[
          const SizedBox(height: 8),
          _muted(
            SupportStrings.text('support.testimonial.tooLong', {
              'seconds': '${r.maxVideoSeconds}',
            }),
            colors,
            13,
          ),
        ],
      ],
      if (flow.notice case final notice?) ...[
        const SizedBox(height: 12),
        _muted(notice, colors, 14),
      ],
      const SizedBox(height: 14),
      ...switch (flow.phase) {
        TestimonialPhase.uploading => [
          LinearProgressIndicator(value: flow.progress, color: palette.accent),
          const SizedBox(height: 4),
          _muted(
            SupportStrings.text('support.testimonial.uploading', {
              'percent': '${(flow.progress * 100).round()}',
            }),
            colors,
            14,
          ),
        ],
        TestimonialPhase.checking => [
          _muted(
            SupportStrings.text('support.testimonial.checking'),
            colors,
            14,
          ),
        ],
        _ => [
          if (f != null)
            _button(
              SupportStrings.text(
                flow.phase == TestimonialPhase.failed
                    ? 'support.action.tryAgain'
                    : 'support.testimonial.submit',
              ),
              palette,
              true,
              () => flow.submit(),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () async => _close(await flow.decline(false)),
                child: Text(
                  SupportStrings.text('support.testimonial.decline'),
                  style: TextStyle(color: colors.muted),
                ),
              ),
              TextButton(
                onPressed: () async => _close(await flow.decline(true)),
                child: Text(
                  SupportStrings.text('support.testimonial.dontAsk'),
                  style: TextStyle(color: colors.muted),
                ),
              ),
            ],
          ),
        ],
      },
    ];
  }

  Widget _rewardBox(String reward, SupportColors colors) => _box(colors, [
    Row(
      children: [
        const Icon(Icons.card_giftcard, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            SupportStrings.text('support.testimonial.reward', {
              'reward': reward,
            }),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
    const SizedBox(height: 4),
    _muted(SupportStrings.text('support.testimonial.rewardNote'), colors, 13),
  ]);

  Widget _box(SupportColors colors, List<Widget> children) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: colors.card,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ),
  );

  Widget _muted(String text, SupportColors colors, [double size = 15]) => Text(
    text,
    style: TextStyle(fontSize: size, color: colors.muted),
  );

  Widget _button(
    String label,
    SupportPalette palette,
    bool primary,
    VoidCallback onTap, [
    IconData? icon,
  ]) => SizedBox(
    height: 50,
    child: FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: primary
            ? palette.accent
            : palette.accent.withValues(alpha: 0.1),
        foregroundColor: primary ? palette.onAccent : palette.accent,
        shape: const StadiumBorder(),
      ),
      onPressed: onTap,
      icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 20),
      label: Text(
        label,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

/// Key of the invitation card on the Support home.
const supportTestimonialInviteKey = ValueKey('supportTestimonialInvite');

/// The request card under a team message in the chat, and the invitation card
/// on the Support home.
class SupportTestimonialCard extends StatelessWidget {
  const SupportTestimonialCard({
    super.key,
    required this.request,
    required this.palette,
    required this.colors,
    required this.open,
  });
  final AppReferTestimonialRequest request;
  final SupportPalette palette;
  final SupportColors colors;
  final VoidCallback open;

  @override
  Widget build(BuildContext context) {
    final active = request.isOpen;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: active
              ? palette.accent.withValues(alpha: 0.22)
              : colors.primary.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              request.title ?? SupportStrings.text('support.testimonial.open'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: colors.primary,
              ),
            ),
          ),
          if (active) ...[
            if (request.prompt case final prompt?) ...[
              const SizedBox(height: 8),
              Text(
                prompt,
                style: TextStyle(fontSize: 14.5, color: colors.primary),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              SupportStrings.text('support.testimonial.honest'),
              style: TextStyle(fontSize: 13, color: colors.muted),
            ),
            if (request.rewardDescription case final reward?) ...[
              const SizedBox(height: 8),
              Text(
                SupportStrings.text('support.testimonial.reward', {
                  'reward': reward,
                }),
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: palette.accent,
                ),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              height: 46,
              child: FilledButton(
                key: const ValueKey('supportTestimonialOpen'),
                style: FilledButton.styleFrom(
                  backgroundColor: palette.accent,
                  foregroundColor: palette.onAccent,
                  shape: const StadiumBorder(),
                ),
                onPressed: open,
                child: Text(SupportStrings.text('support.testimonial.open')),
              ),
            ),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              SupportStrings.text(
                request.status == 'submitted'
                    ? 'support.testimonial.done'
                    : 'support.testimonial.unavailable',
              ),
              style: TextStyle(fontSize: 13.5, color: colors.muted),
            ),
          ],
        ],
      ),
    );
  }
}

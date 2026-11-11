// A stand-in for the Go core (irmago behind `irma.app/irma_mobile_bridge`), at the same
// seam the app's own `IrmaMockBridge` sits: an `IrmaBridge`.
//
// `IrmaMockBridge` (lib/src/data/irma_mock_bridge.dart) answers the launch handshake
// with the scheme and nothing else ("TODO: mock bridge needs to be updated for new
// session state model"): no enrolment status, no cards, no PIN check, no sessions. With
// it the app stays on its splash screen until it shows a start-up error. This class
// answers every event the app sends the way `irmagobridge/receive_event.go` does, from
// an in-memory wallet, so the real `IrmaRepository`, routing and screens run unchanged.
import "dart:async";

import "package:yivi_core/src/data/irma_bridge.dart";
import "package:yivi_core/src/models/authentication_events.dart";
import "package:yivi_core/src/models/change_pin_events.dart";
import "package:yivi_core/src/models/clear_all_data_event.dart";
import "package:yivi_core/src/models/client_preferences.dart";
import "package:yivi_core/src/models/credential_events.dart";
import "package:yivi_core/src/models/enrollment_events.dart";
import "package:yivi_core/src/models/error_event.dart";
import "package:yivi_core/src/models/eudi_configuration.dart";
import "package:yivi_core/src/models/event.dart";
import "package:yivi_core/src/models/handle_url_event.dart";
import "package:yivi_core/src/models/irma_configuration.dart";
import "package:yivi_core/src/models/log_entry.dart";
import "package:yivi_core/src/models/native_events.dart";
import "package:yivi_core/src/models/schemaless/credential_store.dart";
import "package:yivi_core/src/models/schemaless/schemaless_events.dart";
import "package:yivi_core/src/models/schemaless/session_state.dart";
import "package:yivi_core/src/models/schemaless/session_user_interaction.dart";
import "package:yivi_core/src/models/session.dart";
import "package:yivi_core/src/models/session_events.dart";

import "wallet_data.dart" as data;
import "wallet_data.dart" show Json;

const keyshareScheme = "pbdf";

/// How long the core takes to answer. On a device every answer crosses the platform
/// channel and most of them a network round trip to the keyshare server, so the app
/// always shows its waiting state for a moment; the harness's fake clock runs past it.
const _latency = Duration(milliseconds: 150);

/// Wrong PINs the keyshare server allows before it blocks the account for a while.
const _pinAttempts = 3;

/// Things that go wrong outside the app, which it has screens for.
enum Trouble {
  none,

  /// The phone has no connection: the keyshare server cannot be reached.
  offline,

  /// The account was blocked at the keyshare server (through MyYivi, or after a
  /// lost phone was reported): the server no longer knows this user.
  blockedRemotely,

  /// The core could not start (its storage cannot be opened, for instance).
  cannotStart,

  /// Yivi's email and SMS issuers answer with a server error.
  issuerDown,
}

Json _transportError(String url) => {
  "error_type": "transport",
  "info": "",
  "wrapped_error":
      'Post "$url": dial tcp: lookup keyshare.yivi.app: no such host',
  "stack": "",
};

const Json _userNotFound = {
  "error_type": "api",
  "info": "",
  "wrapped_error": "",
  "stack": "",
  "remote_status": 403,
  "remote_error": {
    "status": 403,
    "error": "USER_NOT_FOUND",
    "description": "",
    "message": "",
  },
};

class FakeYiviCore extends IrmaBridge {
  FakeYiviCore({
    required this.enrolled,
    this.pin = "12345",
    this.trouble = Trouble.none,
    List<Json>? credentials,
    List<Json>? logs,
  }) : _credentials = [...?credentials],
       _logs = [...?logs];

  /// What is wrong on this run, if anything.
  final Trouble trouble;

  bool enrolled;
  String pin;
  final List<Json> _credentials;
  final List<Json> _logs;
  bool _developerMode = false;
  int _remainingPinAttempts = _pinAttempts;

  /// Open sessions by id: the URL that started them and the step they are at.
  final Map<int, _Session> _sessions = {};

  /// Types of the events the app sent, in order, for the per-screen log.
  final List<String> received = [];

  /// Events the app sent that the core has nothing to do for under test.
  final Set<String> ignored = {};

  bool _closed = false;

  void close() => _closed = true;

  void _send(Event event) {
    if (!_closed) addEvent(event);
  }

  /// A link the operating system hands the app (a tapped `https://open.yivi.app` link,
  /// or a QR code scanned with the phone's own camera app).
  void openUrl(String url) =>
      _later(() => _send(HandleURLEvent(url: url, isInitialUrl: false)));

  void _later(void Function() answer) => Timer(_latency, answer);

  @override
  void dispatch(Event event) {
    received.add("${event.runtimeType}");
    _later(() => _handle(event));
  }

  void _handle(Event event) {
    switch (event) {
      case AppReadyEvent() when trouble == Trouble.cannotStart:
        _send(
          ErrorEvent(
            exception:
                "open /data/user/0/org.irmacard.cardemu/app_storage/db2: "
                "file is not a database",
            stack:
                "goroutine 17 [running]:\n"
                "github.com/privacybydesign/irmago/irmaclient.New(...)\n"
                "\t/go/pkg/mod/github.com/privacybydesign/irmago/irmaclient/client.go:214\n"
                "irmagobridge.Start(...)\n"
                "\t/irmamobile/yivi_core/irmagobridge/bridge.go:112",
            fatal: true,
          ),
        );
      case AppReadyEvent():
        _sendEnrollmentStatus();
        _send(
          IrmaConfigurationEvent.fromJson({
            "irma_configuration": {
              ...data.schemeJson["IrmaConfiguration"] as Json,
              // No scheme managers. With any, `IrmaRepository.getVersionInformation`
              // reads each one's minimum app version for `Platform.operatingSystem`
              // and throws "Unsupported Platform.operatingSystem" on anything but
              // Android and iOS, the host of `flutter test` included. The router's
              // redirects wait on that stream (routing.dart, RedirectionListenable),
              // so with it broken the app never shows its rooted-device warning or
              // its rename notice and does not leave for onboarding after a wipe.
              "SchemeManagers": <String, dynamic>{},
            },
          }),
        );
        _send(
          EudiConfigurationEvent.fromJson({
            "eudi_configuration": {"issuers": <Json>[], "verifiers": <Json>[]},
          }),
        );
        _sendCredentials();
        _send(
          ClientPreferencesEvent(
            clientPreferences: ClientPreferences(developerMode: _developerMode),
          ),
        );
        _send(AppReadyAckEvent());
      case EnrollEvent() when trouble == Trouble.offline:
        _send(
          EnrollmentFailureEvent(
            schemeManagerID: event.schemeId,
            error: SessionError.fromJson(
              _transportError("https://keyshare.yivi.app/client/register"),
            ),
          ),
        );
      case EnrollEvent():
        enrolled = true;
        pin = event.pin;
        _remainingPinAttempts = _pinAttempts;
        _sendEnrollmentStatus();
        _send(EnrollmentSuccessEvent(schemeManagerID: event.schemeId));
      case AuthenticateEvent() when trouble == Trouble.offline:
        _send(
          AuthenticationErrorEvent(
            error: SessionError.fromJson(
              _transportError("https://keyshare.yivi.app/users/verify/pin"),
            ),
          ),
        );
      case AuthenticateEvent() when trouble == Trouble.blockedRemotely:
        _send(
          AuthenticationErrorEvent(error: SessionError.fromJson(_userNotFound)),
        );
      case AuthenticateEvent():
        if (_checkPin(event.pin)) {
          _send(AuthenticationSuccessEvent());
        } else {
          _send(
            AuthenticationFailedEvent(
              remainingAttempts: _remainingPinAttempts,
              blockedDuration: _remainingPinAttempts == 0 ? 60 : 0,
            ),
          );
        }
      case ChangePinEvent():
        if (_checkPin(event.oldPin)) {
          pin = event.newPin;
          _send(ChangePinSuccessEvent());
        } else {
          _send(
            ChangePinFailedEvent(
              schemeManagerID: keyshareScheme,
              remainingAttempts: _remainingPinAttempts,
              timeout: _remainingPinAttempts == 0 ? 60 : 0,
            ),
          );
        }
      case LoadLogsEvent():
        final before = event.before;
        final page = _logs
            .where(
              (log) =>
                  before == null ||
                  DateTime.parse(log["time"] as String).isBefore(before),
            )
            .take(event.max)
            .toList();
        _send(LogsEvent.fromJson({"log_entries": page}));
      case NewSessionEvent():
        _startSession(event);
      case SessionUserInteractionEvent():
        _continueSession(event);
      case DeleteCredentialEvent():
        final hashes = event.hashByFormat.values.toSet();
        final removed = _credentials
            .where((c) => hashes.contains(c["hash"]))
            .toList();
        _credentials.removeWhere((c) => hashes.contains(c["hash"]));
        if (removed.isNotEmpty) {
          _logs.insert(0, {
            "type": "removal",
            "time": DateTime.utc(2026, 11, 10, 12).toIso8601String(),
            "removal_log": {
              "credentials": [
                for (final c in removed)
                  {
                    ...c,
                    "formats": ["idemix"],
                  },
              ],
            },
          });
        }
        _sendCredentials();
      case ClearAllDataEvent():
        enrolled = false;
        _credentials.clear();
        _logs.clear();
        _sendCredentials();
        _sendEnrollmentStatus();
      case ClientPreferencesEvent():
        _developerMode = event.clientPreferences.developerMode;
        _send(
          ClientPreferencesEvent(
            clientPreferences: ClientPreferences(developerMode: _developerMode),
          ),
        );
      case SetLocaleEvent():
        _sendCredentials();
      default:
        // UpdateSchemesEvent (nothing newer to fetch), AndroidSendToBackgroundEvent,
        // DeleteKeyshareTokensEvent, RefreshCredentialStatusesEvent, ...
        ignored.add("${event.runtimeType}");
    }
  }

  bool _checkPin(String entered) {
    if (_remainingPinAttempts > 0 && entered == pin) {
      _remainingPinAttempts = _pinAttempts;
      return true;
    }
    if (_remainingPinAttempts > 0) _remainingPinAttempts--;
    return false;
  }

  void _sendEnrollmentStatus() => _send(
    EnrollmentStatusEvent(
      enrolledSchemeManagerIds: [if (enrolled) keyshareScheme],
      unenrolledSchemeManagerIds: [if (!enrolled) keyshareScheme],
    ),
  );

  void _sendCredentials() {
    _send(
      SchemalessCredentialStoreEvent.fromJson({
        "credentials": data.credentialStore,
      }),
    );
    _send(
      SchemalessCredentialsEvent.fromJson({
        "credentials": _credentials,
        "problematic": <Json>[],
      }),
    );
  }

  // -------------------------------------------------------------------------
  // Sessions
  // -------------------------------------------------------------------------

  void _sendSession(_Session session, Json changes) {
    session.state = {...session.state, ...changes};
    _send(SessionStateEvent.fromJson({"session_state": session.state}));
  }

  void _startSession(NewSessionEvent event) {
    final url = event.request.u;
    final first = data.sessions[url];
    final session = _Session(url, {
      "id": event.sessionId,
      "protocol": url.startsWith("openid-credential-offer:")
          ? "openid4vci"
          : "irma",
      // True for a QR code scanned from another screen, false for a link opened on
      // this phone (the app then sends the user back to the browser at the end).
      "continue_on_second_device": event.request.continueOnSecondDevice,
      // A URL no requestor of this harness serves: the server cannot be reached.
      ...first ??
          {
            "type": "disclosure",
            "status": "error",
            "requestor": data.unverifiedRequestor,
            "error": {
              "error_type": "transport",
              "info": "",
              "wrapped_error": 'Get "$url": dial tcp: no such host',
              "stack": "",
            },
          },
    });
    _sessions[event.sessionId] = session;
    _sendSession(session, {});
  }

  void _continueSession(SessionUserInteractionEvent event) {
    final session = _sessions[event.sessionId];
    if (session == null) return;
    final payload = event.payload ?? const <String, dynamic>{};
    switch (event.type) {
      case UserInteractionType.dismiss:
        _sessions.remove(event.sessionId);
        _sendSession(session, {"status": "dismissed"});
      case UserInteractionType.permission:
        if (payload["granted"] != true) {
          _sessions.remove(event.sessionId);
          _sendSession(session, {"status": "dismissed"});
        } else {
          // Every card in this wallet is an IRMA (idemix) card of the keyshare scheme,
          // so the keyshare server wants the PIN before it takes part in the proof.
          _sendSession(session, {"status": "request_pin"});
        }
      case UserInteractionType.enteredPin:
        if (payload["proceed"] != true) {
          _sessions.remove(event.sessionId);
          _sendSession(session, {"status": "dismissed"});
        } else if (_checkPin("${payload["pin"]}")) {
          _finishSession(session);
        } else {
          _sendSession(session, {
            "status": "request_pin",
            "remaining_pin_attempts": _remainingPinAttempts,
            if (_remainingPinAttempts == 0) "pin_blocked_time_seconds": 60,
          });
        }
      case UserInteractionType.preAuthorizedCode:
        if (payload["proceed"] != true) {
          _sessions.remove(event.sessionId);
          _sendSession(session, {"status": "dismissed"});
        } else if (payload["transaction_code"] == data.transactionCode) {
          _finishSession(session);
        } else {
          final left =
              (session.state["remaining_tx_code_attempts"] as int? ?? 3) - 1;
          _sendSession(session, {
            "status": left == 0 ? "error" : "request_pre_authorized_code",
            "remaining_tx_code_attempts": left,
          });
        }
      case UserInteractionType.authorizationCode:
        // The browser never comes back in this harness.
        ignored.add("SessionUserInteractionEvent.${event.type.name}");
    }
  }

  void _finishSession(_Session session) {
    _sessions.remove(session.state["id"]);
    final offered = (session.state["offered_credentials"] as List?)
        ?.cast<Json>();
    if (offered != null) {
      _credentials.addAll(offered);
      _logs.insert(0, {
        "type": "issuance",
        "time": DateTime.utc(2026, 11, 10, 12).toIso8601String(),
        "issuance_log": {
          "protocol": "irma",
          "credentials": [
            for (final c in offered)
              {
                ...c,
                "formats": ["idemix"],
              },
          ],
          "disclosed_credentials": <Json>[],
          "issuer": session.state["requestor"],
        },
      });
      _sendCredentials();
    }
    _sendSession(session, {"status": "success"});
  }
}

class _Session {
  _Session(this.url, this.state);

  final String url;
  Json state;
}

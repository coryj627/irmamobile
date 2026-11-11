// What the Go core (irmago, behind `irma.app/irma_mobile_bridge`) would hold for a user
// of the app: the scheme, the credential store, a wallet with a few cards, an activity
// log and the sessions a requestor can start.
//
// Names of credentials, attributes and issuers are not invented here: they are read
// from the app's own mock scheme, `irmaConfigurationEventJson` in
// lib/src/data/mock_data.dart (a snapshot of the production `pbdf` scheme), the same
// data its `IrmaMockBridge` serves. The values (a fictional citizen of Nijmegen), the
// requestors and the dates are the harness's. Everything is written as the JSON the
// bridge sends and decoded with the app's own `fromJson`, so a shape the app could not
// receive on a device cannot be pumped.
import "dart:convert";
import "dart:io";

import "package:yivi_core/src/data/mock_data.dart";

typedef Json = Map<String, dynamic>;

final Json schemeJson = jsonDecode(irmaConfigurationEventJson) as Json;
final Json _config = schemeJson["IrmaConfiguration"] as Json;
final Json _credentialTypes = _config["CredentialTypes"] as Json;
final Json _attributeTypes = _config["AttributeTypes"] as Json;
final Json _issuers = _config["Issuers"] as Json;

/// English text of a translated scheme value. The snapshot predates the English FAQ
/// texts, so those fall back to Dutch, as the app's `TranslatedValue` does.
String? _text(Object? translated) {
  if (translated is! Map) return null;
  final en = translated["en"] as String?;
  if (en != null && en.isNotEmpty) return en;
  final nl = translated["nl"] as String?;
  return (nl == null || nl.isEmpty) ? null : nl.replaceAll(r"\n", "\n");
}

int _unix(int year, int month, int day) =>
    DateTime.utc(year, month, day).millisecondsSinceEpoch ~/ 1000;

/// The Yivi logo the app ships (assets/non-free/logo.png), which is what the
/// credentials issued by Yivi itself (email address, phone number) carry. The other
/// issuers' logos live in the scheme repository, which is not part of this checkout,
/// so their cards are pumped without a logo.
final Json _yiviLogo = {
  "base64": base64Encode(File("assets/non-free/logo.png").readAsBytesSync()),
  "mime_type": "image/png",
};

Json issuer(String issuerId) {
  final issuer = _issuers[issuerId] as Json;
  return {
    "id": issuerId,
    "name": _text(issuer["Name"]),
    "url": null,
    "parent": null,
    "verified": true,
    if (issuerId == "pbdf.pbdf") "image": _yiviLogo,
  };
}

Json requestor(String id, String name, {bool verified = true, String? url}) => {
  "id": id,
  "name": name,
  "url": url,
  "parent": null,
  "verified": verified,
};

final Json gemeenteNijmegen = requestor(
  "pbdf-requestors.nijmegen",
  "Gemeente Nijmegen",
  url: "https://www.nijmegen.nl",
);
final Json bookshop = requestor(
  "pbdf-requestors.boekhandel-dekker",
  "Boekhandel Dekker",
  url: "https://www.boekhandeldekker.example",
);
final Json unverifiedRequestor = requestor(
  "",
  "demo.yivi.app",
  verified: false,
);

Json _attribute(String credentialId, String attributeId, {String? value}) {
  final type = _attributeTypes["$credentialId.$attributeId"] as Json;
  return {
    "claim_path": [attributeId],
    "display_name": _text(type["Name"]),
    "description": _text(type["Description"]),
    if (value != null) "value": {"type": "string", "string": value},
  };
}

String _issuerOf(String credentialId) =>
    credentialId.substring(0, credentialId.lastIndexOf("."));

String _nameOf(String credentialId) =>
    _text((_credentialTypes[credentialId] as Json)["Name"])!;

String? _issueUrlOf(String credentialId) =>
    _text((_credentialTypes[credentialId] as Json)["IssueURL"]);

Json? _imageOf(String credentialId) =>
    _issuerOf(credentialId) == "pbdf.pbdf" ? _yiviLogo : null;

/// A card in the wallet (irmago `clientmodels.Credential`).
Json credential(
  String credentialId,
  String hash,
  Map<String, String> values, {
  required int issued,
  required int expires,
  bool revoked = false,
}) => {
  "credential_id": credentialId,
  "hash": hash,
  "image": _imageOf(credentialId),
  "name": _nameOf(credentialId),
  "issuer": issuer(_issuerOf(credentialId)),
  "credential_instance_ids": {"idemix": hash},
  "batch_instance_counts_remaining": {"idemix": null},
  "attributes": [
    for (final MapEntry(:key, :value) in values.entries)
      _attribute(credentialId, key, value: value),
  ],
  "issuance_date": issued,
  "expiry_date": expires,
  "revoked": revoked,
  "revocation_supported": false,
  "issue_url": _issueUrlOf(credentialId),
};

/// What a requestor asks for, or an issuer offers, before the user has it.
Json descriptor(
  String credentialId, {
  List<String>? attributes,
  String? category,
}) {
  final all = [
    for (final key in _attributeTypes.keys)
      if (key.startsWith("$credentialId."))
        key.substring(credentialId.length + 1),
  ];
  return {
    "credential_id": credentialId,
    "name": _nameOf(credentialId),
    "issuer": issuer(_issuerOf(credentialId)),
    "category": category,
    "image": _imageOf(credentialId),
    "attributes": [
      for (final id in attributes ?? all) _attribute(credentialId, id),
    ],
    "issue_url": _issueUrlOf(credentialId),
    "format": "idemix",
  };
}

// ---------------------------------------------------------------------------
// The wallet
// ---------------------------------------------------------------------------

final Json personalData = credential(
  "pbdf.gemeente.personalData",
  "hash-personal-data",
  {
    "initials": "W.L.",
    "firstnames": "Willeke Liselotte",
    "prefix": "de",
    "familyname": "Bruijn",
    "fullname": "W.L. de Bruijn",
    "gender": "V",
    "nationality": "Ja",
    "surname": "de Bruijn",
    "dateofbirth": "10-03-1965",
    "cityofbirth": "Nijmegen",
    "countryofbirth": "Nederland",
    "over12": "Ja",
    "over16": "Ja",
    "over18": "Ja",
    "over21": "Ja",
    "over65": "Nee",
    "bsn": "999993653",
    "digidlevel": "Substantieel",
  },
  issued: _unix(2026, 9, 14),
  expires: _unix(2031, 9, 14),
);

final Json address = credential(
  "pbdf.gemeente.address",
  "hash-address",
  {
    "street": "Korte Nieuwstraat",
    "houseNumber": "6",
    "zipcode": "6511 PP",
    "municipality": "Nijmegen",
    "city": "Nijmegen",
  },
  issued: _unix(2026, 9, 14),
  expires: _unix(2031, 9, 14),
);

final Json emailPrivate = credential(
  "pbdf.pbdf.email",
  "hash-email-private",
  {"email": "willeke.debruijn@example.nl", "domain": "example.nl"},
  issued: _unix(2026, 10, 2),
  expires: _unix(2031, 10, 2),
);

final Json emailWork = credential(
  "pbdf.pbdf.email",
  "hash-email-work",
  {
    "email": "w.debruijn@bibliotheek.example.nl",
    "domain": "bibliotheek.example.nl",
  },
  issued: _unix(2026, 10, 20),
  expires: _unix(2031, 10, 20),
);

final Json mobileNumber = credential(
  "pbdf.pbdf.mobilenumber",
  "hash-mobile",
  {"mobilenumber": "+31612345678"},
  issued: _unix(2026, 10, 2),
  expires: _unix(2031, 10, 2),
);

/// A card that ran out, which the app shows greyed with a "reobtain" action.
final Json expiredStudentCard = credential(
  "pbdf.pbdf.surfnet-2",
  "hash-surfnet",
  {
    "institute": "Radboud Universiteit",
    "type": "student",
    "id": "s1024883",
    "fullname": "W.L. de Bruijn",
    "firstname": "Willeke",
    "familyname": "de Bruijn",
    "email": "w.debruijn@student.ru.example.nl",
  },
  issued: _unix(2023, 9, 1),
  expires: _unix(2024, 9, 1),
);

/// The wallet of someone who has used the app for a while.
List<Json> get filledWallet => [
  personalData,
  address,
  emailPrivate,
  emailWork,
  mobileNumber,
  expiredStudentCard,
];

// ---------------------------------------------------------------------------
// The credential store ("add data")
// ---------------------------------------------------------------------------

/// Sections of the store. The scheme snapshot has Dutch category names only; these are
/// the English names of the same sections ("Personal" is the one the app sorts first).
const _categories = <String, String>{
  "Persoonsgegevens": "Personal",
  "Zorg": "Health",
  "Onderwijs": "Education",
};

/// Yivi's own issuer, as the production scheme names it today.
final Json _yivi = {
  "id": "pbdf.sidn-pbdf",
  "name": "Yivi",
  "url": null,
  "parent": null,
  "verified": true,
  "image": _yiviLogo,
};

Json _yiviStoreItem(
  String id,
  String name,
  Map<String, String> attributes, {
  required String intro,
  required String content,
  required String howTo,
  String issuerId = "pbdf.sidn-pbdf",
}) => {
  "credential": {
    "credential_id": id,
    "name": name,
    "issuer": {..._yivi, "id": issuerId},
    "category": "Personal",
    "image": _yiviLogo,
    "attributes": [
      for (final MapEntry(:key, :value) in attributes.entries)
        {
          "claim_path": [key],
          "display_name": value,
        },
    ],
    "issue_url": "https://${id.split(".").last}-issuer.yivi.app/",
    "format": "idemix",
  },
  "faq": {
    "intro": intro,
    "purpose":
        "You can use this data to log in to websites and to prove who you "
        "are, without sharing more than is needed.",
    "content": content,
    "how_to": howTo,
  },
};

/// The cards the app obtains with its own screens instead of a website: an email
/// address, a phone number and the three documents it reads over NFC. The app picks
/// those flows by credential id (`IrmaRepository.openIssueURL`), and these ids were
/// added to the production scheme after the snapshot in mock_data.dart was taken, so
/// their names and texts are written here by hand.
List<Json> get _embeddedFlowStoreItems => [
  _yiviStoreItem(
    "pbdf.sidn-pbdf.email",
    "Email address",
    {"email": "Email address", "domain": "Email domain name"},
    intro: "Add your email address to Yivi.",
    content: "Your email address and its domain name.",
    howTo:
        "Enter your email address. You will receive an email with a code. "
        "Enter the code in the app and your email address is added.",
  ),
  _yiviStoreItem(
    "pbdf.sidn-pbdf.mobilenumber",
    "Mobile phone number",
    {"mobilenumber": "Mobile phone number"},
    intro: "Add your mobile phone number to Yivi.",
    content: "Your mobile phone number.",
    howTo:
        "Enter your phone number. You will receive a text message with a "
        "code. Enter the code in the app and your phone number is added.",
  ),
  _yiviStoreItem(
    "pbdf.pbdf.passport",
    "Passport",
    {
      "firstName": "First names",
      "lastName": "Surname",
      "dateOfBirth": "Date of birth",
      "nationality": "Nationality",
      "documentNumber": "Document number",
      "dateOfExpiry": "Date of expiry",
      "photo": "Photo",
    },
    issuerId: "pbdf.pbdf",
    intro: "Add the data of your passport to Yivi.",
    content:
        "The personal data and the photo stored in the chip of your "
        "passport.",
    howTo:
        "Scan the page of your passport that has your photo, then hold "
        "your phone against the passport to read its chip.",
  ),
  _yiviStoreItem(
    "pbdf.pbdf.idcard",
    "Identity card",
    {
      "firstName": "First names",
      "lastName": "Surname",
      "dateOfBirth": "Date of birth",
      "nationality": "Nationality",
      "documentNumber": "Document number",
      "dateOfExpiry": "Date of expiry",
      "photo": "Photo",
    },
    issuerId: "pbdf.pbdf",
    intro: "Add the data of your identity card to Yivi.",
    content:
        "The personal data and the photo stored in the chip of your "
        "identity card.",
    howTo:
        "Scan the back of your identity card, then hold your phone against "
        "the card to read its chip.",
  ),
  _yiviStoreItem(
    "pbdf.pbdf.drivinglicence",
    "Driving licence",
    {
      "firstName": "First names",
      "lastName": "Surname",
      "dateOfBirth": "Date of birth",
      "documentNumber": "Document number",
      "dateOfExpiry": "Date of expiry",
      "categories": "Categories",
    },
    issuerId: "pbdf.pbdf",
    intro: "Add the data of your driving licence to Yivi.",
    content:
        "The personal data and the categories stored in the chip of your "
        "driving licence.",
    howTo:
        "Scan the back of your driving licence, then hold your phone "
        "against the licence to read its chip.",
  ),
];

List<Json> get credentialStore => [
  ..._embeddedFlowStoreItems,
  for (final MapEntry(key: id, value: type) in _credentialTypes.entries)
    if (type is Map &&
        type["IsInCredentialStore"] == true &&
        id.startsWith("pbdf."))
      {
        "credential": descriptor(
          id,
          category: _categories[(type["Category"] as Map?)?["nl"]] ?? "Other",
        ),
        "faq": {
          "intro": _text(type["FAQIntro"]),
          "purpose": _text(type["FAQPurpose"]),
          "content": _text(type["FAQContent"]),
          "how_to": _text(type["FAQHowto"]),
        },
      },
];

// ---------------------------------------------------------------------------
// The activity log
// ---------------------------------------------------------------------------

Json _logCredential(Json credential, {List<String>? only}) => {
  "credential_id": credential["credential_id"],
  "formats": ["idemix"],
  "image": credential["image"],
  "name": credential["name"],
  "issuer": credential["issuer"],
  "attributes": [
    for (final attribute in credential["attributes"] as List)
      if (only == null ||
          only.contains(((attribute as Json)["claim_path"] as List).first))
        attribute,
  ],
  "issuance_date": credential["issuance_date"],
  "expiry_date": credential["expiry_date"],
  "revoked": false,
  "revocation_supported": false,
  "issue_url": credential["issue_url"],
};

String _time(int year, int month, int day, int hour, int minute) =>
    DateTime.utc(year, month, day, hour, minute).toIso8601String();

/// Newest first, as irmago returns them.
List<Json> get activityLog => [
  {
    "type": "disclosure",
    "time": _time(2026, 11, 3, 9, 41),
    "disclosure_log": {
      "protocol": "irma",
      "credentials": [
        _logCredential(personalData, only: ["fullname", "over18"]),
        _logCredential(emailPrivate, only: ["email"]),
      ],
      "verifier": bookshop,
    },
  },
  {
    "type": "signature",
    "time": _time(2026, 10, 28, 14, 5),
    "signed_message_log": {
      "protocol": "irma",
      "credentials": [
        _logCredential(personalData, only: ["fullname"]),
      ],
      "verifier": gemeenteNijmegen,
      "message": signedMessage,
    },
  },
  {
    "type": "issuance",
    "time": _time(2026, 10, 20, 8, 17),
    "issuance_log": {
      "protocol": "irma",
      "credentials": [_logCredential(emailWork)],
      "disclosed_credentials": <Json>[],
      "issuer": issuer("pbdf.pbdf"),
    },
  },
  {
    "type": "removal",
    "time": _time(2026, 10, 5, 19, 30),
    "removal_log": {
      "credentials": [_logCredential(expiredStudentCard)],
    },
  },
  {
    "type": "issuance",
    "time": _time(2026, 10, 2, 11, 52),
    "issuance_log": {
      "protocol": "irma",
      "credentials": [
        _logCredential(emailPrivate),
        _logCredential(mobileNumber),
      ],
      "disclosed_credentials": <Json>[],
      "issuer": issuer("pbdf.pbdf"),
    },
  },
  {
    "type": "issuance",
    "time": _time(2026, 9, 14, 16, 3),
    "issuance_log": {
      "protocol": "irma",
      "credentials": [_logCredential(personalData), _logCredential(address)],
      "disclosed_credentials": <Json>[],
      "issuer": issuer("pbdf.gemeente"),
    },
  },
];

const signedMessage =
    "Ik, W.L. de Bruijn, ga akkoord met de aanvraag van een parkeervergunning "
    "voor kenteken GH-492-K per 1 december 2026.";

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

/// A card as a requestor's disclosure plan lists it: only the requested attributes.
Json _selectable(Json credential, List<String> attributes) => {
  "credential_id": credential["credential_id"],
  "hash": credential["hash"],
  "image": credential["image"],
  "name": credential["name"],
  "issuer": credential["issuer"],
  "format": "idemix",
  "batch_instance_count_remaining": null,
  "attributes": [
    for (final attribute in credential["attributes"] as List)
      if (attributes.contains(
        ((attribute as Json)["claim_path"] as List).first,
      ))
        attribute,
  ],
  "issuance_date": credential["issuance_date"],
  "expiry_date": credential["expiry_date"],
  "revoked": false,
  "revocation_supported": false,
  "issue_url": credential["issue_url"],
};

Json _bundle(List<Json> credentials) => {"credentials": credentials};

/// What a session looks like when it first asks the user something, keyed by the URL
/// in the QR code or link that starts it (see `FakeYiviCore`). `protocol`, `id` and
/// later statuses are filled in by the fake core.
final Map<String, Json> sessions = {
  ..._openid4vciSessions.cast<String, Json>(),
  // The requestor's server answers with something the app does not expect.
  "https://boekhandeldekker.example/yivi/session/broken": {
    "type": "disclosure",
    "status": "error",
    "requestor": bookshop,
    "error": {
      "error_type": "serverResponse",
      "info": "",
      "wrapped_error": "invalid character '<' looking for beginning of value",
      "stack":
          "goroutine 52 [running]:\n"
          "github.com/privacybydesign/irmago/irmaclient.(*irmaSession).getSessionInfo(...)\n"
          "\t/go/pkg/mod/github.com/privacybydesign/irmago/irmaclient/session.go:418",
      "remote_status": 502,
    },
  },
  // A webshop asks for a name, proof of age and an email address; the wallet has two
  // email addresses, so the user chooses.
  "https://boekhandeldekker.example/yivi/session/order": {
    "type": "disclosure",
    "status": "request_permission",
    "requestor": bookshop,
    "disclosure_plan": {
      "disclosure_choices_overview": [
        {
          "optional": false,
          "owned_options": [
            _bundle([
              _selectable(personalData, ["fullname", "over18"]),
            ]),
          ],
        },
        {
          "optional": false,
          "owned_options": [
            _bundle([
              _selectable(emailPrivate, ["email"]),
            ]),
            _bundle([
              _selectable(emailWork, ["email"]),
            ]),
          ],
          "obtainable_options": [
            descriptor("pbdf.pbdf.email", attributes: ["email"]),
          ],
        },
        {
          "optional": true,
          "owned_options": [
            _bundle([
              _selectable(mobileNumber, ["mobilenumber"]),
            ]),
          ],
        },
      ],
    },
  },
  // The municipality asks for data the wallet does not hold yet (iDIN): the user has to
  // obtain it first.
  "https://www.nijmegen.example/yivi/session/idin": {
    "type": "disclosure",
    "status": "request_permission",
    "requestor": gemeenteNijmegen,
    "disclosure_plan": {
      "issue_during_disclosure": {
        "steps": [
          {
            "options": [
              {
                "credentials": [
                  descriptor(
                    "pbdf.pbdf.idin",
                    attributes: ["familyname", "dateofbirth"],
                  ),
                ],
              },
            ],
          },
        ],
      },
    },
  },
  // The municipality asks for a signature under a statement.
  "https://www.nijmegen.example/yivi/session/parking-permit": {
    "type": "signature",
    "status": "request_permission",
    "requestor": gemeenteNijmegen,
    "message_to_sign": signedMessage,
    "disclosure_plan": {
      "disclosure_choices_overview": [
        {
          "optional": false,
          "owned_options": [
            _bundle([
              _selectable(personalData, ["fullname"]),
            ]),
          ],
        },
      ],
    },
  },
  // Yivi's own issuer offers a verified email address.
  emailIssuanceUrl: {
    "type": "issuance",
    "status": "request_permission",
    "requestor": issuer("pbdf.pbdf"),
    "offered_credentials": [newEmail],
  },
  // A requestor that is not in the requestor scheme.
  "https://demo.yivi.example/session/unverified": {
    "type": "disclosure",
    "status": "request_permission",
    "requestor": unverifiedRequestor,
    "disclosure_plan": {
      "disclosure_choices_overview": [
        {
          "optional": false,
          "owned_options": [
            _bundle([
              _selectable(mobileNumber, ["mobilenumber"]),
            ]),
          ],
        },
      ],
    },
  },
  // The municipality's call centre: after sharing, the app offers to place the call.
  "https://www.nijmegen.example/yivi/session/call-centre": {
    "type": "disclosure",
    "status": "request_permission",
    "requestor": gemeenteNijmegen,
    "client_return_url": "tel:+31243299000,123456",
    "disclosure_plan": {
      "disclosure_choices_overview": [
        {
          "optional": false,
          "owned_options": [
            _bundle([
              _selectable(personalData, ["bsn"]),
            ]),
          ],
        },
      ],
    },
  },
  // A QR code on another device whose session asks for a pairing code first.
  "https://boekhandeldekker.example/yivi/session/pairing": {
    "type": "disclosure",
    "status": "show_pairing_code",
    "requestor": bookshop,
    "pairing_code": "4863",
  },
  // A QR code that is no longer valid: the server answers that the session is unknown.
  "https://boekhandeldekker.example/yivi/session/expired": {
    "type": "disclosure",
    "status": "error",
    "requestor": bookshop,
    "error": {
      "error_type": "api",
      "info": "",
      "wrapped_error": "",
      "stack": "",
      "remote_status": 400,
      "remote_error": {
        "status": 400,
        "error": "SESSION_UNKNOWN",
        "description": "Unknown or expired session",
        "message": "",
      },
    },
  },
  // No connection to the requestor's server.
  "https://boekhandeldekker.example/yivi/session/offline": {
    "type": "disclosure",
    "status": "error",
    "requestor": bookshop,
    "error": {
      "error_type": "transport",
      "info": "",
      "wrapped_error":
          'Get "https://boekhandeldekker.example/yivi/session/offline": '
          "dial tcp: lookup boekhandeldekker.example: no such host",
      "stack": "",
    },
  },
};

/// The code the university's letter gives for [diplomaOfferCode].
const transactionCode = "7391";

/// An OpenID4VCI credential offer with a transaction code: a university offers a
/// diploma as an SD-JWT credential.
const diplomaOfferCode =
    "openid-credential-offer://?credential_offer_uri="
    "https%3A%2F%2Fdiplomas.ru.example%2Foffers%2F5f2c";

/// The same issuer's offer that first sends the user to its website to log in.
const diplomaOfferLogin =
    "openid-credential-offer://?credential_offer_uri="
    "https%3A%2F%2Fdiplomas.ru.example%2Foffers%2F9a41";

final Json _university = requestor(
  "https://diplomas.ru.example",
  "Radboud Universiteit",
  url: "https://diplomas.ru.example",
);

final Json _diploma = {
  "credential_id": "https://diplomas.ru.example/credentials/diploma",
  "name": "Diploma",
  "issuer": _university,
  "category": null,
  "image": null,
  "attributes": [
    for (final MapEntry(:key, :value) in const {
      "degree": "Degree",
      "programme": "Programme",
      "graduation_date": "Date of graduation",
      "institution": "Institution",
    }.entries)
      {
        "claim_path": [key],
        "display_name": value,
      },
  ],
  "issue_url": null,
  "format": "dc+sd-jwt",
};

final Json _openid4vciSessions = {
  diplomaOfferCode: {
    "type": "issuance",
    "status": "request_pre_authorized_code",
    "requestor": _university,
    "offered_credential_types": [_diploma],
    "transaction_code_parameters": {
      "input_mode": "numeric",
      "length": 4,
      "description": "The code in the letter you received from the university",
    },
  },
  diplomaOfferLogin: {
    "type": "issuance",
    "status": "request_authorization_code",
    "requestor": _university,
    "offered_credential_types": [_diploma],
    "authorization_request_url":
        "https://diplomas.ru.example/authorize?client_id=yivi&state=9a41",
    "openid4vci_state": "9a41",
  },
};

const emailIssuanceUrl = "https://email-issuer.yivi.example/irma/session/email";

/// The card the email issuance session adds.
final Json newEmail = credential(
  "pbdf.pbdf.email",
  "hash-email-new",
  {"email": "willeke@debruijn.example.nl", "domain": "debruijn.example.nl"},
  issued: _unix(2026, 11, 10),
  expires: _unix(2031, 11, 10),
);

/// The QR code or link that starts [url]'s session, as a requestor's page shows it.
String sessionQr(String url) {
  final type = switch ((sessions[url]!)["type"]) {
    "issuance" => "issuing",
    "signature" => "signing",
    _ => "disclosing",
  };
  return jsonEncode({"u": url, "irmaqr": type});
}

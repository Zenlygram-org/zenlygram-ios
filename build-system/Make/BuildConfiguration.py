import base64
import contextlib
import datetime
import io
import json
import os
import re
import sys
import shutil
import tempfile
import plistlib
import unicodedata
from urllib.parse import unquote_to_bytes, urlsplit

from BuildEnvironment import run_executable_with_output, check_run_system
from DecryptMatch import decrypt_match_data


# SG: the keys SGConfig (Swiftgram/SGConfig/Sources/File.swift) reads, in their JSON spelling.
SG_CONFIG_KEYS = {
    'api_url',
    'webapp_url',
    'bot_username',
    'public_key',
    'iaps',
    'apple_backend_enabled',
    'entitlement_keys',
    'privacy_policy_url',
    'public_policy_url',
    'public_policy_keys',
    'lenta_iaps',
    'consent_mode',
    'consent_operator',
    'tasks_wire',
}

# Zenlygram — `sg_config.lenta_iaps`, the Lenta StoreKit product ids (spec «Premium handle'lar» › «Kill switch'lar,
# doim ishlaydigan yo'llar va sozlamalar»; «Belgilar: haqiqiylik va Plus» › «Plus obunasi App Store'da»):
# <prefix>.lenta.plus.monthly / .yearly (group lenta.plus), <prefix>.lenta.name.t1 … (fixed-price tiers) and
# <prefix>.lenta.auction.s01 … (auction steps). SGFeedCommerce reads the same grammar (SGFeedCommerceCatalog).
LENTA_IAP_PATTERN = re.compile(r'[a-z0-9]+(?:\.[a-z0-9]+)*\.lenta\.(?:plus\.(?:monthly|yearly)|name\.t[1-9][0-9]?|auction\.s[0-9]{2,3})')

# Zenlygram — `sg_config.iaps`, the Pro subscription product ids (<bundle_id>.pro.monthly / .pro.yearly in App
# Store Connect): lowercase dot-separated labels. ASC product ids are case-sensitive and SGIAP compares them
# verbatim with the catalogue, so a stray capital or space loads no product and fails silently on a device.
# check_appstore_sg_config adds the bundle_id prefix and the no-duplicates rule on top of this grammar.
IAP_PRODUCT_ID_PATTERN = re.compile(r'[a-z0-9]+(?:\.[a-z0-9_-]+)+')

# SG: the customer-data consent configuration (design 40 §3, contract §5.4 / §6.1). The mode is a
# build-time fact the server never toggles; the operator values fill the consent text's placeholders
# and are each percent-encoded UTF-8 (sg_config values may hold no white space). SGConsentOperatorValues
# (Swiftgram/SGCustomerSync/Core/SGConsentCanonicalText.swift) applies the same rules at runtime.
CONSENT_MODES = ('required', 'optional')
CONSENT_OPERATOR_FIELDS = ('name', 'stir', 'responsible_person', 'contact_email')
# The production server: a build pointed at it renders the consent text users agree to, so it must
# carry the real operator values in every build, not only in an App Store one.
PRODUCTION_HOSTS = ('zenlygram.org', 'www.zenlygram.org')
# Answers 410 since 2026-10-24; the server moved to zenlygram.org.
RETIRED_HOSTS = ('zenlygram.com', 'www.zenlygram.com')
# Zenlygram — `sg_config.tasks_wire` (wf15 §8.2): the `X-Tasks-Wire` value every Tasks request of the build
# sends. A server that does not accept the value answers 422 before authentication on every request, so a
# client cannot probe and the wire is a build-time fact: 4 (today's production wire, what the client sends when
# the key is absent) or 5 (the assignee note and `completed_by`). A build that points at the production server
# or is an App Store build never sends more than PRODUCTION_TASKS_WIRE_MAX; raising it to 5 is its own reviewed
# commit (WP-I11), made only after the owner confirms the production deploy that accepts 5 — the server is then
# never rolled back below that deploy. SGTasksShippedWire.requestWire (Swiftgram/SGEntitlement) reads the key.
TASKS_WIRES = (4, 5)
PRODUCTION_TASKS_WIRE_MAX = 4
# Unicode White_Space (PropList.txt), as SGConsentCanonicalText.isWhiteSpace spells it out.
_CONSENT_WHITE_SPACE = (
    {chr(code) for code in range(0x09, 0x0E)}
    | {chr(code) for code in (0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000)}
    | {chr(code) for code in range(0x2000, 0x200B)}
)
_CONSENT_EMAIL = re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}')

# SG: SGEntitlementCrypto.p256SPKIPrefix — a pinned key is this prefix plus a 65-byte 0x04 point.
P256_SPKI_PREFIX = bytes([
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
])


def fail_sg_config(message):
    raise Exception('sg_config: {} See appstore/SECRETS.md.'.format(message))


def normalize_build_flag(value, field):
    """Return the exact C boolean spelling, rejecting ambiguous JSON/string values."""
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, str) and value.lower() in ('true', 'false'):
        return value.lower()
    raise ValueError('{} must be a boolean or a true/false string'.format(field))


def normalize_lenta_applinks_host(value):
    """Optional `lenta_applinks_host`: a bare lowercase DNS name for the Lenta applinks entitlement.
    None keeps the default baked into //Telegram:TelegramLentaEntitlements."""
    if value is None:
        return None
    label = r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
    if not isinstance(value, str) or len(value) > 253 or not re.fullmatch(r'{label}(?:\.{label})+'.format(label=label), value):
        raise ValueError('lenta_applinks_host must be a lowercase host name such as "lenta.example.com" (no scheme, port or path)')
    return value


def normalize_lenta_telegram_login_app_id(value):
    """Optional `lenta_telegram_login_app_id`: the BotFather-issued app id of Lenta's Telegram Login client,
    the `{appid}` of the return domain app{appid}-login.tg.dev. None leaves that entitlement out."""
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise ValueError('lenta_telegram_login_app_id must be a positive decimal number such as 123456')
    text = str(value)
    if not re.fullmatch(r'[1-9][0-9]{0,19}', text):
        raise ValueError('lenta_telegram_login_app_id must be a positive decimal number such as 123456')
    return text


def _is_p256_public_key(value):
    if not isinstance(value, str):
        return False
    try:
        der = base64.b64decode(value, validate=True)
    except ValueError:
        return False
    is_spki = len(der) == len(P256_SPKI_PREFIX) + 65 and der.startswith(P256_SPKI_PREFIX) and der[len(P256_SPKI_PREFIX)] == 0x04
    is_point = len(der) == 65 and der[0] == 0x04
    return is_spki or is_point


def _is_canonical_api_origin(value):
    """Mirror SGEntitlementBackendOrigin's HTTPS root and canonical authority rules."""
    if not isinstance(value, str):
        return False
    scheme, separator, authority = value.rstrip('/').partition('://')
    if not separator or scheme.lower() != 'https':
        return False
    parts = authority.split(':')
    if len(parts) not in (1, 2):
        return False
    host = parts[0].lower()
    if not host or len(host) > 253:
        return False
    if len(parts) == 2 and (
        not re.fullmatch(r'[1-9][0-9]{0,4}', parts[1]) or int(parts[1]) > 65535
    ):
        return False
    labels = host.split('.')
    if labels[-1] and labels[-1][0] in '0123456789':
        return len(labels) == 4 and all(
            re.fullmatch(r'0|[1-9][0-9]{0,2}', label) and int(label) <= 255
            for label in labels
        )
    return all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in labels)


def _is_public_policy_url(value):
    if not isinstance(value, str) or any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in value):
        return False
    try:
        url = urlsplit(value)
        port = url.port
        return (
            url.scheme == 'https' and bool(url.hostname)
            and url.username is None and url.password is None
            and url.path == '/v1/monetization'
            and '?' not in value and '#' not in value
            and not url.netloc.endswith(':')
            and (port is None or 1 <= port <= 65535)
        )
    except ValueError:
        return False


def check_lenta_iaps_sg_config(value):
    """Optional `lenta_iaps`: Lenta product ids only, never one of the Pro `iaps` (SGIAP routes them away from Pro)."""
    if 'lenta_iaps' not in value:
        return
    ids = value['lenta_iaps']
    if not isinstance(ids, list) or not all(isinstance(item, str) and LENTA_IAP_PATTERN.fullmatch(item) for item in ids):
        fail_sg_config('lenta_iaps must list Lenta product ids (<prefix>.lenta.plus.monthly / .yearly, <prefix>.lenta.name.tN, <prefix>.lenta.auction.sNN).')
    if len(set(ids)) != len(ids):
        fail_sg_config('lenta_iaps lists a product id twice.')
    pro = value.get('iaps')
    if isinstance(pro, list) and set(ids) & set(item for item in pro if isinstance(item, str)):
        fail_sg_config('lenta_iaps and iaps share a product id; a Lenta product must never reach the Pro engine.')


def sg_config_for_build(sg_config, enable_lenta):
    """The sg_config the app is built with: `lenta_iaps` only when Lenta is compiled in, so a flag-off binary carries
    no Lenta product id (scripts/lenta-boundary-check.sh)."""
    if enable_lenta or sg_config == '':
        return sg_config
    value = json.loads(sg_config)
    if 'lenta_iaps' not in value:
        return sg_config
    del value['lenta_iaps']
    return json.dumps(value, separators=(',', ':'), ensure_ascii=False)


def check_public_policy_sg_config(value):
    """An optional public pair must contain only a usable endpoint and public key shapes."""
    if 'public_policy_url' not in value and 'public_policy_keys' not in value:
        return
    problems = []
    if not _is_public_policy_url(value.get('public_policy_url')):
        problems.append('public_policy_url must be an HTTPS /v1/monetization endpoint with a valid host/port and no userinfo, query or fragment')
    keys = value.get('public_policy_keys')
    if not isinstance(keys, dict) or not keys or not all(
        isinstance(kid, str) and kid and _is_p256_public_key(key)
        for kid, key in keys.items()
    ):
        # A kid is also untrusted input: neither it nor the key belongs in diagnostics.
        problems.append('public_policy_keys must map nonempty key ids to base64 P-256 public keys (SPKI DER or raw public points)')
    if problems:
        fail_sg_config('public policy configuration refused:\n  - {}'.format('\n  - '.join(problems)))


def _url_hostname(value):
    """The lower-cased host of a URL string (no trailing dot), or None."""
    if not isinstance(value, str):
        return None
    try:
        host = urlsplit(value).hostname
    except ValueError:
        return None
    if not host:
        return None
    return host.rstrip('.') or None


def _is_local_host(host):
    """SGConsentOperatorValues.acceptsMissingValues: loopback, RFC 1918 IPv4 or a `.local` name."""
    if not host:
        return False
    host = host.lower()
    if host.startswith('[') and host.endswith(']'):
        host = host[1:-1]
    if host.endswith('.'):
        host = host[:-1]
    if host in ('localhost', '::1') or (host.endswith('.local') and len(host) > len('.local')):
        return True
    octets = host.split('.')
    if len(octets) != 4 or not all(re.fullmatch(r'[0-9]{1,3}', octet) and int(octet) <= 255 for octet in octets):
        return False
    first, second = int(octets[0]), int(octets[1])
    return first in (127, 10) or (first, second) == (192, 168) or (first == 172 and 16 <= second <= 31)


def consent_operator_value_state(raw, field):
    """'valid', 'missing' or 'invalid' for one percent-encoded consent_operator value.

    Mirrors SGConsentOperatorValues.fromConfig/check: an empty value or one holding FILL_ME is
    missing; a malformed escape, non-UTF-8 bytes, a control character, U+2028/U+2029, `{{` or `}}`
    is invalid; the field rules apply to the NFC, White_Space-trimmed text.
    """
    if raw == '':
        return 'missing'
    # Foundation's removingPercentEncoding refuses a `%` without two hex digits; unquote keeps it.
    if re.search(r'%(?![0-9A-Fa-f]{2})', raw):
        return 'invalid'
    try:
        decoded = unquote_to_bytes(raw).decode('utf-8', errors='strict')
    except UnicodeDecodeError:
        return 'invalid'
    if decoded == '' or 'FILL_ME' in decoded:
        return 'missing'
    if any(ord(character) <= 0x1F or 0x7F <= ord(character) <= 0x9F or ord(character) in (0x2028, 0x2029) for character in decoded):
        return 'invalid'
    if '{{' in decoded or '}}' in decoded:
        return 'invalid'
    text = unicodedata.normalize('NFC', decoded)
    start, end = 0, len(text)
    while start < end and text[start] in _CONSENT_WHITE_SPACE:
        start += 1
    while end > start and text[end - 1] in _CONSENT_WHITE_SPACE:
        end -= 1
    text = text[start:end]
    if field in ('name', 'responsible_person'):
        # Rendered inside the Markdown consent text (compliance C-2).
        valid = 1 <= len(text) <= 200 and not any(character in '*[]\\`' for character in text)
    elif field == 'stir':
        valid = re.fullmatch(r'[0-9]{9}|[0-9]{14}', text) is not None
    else:
        valid = _CONSENT_EMAIL.fullmatch(text) is not None
    return 'valid' if valid else 'invalid'


def consent_operator_states(value):
    """field -> state for sg_config's consent_operator; every field is missing when it is absent."""
    if 'consent_operator' not in value:
        return {field: 'missing' for field in CONSENT_OPERATOR_FIELDS}
    operator = value['consent_operator']
    return {field: consent_operator_value_state(operator[field], field) for field in CONSENT_OPERATOR_FIELDS}


def check_consent_sg_config(value, is_appstore):
    """Every build: a known consent mode, a well-formed operator object, and the operator values
    whenever api_url is the production server. Diagnostics name fields, never values."""
    if 'consent_mode' in value and value['consent_mode'] not in CONSENT_MODES:
        fail_sg_config('consent_mode must be "required" or "optional".')
    if 'consent_operator' in value:
        operator = value['consent_operator']
        if (
            not isinstance(operator, dict)
            or set(operator) != set(CONSENT_OPERATOR_FIELDS)
            or not all(isinstance(item, str) for item in operator.values())
        ):
            fail_sg_config('consent_operator must be an object with exactly the string keys name, stir, responsible_person and contact_email.')
    states = consent_operator_states(value)
    invalid = [field for field in CONSENT_OPERATOR_FIELDS if states[field] == 'invalid']
    if invalid:
        fail_sg_config('consent_operator.{} must be a valid percent-encoded UTF-8 value.'.format(', consent_operator.'.join(invalid)))
    complete = all(state == 'valid' for state in states.values())
    if complete or is_appstore:
        # An App Store build requires the values itself (check_appstore_sg_config).
        return
    host = _url_hostname(value.get('api_url'))
    if host in PRODUCTION_HOSTS:
        fail_sg_config('consent_operator must hold the four operator values for a build that points at the production server.')
    if host is not None and not _is_local_host(host):
        print('Warning: consent_operator is missing; the consent pipeline stays inactive in this build.')


def check_tasks_wire_sg_config(value, is_appstore):
    """Every build: an absent tasks_wire (the client sends 4) or the integer 4 or 5 — a JSON boolean, string,
    float, list or object is refused — and never more than PRODUCTION_TASKS_WIRE_MAX for an App Store build or
    a build whose api_url is the production server, whatever the key says. Diagnostics name the field and the
    rule, never the configured value."""
    if 'tasks_wire' not in value:
        return
    wire = value['tasks_wire']
    # `bool` is an `int` subclass: a JSON `true` must not pass as 1.
    if type(wire) is not int or wire not in TASKS_WIRES:
        fail_sg_config('tasks_wire must be the integer 4 or 5.')
    if wire <= PRODUCTION_TASKS_WIRE_MAX:
        return
    if is_appstore or _url_hostname(value.get('api_url')) in PRODUCTION_HOSTS:
        fail_sg_config(
            'tasks_wire above {} is refused for an App Store build and for a build that points at the production '
            'server: a server that does not accept the wire answers 422 to every Tasks request of the build. '
            'Raise PRODUCTION_TASKS_WIRE_MAX in its own reviewed commit once the backend that accepts it is '
            'deployed there.'.format(PRODUCTION_TASKS_WIRE_MAX)
        )


def normalize_sg_config(sg_config, is_appstore_build, bundle_id=None):
    # `bundle_id` anchors the App Store rule that every `iaps` product id starts with it; BuildConfiguration
    # passes it, a caller that has none gets every other rule (see check_appstore_sg_config).
    # SG: sg_config travels to the app through two encodings, and each one corrupts it silently:
    #   1. write_to_variables_file renders it as `sg_config = """<value>"""` in generated Starlark,
    #      where a backslash is an escape and a triple quote ends the string.
    #   2. submodules/BuildConfig/BUILD passes it as an objc_library copt. Copts are Bourne-shell
    #      tokenized, and that BUILD escapes every quote in the value, so nothing in it is quoted for
    #      the tokenizer: every space or newline splits the flag into separate clang arguments, a
    #      single quote opens a quoted section, and `$` is Make-variable expansion.
    # A pretty-printed sg_config broke BuildConfig outright; one missing key made SGConfig drop the
    # whole object at runtime. So parse it, drop `_`-prefixed comment keys (prose has spaces), emit
    # compact JSON, and refuse anything that still cannot make the trip.
    if not isinstance(sg_config, str):
        fail_sg_config('must be a JSON object written as a string.')
    is_appstore = normalize_build_flag(is_appstore_build, 'is_appstore_build') == 'true'
    if sg_config.strip() == '':
        if is_appstore:
            fail_sg_config('is empty in an App Store build, which would ship with no pinned keys, no product ids and no privacy policy link.')
        return ''
    try:
        value = json.loads(sg_config)
    except ValueError as error:
        fail_sg_config('is not valid JSON ({}).'.format(error))
    if not isinstance(value, dict):
        fail_sg_config('must be a JSON object.')

    value = {key: item for key, item in value.items() if not key.startswith('_')}
    if 'apple_backend_enabled' in value and not isinstance(value['apple_backend_enabled'], bool):
        fail_sg_config('apple_backend_enabled must be a boolean.')
    check_public_policy_sg_config(value)
    check_lenta_iaps_sg_config(value)
    check_consent_sg_config(value, is_appstore)
    check_tasks_wire_sg_config(value, is_appstore)
    unknown = sorted(set(value) - SG_CONFIG_KEYS)
    if unknown:
        print('Warning: sg_config has {} unknown keys SGConfig does not read'.format(len(unknown)))
    if is_appstore:
        check_appstore_sg_config(value, bundle_id)

    compact = json.dumps(value, separators=(',', ':'), ensure_ascii=False)
    unsafe = sorted({character for character in compact if character.isspace() or character in '\\\'$'})
    if unsafe or '"""' in compact:
        fail_sg_config(
            'a value contains {} which cannot pass through the generated Starlark string and the '
            'shell-tokenized copts. URLs, product ids, bot usernames and base64 keys never need them; '
            'keys belong here as bare base64 SPKI DER, not PEM.'.format(
                ', '.join(repr(character) for character in unsafe) or 'a triple quote'
            )
        )
    # The value ends up in a C string literal, and BuildConfig compiles with -Werror, so a trigraph
    # (`??=`, `??/`, ...) fails the build with an error that never mentions sg_config.
    trigraph = re.search(r"\?\?[=()/<>!'-]", compact)
    if trigraph:
        fail_sg_config('a value contains the C trigraph {!r}, which BuildConfig cannot compile.'.format(trigraph.group(0)))
    return compact


def check_appstore_sg_config(value, bundle_id=None):
    """The sg_config rules of an App Store build (is_appstore_build true), on top of normalize_sg_config's
    every-build rules. Every gap is reported at once; diagnostics name fields, never values.

    Mandatory in every App Store build: a canonical api_url origin, an https privacy_policy_url, at least
    one P-256 entitlement key, a bot-shaped bot_username, the four consent_operator values and no FILL_ME
    placeholder anywhere. The backend (api_url + entitlement_keys) therefore always ships, and the
    entitlement follows the server-signed policy.

    The payment pair is an explicit two-state rule; which state a release ships is the owner's call for
    that release (2026-11-10 option A shipped it off; the 2026-11-11 decision ships it on with the two Pro
    subscriptions, the server-signed monetization policy deciding whether anything is on sale):
      PAYMENTS ON   apple_backend_enabled true  and iaps the App Store Connect product ids — each one
                    lowercase dot-separated labels (IAP_PRODUCT_ID_PATTERN), each starting with
                    `bundle_id + "."` compared without regard to case when the caller passes the bundle
                    id (SGIAP and the server derive the ids from the bundle id, so a foreign prefix would
                    load no product; a bundle id with a capital is common and the ids stay lowercase),
                    none repeated — three rules judged independently, so every gap is named;
      PAYMENTS OFF  apple_backend_enabled false and iaps [] — SGEntitlement holds every StoreKit path (no
                    Transaction.updates listener, snapshot, products, purchase or restore; Restore rows hidden).
    A mixed pair is refused: products on sale with the flag held would never attach to an account (M11),
    and the flag without products is a contradiction the runtime would resolve silently (the Apple
    predicate needs product ids as well, so the path the flag asks for stays held). An absent flag is
    refused too, so the payment state is always spelled out in the configuration file rather than left
    to SGConfig's default. build-system/appstore/ipa_check.py reads the same pair back from the binaries.
    """
    problems = []

    def check_https_url(key):
        url = value.get(key)
        if not isinstance(url, str) or not re.fullmatch(r'https://[^/?#]+\S*', url):
            problems.append('{} must be an https:// URL'.format(key))
            return None
        return url

    api_url = value.get('api_url')
    if not _is_canonical_api_origin(api_url):
        problems.append('api_url must be a canonical HTTPS server origin (DNS host or IPv4 and optional port); no userinfo, query, fragment or path is allowed')
    elif 'swiftgram.app' in api_url.lower():
        problems.append('api_url points at upstream Swiftgram; SGEntitlementClient refuses to bind to it')
    elif _url_hostname(api_url) in RETIRED_HOSTS:
        problems.append('api_url points at the retired zenlygram.com host; the server is https://zenlygram.org')
    if check_https_url('privacy_policy_url') is not None and _url_hostname(value.get('privacy_policy_url')) in RETIRED_HOSTS:
        problems.append('privacy_policy_url points at the retired zenlygram.com host')

    # The payment pair (see the docstring). normalize_sg_config already refused a non-boolean flag, so
    # here it is a bool or absent; the pair is judged only once iaps has a usable shape.
    apple_backend_enabled = value.get('apple_backend_enabled')
    iaps = value.get('iaps')
    iaps_is_product_list = isinstance(iaps, list) and all(isinstance(item, str) and item for item in iaps)
    if not iaps_is_product_list:
        problems.append('iaps must be a list of App Store Connect product ids (payments on) or [] (payments off)')
    if not isinstance(apple_backend_enabled, bool):
        problems.append('apple_backend_enabled must be an explicit true (payments on, iaps listed) or false (payments off, iaps []) in an App Store build')
    elif iaps_is_product_list and apple_backend_enabled and not iaps:
        problems.append('apple_backend_enabled true requires iaps to list the App Store Connect product ids (payments on); payments off is apple_backend_enabled false with iaps []')
    elif iaps_is_product_list and not apple_backend_enabled and iaps:
        # M11: products on sale while the Apple path is held would leave purchases unattached to any account.
        problems.append('iaps listed but apple_backend_enabled is false; payments off is iaps [] with apple_backend_enabled false, payments on apple_backend_enabled true with the product ids')

    # The product ids themselves, judged whenever iaps has a usable shape so a mixed pair's ids join the
    # same report: the ASC product-id grammar, the bundle-id prefix and no duplicates. Field-named by
    # index — a product id is public, but this module never echoes a configuration value.
    if iaps_is_product_list:
        for index, item in enumerate(iaps):
            if not IAP_PRODUCT_ID_PATTERN.fullmatch(item):
                problems.append('iaps[{}] must match ^[a-z0-9]+(\\.[a-z0-9_-]+)+$ (lowercase dot-separated labels; App Store Connect product ids are case-sensitive)'.format(index))
            # Independently of the grammar (an `elif` hid this rule behind the grammar's message) and
            # without regard to case: a bundle id with a capital (`ph.telegra.Telegraph`) is common,
            # and a lowercase product id can never equal it byte for byte, so a case-sensitive
            # comparison would make the two rules unsatisfiable together.
            if isinstance(bundle_id, str) and bundle_id and not item.lower().startswith(bundle_id.lower() + '.'):
                # The hint names no plan word: a diagnostic must not contain anything that could be read as
                # an echoed id, and a one-label id such as the plan word alone is itself a refused shape.
                problems.append('iaps[{}] must start with bundle_id followed by "." (the Pro ids are <bundle_id>.pro.<period>)'.format(index))
            if item in iaps[:index]:
                problems.append('iaps[{}] repeats an earlier product id'.format(index))

    # The consent text names the operator; check_consent_sg_config already refused malformed values.
    if not all(state == 'valid' for state in consent_operator_states(value).values()):
        problems.append('consent_operator must hold the four operator values (name, stir, responsible_person, contact_email), each percent-encoded UTF-8')

    keys = value.get('entitlement_keys')
    if not isinstance(keys, dict) or not keys:
        problems.append('entitlement_keys must map at least one kid to its public key')
    elif not all(_is_p256_public_key(key) for key in keys.values()):
        problems.append('entitlement_keys must contain only base64 P-256 public keys (SPKI DER or raw public points)')

    bot_username = value.get('bot_username')
    if not isinstance(bot_username, str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{1,28}[Bb][Oo][Tt]', bot_username):
        problems.append('bot_username must be the payment bot username without @ (Telegram bot usernames end in "bot")')

    def find_placeholders(item, path):
        if isinstance(item, str):
            if 'FILL_ME' in item:
                problems.append('{} is still a FILL_ME placeholder'.format(path))
        elif isinstance(item, dict):
            for key, child in item.items():
                # Keep only recognized top-level field names, never an untrusted kid or key.
                child_path = path if path else (key if key in SG_CONFIG_KEYS else 'unknown field')
                find_placeholders(child, child_path)
        elif isinstance(item, list):
            for index, child in enumerate(item):
                find_placeholders(child, '{}[{}]'.format(path, index))

    find_placeholders(value, '')
    # One line per gap: the four consent_operator placeholders share one path.
    problems = list(dict.fromkeys(problems))

    if problems:
        fail_sg_config('this App Store build is refused because:\n  - {}\n'.format('\n  - '.join(problems)))


def check_appstore_configuration(configuration):
    """Reject incomplete release identifiers without echoing configuration values."""
    problems = []
    for field in ('api_id', 'appstore_id'):
        value = configuration.get(field)
        is_positive_integer = type(value) is int and value > 0
        is_decimal_string = isinstance(value, str) and re.fullmatch(r'[1-9][0-9]*', value)
        if not (is_positive_integer or is_decimal_string):
            problems.append('{} must be a positive decimal integer'.format(field))

    api_hash = configuration.get('api_hash')
    if not isinstance(api_hash, str) or not re.fullmatch(r'[0-9a-fA-F]{32}', api_hash):
        problems.append('api_hash must contain exactly 32 hexadecimal characters')

    team_id = configuration.get('team_id')
    if not isinstance(team_id, str) or not re.fullmatch(r'[A-Z0-9]{10}', team_id):
        problems.append('team_id must contain exactly 10 uppercase letters or digits')

    internal = configuration.get('is_internal_build')
    if internal is not False and not (isinstance(internal, str) and internal.lower() == 'false'):
        problems.append('is_internal_build must be false')

    if problems:
        raise ValueError('App Store configuration refused:\n  - {}'.format('\n  - '.join(problems)))


class BuildConfiguration:
    def __init__(self,
        sg_config,
        bundle_id,
        api_id,
        api_hash,
        team_id,
        app_center_id,
        is_internal_build,
        is_appstore_build,
        appstore_id,
        app_specific_url_scheme,
        premium_iap_product_id,
        enable_siri,
        enable_icloud,
        lenta_applinks_host=None,
        lenta_telegram_login_app_id=None
    ):
        self.sg_config = normalize_sg_config(sg_config, is_appstore_build, bundle_id)
        self.bundle_id = bundle_id
        self.api_id = api_id
        self.api_hash = api_hash
        self.team_id = team_id
        self.app_center_id = app_center_id
        self.is_internal_build = is_internal_build
        self.is_appstore_build = is_appstore_build
        self.appstore_id = appstore_id
        self.app_specific_url_scheme = app_specific_url_scheme
        self.premium_iap_product_id = premium_iap_product_id
        self.enable_siri = enable_siri
        self.enable_icloud = enable_icloud
        # Zenlygram — read only by Make.py when --enableLenta is passed (never written to variables.bzl).
        self.lenta_applinks_host = normalize_lenta_applinks_host(lenta_applinks_host)
        self.lenta_telegram_login_app_id = normalize_lenta_telegram_login_app_id(lenta_telegram_login_app_id)

    def write_to_variables_file(self, bazel_path, use_xcode_managed_codesigning, aps_environment, path, minimum_os_version='13.0', enable_lenta=False):
        if not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', minimum_os_version):
            raise Exception('The minimum iOS version must be a dotted version number.')
        string = ''
        string += 'telegram_bazel_path = "{}"\n'.format(bazel_path)
        string += 'telegram_use_xcode_managed_codesigning = {}\n'.format('True' if use_xcode_managed_codesigning else 'False')
        string += 'sg_config = """{}"""\n'.format(sg_config_for_build(self.sg_config, enable_lenta))
        string += 'telegram_bundle_id = "{}"\n'.format(self.bundle_id)
        string += 'telegram_minimum_os_version = "{}"\n'.format(minimum_os_version)
        string += 'telegram_api_id = "{}"\n'.format(self.api_id)
        string += 'telegram_api_hash = "{}"\n'.format(self.api_hash)
        string += 'telegram_team_id = "{}"\n'.format(self.team_id)
        string += 'telegram_app_center_id = "{}"\n'.format(self.app_center_id)
        string += 'telegram_is_internal_build = "{}"\n'.format(normalize_build_flag(self.is_internal_build, 'is_internal_build'))
        string += 'telegram_is_appstore_build = "{}"\n'.format(normalize_build_flag(self.is_appstore_build, 'is_appstore_build'))
        string += 'telegram_appstore_id = "{}"\n'.format(self.appstore_id)
        string += 'telegram_app_specific_url_scheme = "{}"\n'.format(self.app_specific_url_scheme)
        string += 'telegram_premium_iap_product_id = "{}"\n'.format(self.premium_iap_product_id)
        string += 'telegram_aps_environment = "{}"\n'.format(aps_environment)
        string += 'telegram_enable_siri = {}\n'.format(self.enable_siri)
        string += 'telegram_enable_icloud = {}\n'.format(self.enable_icloud)
        string += 'telegram_enable_watch = True\n'

        if os.path.exists(path):
            os.remove(path)
        with open(path, 'w+') as file:
            file.write(string)


def build_configuration_from_json(path):
    if not os.path.exists(path):
        print('Could not load build configuration from non-existing path {}'.format(path))
        sys.exit(1)
    with open(path) as file:
        configuration_dict = json.load(file)
        for field in ('is_appstore_build', 'is_internal_build'):
            configuration_dict[field] = normalize_build_flag(configuration_dict.get(field), field)
        if configuration_dict['is_appstore_build'] == 'true':
            check_appstore_configuration(configuration_dict)
        required_keys = [
            'sg_config',
            'bundle_id',
            'api_id',
            'api_hash',
            'team_id',
            'app_center_id',
            'is_internal_build',
            'is_appstore_build',
            'appstore_id',
            'app_specific_url_scheme',
            'premium_iap_product_id',
            'enable_siri',
            'enable_icloud',
        ]
        for key in required_keys:
            if key not in configuration_dict:
                print('Configuration at {} does not contain {}'.format(path, key))
        return BuildConfiguration(
            sg_config=configuration_dict['sg_config'],
            bundle_id=configuration_dict['bundle_id'],
            api_id=configuration_dict['api_id'],
            api_hash=configuration_dict['api_hash'],
            team_id=configuration_dict['team_id'],
            app_center_id=configuration_dict['app_center_id'],
            is_internal_build=configuration_dict['is_internal_build'],
            is_appstore_build=configuration_dict['is_appstore_build'],
            appstore_id=configuration_dict['appstore_id'],
            app_specific_url_scheme=configuration_dict['app_specific_url_scheme'],
            premium_iap_product_id=configuration_dict['premium_iap_product_id'],
            enable_siri=configuration_dict['enable_siri'],
            enable_icloud=configuration_dict['enable_icloud'],
            lenta_applinks_host=configuration_dict.get('lenta_applinks_host'),
            lenta_telegram_login_app_id=configuration_dict.get('lenta_telegram_login_app_id'),
        )


def decrypt_codesigning_directory_recursively(source_base_path, destination_base_path, password):
    for file_name in os.listdir(source_base_path):
        source_path = source_base_path + '/' + file_name
        destination_path = destination_base_path + '/' + file_name
        allowed_file_extensions = ['.mobileprovision', '.cer', '.p12']
        if os.path.isfile(source_path) and any(source_path.endswith(ext) for ext in allowed_file_extensions):
            decrypt_match_data(source_path, destination_path, password)
        elif os.path.isdir(source_path):
            os.makedirs(destination_path, exist_ok=True)
            decrypt_codesigning_directory_recursively(source_path, destination_path, password)


def load_codesigning_data_from_git(working_dir, repo_url, temp_key_path, branch, password, always_fetch):
    # MARK: Swiftgram
    branch = "master"
    if not os.path.exists(working_dir):
        os.makedirs(working_dir, exist_ok=True)

    ssh_command = 'ssh -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
    if temp_key_path is not None:
        ssh_command += ' -i {}'.format(temp_key_path)

    encrypted_working_dir = working_dir + '/encrypted'
    if os.path.exists(encrypted_working_dir):
        original_working_dir = os.getcwd()
        os.chdir(encrypted_working_dir)
        if always_fetch:
            check_run_system('GIT_SSH_COMMAND="{ssh_command}" git fetch --all'.format(ssh_command=ssh_command))
        check_run_system('git checkout "{branch}"'.format(branch=branch))
        if always_fetch:
            check_run_system('GIT_SSH_COMMAND="{ssh_command}" git pull'.format(ssh_command=ssh_command))
        os.chdir(original_working_dir)
    else:
        os.makedirs(encrypted_working_dir, exist_ok=True)
        original_working_dir = os.getcwd()
        os.chdir(working_dir)
        check_run_system('GIT_SSH_COMMAND="{ssh_command}" git clone --depth=1 {repo_url} -b "{branch}" "{target_path}"'.format(
            ssh_command=ssh_command,
            repo_url=repo_url,
            branch=branch,
            target_path=encrypted_working_dir
        ))
        os.chdir(original_working_dir)

    decrypted_working_dir = working_dir + '/decrypted'
    if os.path.exists(decrypted_working_dir):
        shutil.rmtree(decrypted_working_dir)
    os.makedirs(decrypted_working_dir, exist_ok=True)

    decrypt_codesigning_directory_recursively(encrypted_working_dir + '/profiles', decrypted_working_dir + '/profiles', password)
    decrypt_codesigning_directory_recursively(encrypted_working_dir + '/certs', decrypted_working_dir + '/certs', password)


def copy_profiles_from_directory(source_path, destination_path, team_id, bundle_id):
    profile_name_mapping = {
        # Swiftgram
        # '.SGActionRequestHandler': 'SGActionRequestHandler',
        '.SiriIntents': 'Intents',
        '.NotificationContent': 'NotificationContent',
        '.NotificationService': 'NotificationService',
        '.Share': 'Share',
        '': 'Telegram',
        '.watchkitapp': 'WatchApp',
        '.watchkitapp.watchkitextension': 'WatchExtension',
        '.Widget': 'Widget',
        '.BroadcastUpload': 'BroadcastUpload'
    }

    for file_name in os.listdir(source_path):
        file_path = source_path + '/' + file_name
        if os.path.isfile(file_path):
            if not file_path.endswith('.mobileprovision'):
                continue

            profile_data = run_executable_with_output('openssl', arguments=[
                'smime',
                '-inform',
                'der',
                '-verify',
                '-noverify',
                '-in',
                file_path
            ], decode=False, stderr_to_stdout=False, check_result=True)

            profile_dict = plistlib.loads(profile_data)
            profile_name = profile_dict['Entitlements']['application-identifier']

            if profile_name.startswith(team_id + '.' + bundle_id):
                profile_base_name = profile_name[len(team_id + '.' + bundle_id):]
                if profile_base_name in profile_name_mapping:
                    shutil.copyfile(file_path, destination_path + '/' + profile_name_mapping[profile_base_name] + '.mobileprovision')
                else:
                    print('Warning: skipping provisioning profile at {} with bundle_id {} (base_name {})'.format(file_path, profile_name, profile_base_name))


def _appstore_profile_problems(profile, team_id, bundle_id, suffix, now):
    if not isinstance(profile, dict):
        return ['profile must be a dictionary']
    problems = []
    if profile.get('TeamIdentifier') != [team_id]:
        problems.append('TeamIdentifier must match the configured team')
    if 'ProvisionedDevices' in profile:
        problems.append('ProvisionedDevices is not allowed in App Store distribution')
    if 'ProvisionsAllDevices' in profile:
        problems.append('ProvisionsAllDevices is not allowed in App Store distribution')

    expiration = profile.get('ExpirationDate')
    if not isinstance(expiration, datetime.datetime):
        problems.append('ExpirationDate must be a date')
    else:
        if expiration.tzinfo is None:
            expiration = expiration.replace(tzinfo=datetime.timezone.utc)
        if expiration <= now:
            problems.append('ExpirationDate must be in the future')

    entitlements = profile.get('Entitlements')
    if not isinstance(entitlements, dict):
        return problems + ['Entitlements must be a dictionary']
    if entitlements.get('application-identifier') != team_id + '.' + bundle_id + suffix:
        problems.append('application-identifier must match the selected bundle')
    if entitlements.get('com.apple.developer.team-identifier') != team_id:
        problems.append('com.apple.developer.team-identifier must match the configured team')
    if entitlements.get('get-task-allow') is not False:
        problems.append('get-task-allow must be boolean false')
    groups = entitlements.get('com.apple.security.application-groups')
    if not isinstance(groups, list) or 'group.' + bundle_id not in groups:
        problems.append('com.apple.security.application-groups must contain the configured App Group')
    if suffix == '' and entitlements.get('aps-environment') != 'production':
        problems.append('aps-environment must be production for the main app')
    return problems


def check_appstore_provisioning_profiles(source_path, team_id, bundle_id, now=None):
    """Check the seven selected iOS profiles' metadata, not Apple trust or ASC state."""
    # These are the app and six extensions embedded by Telegram/BUILD. Watch remains opt-in.
    required_profiles = {
        'Telegram': '',
        'Share': '.Share',
        'NotificationContent': '.NotificationContent',
        'NotificationService': '.NotificationService',
        'Intents': '.SiriIntents',
        'Widget': '.Widget',
        'BroadcastUpload': '.BroadcastUpload',
    }
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)
    elif now.tzinfo is None:
        now = now.replace(tzinfo=datetime.timezone.utc)

    problems = []
    for name, suffix in required_profiles.items():
        file_name = name + '.mobileprovision'
        file_path = os.path.join(source_path, file_name)
        if not os.path.isfile(file_path):
            problems.append('{} is missing'.format(file_name))
            continue
        try:
            # The shared runner prints decoded stdout before SystemExit on command failure.
            with contextlib.redirect_stdout(io.StringIO()):
                profile_data = run_executable_with_output('openssl', arguments=[
                    'smime', '-inform', 'der', '-verify', '-noverify', '-in', file_path
                ], decode=False, stderr_to_stdout=False, check_result=True)
            profile = plistlib.loads(profile_data)
        except (Exception, SystemExit):
            # Decoder failures must not echo profile payloads, devices or certificate data.
            problems.append('{} could not be decoded'.format(file_name))
            continue
        for problem in _appstore_profile_problems(profile, team_id, bundle_id, suffix, now):
            problems.append('{}: {}'.format(file_name, problem))

    if problems:
        raise ValueError('App Store provisioning refused:\n  - {}'.format('\n  - '.join(problems)))


def resolve_aps_environment_from_directory(source_path, team_id, bundle_id):
    for file_name in os.listdir(source_path):
        file_path = source_path + '/' + file_name
        if os.path.isfile(file_path):
            if not file_path.endswith('.mobileprovision'):
                continue

            profile_data = run_executable_with_output('openssl', arguments=[
                'smime',
                '-inform',
                'der',
                '-verify',
                '-noverify',
                '-in',
                file_path
            ], decode=False, stderr_to_stdout=False, check_result=True)

            profile_dict = plistlib.loads(profile_data)
            profile_name = profile_dict['Entitlements']['application-identifier']

            if profile_name.startswith(team_id + '.' + bundle_id):
                profile_base_name = profile_name[len(team_id + '.' + bundle_id):]
                if profile_base_name == '':
                    if 'aps-environment' not in profile_dict['Entitlements']:
                        print('Provisioning profile at {} does not include an aps-environment entitlement'.format(file_path))
                        sys.exit(1)
                    return profile_dict['Entitlements']['aps-environment']
    return None


def copy_certificates_from_directory(source_path, destination_path):
    for file_name in os.listdir(source_path):
        file_path = source_path + '/' + file_name
        if os.path.isfile(file_path):
            if file_path.endswith('.p12') or file_path.endswith('.cer'):
                shutil.copyfile(file_path, destination_path + '/' + file_name)


class CodesigningSource:
    def __init__(self):
        pass

    def load_data(self, working_dir):
        raise Exception('Not implemented')

    def copy_profiles_to_destination(self, destination_path):
        raise Exception('Not implemented')

    def resolve_aps_environment(self):
        raise Exception('Not implemented')

    def use_xcode_managed_codesigning(self):
        raise Exception('Not implemented')        

    def copy_certificates_to_destination(self, destination_path):
        raise Exception('Not implemented')


class GitCodesigningSource(CodesigningSource):
    def __init__(self, repo_url, private_key, team_id, bundle_id, codesigning_type, password, always_fetch):
        self.repo_url = repo_url
        self.private_key = private_key
        self.team_id = team_id
        self.bundle_id = bundle_id
        self.codesigning_type = codesigning_type
        self.password = password
        self.always_fetch = always_fetch

    def load_data(self, working_dir):
        self.working_dir = working_dir
        temp_key_path = None
        if self.private_key is not None:
            temp_key_path = tempfile.mktemp()
            with open(temp_key_path, 'w+') as file:
                file.write(self.private_key)
                if not self.private_key.endswith('\n'):
                    file.write('\n')
            os.chmod(temp_key_path, 0o600)

        load_codesigning_data_from_git(working_dir=self.working_dir, repo_url=self.repo_url, temp_key_path=temp_key_path, branch=self.team_id, password=self.password, always_fetch=self.always_fetch)

        if temp_key_path is not None:
            os.remove(temp_key_path)

    def copy_profiles_to_destination(self, destination_path):
        source_path = self.working_dir + '/decrypted/profiles/{}'.format(self.codesigning_type)
        copy_profiles_from_directory(source_path=source_path, destination_path=destination_path, team_id=self.team_id, bundle_id=self.bundle_id)

    def resolve_aps_environment(self):
        source_path = self.working_dir + '/decrypted/profiles/{}'.format(self.codesigning_type)
        return resolve_aps_environment_from_directory(source_path=source_path, team_id=self.team_id, bundle_id=self.bundle_id)

    def use_xcode_managed_codesigning(self):
        return False

    def copy_certificates_to_destination(self, destination_path):
        source_path = None
        if self.codesigning_type in ['adhoc', 'appstore']:
            source_path = self.working_dir + '/decrypted/certs/distribution'
        elif self.codesigning_type == 'enterprise':
            source_path = self.working_dir + '/decrypted/certs/enterprise'
        elif self.codesigning_type == 'development':
            source_path = self.working_dir + '/decrypted/certs/development'
        else:
            raise Exception('Unknown codesigning type {}'.format(self.codesigning_type))
        copy_certificates_from_directory(source_path=source_path, destination_path=destination_path)


class DirectoryCodesigningSource(CodesigningSource):
    def __init__(self, directory_path, team_id, bundle_id):
        self.directory_path = directory_path
        self.team_id = team_id
        self.bundle_id = bundle_id

    def load_data(self, working_dir):
        pass

    def copy_profiles_to_destination(self, destination_path):
        copy_profiles_from_directory(source_path=self.directory_path + '/profiles', destination_path=destination_path, team_id=self.team_id, bundle_id=self.bundle_id)

    def resolve_aps_environment(self):
        return resolve_aps_environment_from_directory(source_path=self.directory_path + '/profiles', team_id=self.team_id, bundle_id=self.bundle_id)

    def use_xcode_managed_codesigning(self):
        return False

    def copy_certificates_to_destination(self, destination_path):
        copy_certificates_from_directory(source_path=self.directory_path + '/certs', destination_path=destination_path)


class XcodeManagedCodesigningSource(CodesigningSource):
    def __init__(self):
        pass

    def load_data(self, working_dir):
        pass

    def copy_profiles_to_destination(self, destination_path):
        pass

    def resolve_aps_environment(self):
        return ""

    def use_xcode_managed_codesigning(self):
        return True

    def copy_certificates_to_destination(self, destination_path):
        pass

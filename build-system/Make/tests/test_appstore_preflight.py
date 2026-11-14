"""Release preflight behavior, using synthetic config and CMS-decoded profile fixtures.

Run from the repository root:
    python3 -B -m unittest discover -s build-system/Make/tests -p test_appstore_preflight.py -v

No real configuration, credential, keychain, Apple service or Bazel process is used.
CMS decoding and prerequisite environment lookups are substituted; selection and copying are real.
"""

import ast
import base64
import contextlib
import datetime
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import traceback
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import BuildConfiguration
import Make


TEAM_ID = "TESTTEAM01"
BUNDLE_ID = "com.example.releaseaudit"
APP_GROUP = "group." + BUNDLE_ID
# Synthetic, non-operational values; no developer configuration is read.
SYNTHETIC_API_HASH = "a1" * 16
PROFILE_SUFFIXES = {
    "Telegram": "",
    "Share": ".Share",
    "NotificationContent": ".NotificationContent",
    "NotificationService": ".NotificationService",
    "Intents": ".SiriIntents",
    "Widget": ".Widget",
    "BroadcastUpload": ".BroadcastUpload",
}
# The public P-256 generator point, not an application's signing key.
PUBLIC_POINT = base64.b64encode(bytes.fromhex(
    "04"
    "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
    "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
)).decode("ascii")
PUBLIC_SPKI = base64.b64encode(
    bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")
    + base64.b64decode(PUBLIC_POINT)
).decode("ascii")
# Non-operational DER-shaped fixtures: scalar zero is not a valid EC private key.
PRIVATE_SEC1_SHAPE = (
    bytes.fromhex("30770201010420") + bytes(32)
    + bytes.fromhex("a00a06082a8648ce3d030107a144034200")
    + base64.b64decode(PUBLIC_POINT)
)
PRIVATE_PKCS8_SHAPE = (
    bytes.fromhex("308193020100301306072a8648ce3d020106082a8648ce3d0301070479")
    + PRIVATE_SEC1_SHAPE
)

# Clearly fake operator values, percent-encoded as sg_config carries them; never a real identity.
FIXTURE_OPERATOR = {
    "name": "Fixture%20Operator%20MChJ",
    "stir": "000000000",
    "responsible_person": "Fixture%20Person",
    "contact_email": "privacy@release.example.invalid",
}

# Marks a field the fixture leaves out of sg_config.
ABSENT = object()


def valid_configuration():
    return {
        "sg_config": json.dumps({
            "api_url": "https://release.example.invalid",
            "privacy_policy_url": "https://release.example.invalid/privacy",
            "bot_username": "ReleaseFixtureBot",
            "iaps": [BUNDLE_ID + ".pro.monthly", BUNDLE_ID + ".pro.yearly"],
            "entitlement_keys": {"fixture": PUBLIC_POINT},
            "apple_backend_enabled": True,
            "consent_mode": "required",
            "consent_operator": dict(FIXTURE_OPERATOR),
        }),
        "bundle_id": BUNDLE_ID,
        "api_id": "1234567",
        "api_hash": SYNTHETIC_API_HASH,
        "team_id": TEAM_ID,
        "app_center_id": "0",
        "is_internal_build": "false",
        "is_appstore_build": "true",
        "appstore_id": "1234567890",
        "app_specific_url_scheme": "releasefixture",
        "premium_iap_product_id": "",
        "enable_siri": False,
        "enable_icloud": False,
    }


def payments_off_configuration():
    """The PAYMENTS OFF pair: the backend ships, every StoreKit path is held."""
    configuration = valid_configuration()
    sg_config = {**json.loads(configuration["sg_config"]), "apple_backend_enabled": False, "iaps": []}
    return {**configuration, "sg_config": json.dumps(sg_config)}


def distribution_profiles():
    return {
        name: {
            "TeamIdentifier": [TEAM_ID],
            # Fixed dates keep the fixture independent of the test day's clock.
            "ExpirationDate": datetime.datetime(2100, 1, 1),
            "Entitlements": {
                "application-identifier": TEAM_ID + "." + BUNDLE_ID + suffix,
                "com.apple.developer.team-identifier": TEAM_ID,
                "com.apple.security.application-groups": [APP_GROUP],
                "get-task-allow": False,
                **({"aps-environment": "production"} if name == "Telegram" else {}),
            },
        }
        for name, suffix in PROFILE_SUFFIXES.items()
    }


def with_profile(profiles, name, fields=None, entitlements=None):
    original = profiles[name]
    return {
        **profiles,
        name: {
            **original,
            **(fields or {}),
            "Entitlements": {
                **original["Entitlements"],
                **(entitlements or {}),
            },
        },
    }


def read_generated_variables(path):
    return {
        statement.targets[0].id: ast.literal_eval(statement.value)
        for statement in ast.parse(path.read_text(encoding="utf-8")).body
        if isinstance(statement, ast.Assign)
    }


class AppStoreConfigurationTests(unittest.TestCase):
    def load_configuration(self, configuration):
        with tempfile.TemporaryDirectory(prefix="appstore-config-test-") as directory:
            path = Path(directory) / "synthetic.json"
            path.write_text(json.dumps(configuration), encoding="utf-8")
            return BuildConfiguration.build_configuration_from_json(str(path))

    def compiler_variables(self, configuration):
        result = self.load_configuration(configuration)
        with tempfile.TemporaryDirectory(prefix="appstore-variables-test-") as directory:
            path = Path(directory) / "variables.bzl"
            result.write_to_variables_file(
                bazel_path="synthetic-bazel",
                use_xcode_managed_codesigning=False,
                aps_environment="production",
                path=str(path),
            )
            return read_generated_variables(path)

    def assert_configuration_rejected(self, configuration, field, forbidden=()):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaises(Exception) as raised:
                self.load_configuration(configuration)
        self.assertNotIsInstance(raised.exception, (KeyError, TypeError))
        diagnostic = str(raised.exception) + output.getvalue()
        self.assertIn(field, diagnostic)
        self.assertNotIn(SYNTHETIC_API_HASH, diagnostic)
        for value in forbidden:
            self.assertNotIn(value, diagnostic)

    def test_valid_synthetic_appstore_configuration_preserves_values(self):
        configuration = valid_configuration()
        result = self.load_configuration(configuration)
        for field in ("api_id", "api_hash", "team_id", "appstore_id", "is_internal_build"):
            with self.subTest(field=field):
                self.assertEqual(getattr(result, field), configuration[field])
        self.assertEqual(json.loads(result.sg_config), json.loads(configuration["sg_config"]))
        self.assertNotIn(" ", result.sg_config)

    def test_api_origin_rejects_noncanonical_authorities_without_echo(self):
        configuration = valid_configuration()
        base = json.loads(configuration["sg_config"])
        invalid_urls = (
            "https://:443", "https:///release.example.invalid", "http://release.example.invalid",
            "https://DO_NOT_ECHO@release.example.invalid",
            "https://user:DO_NOT_ECHO@release.example.invalid",
            "https://release.example.invalid/v1", "https://release.example.invalid/path/",
            "https://release.example.invalid?", "https://release.example.invalid#",
            "https://release.example.invalid/?DO_NOT_ECHO=query",
            "https://release.example.invalid/#DO_NOT_ECHO",
            "https://release.example.invalid:", "https://release.example.invalid:0",
            "https://release.example.invalid:65536", "https://release.example.invalid:0443",
            "https://release.example.invalid:+443", "https://release.example.invalid:-1",
            "https://release.example.invalid:443.0", "https://release.example.invalid:４４３",
            "https://release.example.invalid:DO_NOT_ECHO",
            "https://release.example.invalid:999999999999999999999999999999",
            "https://[::1]", "https://[2001:db8::1]:443", "https://::1",
            "https://[::1", "https://release.example.invalid.",
            "https://.release.example.invalid", "https://release..example.invalid",
            "https://release_example.invalid", "https://-release.example.invalid",
            "https://release-.example.invalid", "https://rélease.example.invalid",
            "https://release.example.%69nvalid", "https://release.example.1invalid",
            "https://" + "a" * 64 + ".invalid",
            "https://" + ".".join(("a" * 63, "b" * 63, "c" * 63, "d" * 62)),
            "https://127.1", "https://2130706433", "https://0x7f000001",
            "https://0177.0.0.1", "https://0x7f.0.0.1", "https://127.00.0.1",
            "https://1.2.3", "https://1.2.3.4.5", "https://256.0.0.1",
            "https://127.0.0.-1", "https://127.0.0.+1",
            "\nhttps://release.example.invalid", "https://release.example.invalid\n",
            "https://release.\texample.invalid", "https://release.\x01example.invalid",
            "https://release.\x7fexample.invalid",
        )
        for index, url in enumerate(invalid_urls):
            with self.subTest(case=index):
                self.assert_configuration_rejected({
                    **configuration,
                    "sg_config": json.dumps({**base, "api_url": url}),
                }, "api_url", forbidden=(url, "DO_NOT_ECHO"))

    def test_api_origin_preserves_canonical_dns_ipv4_and_ports_in_generated_config(self):
        configuration = valid_configuration()
        base = json.loads(configuration["sg_config"])
        valid_urls = (
            "https://release.example.invalid", "HTTPS://RELEASE.Example.Invalid",
            "https://release.example.invalid/", "https://release.example.invalid///",
            "https://release.example.invalid:1", "https://release.example.invalid:443",
            "https://release.example.invalid:8443", "https://release.example.invalid:65535",
            "https://release-1.example.invalid", "https://1release.example.invalid",
            "https://localhost", "https://localhost:8443",
            "https://0.0.0.0", "https://10.0.0.1", "https://172.16.0.1",
            "https://192.168.1.2", "https://127.0.0.1", "https://127.0.0.1:8443",
            "https://255.255.255.255",
            "https://" + ".".join(("a" * 63, "b" * 63, "c" * 63, "d" * 61)),
        )
        for index, url in enumerate(valid_urls):
            with self.subTest(case=index):
                sg_config = {**base, "api_url": url}
                variables = self.compiler_variables({
                    **configuration,
                    "sg_config": json.dumps(sg_config),
                })
                self.assertEqual(json.loads(variables["sg_config"]), sg_config)

    def test_api_origin_preserves_existing_upstream_restriction(self):
        configuration = valid_configuration()
        base = json.loads(configuration["sg_config"])
        for url in (
            "https://swiftgram.app", "https://api.swiftgram.app",
            "https://API.SWIFTGRAM.APP:443", "https://swiftgram.app.example.invalid",
        ):
            with self.subTest(url=url):
                self.assert_configuration_rejected({
                    **configuration,
                    "sg_config": json.dumps({**base, "api_url": url}),
                }, "upstream Swiftgram", forbidden=(url,))

    def test_api_origin_validation_does_not_change_debug_compatibility(self):
        configuration = valid_configuration()
        sg_config = {
            **json.loads(configuration["sg_config"]),
            "api_url": "https://127.1",
        }
        variables = self.compiler_variables({
            **configuration,
            "is_appstore_build": False,
            "sg_config": json.dumps(sg_config),
        })
        self.assertEqual(json.loads(variables["sg_config"]), sg_config)

    def test_missing_release_fields_have_explicit_field_diagnostics(self):
        for field in ("api_id", "api_hash", "team_id", "appstore_id", "is_internal_build"):
            with self.subTest(field=field):
                configuration = {key: value for key, value in valid_configuration().items() if key != field}
                self.assert_configuration_rejected(configuration, field)

    def test_empty_null_and_placeholder_release_fields_are_rejected(self):
        for field in ("api_id", "api_hash", "team_id", "appstore_id", "is_internal_build"):
            for label, value in (("empty", ""), ("null", None), ("placeholder", "FILL_ME_private_fixture")):
                with self.subTest(field=field, case=label):
                    self.assert_configuration_rejected(
                        {**valid_configuration(), field: value}, field,
                        forbidden=("FILL_ME_private_fixture",),
                    )

    def test_api_and_appstore_ids_require_positive_decimal_values(self):
        invalid_values = (0, "0", -1, "-1", True, 1.5, "1.5", " 123", "123 ", "１２３", [], {})
        for field in ("api_id", "appstore_id"):
            for index, value in enumerate(invalid_values):
                with self.subTest(field=field, case=index):
                    self.assert_configuration_rejected({**valid_configuration(), field: value}, field)

    def test_positive_integer_ids_remain_accepted(self):
        configuration = {**valid_configuration(), "api_id": 1234567, "appstore_id": 1234567890}
        result = self.load_configuration(configuration)
        self.assertEqual(result.api_id, configuration["api_id"])
        self.assertEqual(result.appstore_id, configuration["appstore_id"])

    def test_api_hash_requires_exactly_32_hex_characters(self):
        for index, value in enumerate(("a" * 31, "a" * 33, "g" * 32, " " + "a" * 32, 123, [], {})):
            with self.subTest(case=index):
                self.assert_configuration_rejected({**valid_configuration(), "api_hash": value}, "api_hash")

    def test_team_id_requires_ten_uppercase_alphanumeric_characters(self):
        for index, value in enumerate(("SHORT", "TOOLONGTEAM1", "testteam01", "TEST-TEAM1", 123, [], {})):
            with self.subTest(case=index):
                self.assert_configuration_rejected({**valid_configuration(), "team_id": value}, "team_id")

    def test_appstore_build_cannot_be_internal_or_use_an_ambiguous_internal_flag(self):
        for index, value in enumerate((True, "true", 0, 1, "0", "no", [], {})):
            with self.subTest(case=index):
                self.assert_configuration_rejected({**valid_configuration(), "is_internal_build": value}, "is_internal_build")

    def test_accepted_flags_are_lowercase_booleans_at_the_compiler_boundary(self):
        cases = (
            (True, False, "true", "false"),
            ("TRUE", "FALSE", "true", "false"),
            ("tRuE", "fAlSe", "true", "false"),
            (False, True, "false", "true"),
            ("fAlSe", "tRuE", "false", "true"),
            ("false", "false", "false", "false"),
        )
        for index, (appstore, internal, expected_appstore, expected_internal) in enumerate(cases):
            with self.subTest(case=index):
                variables = self.compiler_variables({
                    **valid_configuration(),
                    "is_appstore_build": appstore,
                    "is_internal_build": internal,
                })
                self.assertEqual(variables["telegram_is_appstore_build"], expected_appstore)
                self.assertEqual(variables["telegram_is_internal_build"], expected_internal)

    def test_invalid_appstore_flags_cannot_bypass_the_release_guards(self):
        values = (1, "1", 1.0, 0, "0", 0.0, None, "", "yes", [], {}, "FILL_ME_private_flag")
        for index, value in enumerate(values):
            with self.subTest(case=index):
                self.assert_configuration_rejected(
                    {**valid_configuration(), "is_appstore_build": value},
                    "is_appstore_build",
                    forbidden=("FILL_ME_private_flag",),
                )

    def test_missing_appstore_flag_has_an_explicit_field_diagnostic(self):
        configuration = {key: value for key, value in valid_configuration().items() if key != "is_appstore_build"}
        self.assert_configuration_rejected(configuration, "is_appstore_build")

    def test_invalid_internal_flags_are_also_rejected_in_non_appstore_mode(self):
        for index, value in enumerate((1, "1", 1.0, 0, "0", 0.0, None, "", "yes", [], {})):
            with self.subTest(case=index):
                self.assert_configuration_rejected(
                    {**valid_configuration(), "is_appstore_build": "false", "is_internal_build": value},
                    "is_internal_build",
                )

    def test_invalid_field_values_and_other_secrets_are_never_echoed(self):
        for field in ("api_id", "api_hash", "team_id", "appstore_id", "is_internal_build"):
            marker = "DO_NOT_ECHO_" + field
            with self.subTest(field=field):
                self.assert_configuration_rejected(
                    {**valid_configuration(), field: marker}, field, forbidden=(marker,),
                )

    def test_non_appstore_configuration_keeps_existing_placeholder_compatibility(self):
        configuration = {
            **valid_configuration(),
            "is_appstore_build": "false",
            "is_internal_build": "true",
            "sg_config": "",
            "api_id": "FILL_ME_development",
            "api_hash": "FILL_ME_development",
            "team_id": "FILL_ME_development",
            "appstore_id": "0",
        }
        result = self.load_configuration(configuration)
        self.assertEqual(result.api_id, configuration["api_id"])
        self.assertEqual(result.api_hash, configuration["api_hash"])
        self.assertEqual(result.sg_config, "")
        self.assertEqual(result.is_internal_build, "true")

    def test_public_policy_only_appstore_configuration_remains_refused(self):
        configuration = {
            **valid_configuration(),
            "sg_config": json.dumps({
                "public_policy_url": "https://release.example.invalid/v1/monetization",
                "public_policy_keys": {"fixture": PUBLIC_POINT},
                "privacy_policy_url": "https://release.example.invalid/privacy",
            }),
        }
        self.assert_configuration_rejected(configuration, "sg_config")

    def test_apple_backend_flag_absence_survives_only_outside_appstore_builds(self):
        for configuration in (valid_configuration(), payments_off_configuration()):
            expected = json.loads(configuration["sg_config"])
            del expected["apple_backend_enabled"]
            configuration = {**configuration, "sg_config": json.dumps(expected)}
            with self.subTest(payments=bool(expected["iaps"])):
                variables = self.compiler_variables({**configuration, "is_appstore_build": False})
                result = json.loads(variables["sg_config"])
                self.assertNotIn("apple_backend_enabled", result)
                self.assertEqual(result, expected)
                # An App Store build spells the payment state out; SGConfig's silent false is not enough.
                self.assert_configuration_rejected(
                    configuration,
                    "apple_backend_enabled must be an explicit true (payments on, iaps listed) or false (payments off, iaps [])",
                )

    def test_iaps_absence_survives_only_outside_appstore_builds(self):
        # Outside an App Store build SGConfig's default [] is enough; inside, the state is spelled out.
        for configuration in (valid_configuration(), payments_off_configuration()):
            expected = json.loads(configuration["sg_config"])
            del expected["iaps"]
            configuration = {**configuration, "sg_config": json.dumps(expected)}
            with self.subTest(enabled=expected["apple_backend_enabled"]):
                variables = self.compiler_variables({**configuration, "is_appstore_build": False})
                result = json.loads(variables["sg_config"])
                self.assertNotIn("iaps", result)
                self.assertEqual(result, expected)
                self.assert_configuration_rejected(
                    configuration,
                    "iaps must be a list of App Store Connect product ids (payments on) or [] (payments off)",
                )

    def test_payment_pairs_survive_generated_sg_config_without_warning(self):
        configuration = valid_configuration()
        base = json.loads(configuration["sg_config"])
        products = base["iaps"]
        # Outside an App Store build every combination passes through; inside, exactly the two pairs.
        cases = (
            (False, False, products), (False, True, products), (False, False, []), (False, True, []),
            (True, True, products), (True, False, []),
        )
        for appstore, enabled, iaps in cases:
            with self.subTest(appstore=appstore, enabled=enabled, products=len(iaps)):
                sg_config = {**base, "apple_backend_enabled": enabled, "iaps": iaps}
                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    variables = self.compiler_variables({
                        **configuration,
                        "is_appstore_build": appstore,
                        "sg_config": json.dumps(sg_config),
                    })
                result = json.loads(variables["sg_config"])
                self.assertIs(result["apple_backend_enabled"], enabled)
                self.assertEqual(result["iaps"], iaps)
                self.assertEqual(result, sg_config)
                self.assertEqual(output.getvalue(), "")

    def test_payments_off_pair_is_accepted_in_an_appstore_build(self):
        # The OFF pair stays accepted: the backend ships, every StoreKit path is held.
        configuration = payments_off_configuration()
        expected = json.loads(configuration["sg_config"])
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            variables = self.compiler_variables({**configuration, "sg_config": json.dumps(expected, indent=2)})
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(variables["telegram_is_appstore_build"], "true")
        compact = variables["sg_config"]
        self.assertNotIn(" ", compact)
        self.assertNotIn("\n", compact)
        result = json.loads(compact)
        self.assertIs(result["apple_backend_enabled"], False)
        self.assertEqual(result["iaps"], [])
        # The backend half reaches the binary untouched: the entitlement follows the server-signed policy.
        self.assertEqual(result["api_url"], expected["api_url"])
        self.assertEqual(result["entitlement_keys"], {"fixture": PUBLIC_POINT})
        self.assertEqual(result["consent_operator"], FIXTURE_OPERATOR)
        self.assertEqual(result, expected)

    def test_mixed_payment_pairs_are_refused_with_field_names(self):
        configuration = valid_configuration()
        base = json.loads(configuration["sg_config"])
        product = BUNDLE_ID + ".DO_NOT_ECHO.monthly"
        cases = (
            (True, [], "apple_backend_enabled true requires iaps to list the App Store Connect product ids"),
            (False, [product], "iaps listed but apple_backend_enabled is false"),
            (False, base["iaps"], "iaps listed but apple_backend_enabled is false"),
        )
        for enabled, iaps, diagnostic in cases:
            with self.subTest(enabled=enabled, products=len(iaps)):
                sg_config = {**base, "apple_backend_enabled": enabled, "iaps": iaps}
                self.assert_configuration_rejected(
                    {**configuration, "sg_config": json.dumps(sg_config)}, diagnostic, forbidden=(product,),
                )
                # The pair is an App Store rule only; other builds pass it through unchanged.
                variables = self.compiler_variables({
                    **configuration, "is_appstore_build": False, "sg_config": json.dumps(sg_config),
                })
                self.assertEqual(json.loads(variables["sg_config"]), sg_config)

    def test_mixed_payment_pair_is_the_only_gap_reported(self):
        base = json.loads(valid_configuration()["sg_config"])
        cases = (
            ({"apple_backend_enabled": True, "iaps": []}, "apple_backend_enabled true requires iaps"),
            ({"apple_backend_enabled": False}, "iaps listed but apple_backend_enabled is false"),
        )
        for fields, diagnostic in cases:
            with self.subTest(diagnostic=diagnostic):
                with self.assertRaises(Exception) as raised:
                    BuildConfiguration.normalize_sg_config(json.dumps({**base, **fields}), "true")
                problems = [line for line in str(raised.exception).splitlines() if line.startswith("  - ")]
                self.assertEqual(len(problems), 1)
                self.assertIn(diagnostic, problems[0])

    def test_iaps_must_be_a_list_of_product_ids_in_an_appstore_build(self):
        configuration = valid_configuration()
        base = json.loads(configuration["sg_config"])
        shapes = (
            ABSENT, None, "", "DO_NOT_ECHO", 1, True, {}, {"DO_NOT_ECHO": True},
            [""], ["DO_NOT_ECHO", ""], ["DO_NOT_ECHO", 1], [None], [["DO_NOT_ECHO"]],
        )
        for enabled in (False, True):
            for index, iaps in enumerate(shapes):
                with self.subTest(enabled=enabled, case=index):
                    sg_config = {**base, "apple_backend_enabled": enabled, "iaps": iaps}
                    sg_config = {key: item for key, item in sg_config.items() if item is not ABSENT}
                    self.assert_configuration_rejected(
                        {**configuration, "sg_config": json.dumps(sg_config)},
                        "iaps must be a list of App Store Connect product ids (payments on) or [] (payments off)",
                        forbidden=("DO_NOT_ECHO",),
                    )

    def test_apple_backend_flag_wrong_types_fail_without_echo_in_all_builds(self):
        configuration = valid_configuration()
        base = json.loads(configuration["sg_config"])
        invalid_values = (
            "", "true", "false", "TRUE", "FALSE", "yes", "FILL_ME_DO_NOT_ECHO",
            "DO_NOT_ECHO with spaces", 0, 1, -1, 0.0, 1.0, 1.5, None,
            [], ["DO_NOT_ECHO"], {}, {"DO_NOT_ECHO": True},
        )
        for appstore in (False, True):
            for index, value in enumerate(invalid_values):
                with self.subTest(appstore=appstore, case=index):
                    output = io.StringIO()
                    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                        with self.assertRaises(Exception) as raised:
                            self.compiler_variables({
                                **configuration,
                                "is_appstore_build": appstore,
                                "sg_config": json.dumps({**base, "apple_backend_enabled": value}),
                            })
                    self.assertEqual(
                        str(raised.exception),
                        "sg_config: apple_backend_enabled must be a boolean. See appstore/SECRETS.md.",
                    )
                    self.assertEqual(output.getvalue(), "")

    def test_payment_pairs_do_not_bypass_the_other_appstore_guards(self):
        # Everything but the payment pair stays mandatory in both pairs: the backend always ships.
        cases = (
            ("api_url", ""), ("api_url", ABSENT),
            ("entitlement_keys", {}), ("entitlement_keys", ABSENT),
            ("privacy_policy_url", "http://release.example.invalid/privacy"), ("privacy_policy_url", ABSENT),
            ("bot_username", "FixtureWithoutSuffix"), ("bot_username", ABSENT),
            ("consent_operator", ABSENT),
        )
        for configuration in (valid_configuration(), payments_off_configuration()):
            base = json.loads(configuration["sg_config"])
            for field, item in cases:
                with self.subTest(payments=bool(base["iaps"]), field=field, absent=item is ABSENT):
                    sg_config = {**base, field: item}
                    sg_config = {key: value for key, value in sg_config.items() if value is not ABSENT}
                    self.assert_configuration_rejected({**configuration, "sg_config": json.dumps(sg_config)}, field)

    def test_apple_backend_flag_does_not_bypass_public_policy_guards(self):
        configuration = valid_configuration()
        base = {
            **json.loads(configuration["sg_config"]),
            "public_policy_url": "https://release.example.invalid/v1/monetization",
            "public_policy_keys": {"fixture": PUBLIC_POINT},
        }
        invalid_fields = (
            ("public_policy_url", "http://release.example.invalid/v1/monetization"),
            ("public_policy_keys", {"fixture": "DO_NOT_ECHO"}),
        )
        for appstore in (False, True):
            for enabled in (False, True):
                for field, value in invalid_fields:
                    with self.subTest(appstore=appstore, enabled=enabled, field=field):
                        self.assert_configuration_rejected({
                            **configuration,
                            "is_appstore_build": appstore,
                            "sg_config": json.dumps({**base, "apple_backend_enabled": enabled, field: value}),
                        }, field, forbidden=("DO_NOT_ECHO",))

    def test_apple_backend_flag_does_not_admit_public_only_appstore_configuration(self):
        for enabled in (False, True):
            with self.subTest(enabled=enabled):
                self.assert_configuration_rejected({
                    **valid_configuration(),
                    "sg_config": json.dumps({
                        "apple_backend_enabled": enabled,
                        "public_policy_url": "https://release.example.invalid/v1/monetization",
                        "public_policy_keys": {"fixture": PUBLIC_POINT},
                        "privacy_policy_url": "https://release.example.invalid/privacy",
                    }),
                }, "api_url")

    def test_payments_on_pair_with_the_two_pro_ids_is_accepted_in_an_appstore_build(self):
        # The store build ships the ON pair (owner decision 2026-11-11); the server-signed policy, not this
        # pair, decides whether anything is on sale. Pretty-printed input still compacts cleanly.
        configuration = valid_configuration()
        expected = json.loads(configuration["sg_config"])
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            variables = self.compiler_variables({**configuration, "sg_config": json.dumps(expected, indent=2)})
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(variables["telegram_is_appstore_build"], "true")
        compact = variables["sg_config"]
        self.assertNotIn(" ", compact)
        result = json.loads(compact)
        self.assertIs(result["apple_backend_enabled"], True)
        self.assertEqual(result["iaps"], [BUNDLE_ID + ".pro.monthly", BUNDLE_ID + ".pro.yearly"])
        self.assertEqual(result, expected)

    def test_product_ids_must_be_lowercase_dot_separated_labels(self):
        configuration = valid_configuration()
        base = json.loads(configuration["sg_config"])
        shapes = (
            BUNDLE_ID + ".Pro.DO_NOT_ECHO",             # a capital: ASC product ids are case-sensitive
            BUNDLE_ID.upper() + ".pro.monthly",
            BUNDLE_ID + ".pro.monthly ",                # trailing space
            BUNDLE_ID + ".pro monthly",                 # inner space
            BUNDLE_ID + ".pro.monthly\n",
            BUNDLE_ID + ".pro..monthly",                # empty label
            BUNDLE_ID + ".pro.monthly.",                # trailing dot
            "." + BUNDLE_ID + ".pro.monthly",           # leading dot
            "monthly",                                  # a single label
            BUNDLE_ID + ".pro.mönthly",            # non-ASCII
            BUNDLE_ID + "/pro.monthly",
            BUNDLE_ID + ".pro.monthly+",
            "com-example.pro.monthly",                  # "-" and "_" are allowed after the first label only
            "com_example.pro.monthly",
        )
        for index, product in enumerate(shapes):
            for enabled in (True, False):
                with self.subTest(case=index, enabled=enabled):
                    sg_config = {**base, "apple_backend_enabled": enabled, "iaps": [BUNDLE_ID + ".pro.yearly", product]}
                    self.assert_configuration_rejected(
                        {**configuration, "sg_config": json.dumps(sg_config)},
                        "iaps[1] must match ^[a-z0-9]+(\\.[a-z0-9_-]+)+$",
                        forbidden=(product, "DO_NOT_ECHO"),
                    )
                    # An App Store rule only: other builds pass the ids through unchanged (white space
                    # is refused in every build by the copt rule, so those cases stop here).
                    if not any(character.isspace() for character in product):
                        variables = self.compiler_variables({
                            **configuration, "is_appstore_build": False, "sg_config": json.dumps(sg_config),
                        })
                        self.assertEqual(json.loads(variables["sg_config"]), sg_config)

    def test_product_id_grammar_accepts_lowercase_labels_with_dash_and_underscore(self):
        configuration = valid_configuration()
        base = json.loads(configuration["sg_config"])
        iaps = [BUNDLE_ID + ".pro.monthly", BUNDLE_ID + ".pro.yearly", BUNDLE_ID + ".pro.tier_1-a", BUNDLE_ID + ".x9"]
        variables = self.compiler_variables({**configuration, "sg_config": json.dumps({**base, "iaps": iaps})})
        self.assertEqual(json.loads(variables["sg_config"])["iaps"], iaps)

    def test_product_ids_must_start_with_the_bundle_id(self):
        configuration = valid_configuration()
        base = json.loads(configuration["sg_config"])
        foreign = (
            "com.other.pro.monthly",
            "com.example.pro.monthly",                  # a parent of the bundle id
            BUNDLE_ID + "pro.monthly",                  # no "." after the bundle id
            BUNDLE_ID,                                  # the bundle id alone
            BUNDLE_ID + "2.pro.monthly",
            "x" + BUNDLE_ID + ".pro.monthly",
            "org.zenlygram.ios.pro.monthly",            # the shipped id under another bundle id
        )
        for index, product in enumerate(foreign):
            with self.subTest(case=index):
                sg_config = {**base, "iaps": [product, BUNDLE_ID + ".pro.yearly"]}
                self.assert_configuration_rejected(
                    {**configuration, "sg_config": json.dumps(sg_config)},
                    'iaps[0] must start with bundle_id followed by "."',
                    forbidden=(product,),
                )
                variables = self.compiler_variables({
                    **configuration, "is_appstore_build": False, "sg_config": json.dumps(sg_config),
                })
                self.assertEqual(json.loads(variables["sg_config"]), sg_config)

    def test_prefix_rule_is_anchored_by_the_bundle_id_the_build_path_passes(self):
        # normalize_sg_config alone knows no bundle id: the grammar and duplicate rules still apply there,
        # the prefix rule needs the bundle id BuildConfiguration passes (build_configuration_from_json).
        base = json.loads(valid_configuration()["sg_config"])
        foreign = {**base, "iaps": ["com.other.pro.monthly", "com.other.pro.yearly"]}
        self.assertEqual(json.loads(BuildConfiguration.normalize_sg_config(json.dumps(foreign), "true")), foreign)
        with self.assertRaises(Exception) as raised:
            BuildConfiguration.normalize_sg_config(json.dumps(foreign), "true", BUNDLE_ID)
        problems = [line for line in str(raised.exception).splitlines() if line.startswith("  - ")]
        self.assertEqual(len(problems), 2)
        self.assertIn('iaps[0] must start with bundle_id followed by "."', problems[0])
        self.assertIn('iaps[1] must start with bundle_id followed by "."', problems[1])
        self.assertNotIn("com.other", str(raised.exception))

    def test_prefix_rule_ignores_the_bundle_ids_case_and_reports_independently_of_the_grammar(self):
        # A bundle id with a capital (`ph.telegra.Telegraph`) is common; the product ids must still be
        # lowercase, so the prefix is compared without regard to case — otherwise no id could satisfy both
        # rules, and the only diagnostic would have been the grammar's, hiding the real cause.
        configuration = {**valid_configuration(), "bundle_id": "ph.telegra.Telegraph"}
        base = json.loads(configuration["sg_config"])
        accepted = {**base, "iaps": ["ph.telegra.telegraph.pro.monthly", "ph.telegra.telegraph.pro.yearly"]}
        variables = self.compiler_variables({**configuration, "sg_config": json.dumps(accepted)})
        self.assertEqual(json.loads(variables["sg_config"])["iaps"], accepted["iaps"])
        # An id that is foreign AND breaks the grammar is reported for both rules, by index, no echo.
        with self.assertRaises(Exception) as raised:
            BuildConfiguration.normalize_sg_config(json.dumps({**base, "iaps": ["Com.Other.pro.monthly", "ph.telegra.telegraph.pro.yearly"]}), "true", "ph.telegra.Telegraph")
        problems = [line for line in str(raised.exception).splitlines() if line.startswith("  - ")]
        self.assertEqual(len(problems), 2, problems)
        self.assertIn("iaps[0] must match", problems[0])
        self.assertIn('iaps[0] must start with bundle_id followed by "."', problems[1])
        self.assertNotIn("Com.Other", str(raised.exception))

    def test_duplicate_product_ids_are_refused_by_index(self):
        configuration = valid_configuration()
        base = json.loads(configuration["sg_config"])
        monthly, yearly = base["iaps"]
        cases = (
            ([monthly, monthly], "iaps[1] repeats an earlier product id"),
            ([monthly, yearly, monthly], "iaps[2] repeats an earlier product id"),
            ([yearly, monthly, monthly, yearly], "iaps[2] repeats an earlier product id"),
        )
        for iaps, diagnostic in cases:
            with self.subTest(products=len(iaps)):
                self.assert_configuration_rejected(
                    {**configuration, "sg_config": json.dumps({**base, "iaps": iaps})}, diagnostic,
                )
        # Every repeat is named, each once, and nothing else is wrong with a well-formed pair.
        with self.assertRaises(Exception) as raised:
            BuildConfiguration.normalize_sg_config(json.dumps({**base, "iaps": [yearly, monthly, monthly, yearly]}), "true", BUNDLE_ID)
        problems = [line for line in str(raised.exception).splitlines() if line.startswith("  - ")]
        self.assertEqual(problems, ["  - iaps[2] repeats an earlier product id", "  - iaps[3] repeats an earlier product id"])

    def test_tracked_template_payment_pair_passes_once_placeholders_are_filled(self):
        # D12 (2026-11-11): the GPL-published template carries the ON pair with the two public product ids and
        # must agree with the preflight it documents, so only its FILL_ME values separate it from acceptance.
        template_path = Path(__file__).resolve().parents[2] / "zenlygram-appstore.json"
        template = json.loads(template_path.read_text(encoding="utf-8"))
        sg_config = json.loads(template["sg_config"])
        self.assertEqual(template["bundle_id"], "org.zenlygram.ios")
        self.assertIs(sg_config["apple_backend_enabled"], True)
        self.assertEqual(sg_config["iaps"], ["org.zenlygram.ios.pro.monthly", "org.zenlygram.ios.pro.yearly"])
        self.assertEqual(template["premium_iap_product_id"], "")
        self.assert_configuration_rejected(template, "api_id")
        filled = {
            **template,
            "api_id": "1234567",
            "api_hash": SYNTHETIC_API_HASH,
            "team_id": TEAM_ID,
            "appstore_id": "1234567890",
            "sg_config": json.dumps({
                **sg_config,
                "bot_username": "ReleaseFixtureBot",
                "consent_operator": dict(FIXTURE_OPERATOR),
            }),
        }
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = self.load_configuration(filled)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(json.loads(result.sg_config)["iaps"], sg_config["iaps"])


class PublicPolicyBuildConfigurationTests(unittest.TestCase):
    endpoint = "https://release.example.invalid/v1/monetization"

    def normalize(self, public_fields, appstore=False):
        base = json.loads(valid_configuration()["sg_config"]) if appstore else {}
        return BuildConfiguration.normalize_sg_config(
            json.dumps({**base, **public_fields}), "true" if appstore else "false"
        )

    def assert_public_fields_rejected(self, fields, diagnostic_field, forbidden=()):
        for appstore in (False, True):
            with self.subTest(appstore=appstore):
                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    with self.assertRaises(Exception) as raised:
                        self.normalize(fields, appstore=appstore)
                diagnostic = str(raised.exception) + output.getvalue()
                self.assertIn(diagnostic_field, diagnostic)
                self.assertNotIn("DO_NOT_ECHO", diagnostic)
                for value in forbidden:
                    self.assertNotIn(value, diagnostic)

    def test_absent_public_pair_preserves_legacy_configuration(self):
        self.assertEqual(json.loads(self.normalize({})), {})
        self.assertEqual(
            json.loads(self.normalize({}, appstore=True)),
            json.loads(valid_configuration()["sg_config"]),
        )

    def test_public_raw_point_and_spki_are_preserved_in_debug_and_appstore(self):
        for appstore in (False, True):
            for key in (PUBLIC_POINT, PUBLIC_SPKI):
                with self.subTest(appstore=appstore, spki=key == PUBLIC_SPKI):
                    fields = {"public_policy_url": self.endpoint, "public_policy_keys": {"fixture": key}}
                    result = json.loads(self.normalize(fields, appstore=appstore))
                    self.assertEqual(result["public_policy_url"], self.endpoint)
                    self.assertEqual(result["public_policy_keys"], fields["public_policy_keys"])
                    if not appstore:
                        self.assertNotIn("api_url", result)
                        self.assertNotIn("entitlement_keys", result)

    def test_missing_public_pair_member_is_rejected(self):
        self.assert_public_fields_rejected(
            {"public_policy_url": self.endpoint}, "public_policy_keys"
        )
        self.assert_public_fields_rejected(
            {"public_policy_keys": {"fixture": PUBLIC_POINT}}, "public_policy_url"
        )

    def test_invalid_public_key_ring_or_member_is_rejected(self):
        rings = (
            None, [], {}, {"": PUBLIC_POINT}, {"fixture": None}, {"fixture": 123},
            {"fixture": "not-base64"},
            {"fixture": base64.b64encode(bytes(65)).decode("ascii")},
            {"fixture": PUBLIC_SPKI[:-4]},
            {"valid": PUBLIC_POINT, "invalid": "not-base64"},
        )
        for index, ring in enumerate(rings):
            with self.subTest(case=index):
                self.assert_public_fields_rejected(
                    {"public_policy_url": self.endpoint, "public_policy_keys": ring},
                    "public_policy_keys",
                )

    def test_private_der_shapes_are_refused_without_echo_in_all_builds(self):
        for shape in (PRIVATE_SEC1_SHAPE, PRIVATE_PKCS8_SHAPE):
            encoded = base64.b64encode(shape).decode("ascii")
            with self.subTest(pkcs8=shape == PRIVATE_PKCS8_SHAPE):
                self.assert_public_fields_rejected(
                    {
                        "public_policy_url": self.endpoint,
                        "public_policy_keys": {"DO_NOT_ECHO_PRIVATE_LABEL": encoded},
                    },
                    "public_policy_keys",
                    forbidden=(encoded,),
                )

    def test_public_endpoint_requires_exact_https_path_and_valid_authority(self):
        urls = (
            None, 123, "", "http://release.example.invalid/v1/monetization",
            "https:///v1/monetization",
            "https://release.example.invalid/v1/other",
            self.endpoint + "/", self.endpoint + "?DO_NOT_ECHO=query",
            self.endpoint + "#DO_NOT_ECHO", self.endpoint + "?", self.endpoint + "#",
            "https://DO_NOT_ECHO@release.example.invalid/v1/monetization",
            "https://user:DO_NOT_ECHO@release.example.invalid/v1/monetization",
            "https://release.example.invalid:0/v1/monetization",
            "https://release.example.invalid:65536/v1/monetization",
            "https://release.example.invalid:DO_NOT_ECHO/v1/monetization",
            "https://release.example.invalid:/v1/monetization",
            "https://[::1/v1/monetization",
            "https://release.example.invalid/v1/%6donetization",
            "\n" + self.endpoint,
            "https://release.example.invalid /v1/monetization",
        )
        for index, url in enumerate(urls):
            with self.subTest(case=index):
                self.assert_public_fields_rejected(
                    {"public_policy_url": url, "public_policy_keys": {"fixture": PUBLIC_POINT}},
                    "public_policy_url",
                )

    def test_valid_public_ports_and_ipv6_authority_remain_supported(self):
        urls = (
            self.endpoint,
            "HTTPS://release.example.invalid:443/v1/monetization",
            "https://release.example.invalid:8443/v1/monetization",
            "https://release.example.invalid:65535/v1/monetization",
            "https://[::1]:8443/v1/monetization",
        )
        for url in urls:
            with self.subTest(url=url):
                result = json.loads(self.normalize(
                    {"public_policy_url": url, "public_policy_keys": {"fixture": PUBLIC_POINT}}
                ))
                self.assertEqual(result["public_policy_url"], url)


class ConsentBuildConfigurationTests(unittest.TestCase):
    """consent_mode / consent_operator (design 40 §3): checked in every build, required for release."""

    debug_origin = "https://debug.example.invalid"

    def normalize(self, fields, appstore=False, base=None):
        if base is None:
            base = json.loads(valid_configuration()["sg_config"]) if appstore else {"api_url": self.debug_origin}
        config = {**base, **fields}
        config = {key: item for key, item in config.items() if item is not ABSENT}
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = BuildConfiguration.normalize_sg_config(json.dumps(config), "true" if appstore else "false")
        return json.loads(result), output.getvalue()

    def assert_refused(self, fields, diagnostic_field, appstore_values=(False, True), forbidden=(), base=None):
        for appstore in appstore_values:
            with self.subTest(appstore=appstore):
                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    with self.assertRaises(Exception) as raised:
                        self.normalize(fields, appstore=appstore, base=base)
                self.assertNotIsInstance(raised.exception, (KeyError, TypeError, AttributeError))
                diagnostic = str(raised.exception) + output.getvalue()
                self.assertIn(diagnostic_field, diagnostic)
                self.assertNotIn("DO_NOT_ECHO", diagnostic)
                for value in forbidden:
                    self.assertNotIn(value, diagnostic)

    def operator(self, **fields):
        return {**FIXTURE_OPERATOR, **fields}

    def test_consent_keys_are_known_sg_config_keys(self):
        self.assertIn("consent_mode", BuildConfiguration.SG_CONFIG_KEYS)
        self.assertIn("consent_operator", BuildConfiguration.SG_CONFIG_KEYS)
        self.assertEqual(
            BuildConfiguration.CONSENT_OPERATOR_FIELDS,
            ("name", "stir", "responsible_person", "contact_email"),
        )

    def test_both_modes_and_an_absent_mode_survive_in_every_build(self):
        for appstore in (False, True):
            for mode in ("required", "optional", ABSENT):
                with self.subTest(appstore=appstore, mode=mode):
                    result, output = self.normalize(
                        {"consent_mode": mode, "consent_operator": self.operator()}, appstore=appstore
                    )
                    if mode is ABSENT:
                        self.assertNotIn("consent_mode", result)
                    else:
                        self.assertEqual(result["consent_mode"], mode)
                    self.assertEqual(output, "")

    def test_any_other_mode_is_refused_without_echo_in_every_build(self):
        modes = ("", "REQUIRED", "Optional", "off", "DO_NOT_ECHO", None, 0, 1, True, False, [], ["required"], {})
        for index, mode in enumerate(modes):
            with self.subTest(case=index):
                self.assert_refused(
                    {"consent_mode": mode, "consent_operator": self.operator()},
                    'consent_mode must be "required" or "optional".',
                )

    def test_operator_must_be_an_object_with_exactly_four_string_values(self):
        shapes = (
            None, [], "DO_NOT_ECHO", 1, {},
            {key: value for key, value in FIXTURE_OPERATOR.items() if key != "stir"},
            {**FIXTURE_OPERATOR, "DO_NOT_ECHO": "x"},
            {**FIXTURE_OPERATOR, "stir": 123456789},
            {**FIXTURE_OPERATOR, "name": None},
            {**FIXTURE_OPERATOR, "contact_email": ["DO_NOT_ECHO"]},
            {"NAME": "x", "STIR": "x", "RESPONSIBLE_PERSON": "x", "CONTACT_EMAIL": "x"},
            {"name": "x", "stir": "x", "responsiblePerson": "x", "contactEmail": "x"},
        )
        for index, shape in enumerate(shapes):
            with self.subTest(case=index):
                self.assert_refused({"consent_operator": shape}, "consent_operator must be an object")

    def test_malformed_values_are_refused_without_echo_in_every_build(self):
        cases = (
            ("name", "DO_NOT_ECHO%2A"),               # Markdown emphasis
            ("name", "DO_NOT_ECHO%5Bx%5D"),           # Markdown link brackets
            ("name", "DO_NOT_ECHO%60"),               # code span
            ("name", "DO_NOT_ECHO%5C"),               # backslash
            ("name", "DO_NOT_ECHO%0A"),               # LF
            ("name", "DO_NOT_ECHO%09"),               # TAB
            ("name", "DO_NOT_ECHO%7F"),               # DEL
            ("name", "DO_NOT_ECHO%C2%85"),            # C1 NEL
            ("name", "DO_NOT_ECHO%E2%80%A8"),         # U+2028
            ("name", "DO_NOT_ECHO%7B%7BX%7D%7D"),     # placeholder braces
            ("name", "DO_NOT_ECHO{{"),
            ("name", "DO_NOT_ECHO%"),                 # truncated escape
            ("name", "DO_NOT_ECHO%G1"),               # non-hex escape
            ("name", "DO_NOT_ECHO%FF"),               # not UTF-8
            ("name", "DO_NOT_ECHO%C3"),               # truncated UTF-8
            ("name", "%20%20"),                       # only white space once trimmed
            ("name", "A" * 201),
            ("responsible_person", "DO_NOT_ECHO%2A"),
            ("responsible_person", "B" * 201),
            ("stir", "12345678"),
            ("stir", "1234567890"),
            ("stir", "123456789012345"),
            ("stir", "DO_NOT_ECHO"),
            ("stir", "%D9%A1%D9%A2%D9%A3%D9%A4%D9%A5%D9%A6%D9%A7%D9%A8%D9%A9"),  # Arabic-Indic digits
            ("contact_email", "DO_NOT_ECHO"),
            ("contact_email", "DO_NOT_ECHO@example"),
            ("contact_email", "DO_NOT_ECHO@example.x"),
            ("contact_email", "DO_NOT_ECHO@@example.org"),
            ("contact_email", "DO_NOT_ECHO%20x@example.org"),
            ("contact_email", "DO_NOT_ECHO@exa_mple.org"),
            ("contact_email", "DO_NOT_ECHO@example..org"),
        )
        for field, value in cases:
            with self.subTest(field=field, value=value):
                self.assert_refused(
                    {"consent_operator": self.operator(**{field: value})},
                    "consent_operator." + field,
                    forbidden=(value,),
                )

    def test_percent_decoding_nfc_and_trimming_accept_valid_values(self):
        cases = (
            ("name", "Fixture+Operator"),                       # "+" is literal, not a space
            ("name", "%D0%A4%D0%B8%D0%BA%D1%81%D1%82%D1%83%D1%80%D0%B0%20%D0%9C%D0%A7%D0%96"),
            ("name", "O%CA%BBzbek%20Fixture"),
            ("name", "%20%20Padded%20Fixture%E3%80%80"),      # trimmed: ASCII spaces, U+3000
            ("name", "e%CC%81" + "a" * 199),                    # 200 scalars after NFC composes e + U+0301
            ("name", "A" * 200),
            ("responsible_person", "Fixture%20Person%20Ism%20O%CA%BBg%CA%BBli"),
            ("stir", "00000000000000"),
            ("stir", "%20000000000%20"),
            ("contact_email", "first.last+tag@sub.example.invalid"),
            ("contact_email", "privacy%40example.invalid"),
        )
        for appstore in (False, True):
            for field, value in cases:
                with self.subTest(appstore=appstore, field=field, value=value):
                    operator = self.operator(**{field: value})
                    result, output = self.normalize({"consent_operator": operator}, appstore=appstore)
                    # The raw, still-encoded values reach the app unchanged; SGConfig decodes them.
                    self.assertEqual(result["consent_operator"], operator)
                    self.assertEqual(output, "")

    def test_value_state_mirrors_the_runtime_rules(self):
        state = BuildConfiguration.consent_operator_value_state
        self.assertEqual(state("", "name"), "missing")
        self.assertEqual(state("FILL_ME", "stir"), "missing")
        self.assertEqual(state("FILL_ME_operator_name", "name"), "missing")
        self.assertEqual(state("%46ILL_ME", "contact_email"), "missing")   # decoded FILL_ME
        self.assertEqual(state("FILL_ME%", "name"), "invalid")              # undecodable first
        self.assertEqual(state("%20", "name"), "invalid")
        self.assertEqual(state("123456789", "stir"), "valid")

    def test_local_hosts_accept_missing_values_without_warning(self):
        hosts = (
            "https://127.0.0.1", "https://127.1.2.3:8443", "https://10.0.2.2", "https://192.168.1.15",
            "https://172.16.0.1", "https://172.31.255.255", "https://localhost", "https://LOCALHOST:443",
            "https://zenlypay.local", "https://[::1]:8443",
        )
        operators = (ABSENT, {field: "FILL_ME" for field in FIXTURE_OPERATOR}, self.operator(stir="FILL_ME"),
                     self.operator(name=""))
        for api_url in hosts:
            for index, operator in enumerate(operators):
                with self.subTest(api_url=api_url, operator=index):
                    result, output = self.normalize({"api_url": api_url, "consent_operator": operator})
                    self.assertEqual(result["api_url"], api_url)
                    self.assertEqual(output, "")

    def test_other_hosts_warn_once_when_values_are_missing(self):
        hosts = (
            "https://debug.example.invalid", "https://172.32.0.1", "https://192.169.0.1",
            "https://8.8.8.8", "https://local", "https://zenlygram.org.example.invalid",
        )
        for api_url in hosts:
            for index, operator in enumerate((ABSENT, self.operator(contact_email="FILL_ME_DO_NOT_ECHO"))):
                with self.subTest(api_url=api_url, operator=index):
                    _, output = self.normalize({"api_url": api_url, "consent_operator": operator})
                    self.assertEqual(
                        output,
                        "Warning: consent_operator is missing; the consent pipeline stays inactive in this build.\n",
                    )

    def test_no_api_url_or_complete_values_print_nothing(self):
        _, output = self.normalize({"consent_mode": "optional"}, base={})
        self.assertEqual(output, "")
        _, output = self.normalize({"consent_operator": self.operator()})
        self.assertEqual(output, "")

    def test_production_host_requires_the_values_in_every_build(self):
        origins = (
            "https://zenlygram.org", "https://www.zenlygram.org", "https://ZENLYGRAM.ORG",
            "https://zenlygram.org:443", "https://zenlygram.org/", "https://zenlygram.org.",
        )
        operators = (
            ABSENT,
            {field: "FILL_ME" for field in FIXTURE_OPERATOR},
            self.operator(name="FILL_ME_DO_NOT_ECHO"),
            self.operator(responsible_person=""),
        )
        for api_url in origins:
            for index, operator in enumerate(operators):
                with self.subTest(api_url=api_url, operator=index):
                    self.assert_refused(
                        {"api_url": api_url, "consent_operator": operator},
                        "consent_operator must hold the four operator values",
                        appstore_values=(False,),
                    )
        for api_url in origins[:3]:
            with self.subTest(api_url=api_url, operator="complete"):
                result, output = self.normalize({"api_url": api_url, "consent_operator": self.operator()})
                self.assertEqual(result["consent_operator"], FIXTURE_OPERATOR)
                self.assertEqual(output, "")

    def test_appstore_build_requires_the_four_values(self):
        operators = (
            ABSENT,
            {field: "FILL_ME" for field in FIXTURE_OPERATOR},
            self.operator(name="FILL_ME_DO_NOT_ECHO"),
            self.operator(stir="FILL_ME_DO_NOT_ECHO"),
            self.operator(responsible_person="FILL_ME_DO_NOT_ECHO"),
            self.operator(contact_email="FILL_ME_DO_NOT_ECHO"),
            self.operator(contact_email=""),
        )
        for index, operator in enumerate(operators):
            with self.subTest(operator=index):
                self.assert_refused(
                    {"consent_operator": operator},
                    "consent_operator must hold the four operator values",
                    appstore_values=(True,),
                )

    def test_appstore_build_on_the_production_origin_is_accepted_with_values(self):
        result, output = self.normalize({
            "api_url": "https://zenlygram.org",
            "privacy_policy_url": "https://zenlygram.org/privacy-policy.html",
        }, appstore=True)
        self.assertEqual(result["api_url"], "https://zenlygram.org")
        self.assertEqual(output, "")

    def test_payments_off_appstore_build_on_the_production_origin_is_accepted_with_values(self):
        result, output = self.normalize({
            "api_url": "https://zenlygram.org",
            "privacy_policy_url": "https://zenlygram.org/privacy-policy.html",
        }, appstore=True, base=json.loads(payments_off_configuration()["sg_config"]))
        self.assertEqual(result["api_url"], "https://zenlygram.org")
        self.assertIs(result["apple_backend_enabled"], False)
        self.assertEqual(result["iaps"], [])
        self.assertEqual(result["consent_operator"], FIXTURE_OPERATOR)
        self.assertEqual(output, "")

    def test_payments_off_appstore_build_still_requires_the_four_values(self):
        base = json.loads(payments_off_configuration()["sg_config"])
        operators = (
            ABSENT,
            {field: "FILL_ME" for field in FIXTURE_OPERATOR},
            self.operator(stir="FILL_ME_DO_NOT_ECHO"),
            self.operator(contact_email=""),
        )
        for index, operator in enumerate(operators):
            with self.subTest(operator=index):
                self.assert_refused(
                    {"consent_operator": operator},
                    "consent_operator must hold the four operator values",
                    appstore_values=(True,), base=base,
                )

    def test_appstore_build_refuses_the_retired_zenlygram_com_origin(self):
        for api_url in (
            "https://zenlygram.com", "https://www.zenlygram.com", "https://ZENLYGRAM.COM",
            "https://Zenlygram.Com:443", "https://zenlygram.com/",
        ):
            with self.subTest(api_url=api_url):
                self.assert_refused(
                    {"api_url": api_url}, "retired zenlygram.com host", appstore_values=(True,),
                    forbidden=("ZENLYGRAM.COM", "Zenlygram.Com"),
                )
        self.assert_refused(
            {"privacy_policy_url": "https://ZENLYGRAM.COM/privacy-policy.html"},
            "privacy_policy_url points at the retired zenlygram.com host",
            appstore_values=(True,), forbidden=("ZENLYGRAM.COM",),
        )

    def test_appstore_refusal_lists_every_release_gap_at_once_without_echo(self):
        configuration = valid_configuration()
        base = json.loads(configuration["sg_config"])
        del base["apple_backend_enabled"]
        base["api_url"] = "https://zenlygram.com"
        base["consent_operator"] = {field: "FILL_ME_DO_NOT_ECHO" for field in FIXTURE_OPERATOR}
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaises(Exception) as raised:
                BuildConfiguration.normalize_sg_config(json.dumps(base), "true")
        diagnostic = str(raised.exception) + output.getvalue()
        for expected in (
            "retired zenlygram.com host",
            "apple_backend_enabled must be an explicit true (payments on, iaps listed) or false (payments off, iaps [])",
            "consent_operator must hold the four operator values",
            "consent_operator is still a FILL_ME placeholder",
        ):
            self.assertIn(expected, diagnostic)
        self.assertNotIn("DO_NOT_ECHO", diagnostic)
        # The free release's pair with a product id left behind is one more gap in the same list.
        base = json.loads(payments_off_configuration()["sg_config"])
        base["iaps"] = [BUNDLE_ID + ".DO_NOT_ECHO.monthly"]
        base["bot_username"] = "FILL_ME_DO_NOT_ECHO"
        base["consent_operator"] = {field: "FILL_ME_DO_NOT_ECHO" for field in FIXTURE_OPERATOR}
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaises(Exception) as raised:
                BuildConfiguration.normalize_sg_config(json.dumps(base), "true")
        diagnostic = str(raised.exception) + output.getvalue()
        for expected in (
            "iaps listed but apple_backend_enabled is false",
            # The uppercase marker also breaks the product-id grammar: one more gap in the same list.
            "iaps[0] must match ^[a-z0-9]+(\\.[a-z0-9_-]+)+$",
            "consent_operator must hold the four operator values",
            "bot_username is still a FILL_ME placeholder",
            "consent_operator is still a FILL_ME placeholder",
        ):
            self.assertIn(expected, diagnostic)
        self.assertNotIn("DO_NOT_ECHO", diagnostic)

    def test_compact_output_keeps_percent_escapes_through_the_generated_variables(self):
        configuration = valid_configuration()
        base = json.loads(configuration["sg_config"])
        operator = self.operator(name="%D0%9E%D0%9E%D0%9E%20Fixture%2C%20MChJ")
        sg_config = {**base, "consent_operator": operator, "consent_mode": "optional"}
        variables = AppStoreConfigurationTests.compiler_variables(
            AppStoreConfigurationTests(), {**configuration, "sg_config": json.dumps(sg_config, indent=2)}
        )
        self.assertNotIn(" ", variables["sg_config"])
        self.assertEqual(json.loads(variables["sg_config"]), sg_config)


class TasksWireBuildConfigurationTests(unittest.TestCase):
    """sg_config.tasks_wire (wf15 §8.2): the build-time `X-Tasks-Wire` value. Absent means the client's 4 and the
    key is not added, so today's traffic stays byte-identical; 4 or 5 pass through as integers; anything else is
    refused; and 5 is refused for an App Store build and for a build that points at the production server while
    PRODUCTION_TASKS_WIRE_MAX is 4 (a server that does not accept the wire answers 422 to every Tasks request)."""

    debug_origin = "https://debug.example.invalid"
    production_origins = (
        "https://zenlygram.org", "https://www.zenlygram.org", "https://ZENLYGRAM.ORG",
        "https://zenlygram.org:443", "https://zenlygram.org/", "https://zenlygram.org.",
    )
    local_origins = ("https://127.0.0.1", "https://192.168.1.3", "https://localhost", "https://10.0.2.2:8443")

    def normalize(self, fields, appstore=False, base=None):
        if base is None:
            if appstore:
                base = json.loads(valid_configuration()["sg_config"])
            else:
                # The complete operator keeps the consent rule quiet on every origin, production included.
                base = {"api_url": self.debug_origin, "consent_operator": dict(FIXTURE_OPERATOR)}
        config = {**base, **fields}
        config = {key: item for key, item in config.items() if item is not ABSENT}
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = BuildConfiguration.normalize_sg_config(json.dumps(config), "true" if appstore else "false")
        return json.loads(result), output.getvalue()

    def assert_refused(self, fields, diagnostic, appstore_values=(False, True), base=None):
        for appstore in appstore_values:
            with self.subTest(appstore=appstore):
                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    with self.assertRaises(Exception) as raised:
                        self.normalize(fields, appstore=appstore, base=base)
                self.assertNotIsInstance(raised.exception, (KeyError, TypeError, AttributeError))
                message = str(raised.exception) + output.getvalue()
                self.assertIn(diagnostic, message)
                self.assertNotIn("DO_NOT_ECHO", message)

    def compiler_variables(self, configuration):
        with tempfile.TemporaryDirectory(prefix="tasks-wire-variables-test-") as directory:
            path = Path(directory) / "synthetic.json"
            path.write_text(json.dumps(configuration), encoding="utf-8")
            result = BuildConfiguration.build_configuration_from_json(str(path))
            variables = Path(directory) / "variables.bzl"
            result.write_to_variables_file(
                bazel_path="synthetic-bazel",
                use_xcode_managed_codesigning=False,
                aps_environment="production",
                path=str(variables),
            )
            return read_generated_variables(variables)

    def test_tasks_wire_is_a_known_key_and_production_stays_on_wire_four(self):
        self.assertIn("tasks_wire", BuildConfiguration.SG_CONFIG_KEYS)
        self.assertEqual(BuildConfiguration.TASKS_WIRES, (4, 5))
        # Raised to 5 in its own reviewed commit (WP-I11), only after the owner confirms the deploy that accepts 5.
        self.assertEqual(BuildConfiguration.PRODUCTION_TASKS_WIRE_MAX, 4)

    def test_an_absent_key_passes_through_untouched_in_every_build(self):
        for appstore in (False, True):
            with self.subTest(appstore=appstore):
                result, output = self.normalize({"tasks_wire": ABSENT}, appstore=appstore)
                self.assertNotIn("tasks_wire", result)
                self.assertEqual(output, "")

    def test_wire_four_passes_through_as_an_integer_in_every_build(self):
        for appstore in (False, True):
            with self.subTest(appstore=appstore):
                result, output = self.normalize({"tasks_wire": 4}, appstore=appstore)
                self.assertIs(type(result["tasks_wire"]), int)
                self.assertEqual(result["tasks_wire"], 4)
                self.assertEqual(output, "")
        for api_url in self.production_origins:
            with self.subTest(api_url=api_url, appstore=False):
                result, output = self.normalize({"tasks_wire": 4, "api_url": api_url})
                self.assertEqual(result["tasks_wire"], 4)
                self.assertEqual(output, "")
        with self.subTest(api_url="production", appstore=True):
            result, output = self.normalize({
                "tasks_wire": 4,
                "api_url": "https://zenlygram.org",
                "privacy_policy_url": "https://zenlygram.org/privacy-policy.html",
            }, appstore=True)
            self.assertEqual(result["tasks_wire"], 4)
            self.assertEqual(output, "")

    def test_wire_five_passes_through_for_a_debug_build_off_the_production_server(self):
        for api_url in (self.debug_origin,) + self.local_origins + (ABSENT,):
            with self.subTest(api_url=api_url):
                result, output = self.normalize({"tasks_wire": 5, "api_url": api_url})
                self.assertIs(type(result["tasks_wire"]), int)
                self.assertEqual(result["tasks_wire"], 5)
                self.assertEqual(output, "")

    def test_wire_five_is_refused_for_a_debug_build_that_points_at_the_production_server(self):
        for api_url in self.production_origins:
            with self.subTest(api_url=api_url):
                self.assert_refused(
                    {"tasks_wire": 5, "api_url": api_url},
                    "tasks_wire above 4 is refused",
                    appstore_values=(False,),
                )

    def test_wire_five_is_refused_in_every_appstore_build(self):
        # Whatever the origin: a release build is distributed against production.
        cases = {
            "fixture origin": {"tasks_wire": 5},
            "production origin": {
                "tasks_wire": 5,
                "api_url": "https://zenlygram.org",
                "privacy_policy_url": "https://zenlygram.org/privacy-policy.html",
            },
            "local origin": {"tasks_wire": 5, "api_url": "https://127.0.0.1"},
        }
        for name, fields in cases.items():
            with self.subTest(case=name):
                self.assert_refused(fields, "tasks_wire above 4 is refused", appstore_values=(True,))
        with self.subTest(case="payments off"):
            self.assert_refused(
                {"tasks_wire": 5}, "tasks_wire above 4 is refused", appstore_values=(True,),
                base=json.loads(payments_off_configuration()["sg_config"]),
            )

    def test_any_other_value_is_refused_without_echo_in_every_build(self):
        values = (3, 6, 0, -4, 45, "4", "5", "DO_NOT_ECHO", "", 4.0, 5.0, 4.5, True, False, None, [4], [5], {"wire": 5}, {})
        for index, value in enumerate(values):
            with self.subTest(case=index):
                self.assert_refused({"tasks_wire": value}, "tasks_wire must be the integer 4 or 5.")

    def test_the_wire_reaches_the_generated_variables_as_written(self):
        # A simulator build against the local stack may send 5 (the WP-V3 variant); the generated Starlark
        # carries the compact sg_config with the integer as written, and an absent key stays absent.
        configuration = valid_configuration()
        base = {
            **json.loads(configuration["sg_config"]),
            "api_url": "https://127.0.0.1",
            "privacy_policy_url": "https://127.0.0.1/privacy-policy.html",
        }
        for wire in (ABSENT, 4, 5):
            with self.subTest(wire=wire):
                sg_config = {key: item for key, item in {**base, "tasks_wire": wire}.items() if item is not ABSENT}
                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    variables = self.compiler_variables({
                        **configuration,
                        "is_appstore_build": "false",
                        "sg_config": json.dumps(sg_config),
                    })
                result = json.loads(variables["sg_config"])
                self.assertEqual(result, sg_config)
                if wire is ABSENT:
                    self.assertNotIn("tasks_wire", result)
                else:
                    self.assertIs(type(result["tasks_wire"]), int)
                    self.assertEqual(result["tasks_wire"], wire)
                self.assertEqual(output.getvalue(), "")

    def test_the_tracked_template_sends_wire_four_and_cannot_be_raised_before_the_flip(self):
        # The App Store template names no tasks_wire (the client's default, 4). Filled in, it passes with the key
        # absent or 4 and is refused with 5 until PRODUCTION_TASKS_WIRE_MAX is raised (WP-I11).
        template_path = Path(__file__).resolve().parents[2] / "zenlygram-appstore.json"
        template_sg_config = json.loads(json.loads(template_path.read_text(encoding="utf-8"))["sg_config"])
        self.assertNotIn("tasks_wire", template_sg_config)
        filled = {**template_sg_config, "bot_username": "ReleaseFixtureBot", "consent_operator": dict(FIXTURE_OPERATOR)}
        for wire in (ABSENT, 4):
            with self.subTest(wire=wire):
                result, output = self.normalize({"tasks_wire": wire}, appstore=True, base=filled)
                self.assertEqual(result.get("tasks_wire", 4), 4)
                self.assertEqual(output, "")
        self.assert_refused({"tasks_wire": 5}, "tasks_wire above 4 is refused", appstore_values=(True,), base=filled)


class AppStoreSelectedProfileTests(unittest.TestCase):
    def decode_fixture_cms(self, executable, arguments, **options):
        # The only substituted boundary: unsigned fixture plists stand in for CMS payloads.
        # An unexpected subprocess is a test failure, never executed on the host.
        self.assertEqual(executable, "openssl")
        self.assertEqual(arguments[:-1], ["smime", "-inform", "der", "-verify", "-noverify", "-in"])
        self.assertFalse(options.get("decode", True))
        return Path(arguments[-1]).read_bytes()

    def resolve_profiles(self, profiles, configuration=None, xcode_managed=False, decoder=None, argument_overrides=None):
        import plistlib

        with tempfile.TemporaryDirectory(prefix="appstore-profiles-test-") as directory:
            root = Path(directory)
            source = root / "signing" / "profiles"
            source.mkdir(parents=True)
            for index, (name, profile) in enumerate(profiles.items()):
                # Selection must use the decoded application identifier, not the source name.
                (source / ("arbitrary-{}.mobileprovision".format(index))).write_bytes(plistlib.dumps(profile))
            # Follow the filesystem's actual iteration order without mocking selection. Rewriting
            # contents (not directory entries) makes duplicate-profile order deterministic.
            for file_name, profile in zip(os.listdir(source), profiles.values()):
                (source / file_name).write_bytes(plistlib.dumps(profile))
            config_path = root / "synthetic.json"
            config_path.write_text(json.dumps(configuration if configuration is not None else valid_configuration()), encoding="utf-8")
            arguments = SimpleNamespace(
                configurationPath=str(config_path),
                gitCodesigningRepository=None,
                gitCodesigningType=None,
                gitCodesigningUseCurrent=False,
                codesigningInformationPath=None if xcode_managed else str(source.parent),
                xcodeManagedCodesigning=xcode_managed,
            )
            for field, value in (argument_overrides or {}).items():
                setattr(arguments, field, value)
            variables_path = root / "build-input" / "configuration-repository" / "variables.bzl"
            with mock.patch.object(BuildConfiguration, "run_executable_with_output", side_effect=decoder or self.decode_fixture_cms):
                try:
                    Make.resolve_configuration(
                        base_path=str(root),
                        bazel_command_line=SimpleNamespace(bazel="synthetic-bazel"),
                        arguments=arguments,
                        additional_codesigning_output_path=None,
                    )
                except (Exception, SystemExit):
                    self.assertFalse(variables_path.exists(), "Rejected inputs must not reach generated compiler variables")
                    raise
            selected = root / "build-input" / "configuration-repository" / "provisioning"
            selected_profiles = {path.stem: plistlib.loads(path.read_bytes()) for path in selected.glob("*.mobileprovision")}
            return selected_profiles, read_generated_variables(variables_path)

    def assert_profiles_rejected(self, profiles, diagnostic_field, forbidden=(), **arguments):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaises((Exception, SystemExit)) as raised:
                self.resolve_profiles(profiles, **arguments)
        self.assertIn(diagnostic_field, str(raised.exception) + output.getvalue())
        self.assertNotIn(SYNTHETIC_API_HASH, str(raised.exception) + output.getvalue())
        for value in forbidden:
            self.assertNotIn(value, str(raised.exception) + output.getvalue())

    def test_exact_seven_distribution_profiles_are_selected_and_preserved(self):
        profiles = distribution_profiles()
        selected, variables = self.resolve_profiles(profiles)
        self.assertEqual(set(selected), set(PROFILE_SUFFIXES))
        self.assertEqual(selected, profiles)
        self.assertEqual(variables["telegram_aps_environment"], "production")
        self.assertEqual(variables["telegram_minimum_os_version"], "13.0")

    def test_mixed_development_distribution_duplicates_fail_before_variables_in_both_orders(self):
        development = with_profile(
            distribution_profiles(), "Telegram",
            fields={"ProvisionedDevices": ["synthetic-device-not-a-udid"]},
            entitlements={"get-task-allow": True, "aps-environment": "development"},
        )["Telegram"]
        cases = (
            {"DuplicateDevelopment": development, **distribution_profiles()},
            {**distribution_profiles(), "DuplicateDevelopment": development},
        )
        for index, profiles in enumerate(cases):
            with self.subTest(development_first=index == 0):
                self.assert_profiles_rejected(profiles, "aps-environment")

    def test_every_required_selected_profile_is_mandatory(self):
        for name in PROFILE_SUFFIXES:
            with self.subTest(profile=name):
                profiles = {key: value for key, value in distribution_profiles().items() if key != name}
                self.assert_profiles_rejected(profiles, name)

    def test_development_profile_is_rejected_for_every_bundle(self):
        for name in PROFILE_SUFFIXES:
            with self.subTest(profile=name):
                profiles = with_profile(distribution_profiles(), name, entitlements={"get-task-allow": True})
                self.assert_profiles_rejected(profiles, "get-task-allow")

    def test_adhoc_and_even_empty_device_lists_are_rejected(self):
        for name in PROFILE_SUFFIXES:
            for devices in (["synthetic-device-not-a-udid"], []):
                with self.subTest(profile=name, empty=not devices):
                    profiles = with_profile(distribution_profiles(), name, fields={"ProvisionedDevices": devices})
                    self.assert_profiles_rejected(profiles, "ProvisionedDevices")

    def test_enterprise_profile_is_rejected(self):
        profiles = with_profile(distribution_profiles(), "Share", fields={"ProvisionsAllDevices": True})
        self.assert_profiles_rejected(profiles, "ProvisionsAllDevices")

    def test_debug_permission_must_be_explicit_boolean_false(self):
        for value in (0, "false"):
            with self.subTest(value_type=type(value).__name__):
                profiles = with_profile(distribution_profiles(), "Share", entitlements={"get-task-allow": value})
                self.assert_profiles_rejected(profiles, "get-task-allow")
        profiles = distribution_profiles()
        share = profiles["Share"]
        profiles = {**profiles, "Share": {**share, "Entitlements": {key: value for key, value in share["Entitlements"].items() if key != "get-task-allow"}}}
        self.assert_profiles_rejected(profiles, "get-task-allow")

    def test_expired_profiles_are_rejected_for_every_bundle(self):
        for name in PROFILE_SUFFIXES:
            with self.subTest(profile=name):
                profiles = with_profile(distribution_profiles(), name, fields={"ExpirationDate": datetime.datetime(2000, 1, 1)})
                self.assert_profiles_rejected(profiles, "ExpirationDate")

    def test_missing_or_malformed_expiration_is_rejected(self):
        profiles = distribution_profiles()
        profiles = {**profiles, "Share": {key: value for key, value in profiles["Share"].items() if key != "ExpirationDate"}}
        self.assert_profiles_rejected(profiles, "ExpirationDate")
        profiles = with_profile(distribution_profiles(), "Share", fields={"ExpirationDate": "not-a-date"})
        self.assert_profiles_rejected(profiles, "ExpirationDate")

    def test_profile_team_must_match_even_when_application_identifier_matches(self):
        for value in (["OTHERTEAM1"], [], TEAM_ID):
            with self.subTest(value_type=type(value).__name__, empty=not value):
                profiles = with_profile(distribution_profiles(), "Share", fields={"TeamIdentifier": value})
                self.assert_profiles_rejected(profiles, "TeamIdentifier")

    def test_entitlement_team_must_match(self):
        profiles = with_profile(distribution_profiles(), "Share", entitlements={"com.apple.developer.team-identifier": "OTHERTEAM1"})
        self.assert_profiles_rejected(profiles, "com.apple.developer.team-identifier")

    def test_wrong_bundle_or_team_cannot_fill_a_required_extension_slot(self):
        identifiers = (
            TEAM_ID + ".com.example.foreign.Share",
            "OTHERTEAM1." + BUNDLE_ID + ".Share",
            TEAM_ID + "." + BUNDLE_ID + ".ShareExtra",
        )
        for index, identifier in enumerate(identifiers):
            with self.subTest(case=index):
                profiles = with_profile(distribution_profiles(), "Share", entitlements={"application-identifier": identifier})
                self.assert_profiles_rejected(profiles, "Share")

    def test_every_bundle_requires_the_exact_app_group(self):
        for name in PROFILE_SUFFIXES:
            for groups in ([], ["group.com.example.other"], [APP_GROUP + ".extra"], APP_GROUP):
                with self.subTest(profile=name, groups_type=type(groups).__name__):
                    profiles = with_profile(distribution_profiles(), name, entitlements={"com.apple.security.application-groups": groups})
                    self.assert_profiles_rejected(profiles, "com.apple.security.application-groups")

    def test_main_profile_requires_production_push(self):
        for value in ("development", "", True):
            with self.subTest(value_type=type(value).__name__):
                profiles = with_profile(distribution_profiles(), "Telegram", entitlements={"aps-environment": value})
                self.assert_profiles_rejected(profiles, "aps-environment")

    def test_missing_main_push_entitlement_is_rejected(self):
        profiles = distribution_profiles()
        main = profiles["Telegram"]
        profiles = {**profiles, "Telegram": {**main, "Entitlements": {key: value for key, value in main["Entitlements"].items() if key != "aps-environment"}}}
        self.assert_profiles_rejected(profiles, "aps-environment")

    def test_missing_git_password_names_the_prerequisite_without_git_access(self):
        with mock.patch.object(Make.os, "getenv", return_value=None), mock.patch.object(
            BuildConfiguration.GitCodesigningSource, "load_data",
            side_effect=AssertionError("Git access forbidden in prerequisite test"),
        ):
            self.assert_profiles_rejected(
                {}, "TELEGRAM_CODESIGNING_GIT_PASSWORD",
                argument_overrides={
                    "gitCodesigningRepository": "https://release.example.invalid/signing.git",
                    "gitCodesigningType": "appstore",
                },
            )

    def test_missing_git_signing_type_names_the_field_without_password_echo(self):
        marker = "SYNTHETIC_PASSWORD_DO_NOT_ECHO"
        with mock.patch.object(Make.os, "getenv", return_value=marker), mock.patch.object(
            BuildConfiguration.GitCodesigningSource, "load_data",
            side_effect=AssertionError("Git access forbidden in prerequisite test"),
        ):
            self.assert_profiles_rejected(
                {}, "gitCodesigningType", forbidden=(marker,),
                argument_overrides={
                    "gitCodesigningRepository": "https://release.example.invalid/signing.git",
                    "gitCodesigningType": None,
                },
            )

    def test_missing_signing_source_names_the_input_field(self):
        self.assert_profiles_rejected(
            {}, "codesigningInformationPath",
            argument_overrides={"codesigningInformationPath": None},
        )

    def test_missing_signing_directory_names_the_field_without_echoing_the_path(self):
        with tempfile.TemporaryDirectory(prefix="signing-prerequisite-test-") as directory:
            for path in (Path(directory) / "DO_NOT_ECHO_missing", Path(directory)):
                with self.subTest(root_exists=path == Path(directory)):
                    self.assert_profiles_rejected(
                        {}, "codesigningInformationPath", forbidden=(str(path),),
                        argument_overrides={"codesigningInformationPath": str(path)},
                    )

    def test_xcode_managed_appstore_signing_is_explicitly_refused(self):
        self.assert_profiles_rejected({}, "xcodeManagedCodesigning", xcode_managed=True)

    def test_appstore_selection_and_aps_failures_never_echo_decoder_payloads(self):
        marker = "SYNTHETIC_PRIVATE_CMS_PAYLOAD_DO_NOT_ECHO"
        for stage in ("selection", "aps"):
            for failure_type in (RuntimeError, SystemExit):
                with self.subTest(stage=stage, failure=failure_type.__name__):
                    seen_paths = set()

                    def failing_decoder(executable, arguments, **options):
                        path = Path(arguments[-1])
                        already_decoded = path in seen_paths
                        seen_paths.add(path)
                        if stage == "selection" or already_decoded:
                            print(marker)
                            print(marker, file=sys.stderr)
                            raise failure_type(marker)
                        return self.decode_fixture_cms(executable, arguments, **options)

                    output = io.StringIO()
                    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                        with self.assertRaises((Exception, SystemExit)) as raised:
                            self.resolve_profiles(distribution_profiles(), decoder=failing_decoder)
                    diagnostic = "".join(traceback.format_exception(
                        type(raised.exception), raised.exception, raised.exception.__traceback__
                    )) + output.getvalue()
                    self.assertNotIn(marker, diagnostic)
                    self.assertIn("App Store", str(raised.exception))
                    self.assertIn("profiles", str(raised.exception))

    def test_successful_appstore_resolution_preserves_diagnostic_streams(self):
        def reporting_decoder(executable, arguments, **options):
            print("synthetic-selection-stdout")
            print("synthetic-selection-stderr", file=sys.stderr)
            return self.decode_fixture_cms(executable, arguments, **options)

        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            selected, _ = self.resolve_profiles(distribution_profiles(), decoder=reporting_decoder)
        self.assertEqual(selected, distribution_profiles())
        self.assertIn("synthetic-selection-stdout", stdout.getvalue())
        self.assertIn("synthetic-selection-stderr", stderr.getvalue())

    def test_non_appstore_decoder_failure_and_output_remain_unchanged(self):
        failure = RuntimeError("synthetic-development-diagnostic")

        def failing_decoder(executable, arguments, **options):
            print("synthetic-development-stdout")
            print("synthetic-development-stderr", file=sys.stderr)
            raise failure

        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            with self.assertRaises(RuntimeError) as raised:
                self.resolve_profiles(
                    distribution_profiles(),
                    configuration={**valid_configuration(), "is_appstore_build": "false"},
                    decoder=failing_decoder,
                )
        self.assertIs(raised.exception, failure)
        self.assertIn("synthetic-development-stdout", stdout.getvalue())
        self.assertIn("synthetic-development-stderr", stderr.getvalue())

    def test_non_appstore_development_profile_selection_remains_compatible(self):
        profiles = distribution_profiles()
        main = {"Telegram": profiles["Telegram"]}
        main = with_profile(main, "Telegram", fields={"ProvisionedDevices": ["synthetic-device-not-a-udid"]}, entitlements={"get-task-allow": True, "aps-environment": "development"})
        selected, variables = self.resolve_profiles(main, configuration={**valid_configuration(), "is_appstore_build": "false"})
        self.assertEqual(selected, main)
        self.assertEqual(variables["telegram_aps_environment"], "development")

    def test_non_appstore_xcode_managed_signing_remains_compatible(self):
        selected, _ = self.resolve_profiles({}, configuration={**valid_configuration(), "is_appstore_build": "false"}, xcode_managed=True)
        self.assertEqual(selected, {})


if __name__ == "__main__":
    unittest.main()

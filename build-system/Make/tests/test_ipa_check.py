"""ipa_check's `iaps` check: the configuration's payment pair read back from a fixture .app's binaries.

Run from the repository root:
    python3 -B -m unittest discover -s build-system/Make/tests -p test_ipa_check.py -v

No IPA, codesign, Bazel or network: a fixture .app directory whose "Mach-O binaries" are plain byte files
stands in, with the compiled sg_config placed where rules_apple puts it (an embedded framework).
"""

import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "appstore"))
import ipa_check


# The fixture's own bundle id and Pro family: the gate anchors the family on the configuration's bundle_id (as the
# preflight does), never on the shipped literal, so a fixture under another id exercises exactly that.
BUNDLE_ID = "com.example.releaseaudit"
PREFIX = BUNDLE_ID + ".pro."
MONTHLY = PREFIX + "monthly"
YEARLY = PREFIX + "yearly"
# Mach-O magic plus every byte value, never a product id: the needle must not be found in noise.
FILLER = bytes.fromhex("cffaedfe") + bytes(range(256)) * 8


def compiled_sg_config(enabled, iaps):
    """The sg_config string as BuildConfig compiles it: compact JSON, the ids verbatim."""
    return json.dumps({
        "api_url": "https://release.example.invalid",
        "apple_backend_enabled": enabled,
        "iaps": iaps,
    }, separators=(",", ":")).encode("utf-8")


class FixtureApp:
    def __init__(self, root, name="Fixture", main_payload=b""):
        self.name = name
        self.path = Path(root) / (name + ".app")
        self.path.mkdir()
        (self.path / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": name,
            "CFBundleIdentifier": BUNDLE_ID,
            "CFBundleShortVersionString": "0.0.0",
            "CFBundleVersion": "1",
        }))
        (self.path / name).write_bytes(FILLER + main_payload + FILLER)

    def framework(self, name, payload):
        bundle = self.path / "Frameworks" / (name + ".framework")
        bundle.mkdir(parents=True)
        (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": name}))
        (bundle / name).write_bytes(FILLER + payload + FILLER)
        return bundle / name

    def extension(self, name, payload):
        bundle = self.path / "PlugIns" / (name + ".appex")
        bundle.mkdir(parents=True)
        (bundle / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": name,
            "CFBundleIdentifier": BUNDLE_ID + "." + name,
        }))
        (bundle / name).write_bytes(FILLER + payload + FILLER)
        return bundle / name


def run_check(app, enabled, iaps, bundle_id=BUNDLE_ID):
    report = ipa_check.Report()
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        ipa_check.check_iaps(report, str(app.path), {"apple_backend_enabled": enabled, "iaps": iaps}, bundle_id)
    return report.failures, output.getvalue()


class IapsCheckTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ipa-check-test-")
        self.addCleanup(self.directory.cleanup)
        self.app = FixtureApp(self.directory.name)

    def test_bundle_binaries_lists_main_frameworks_and_extensions_once(self):
        core = self.app.framework("Core", b"")
        share = self.app.extension("Share", b"")
        (self.app.path / "Frameworks" / "NotABundle.txt").write_bytes(b"ignored")
        (self.app.path / "Frameworks" / "Empty.framework").mkdir()   # no executable inside
        binaries = ipa_check.bundle_binaries(str(self.app.path))
        self.assertEqual(binaries, [str(self.app.path / "Fixture"), str(core), str(share)])

    def test_on_pair_passes_when_both_ids_are_compiled_into_a_framework(self):
        self.app.framework("Core", compiled_sg_config(True, [MONTHLY, YEARLY]))
        self.app.framework("UI", b"no product id here")
        self.app.extension("Share", b"")
        failures, output = run_check(self.app, True, [MONTHLY, YEARLY])
        self.assertEqual(failures, 0, output)
        lines = output.splitlines()
        self.assertEqual(lines[0], "ok   iaps     4 Mach-O binaries scanned (main executable, Frameworks, PlugIns)")
        self.assertEqual(lines[1], "ok   iaps     payments on: 2/2 sg_config.iaps product ids compiled in (Core)")

    def test_on_pair_finds_ids_in_the_main_executable_too(self):
        # Where rules_apple links BuildConfig may move; the gate follows the string, not the bundle.
        app = FixtureApp(self.directory.name, name="MainOnly", main_payload=compiled_sg_config(True, [MONTHLY, YEARLY]))
        failures, output = run_check(app, True, [MONTHLY, YEARLY])
        self.assertEqual(failures, 0, output)
        self.assertIn("2/2 sg_config.iaps product ids compiled in (MainOnly)", output)

    def test_on_pair_fails_when_an_id_is_missing(self):
        self.app.framework("Core", compiled_sg_config(True, [MONTHLY]))
        failures, output = run_check(self.app, True, [MONTHLY, YEARLY])
        self.assertEqual(failures, 1, output)
        self.assertIn("FAIL iaps     payments on: 1/2 sg_config.iaps product ids compiled in (Core); missing " + YEARLY, output)

    def test_on_pair_fails_when_the_binaries_carry_no_id_at_all(self):
        self.app.framework("Core", compiled_sg_config(False, []))
        failures, output = run_check(self.app, True, [MONTHLY, YEARLY])
        self.assertEqual(failures, 1, output)
        self.assertIn("payments on: 0/2 sg_config.iaps product ids compiled in; missing {}, {}".format(MONTHLY, YEARLY), output)

    def test_on_pair_fails_on_a_stray_pro_id(self):
        self.app.framework("Core", compiled_sg_config(True, [MONTHLY, YEARLY]))
        self.app.extension("Widget", (PREFIX + "lifetime").encode("ascii") + b"\x00")
        failures, output = run_check(self.app, True, [MONTHLY, YEARLY])
        self.assertEqual(failures, 1, output)
        self.assertIn("payments on: 2/2 sg_config.iaps product ids compiled in (Core); stray " + PREFIX + "lifetime", output)

    def test_on_pair_with_an_empty_configuration_list_fails(self):
        self.app.framework("Core", compiled_sg_config(True, [MONTHLY, YEARLY]))
        failures, output = run_check(self.app, True, [])
        self.assertEqual(failures, 1, output)
        self.assertIn("sg_config.iaps is empty", output)
        self.assertIn("stray {}, {}".format(MONTHLY, YEARLY), output)

    def test_off_pair_passes_on_a_clean_bundle(self):
        self.app.framework("Core", compiled_sg_config(False, []))
        self.app.framework("UI", (BUNDLE_ID + ".pr").encode("ascii") + b"\x00o.monthly")   # split across a NUL: not the string
        self.app.extension("Share", b"")
        failures, output = run_check(self.app, False, [])
        self.assertEqual(failures, 0, output)
        self.assertIn("ok   iaps     payments off: no '{}' string in the binaries".format(PREFIX), output)

    def test_off_pair_fails_when_a_pro_id_is_compiled_in(self):
        self.app.framework("Core", compiled_sg_config(False, []))
        self.app.extension("Share", b"\x00" + MONTHLY.encode("ascii") + b"\x00")
        failures, output = run_check(self.app, False, [])
        self.assertEqual(failures, 1, output)
        self.assertIn("FAIL iaps     payments off: no '{}' string in the binaries expected; {} in Share".format(PREFIX, MONTHLY), output)

    def test_the_family_follows_the_configuration_bundle_id_not_the_shipped_literal(self):
        # The same binary judged under two configurations: for the fixture's bundle id a stray
        # org.zenlygram.ios.pro.* string is not its family (the preflight would never let that id into
        # its sg_config), while for the shipped bundle id it is exactly what the OFF check must catch.
        shipped = "org.zenlygram.ios"
        shipped_monthly = ipa_check.pro_product_id_prefix(shipped) + "monthly"
        self.assertEqual(shipped_monthly, "org.zenlygram.ios.pro.monthly")
        self.app.framework("Core", compiled_sg_config(True, [MONTHLY, YEARLY]))
        self.app.extension("Widget", b"\x00" + shipped_monthly.encode("ascii") + b"\x00")
        failures, output = run_check(self.app, True, [MONTHLY, YEARLY])
        self.assertEqual(failures, 0, output)
        self.assertNotIn("stray", output)
        failures, output = run_check(self.app, False, [], bundle_id=shipped)
        self.assertEqual(failures, 1, output)
        self.assertIn("payments off: no 'org.zenlygram.ios.pro.' string in the binaries expected; {} in Widget".format(shipped_monthly), output)

    def test_the_tracked_template_ids_are_the_shipped_family(self):
        # D12: the GPL-published template ships the ON pair; its ids must be the family ipa_check derives
        # from its own bundle_id, or the pre-upload gate and the preflight would judge different strings.
        template_path = Path(__file__).resolve().parents[2] / "zenlygram-appstore.json"
        template = json.loads(template_path.read_text(encoding="utf-8"))
        prefix = ipa_check.pro_product_id_prefix(template["bundle_id"])
        self.assertEqual(prefix, "org.zenlygram.ios.pro.")
        iaps = ipa_check.configuration_sg_config(template)["iaps"]
        self.assertEqual(iaps, [prefix + "monthly", prefix + "yearly"])
        for item in iaps:
            self.assertTrue(ipa_check.pro_product_id_pattern(template["bundle_id"]).fullmatch(item.encode("ascii")), item)

    def test_off_pair_fails_when_the_configuration_still_lists_ids(self):
        self.app.framework("Core", compiled_sg_config(False, []))
        failures, output = run_check(self.app, False, [MONTHLY])
        self.assertEqual(failures, 1, output)
        self.assertIn("1 sg_config.iaps product id(s) configured", output)

    def test_absent_flag_is_payments_off(self):
        self.app.framework("Core", compiled_sg_config(True, [MONTHLY, YEARLY]))
        report = ipa_check.Report()
        with contextlib.redirect_stdout(io.StringIO()) as output:
            ipa_check.check_iaps(report, str(self.app.path), {}, BUNDLE_ID)
        self.assertEqual(report.failures, 1)
        self.assertIn("payments off", output.getvalue())
        self.assertIn(MONTHLY + " in Core", output.getvalue())

    def test_bundle_without_any_binary_fails(self):
        os.remove(self.app.path / "Fixture")
        failures, output = run_check(self.app, False, [])
        self.assertEqual(failures, 1, output)
        self.assertIn("FAIL iaps     0 Mach-O binaries scanned", output)

    def test_configuration_sg_config_accepts_the_string_form_and_tolerates_others(self):
        self.assertEqual(ipa_check.configuration_sg_config({"sg_config": '{"iaps":["a.b"]}'}), {"iaps": ["a.b"]})
        self.assertEqual(ipa_check.configuration_sg_config({"sg_config": ""}), {})
        self.assertEqual(ipa_check.configuration_sg_config({"sg_config": {"iaps": []}}), {"iaps": []})
        self.assertEqual(ipa_check.configuration_sg_config({}), {})
        self.assertEqual(ipa_check.configuration_sg_config({"sg_config": "[]"}), {})

    def test_main_prints_the_iaps_lines_from_the_configuration_file(self):
        # The wiring: main() reads sg_config from --config and runs the check on an unpacked .app.
        self.app.framework("Core", compiled_sg_config(True, [MONTHLY, YEARLY]))
        config_path = Path(self.directory.name) / "config.json"
        config_path.write_text(json.dumps({
            "bundle_id": BUNDLE_ID,
            "team_id": "TESTTEAM01",
            "sg_config": json.dumps({"apple_backend_enabled": True, "iaps": [MONTHLY, YEARLY]}),
        }), encoding="utf-8")
        output = io.StringIO()
        with mock.patch.object(sys, "argv", ["ipa_check.py", str(self.app.path), "--config", str(config_path), "--skip-boundary"]):
            with contextlib.redirect_stdout(output):
                exit_code = ipa_check.main()
        lines = output.getvalue().splitlines()
        self.assertIn("ok   iaps     2 Mach-O binaries scanned (main executable, Frameworks, PlugIns)", lines)
        self.assertIn("ok   iaps     payments on: 2/2 sg_config.iaps product ids compiled in (Core)", lines)
        # The fixture is no release bundle (name, privacy manifests, version...): the other checks fail, the run says so.
        self.assertEqual(exit_code, 1)
        self.assertTrue(lines[-1].endswith("check(s) FAILED — do not upload"), lines[-1])


if __name__ == "__main__":
    unittest.main()

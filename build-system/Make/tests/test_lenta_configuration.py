"""Lenta build-boundary configuration: the optional configuration keys and the Bazel flags Make.py derives.

Run from the repository root:
    python3 -B -m unittest discover -s build-system/Make/tests -p test_lenta_configuration.py -v

No configuration file, Xcode or Bazel process is used.
"""

from pathlib import Path
import json
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import BuildConfiguration
import Make


def define_arguments(enable_lenta, applinks_host=None, telegram_login_app_id=None):
    # BazelCommandLine.__init__ probes the build environment; only the fields get_define_arguments reads are set.
    command_line = object.__new__(Make.BazelCommandLine)
    command_line.build_number = '1'
    command_line.embed_watch_app = False
    command_line.enable_lenta = False
    command_line.lenta_applinks_host = None
    command_line.lenta_telegram_login_app_id = None
    if enable_lenta:
        command_line.set_enable_lenta(applinks_host, telegram_login_app_id)
    return command_line.get_define_arguments()


class LentaTelegramLoginAppIdTests(unittest.TestCase):
    def test_absent_value_leaves_the_entitlement_out(self):
        self.assertIsNone(BuildConfiguration.normalize_lenta_telegram_login_app_id(None))

    def test_decimal_ids_are_accepted_as_strings(self):
        self.assertEqual(BuildConfiguration.normalize_lenta_telegram_login_app_id(123456), '123456')
        self.assertEqual(BuildConfiguration.normalize_lenta_telegram_login_app_id('7000000001'), '7000000001')

    def test_non_decimal_values_are_rejected(self):
        for value in ('', '0', '012', '12a', 'app123', '123-login.tg.dev', ' 123', -5, 0, True, 1.5, ['1']):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    BuildConfiguration.normalize_lenta_telegram_login_app_id(value)


class LentaDefineArgumentsTests(unittest.TestCase):
    def test_flag_off_adds_no_lenta_arguments(self):
        self.assertEqual(define_arguments(False), ['--define=buildNumber=1'])

    def test_flag_on_without_overrides_uses_the_built_in_defaults(self):
        self.assertEqual(define_arguments(True), ['--define=buildNumber=1', '--//Telegram:enableLenta'])

    def test_flag_on_with_host_and_login_app_id(self):
        self.assertEqual(define_arguments(True, 'lenta.example.com', '123456'), [
            '--define=buildNumber=1',
            '--//Telegram:enableLenta',
            '--define=lentaApplinksHost=lenta.example.com',
            '--//Telegram:enableLentaTelegramLogin',
            '--define=lentaTelegramLoginAppId=123456',
        ])


class LentaIapsTests(unittest.TestCase):
    plus = 'org.zenlygram.ios.lenta.plus.monthly'
    tier = 'org.zenlygram.ios.lenta.name.t1'
    step = 'org.zenlygram.ios.lenta.auction.s01'
    pro = 'org.zenlygram.pro.month'

    def normalize(self, value):
        return BuildConfiguration.normalize_sg_config(json.dumps(value), 'false')

    def test_lenta_product_ids_are_accepted(self):
        compact = self.normalize({'iaps': [self.pro], 'lenta_iaps': [self.plus, 'org.zenlygram.ios.lenta.plus.yearly', self.tier, step_six := 'org.zenlygram.ios.lenta.name.t6', self.step]})
        self.assertIn(step_six, json.loads(compact)['lenta_iaps'])

    def test_other_values_are_rejected(self):
        for ids in ([self.pro], ['org.zenlygram.ios.lenta.plus.weekly'], ['org.zenlygram.ios.lenta.name.t0'], ['lenta.plus.monthly'], [self.plus, self.plus], 'x', [1]):
            with self.subTest(ids=ids):
                with self.assertRaises(Exception):
                    self.normalize({'lenta_iaps': ids})

    def test_a_pro_id_is_never_a_lenta_id(self):
        with self.assertRaises(Exception):
            self.normalize({'iaps': [self.plus], 'lenta_iaps': [self.plus]})

    def test_flag_off_build_drops_the_key(self):
        compact = self.normalize({'iaps': [self.pro], 'lenta_iaps': [self.plus]})
        stripped = BuildConfiguration.sg_config_for_build(compact, enable_lenta=False)
        self.assertNotIn('lenta', stripped)
        self.assertEqual(json.loads(stripped), {'iaps': [self.pro]})
        self.assertEqual(BuildConfiguration.sg_config_for_build(compact, enable_lenta=True), compact)
        self.assertEqual(BuildConfiguration.sg_config_for_build('', enable_lenta=False), '')

    def test_variables_file_follows_the_flag(self):
        configuration = object.__new__(BuildConfiguration.BuildConfiguration)
        configuration.sg_config = self.normalize({'iaps': [self.pro], 'lenta_iaps': [self.plus]})
        for name in ('bundle_id', 'api_id', 'api_hash', 'team_id', 'app_center_id', 'appstore_id', 'app_specific_url_scheme', 'premium_iap_product_id'):
            setattr(configuration, name, 'x')
        configuration.is_internal_build = 'false'
        configuration.is_appstore_build = 'false'
        configuration.enable_siri = False
        configuration.enable_icloud = False
        for enable_lenta in (False, True):
            with self.subTest(enable_lenta=enable_lenta), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'variables.bzl'
                configuration.write_to_variables_file('bazel', False, 'development', str(path), enable_lenta=enable_lenta)
                self.assertEqual('lenta_iaps' in path.read_text(), enable_lenta)


if __name__ == '__main__':
    unittest.main()

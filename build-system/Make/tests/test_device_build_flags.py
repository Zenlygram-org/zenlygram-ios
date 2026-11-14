"""Device-floor build flags: --deviceMinimumOS and --deviceLegacyDeprecationWarnings (the App Store build on Xcode 27).

Run from the repository root:
    python3 -B -m unittest discover -s build-system/Make/tests -p test_device_build_flags.py -v

No configuration file, Xcode or Bazel process is used: BazelCommandLine and resolve_configuration are substituted,
the configuration guards and the Bazel argument list Make.build assembles are real.
"""

import argparse
import ast
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import Make


LEGACY_COMPONENTS_RELAXATION = '--per_file_copt=submodules/LegacyComponents/.*@-Wno-error=deprecated-declarations'
DEVICE_CONFIGURATIONS = ('debug_arm64', 'release_arm64')
SIMULATOR_CONFIGURATIONS = ('debug_sim_arm64', 'release_sim_arm64')


def build_arguments(configuration, **overrides):
    # Every attribute Make.build reads, with the argparse defaults of the `build` sub-command.
    arguments = SimpleNamespace(
        configuration=configuration,
        buildNumber=1,
        disableProvisioningProfiles=False,
        simulatorMinimumOS=None,
        deviceMinimumOS=None,
        simulatorLegacyDeprecationWarnings=False,
        deviceLegacyDeprecationWarnings=False,
        overrideBazelVersion=False,
        overrideXcodeVersion=True,
        bazelUserRoot=None,
        lock=False,
        cacheDir=None,
        cacheHost=None,
        enableLenta=False,
        embedWatchApp=False,
        target=None,
        continueOnError=False,
        showActions=False,
        sandbox=False,
        profileSwift=False,
        enableParallelSwiftmoduleGeneration=False,
        outputBuildArtifactsPath=None,
    )
    for field, value in overrides.items():
        setattr(arguments, field, value)
    return arguments


class FakeBazelCommandLine:
    """Records what Make.build hands to Bazel; nothing is probed or executed."""

    def __init__(self, **options):
        self.options = options
        self.common_build_args = []
        self.calls = []

    def __getattr__(self, name):
        def record(*arguments, **options):
            self.calls.append((name, arguments, options))
        return record


class DeviceMinimumOsTypeTests(unittest.TestCase):
    def test_versions_below_13_are_rejected(self):
        for value in ('12.4', '11.0', '9.3.5', '0.0'):
            with self.subTest(value=value):
                with self.assertRaises(argparse.ArgumentTypeError) as raised:
                    Make.device_minimum_os_version(value)
                self.assertIn('13.0', str(raised.exception))

    def test_malformed_versions_are_rejected(self):
        for value in ('15', 'fifteen', '15.0.0.1', ' 15.0', '15.0 ', '15,0', ''):
            with self.subTest(value=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    Make.device_minimum_os_version(value)

    def test_the_default_floor_and_the_xcode_27_floor_pass_through_unchanged(self):
        for value in ('13.0', '15.0', '15.0.1', '26.2'):
            with self.subTest(value=value):
                self.assertEqual(Make.device_minimum_os_version(value), value)


class DeviceFlagConfigurationGuardTests(unittest.TestCase):
    def assert_refused_before_bazel(self, arguments, flag):
        with mock.patch.object(Make, 'BazelCommandLine', side_effect=AssertionError('BazelCommandLine must not be constructed')), \
                mock.patch.object(Make, 'resolve_configuration', side_effect=AssertionError('no configuration may be resolved')):
            with self.assertRaises(Exception) as raised:
                Make.build(bazel='synthetic-bazel', arguments=arguments)
        self.assertNotIsInstance(raised.exception, AssertionError)
        self.assertIn(flag, str(raised.exception))
        self.assertIn('debug_arm64', str(raised.exception))
        self.assertIn('release_arm64', str(raised.exception))

    def test_device_minimum_os_is_rejected_for_simulator_configurations(self):
        for configuration in SIMULATOR_CONFIGURATIONS:
            with self.subTest(configuration=configuration):
                self.assert_refused_before_bazel(build_arguments(configuration, deviceMinimumOS='15.0'), '--deviceMinimumOS')

    def test_device_legacy_deprecation_warnings_is_rejected_for_simulator_configurations(self):
        for configuration in SIMULATOR_CONFIGURATIONS:
            with self.subTest(configuration=configuration):
                self.assert_refused_before_bazel(build_arguments(configuration, deviceLegacyDeprecationWarnings=True), '--deviceLegacyDeprecationWarnings')

    def test_both_device_flags_together_are_rejected_for_simulator_configurations(self):
        for configuration in SIMULATOR_CONFIGURATIONS:
            with self.subTest(configuration=configuration):
                self.assert_refused_before_bazel(
                    build_arguments(configuration, deviceMinimumOS='15.0', deviceLegacyDeprecationWarnings=True),
                    '--deviceMinimumOS',
                )


class DeviceFlagBazelArgumentTests(unittest.TestCase):
    def run_build(self, arguments):
        created = []

        def fake_command_line(**options):
            command_line = FakeBazelCommandLine(**options)
            created.append(command_line)
            return command_line

        resolved = SimpleNamespace(lenta_applinks_host=None, lenta_telegram_login_app_id=None)
        with mock.patch.object(Make, 'BazelCommandLine', side_effect=fake_command_line), \
                mock.patch.object(Make, 'resolve_configuration', return_value=resolved) as resolve:
            Make.build(bazel='synthetic-bazel', arguments=arguments)
        self.assertEqual(len(created), 1)
        resolve.assert_called_once()
        return created[0], resolve.call_args.kwargs

    def test_both_flags_are_accepted_for_release_arm64_and_debug_arm64(self):
        for configuration in DEVICE_CONFIGURATIONS:
            with self.subTest(configuration=configuration):
                command_line, resolve_options = self.run_build(
                    build_arguments(configuration, deviceMinimumOS='15.0', deviceLegacyDeprecationWarnings=True)
                )
                self.assertEqual(resolve_options['minimum_os_version'], '15.0')
                self.assertEqual(command_line.common_build_args, [LEGACY_COMPONENTS_RELAXATION])
                self.assertIn(('set_configuration', (configuration,), {}), command_line.calls)
                self.assertEqual([call for call in command_line.calls if call[0] == 'invoke_build'], [('invoke_build', (), {})])

    def test_the_relaxation_touches_only_legacy_components_deprecated_declarations(self):
        command_line, _ = self.run_build(build_arguments('release_arm64', deviceMinimumOS='15.0', deviceLegacyDeprecationWarnings=True))
        self.assertEqual(len(command_line.common_build_args), 1)
        relaxation = command_line.common_build_args[0]
        self.assertTrue(relaxation.startswith('--per_file_copt=submodules/LegacyComponents/.*@'))
        self.assertEqual(relaxation.split('@', 1)[1], '-Wno-error=deprecated-declarations')
        for forbidden in ('#warnings', '-Wno-error ', '-Wno-error=deprecated-declarations -', '--copt=', '--objccopt=', '--cxxopt='):
            self.assertNotIn(forbidden, ' '.join(command_line.common_build_args))

    def test_device_minimum_os_without_the_relaxation_keeps_bazel_arguments_strict(self):
        command_line, resolve_options = self.run_build(build_arguments('release_arm64', deviceMinimumOS='15.0'))
        self.assertEqual(resolve_options['minimum_os_version'], '15.0')
        self.assertEqual(command_line.common_build_args, [])

    def test_device_builds_default_to_the_13_0_floor_without_relaxation(self):
        for configuration in DEVICE_CONFIGURATIONS:
            with self.subTest(configuration=configuration):
                command_line, resolve_options = self.run_build(build_arguments(configuration))
                self.assertEqual(resolve_options['minimum_os_version'], '13.0')
                self.assertEqual(command_line.common_build_args, [])

    def test_the_device_relaxation_is_the_simulator_relaxation(self):
        device, _ = self.run_build(build_arguments('release_arm64', deviceMinimumOS='15.0', deviceLegacyDeprecationWarnings=True))
        simulator, _ = self.run_build(build_arguments('debug_sim_arm64', simulatorMinimumOS='15.0', simulatorLegacyDeprecationWarnings=True))
        self.assertEqual(device.common_build_args, simulator.common_build_args)


class DeviceFlagParserDefinitionTests(unittest.TestCase):
    """The argparse definitions live under Make.py's __main__ block; read them from the source instead of running it."""

    @classmethod
    def setUpClass(cls):
        tree = ast.parse(Path(Make.__file__).read_text(encoding='utf-8'))
        cls.definitions = {}
        for node in ast.walk(tree):
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'add_argument'):
                continue
            if not (node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str)):
                continue
            parser = node.func.value.id if isinstance(node.func.value, ast.Name) else None
            keywords = {keyword.arg: keyword.value for keyword in node.keywords}
            cls.definitions.setdefault(node.args[0].value, []).append((parser, keywords))

    def help_text(self, keywords):
        value = keywords['help']
        # Help strings may be written as adjacent literals (one ast.Constant) or an explicit concatenation.
        parts = []
        stack = [value]
        while stack:
            node = stack.pop()
            if isinstance(node, ast.Constant):
                parts.append(str(node.value))
            elif isinstance(node, ast.BinOp):
                stack.extend([node.right, node.left])
        return ''.join(parts)

    def test_device_flags_belong_to_the_build_sub_command_only(self):
        for flag in ('--deviceMinimumOS', '--deviceLegacyDeprecationWarnings'):
            with self.subTest(flag=flag):
                self.assertEqual([parser for parser, _ in self.definitions[flag]], ['buildParser'])

    def test_device_legacy_deprecation_warnings_is_an_off_by_default_switch(self):
        (_, keywords), = self.definitions['--deviceLegacyDeprecationWarnings']
        self.assertEqual(keywords['action'].value, 'store_true')
        self.assertIs(keywords['default'].value, False)

    def test_device_legacy_deprecation_warnings_help_names_its_exact_scope(self):
        (_, keywords), = self.definitions['--deviceLegacyDeprecationWarnings']
        text = self.help_text(keywords)
        for expected in ('LegacyComponents', 'deprecated-declarations', 'debug_arm64', 'release_arm64', '--deviceMinimumOS=15.0', 'Xcode 27'):
            self.assertIn(expected, text)

    def test_device_minimum_os_help_names_the_app_store_build(self):
        (_, keywords), = self.definitions['--deviceMinimumOS']
        text = self.help_text(keywords)
        for expected in ('default: 13.0', 'release_arm64', '--deviceMinimumOS=15.0', '--deviceLegacyDeprecationWarnings', 'App Store', '15.0'):
            self.assertIn(expected, text)
        self.assertEqual(keywords['type'].id, 'device_minimum_os_version')


if __name__ == '__main__':
    unittest.main()

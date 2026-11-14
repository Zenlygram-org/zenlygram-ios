#!/usr/bin/env python3
"""Zenlygram — pre-upload checks for the App Store IPA (appstore/CHECKLIST.md "release_arm64 production build").

    python3 build-system/appstore/ipa_check.py bazel-bin/Telegram/Swiftgram.ipa \
        [--config build-system/zenlygram-appstore.local.json] [--build-number N] [--minimum-os 15.0] [--skip-boundary]

Also accepts an unpacked .app (simulator or device) for a partial check. Exit 0 = every check passed.

Checks (each printed as ok / FAIL):
  bundle   Payload/<name>.app is Zenlygram.app, CFBundleExecutable / CFBundleName / CFBundleIconName are not "Swiftgram",
           CFBundleIdentifier equals the configuration's bundle_id, UIDeviceFamily is iPhone + iPad
  version  CFBundleShortVersionString equals versions.json "app"; CFBundleVersion equals --build-number when given
  floor    MinimumOSVersion equals --minimum-os (default 15.0: the Xcode 27 floor, see docs/ui-testing.md); and in the
           app, every embedded framework and every extension the Mach-O deployment target (LC_BUILD_VERSION minos) is
           not above that bundle's own MinimumOSVersion — App Store validation refuses the IPA otherwise (ERROR 90208
           "does not support the minimum OS Version specified in the Info.plist"; Telegram/PatchMinOSVersion.source.sh
           once wrote 14.0 into a widget extension built for 15.0)
  export   ITSAppUsesNonExemptEncryption is false (owner decision 2026-11-09)
  privacy  exactly 11 PrivacyInfo.xcprivacy files (app + 6 extensions + 4 frameworks)
  watch    no embedded Watch app unless --expect-watch
  signing  (IPA / device .app only) each of the 7 bundles has an embedded.mobileprovision; the main app's signed
           entitlements carry aps-environment=production, application-groups group.<bundle>, no get-task-allow
  iaps     the configuration's payment pair read back from the bundle's Mach-O binaries (main executable, Frameworks/*,
           PlugIns/*; sg_config is a BuildConfig C string that rules_apple links into TelegramCoreFramework, not into the
           main executable): payments ON (sg_config.apple_backend_enabled true) => every sg_config.iaps product id is
           a string in a binary and no other <bundle_id>.pro.* id is; payments OFF => no <bundle_id>.pro. string at all
           and sg_config.iaps empty. The family prefix follows the configuration's bundle_id, the same anchor the
           Make preflight enforces (org.zenlygram.ios.pro. for the store configuration)
  lenta    scripts/lenta-boundary-check.sh passes (no Lenta string, symbol, plist key or entitlement)
"""

import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXTENSION_SUFFIXES = ['.Share', '.NotificationContent', '.NotificationService', '.SiriIntents', '.Widget', '.BroadcastUpload']
# The Pro subscription family in App Store Connect: <bundle_id>.pro.monthly / .pro.yearly (appstore/CHECKLIST.md),
# anchored on the configuration's bundle_id exactly as the preflight anchors the ids
# (BuildConfiguration.check_appstore_sg_config requires every sg_config.iaps id to start with bundle_id + '.'), so
# the two gates agree for every configuration — the git-ignored device / development ones included — and not only
# for the shipped 'org.zenlygram.ios.pro.'. A payments-off binary must not carry the family at all; a payments-on
# binary exactly the ids sg_config lists.
PRO_PRODUCT_ID_SUFFIX = '.pro.'


def pro_product_id_prefix(bundle_id):
    return bundle_id + PRO_PRODUCT_ID_SUFFIX


def pro_product_id_pattern(bundle_id):
    """Any id of the bundle's Pro family as a byte regex: the ASC product-id alphabet (letters, digits, hyphens,
    periods, underscores) after the prefix."""
    return re.compile(re.escape(pro_product_id_prefix(bundle_id)).encode('ascii') + rb'[A-Za-z0-9_.-]+')


class Report:
    def __init__(self):
        self.failures = 0

    def check(self, group, ok, text):
        print('{} {:8} {}'.format('ok  ' if ok else 'FAIL', group, text))
        if not ok:
            self.failures += 1


def read_plist(path):
    with open(path, 'rb') as f:
        return plistlib.load(f)


def signed_entitlements(app_path):
    proc = subprocess.run(['codesign', '-d', '--entitlements', ':-', app_path], capture_output=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    data = proc.stdout
    # codesign may emit the entitlements as a binary blob with a 8-byte header, or as XML.
    idx = data.find(b'<?xml')
    if idx > 0:
        data = data[idx:]
    try:
        return plistlib.loads(data)
    except Exception:
        return None


def find_app(payload_dir):
    apps = [d for d in os.listdir(payload_dir) if d.endswith('.app')]
    if len(apps) != 1:
        return None
    return os.path.join(payload_dir, apps[0])


def bundle_executable(bundle, default_name):
    """The bundle's executable file (CFBundleExecutable, else the bundle's own name), or None."""
    plist = os.path.join(bundle, 'Info.plist')
    name = read_plist(plist).get('CFBundleExecutable') if os.path.isfile(plist) else None
    path = os.path.join(bundle, name or default_name)
    return path if os.path.isfile(path) else None


def bundle_binaries(app):
    """The Mach-O binaries of the app bundle: the main executable, then each embedded framework's and each
    extension's. sg_config reaches the app as a C string in BuildConfig, a static library rules_apple links
    into whichever bundle owns it (TelegramCoreFramework today; the main executable is a 137 KB stub), so a
    string check must cover all of them, as scripts/lenta-boundary-check.sh does."""
    binaries = []
    main = bundle_executable(app, os.path.basename(app)[:-len('.app')])
    if main:
        binaries.append(main)
    for folder, suffix in (('Frameworks', '.framework'), ('PlugIns', '.appex')):
        root = os.path.join(app, folder)
        for name in sorted(os.listdir(root)) if os.path.isdir(root) else []:
            if name.endswith(suffix):
                path = bundle_executable(os.path.join(root, name), name[:-len(suffix)])
                if path:
                    binaries.append(path)
    return binaries


def version_tuple(text):
    """'15.0' → (15, 0, 0); anything unreadable → None."""
    parts = str(text).split('.') if text is not None else []
    if not parts or len(parts) > 3 or not all(p.isdigit() for p in parts):
        return None
    return tuple([int(p) for p in parts] + [0] * (3 - len(parts)))


def macho_minimum_os(path):
    """The highest deployment target among the binary's slices, as a string ('15.0'), or None when no
    LC_BUILD_VERSION `minos` line can be read (`xcrun vtool -show-build`)."""
    proc = subprocess.run(['xcrun', 'vtool', '-show-build', path], capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    found = [v for v in re.findall(r'^\s*minos\s+(\d+(?:\.\d+){0,2})\s*$', proc.stdout, re.M) if version_tuple(v)]
    return max(found, key=version_tuple) if found else None


def nested_bundles(app):
    """(display name, bundle path, default executable name) of the app, its frameworks and its extensions."""
    bundles = [(os.path.basename(app), app, os.path.basename(app)[:-len('.app')])]
    for folder, suffix in (('Frameworks', '.framework'), ('PlugIns', '.appex')):
        root = os.path.join(app, folder)
        for name in sorted(os.listdir(root)) if os.path.isdir(root) else []:
            if name.endswith(suffix):
                bundles.append((folder + '/' + name, os.path.join(root, name), name[:-len(suffix)]))
    return bundles


def check_bundle_floors(report, app):
    """Every bundle's binary must run on the MinimumOSVersion its own Info.plist declares (ERROR 90208)."""
    problems, floors = [], set()
    bundles = nested_bundles(app)
    for label, bundle, default_name in bundles:
        plist = os.path.join(bundle, 'Info.plist')
        declared = read_plist(plist).get('MinimumOSVersion') if os.path.isfile(plist) else None
        binary = bundle_executable(bundle, default_name)
        built = macho_minimum_os(binary) if binary else None
        if version_tuple(declared) is None or built is None:
            problems.append('{}: MinimumOSVersion {} / binary minos {} unreadable'.format(label, declared, built))
            continue
        floors.add(declared)
        if version_tuple(built) > version_tuple(declared):
            problems.append('{}: Info.plist MinimumOSVersion {} is below the binary\'s minos {}'.format(label, declared, built))
    report.check('floor', not problems, 'each of the {} bundles\' binaries supports its own MinimumOSVersion ({})'.format(
        len(bundles), ', '.join(sorted(floors, key=version_tuple))) if not problems else '; '.join(problems) + ' — App Store ERROR 90208')


def check_iaps(report, app, sg_config, bundle_id):
    """The payment pair of the configuration the artifact was built with, read back from its binaries.

    Payments ON (apple_backend_enabled true): every sg_config.iaps product id is a string in one of the
    bundle's binaries (the compiled sg_config), and no other <bundle_id>.pro.* id is (a stale hard-coded
    id would load no product on a device and fail silently). Payments OFF: no <bundle_id>.pro. string
    anywhere and sg_config.iaps empty, so a flag-off binary carries no product id at all. The family is
    the configuration's own (`bundle_id`), as in the preflight. Product ids are public (the tracked
    template lists them), so they are printed."""
    prefix = pro_product_id_prefix(bundle_id)
    pattern = pro_product_id_pattern(bundle_id)
    enabled = sg_config.get('apple_backend_enabled') is True
    configured = [item for item in (sg_config.get('iaps') or []) if isinstance(item, str) and item]
    binaries = bundle_binaries(app)
    found = {}  # product id string present in a binary -> the first binary carrying it
    for path in binaries:
        with open(path, 'rb') as f:
            data = f.read()
        for match in pattern.finditer(data):
            found.setdefault(match.group(0).decode('ascii'), os.path.basename(path))
        for item in configured:
            if item.encode('utf-8') in data:
                found.setdefault(item, os.path.basename(path))
    report.check('iaps', bool(binaries), '{} Mach-O binaries scanned (main executable, Frameworks, PlugIns)'.format(len(binaries)))
    if enabled:
        missing = [item for item in configured if item not in found]
        stray = sorted(item for item in found if item not in configured)
        where = sorted({found[item] for item in configured if item in found})
        notes = []
        if not configured:
            notes.append('sg_config.iaps is empty')
        if missing:
            notes.append('missing ' + ', '.join(missing))
        if stray:
            notes.append('stray ' + ', '.join(stray))
        report.check('iaps', not notes, 'payments on: {}/{} sg_config.iaps product ids compiled in{}{}'.format(
            len(configured) - len(missing), len(configured),
            ' (' + ', '.join(where) + ')' if where else '',
            '; ' + '; '.join(notes) if notes else ''))
    else:
        notes = []
        if configured:
            notes.append('{} sg_config.iaps product id(s) configured'.format(len(configured)))
        if found:
            notes.append(', '.join('{} in {}'.format(item, found[item]) for item in sorted(found)))
        report.check('iaps', not notes, "payments off: no '{}' string in the binaries{}".format(
            prefix, '' if not notes else ' expected; ' + '; '.join(notes)))


def configuration_sg_config(cfg):
    """sg_config as the configuration file carries it: a JSON object written as a string (BuildConfiguration.py)."""
    raw = cfg.get('sg_config')
    if isinstance(raw, str):
        raw = json.loads(raw) if raw.strip() else {}
    return raw if isinstance(raw, dict) else {}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('artifact', help='.ipa or .app')
    ap.add_argument('--config', default='build-system/zenlygram-appstore.local.json')
    ap.add_argument('--build-number', type=int, default=None)
    ap.add_argument('--minimum-os', default='15.0')
    ap.add_argument('--expect-watch', action='store_true')
    ap.add_argument('--skip-boundary', action='store_true')
    args = ap.parse_args()

    cfg_path = os.path.join(ROOT, args.config) if not os.path.isabs(args.config) else args.config
    with open(cfg_path) as f:
        cfg = json.load(f)
    bundle_id = cfg['bundle_id']
    sg_config = configuration_sg_config(cfg)
    with open(os.path.join(ROOT, 'versions.json')) as f:
        expected_version = json.load(f)['app']

    report = Report()
    tmp = None
    artifact = os.path.abspath(args.artifact)
    try:
        if artifact.endswith('.ipa'):
            tmp = tempfile.mkdtemp(prefix='zenlygram-ipa-check-')
            with zipfile.ZipFile(artifact) as z:
                names = z.namelist()
                z.extractall(tmp)
            payload = os.path.join(tmp, 'Payload')
            app = find_app(payload)
            report.check('bundle', app is not None, 'exactly one .app in Payload')
            if app is None:
                return 1
            swiftgram_named = [n for n in names if n.startswith('Payload/') and ('Swiftgram.app' in n or n.endswith('/Swiftgram'))]
            report.check('bundle', not swiftgram_named, 'no Swiftgram-named bundle or executable in Payload ({} hit(s))'.format(len(swiftgram_named)))
            xcprivacy = [n for n in names if n.endswith('PrivacyInfo.xcprivacy')]
            report.check('privacy', len(xcprivacy) == 11, '{} PrivacyInfo.xcprivacy files (expected 11)'.format(len(xcprivacy)))
            is_device = True
        else:
            app = artifact
            report.check('bundle', os.path.isdir(app) and app.endswith('.app'), 'artifact is an .app directory')
            count = 0
            for dirpath, _dirs, files in os.walk(app):
                count += files.count('PrivacyInfo.xcprivacy')
            report.check('privacy', count == 11, '{} PrivacyInfo.xcprivacy files (expected 11)'.format(count))
            is_device = os.path.exists(os.path.join(app, 'embedded.mobileprovision'))

        info = read_plist(os.path.join(app, 'Info.plist'))
        report.check('bundle', os.path.basename(app) == 'Zenlygram.app', 'app bundle is {}'.format(os.path.basename(app)))
        for key in ('CFBundleExecutable', 'CFBundleName'):
            value = info.get(key)
            report.check('bundle', value is not None and 'Swiftgram' not in str(value), '{} = {}'.format(key, value))
        # The icon name lives under CFBundleIcons / CFBundleIcons~ipad → CFBundlePrimaryIcon (asset catalog build).
        icon_names = []
        for icons_key in ('CFBundleIcons', 'CFBundleIcons~ipad'):
            icons = info.get(icons_key) or {}
            primary = (icons.get('CFBundlePrimaryIcon') or {}).get('CFBundleIconName')
            if primary:
                icon_names.append(primary)
            icon_names.extend((icons.get('CFBundleAlternateIcons') or {}).keys())
        if info.get('CFBundleIconName'):
            icon_names.append(info['CFBundleIconName'])
        bad_icons = sorted({n for n in icon_names if 'Swiftgram' in str(n)})
        report.check('bundle', bool(icon_names) and not bad_icons, 'icon names: primary {} + {} alternates{}'.format(
            (info.get('CFBundleIcons') or {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconName'), max(0, len(set(icon_names)) - 1),
            '' if not bad_icons else ' — Swiftgram-named: ' + ', '.join(bad_icons)))
        report.check('bundle', info.get('CFBundleIdentifier') == bundle_id, 'CFBundleIdentifier = {} (config {})'.format(info.get('CFBundleIdentifier'), bundle_id))
        families = sorted(info.get('UIDeviceFamily') or [])
        report.check('bundle', families == [1, 2], 'UIDeviceFamily = {} (iPhone + iPad expected)'.format(families))
        report.check('version', info.get('CFBundleShortVersionString') == expected_version, 'CFBundleShortVersionString = {} (versions.json {})'.format(info.get('CFBundleShortVersionString'), expected_version))
        if args.build_number is not None:
            report.check('version', str(info.get('CFBundleVersion')) == str(args.build_number), 'CFBundleVersion = {} (expected {})'.format(info.get('CFBundleVersion'), args.build_number))
        else:
            print('info version  CFBundleVersion = {}'.format(info.get('CFBundleVersion')))
        report.check('floor', info.get('MinimumOSVersion') == args.minimum_os, 'MinimumOSVersion = {} (expected {})'.format(info.get('MinimumOSVersion'), args.minimum_os))
        check_bundle_floors(report, app)
        report.check('export', info.get('ITSAppUsesNonExemptEncryption') is False, 'ITSAppUsesNonExemptEncryption = {}'.format(info.get('ITSAppUsesNonExemptEncryption')))
        has_watch = os.path.isdir(os.path.join(app, 'Watch'))
        report.check('watch', has_watch == args.expect_watch, 'embedded Watch app: {}'.format('present' if has_watch else 'absent'))

        plugins = os.path.join(app, 'PlugIns')
        ext_bundles = sorted(os.listdir(plugins)) if os.path.isdir(plugins) else []
        ext_ids = []
        for b in ext_bundles:
            p = os.path.join(plugins, b, 'Info.plist')
            if os.path.exists(p):
                ext_ids.append(read_plist(p).get('CFBundleIdentifier'))
        expected_ext = sorted(bundle_id + s for s in EXTENSION_SUFFIXES)
        report.check('bundle', sorted(ext_ids) == expected_ext, '{} extensions: {}'.format(len(ext_ids), ', '.join(i.replace(bundle_id, '…') for i in sorted(ext_ids))))

        if is_device:
            missing_profiles = [b for b in [app] + [os.path.join(plugins, b) for b in ext_bundles] if not os.path.exists(os.path.join(b, 'embedded.mobileprovision'))]
            report.check('signing', not missing_profiles, 'embedded.mobileprovision in app + {} extensions'.format(len(ext_bundles)) if not missing_profiles else 'missing embedded.mobileprovision in {}'.format(', '.join(os.path.basename(b) for b in missing_profiles)))
            ent = signed_entitlements(app)
            report.check('signing', ent is not None, 'signed entitlements readable')
            if ent:
                report.check('signing', ent.get('aps-environment') == 'production', 'aps-environment = {}'.format(ent.get('aps-environment')))
                group = 'group.' + bundle_id
                report.check('signing', group in (ent.get('com.apple.security.application-groups') or []), 'application-groups contains {}'.format(group))
                report.check('signing', not ent.get('get-task-allow'), 'get-task-allow = {}'.format(ent.get('get-task-allow')))
                report.check('signing', ent.get('application-identifier') == '{}.{}'.format(cfg['team_id'], bundle_id), 'application-identifier = {}'.format(ent.get('application-identifier')))
        else:
            print('info signing  simulator/unsigned bundle: provisioning and signed-entitlement checks skipped')

        check_iaps(report, app, sg_config, bundle_id)

        if not args.skip_boundary:
            script = os.path.join(ROOT, 'scripts', 'lenta-boundary-check.sh')
            proc = subprocess.run(['bash', script, artifact, '--configuration', cfg_path], capture_output=True, text=True)
            tail = (proc.stdout or '').strip().splitlines()[-1:] or ['']
            report.check('lenta', proc.returncode == 0, 'scripts/lenta-boundary-check.sh → {} (exit {})'.format(tail[0], proc.returncode))
            if proc.returncode != 0:
                print((proc.stdout or '')[-3000:])
                print((proc.stderr or '')[-1000:])
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)

    print('\n{}'.format('ALL CHECKS PASSED — ready for `asc.py validate`' if report.failures == 0 else '{} check(s) FAILED — do not upload'.format(report.failures)))
    return 1 if report.failures else 0


if __name__ == '__main__':
    sys.exit(main())

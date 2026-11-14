# Zenlygram

Zenlygram is an independent, unofficial Telegram client for iPhone and iPad. It is **not affiliated with, endorsed by or supported by Telegram FZ-LLC**, the company behind Telegram; "Telegram" is a trademark of its owner, and the official apps live at https://telegram.org/.

Zenlygram is a fork of [Swiftgram](https://github.com/Swiftgram/Telegram-iOS), which is itself a fork of the official [Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) client: the lineage is Telegram-iOS → Swiftgram → Zenlygram. It talks to the Telegram network through the public [Telegram API](https://core.telegram.org/api) with its own `api_id`.

- Website: https://zenlygram.org/
- Privacy policy: https://zenlygram.org/privacy-policy.html
- Account deletion: https://zenlygram.org/account/delete
- Support: https://zenlygram.org/en/contact (in Russian: https://zenlygram.org/ru/contact)
- Source code: https://github.com/Zenlygram-org/zenlygram-ios

## License

Zenlygram is free software, distributed under the GNU General Public License, version 2 or (at your option) any later version — see [LICENSE](LICENSE) for the text of version 2 and [NOTICE.md](NOTICE.md) for the copyright notice, the origin of the code and what this repository contains. The code inherited from Telegram-iOS and Swiftgram remains under the copyright of its respective authors. The vendored third-party components under `third-party/` and `submodules/` stay under their own upstream licences; their licence files and per-file notices are kept next to their sources where upstream provides them.

Every build distributed through the App Store corresponds to a tag of this repository named `appstore/<version>-<build>` (version = the marketing version shown in the App Store, build = the App Store build number): that tag marks the source the binary was built from ([NOTICE.md](NOTICE.md) says which files of the development tree are not published). If you cannot find the tag for a build you received, ask through the support page above.

## Compilation

The app target kept its upstream label `//Telegram:Swiftgram`; the bundle it produces is `Zenlygram.app`. Zenlygram's compilation steps are the same as for the official app. Below you'll find a complete compilation guide based on the official app.

### Building the App Store configuration

The App Store builds of Zenlygram use `build-system/zenlygram-appstore.json`. That file is a template. Copy it to
`build-system/zenlygram-appstore.local.json` (git-ignored) and replace every `FILL_ME` value with your own:

- `api_id` and `api_hash` — your own pair from https://my.telegram.org;
- `team_id` and `appstore_id` — your Apple developer team and your app's Apple ID;
- in `sg_config`: `bot_username` and the four `consent_operator` values (`name`, `stir`, `responsible_person`,
  `contact_email`, each percent-encoded UTF-8);
- `bundle_id` — your own; every product id in `sg_config.iaps` has to start with it.

Three more values of `sg_config` belong to the Zenlygram service: `api_url`, `privacy_policy_url` and
`entitlement_keys`. A build of your own has to use its own server, privacy policy and keys there.

`build-system/Make/BuildConfiguration.py` checks the file before the build starts and names the field it
refuses. The template sets `is_appstore_build` to `"true"`, and the store command below passes a directory as
`--codesigningInformationPath`. It is laid out like `build-system/fake-codesigning`. Its `profiles/`
subdirectory holds seven App Store distribution profiles of your own team, one for the app and one for each of
its six extensions (bundle id suffixes `.Share`, `.NotificationContent`, `.NotificationService`,
`.SiriIntents`, `.Widget` and `.BroadcastUpload`). The signing certificate has to be in a keychain:
`python3 build-system/Make/ImportCertificates.py --path <directory>/certs` imports the `.p12` and `.cer` files
of the `certs/` subdirectory into a temporary one, as `.github/workflows/build.yml` does before it builds. For
such a configuration the build refuses, among other things, `--xcodeManagedCodesigning`, a directory without
`profiles/`, a missing or expired profile, a profile of another team or with a device list, and an app
profile whose `aps-environment` is not `production`. The command the store builds are made with (Xcode 27;
the iOS 15.0 floor is that SDK's minimum):

```
python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir "$HOME/telegram-bazel-cache" build \
    --configurationPath build-system/zenlygram-appstore.local.json \
    --codesigningInformationPath <directory with profiles/ and certs/> \
    --deviceMinimumOS=15.0 --deviceLegacyDeprecationWarnings \
    --buildNumber <build number> --configuration=release_arm64
```

The build number of a published build is the number in its tag name (`appstore/<version>-<build>`). This
repository has one commit per published build, so the rule of `.github/workflows/build.yml` (commit count plus
`build_number_offset`) does not give that number here.

The store builds are made without `--enableLenta`. See [NOTICE.md](NOTICE.md) for what this repository
contains and what it leaves out.

# Telegram iOS Source Code Compilation Guide

We welcome all developers to use our API and source code to create applications on our platform.
There are several things we require from **all developers** for the moment.

# Creating your Telegram Application

1. [**Obtain your own api_id**](https://core.telegram.org/api/obtaining_api_id) for your application.
2. Please **do not** use the name Telegram for your app — or make sure your users understand that it is unofficial.
3. Kindly **do not** use our standard logo (white paper plane in a blue circle) as your app's logo.
3. Please study our [**security guidelines**](https://core.telegram.org/mtproto/security_guidelines) and take good care of your users' data and privacy.
4. Please remember to publish **your** code too in order to comply with the licences.

# Quick Compilation Guide

## Get the Code

```
git clone --recursive -j8 https://github.com/Zenlygram-org/zenlygram-ios.git
```

## Setup Xcode

Install Xcode (directly from https://developer.apple.com/download/applications or using the App Store).

## Adjust Configuration

1. Generate a random identifier:
```
openssl rand -hex 8
```
2. Create a new Xcode project. Use `Swiftgram` as the Product Name — it has to match the `.Swiftgram` suffix of the `bundle_id` in the template edited in step 4 (the app bundle is still named `Zenlygram.app`). Use `org.{identifier from step 1}` as the Organization Identifier.
3. Open `Keychain Access` and navigate to `Certificates`. Locate `Apple Development: your@email.address (XXXXXXXXXX)` and double tap the certificate. Under `Details`, locate `Organizational Unit`. This is the Team ID.
4. Edit `build-system/template_minimal_development_configuration.json`. Use data from the previous steps.

## Generate an Xcode project

```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=build-system/template_minimal_development_configuration.json \
    --xcodeManagedCodesigning
```

# Advanced Compilation Guide

## Xcode

1. Copy and edit `build-system/appstore-configuration.json`. That file is Telegram's: it has no `sg_config` key, which the build of this fork requires (`build-system/Make/BuildConfiguration.py` stops on a configuration without it). Add one: with `is_appstore_build` set to `"true"`, as in that file, it has to be complete (see "Building the App Store configuration" above); an empty string is accepted when `is_appstore_build` is `"false"`.
2. Copy `build-system/fake-codesigning`. Create and download provisioning profiles, using the `profiles` folder as a reference for the entitlements.
3. Generate an Xcode project:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=configuration_from_step_1.json \
    --codesigningInformationPath=directory_from_step_2
```

## IPA

1. Repeat the steps from the previous section. Use distribution provisioning profiles.
2. Run:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    build \
    --configurationPath=...see previous section... \
    --codesigningInformationPath=...see previous section... \
    --buildNumber=100001 \
    --configuration=release_arm64
```

# FAQ

## Xcode is stuck at "build-request.json not updated yet"

Occasionally, you might observe the following message in your build log:
```
"~/Library/Developer/Xcode/DerivedData/Telegram-xxx/Build/Intermediates.noindex/XCBuildData/xxx.xcbuilddata/build-request.json" not updated yet, waiting...
```

Should this occur, simply cancel the ongoing build and initiate a new one.

## Telegram_xcodeproj: no such package 

Following a system restart, the auto-generated Xcode project might encounter a build failure accompanied by this error:
```
ERROR: Skipping '@rules_xcodeproj_generated//generator/Telegram/Telegram_xcodeproj:Telegram_xcodeproj': no such package '@rules_xcodeproj_generated//generator/Telegram/Telegram_xcodeproj': BUILD file not found in directory 'generator/Telegram/Telegram_xcodeproj' of external repository @rules_xcodeproj_generated. Add a BUILD file to a directory to mark it as a package.
```

If you encounter this issue, re-run the project generation steps in the README.


# Tips

## Codesigning is not required for simulator-only builds

Add `--disableProvisioningProfiles`:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=path-to-configuration.json \
    --codesigningInformationPath=path-to-provisioning-data \
    --disableProvisioningProfiles
```

## Xcode 27 refuses the default iOS 13.0 minimum

Xcode 27 SDKs refuse a deployment floor below iOS 15.0, so with the default 13.0 the build fails. Pass `--deviceMinimumOS=15.0` to `build` for the device configurations (`debug_arm64`, `release_arm64`) and `--simulatorMinimumOS=15.0` for simulator configurations; the resulting IPA then requires iOS 15.0 or later. `python3 build-system/Make/Make.py build --help` lists the related flags.

## Versions

Each release is built using a specific Xcode version (see `versions.json`). The helper script checks the versions of the installed software and reports an error if they don't match the ones specified in `versions.json`. It is possible to bypass these checks:

```
python3 build-system/Make/Make.py --overrideXcodeVersion build ... # Don't check the version of Xcode
```

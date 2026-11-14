# NOTICE

Zenlygram for iOS
Copyright (C) 2026 The Zenlygram Authors

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General
Public License as published by the Free Software Foundation;
either version 2 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the
implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
in [LICENSE](LICENSE) for more details.

The name "Zenlygram" and the Zenlygram logo identify this project and its app. The image files in this
repository, the icons included, are covered by the licence like every other file. The licence grants no right
to use the name or the logo as a mark for another app.

## Origin

Zenlygram is a modified version of Swiftgram 12.9.2 (https://github.com/Swiftgram/Telegram-iOS,
tag `12.9.2-281`, commit `cf8b23beaaac4126a396337ac2d5be13f9f76b66`),
which is itself a modified version of Telegram for iOS (https://github.com/TelegramMessenger/Telegram-iOS).
The code inherited from both remains under the copyright of its authors.

Parts of the following features were ported from Novagram (https://github.com/Novagramorg/iOS), another client
derived from Telegram for iOS: Chat Lock, Secret Vault, Tasks, the unread reminder, auto-accept of join
requests, the proxy pool, the helper-bot list, the edit history of messages, round video from the gallery, the
foreign-number filter, and the icons and NEW badge of the settings rows. That code is mainly in
`Swiftgram/SGChatLock`, `Swiftgram/SGSecretVault`, `Swiftgram/SGTasks`, `Swiftgram/SGUnreadReminder`,
`Swiftgram/SGAutoAccept`, `Swiftgram/SGAutoProxy`, `Swiftgram/SGEditedHistory`,
`Swiftgram/SGRoundVideoFromGallery`, `Swiftgram/SGForeignUserBlock`,
`Swiftgram/SGItemListUI/Sources/SGSettingsIcons.swift`, `Swiftgram/SGItemListUI/Sources/SGNewBadgeComponent.swift`,
`Swiftgram/SGSettingsUI/Sources/SGHelperBotsController.swift` and
`submodules/TelegramCore/Sources/SyncCore/SyncCore_EditedMessageHistoryAttribute.swift`, with smaller pieces in
the upstream files those features modify. Much of it keeps Novagram's names `Fenixuz` and `fenix` in
identifiers and comments; some of the ported files carry no such marker.

[UPSTREAM-CHANGES.txt](UPSTREAM-CHANGES.txt) lists every file of this repository that differs from that
Swiftgram commit (A = added, M = modified, D = deleted), as required by section 2(a) of the licence.
Zenlygram's changes were made from 2026-07-09 on (first on top of Swiftgram 12.8; on 2026-09-23 they were
carried over to Swiftgram 12.9.2). The changes in each commit of this repository end no later than the date of
that commit: the source of a build was last changed on or before its build date in the table below, and the
files that this repository adds or edits on top of the development tree are written when the commit is made.

## What this repository contains

This repository is published at https://github.com/Zenlygram-org/zenlygram-ios.
Each commit on its branch `release/appstore` is the source of one App Store build and carries the tag
`appstore/<version>-<build>`. It is an export of the project's private development tree at the commit that
build was made from. Every file that is compiled into the app and every build script is published unchanged;
the files listed further down that differ are not inputs of the build.

| App Store version | Build | Tag | Built (UTC) |
|---|---|---|---|
| 12.9.2 | 6708 | `appstore/12.9.2-6708` | 2026-11-14 |

Left out are files that are not part of the shipped app:

- the project's internal release documents and its App Store Connect tooling: everything under `appstore/`
  except a stub at `appstore/SECRETS.md`, everything under `build-system/appstore/` except
  `build-system/appstore/ipa_check.py`, and the design documents `docs/entitlement.md`,
  `docs/customer-data.md`, `docs/lenta.md` and `docs/lenta-performance.md`;
- the sources of an unreleased feature: the fifteen directories `Swiftgram/SGFeed*`, its workflow
  `.github/workflows/lenta-boundary.yml` and two of its helper scripts,
  `scripts/lenta-boundary-selftest.sh` and `scripts/lenta-sbom.py`. That feature is behind the
  `--enableLenta` build flag, which is off in every build listed here, so none of these sources is
  compiled into the app.

Files that differ from the development tree (none of them is compiled into the app):

- `NOTICE.md` and `UPSTREAM-CHANGES.txt` are written for this repository, and `appstore/SECRETS.md` is a stub
  that points to the build guide;
- `LICENSE` is the unmodified text of version 2 of the licence, the same file as
  `submodules/ffmpeg/Sources/FFMpeg/ffmpeg-7.1.1/COPYING.GPLv2`;
- `README.md` names this repository, states the licence as above, describes the App Store build
  configuration and adds a note to the inherited build guide; `.github/CONTRIBUTING.md` names this
  repository, states the licence and says how contributions are taken;
  `.github/ISSUE_TEMPLATE/bug_report.md` names this repository;
- `CLAUDE.md`, `.github/workflows/build.yml` and `docs/ui-testing.md` have the text of the Swiftgram commit
  named above instead of the development tree's version;
- `.gitignore`: three comments are shortened;
- `build-system/zenlygram-appstore.json`: the explanatory `_comment` is shortened, every value is unchanged;
- `Swiftgram/SGEntitlement/Tests/SGEntitlementServerInteropTests.swift`: one comment line is shortened;
- `Swiftgram/SGTasks/Tests/check-strings.sh`: the default paths of the helper are changed.

Comments and messages in the published files may name documents and tools of the development tree that are
not part of this repository. A build with `--enableLenta`, and dependency queries over the whole
workspace, need the unpublished packages and do not work from this repository; the store build does
not need them.

## Third-party components

Third-party components keep their own licences wherever they are in this tree: under `third-party/` and
`submodules/`, and in other places such as `Swiftgram/SwiftSoup`, `Swiftgram/Wrap`, `build-system/bazel-rules`
and `Tests/LottieMetalTest`. Their licence files and per-file notices are kept next to their sources where
their authors provide them. Some inherited items are not covered by the GPL statement above; among them are
`third-party/recaptcha/RecaptchaEnterprise.xcframework`, a prebuilt SDK published by Google, the prebuilt Skia
frameworks under `Tests/LottieMetalTest/skia`, which only a test target uses, and the font files
`submodules/TelegramUI/Resources/Fonts/AremacFS-*.otf`, which are Apple's. They are unchanged from the
Swiftgram commit named above.

load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

# Zenlygram — the entitlement: JWS verification against the pinned keys, Keychain storage, the clock
# high-water mark, grace evaluation, the degraded-mode predicate, the App Group mirror for the NSE
# and the bind / refresh / trial / Apple client.
#
# Extension-safe, like SGProtectedStore: Foundation + Security + CryptoKit + notify, and UIKit only
# for notification NAMES (never UIApplication.shared). Keep the dependency list minimal — the NSE
# reads the App Group mirror through this module.
swift_library(
    name = "SGEntitlement",
    module_name = "SGEntitlement",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Swiftgram/SGAppGroupIdentifier:SGAppGroupIdentifier",
        "//Swiftgram/SGProtectedStore:SGProtectedStore",
        "//Swiftgram/SGConfig:SGConfig",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "SGEntitlementTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":SGEntitlement",
        # `SGEntitlementPublicPolicyConfigTests` decodes `SGConfig` itself.
        "//Swiftgram/SGConfig:SGConfig",
        # `SGEntitlementOriginIsolationTests` injects a Keychain fixture (`SGKeychainReadResult`).
        "//Swiftgram/SGProtectedStore:SGProtectedStore",
    ],
)

# Zenlygram — ONLY the backend-origin isolation and the Apple hold (origin validation, origin-scoped
# sessions/device identity/outbox against an injected Keychain, the origin-scoped policy cache, the
# authenticated client's redirect refusal, the single Apple predicate on the live coordinator, the
# `apple_backend_enabled` decode):
#   Make.py test ... --target //Swiftgram/SGEntitlement:SGEntitlementOriginTests
swift_library(
    name = "SGEntitlementOriginTestsLib",
    testonly = True,
    srcs = [
        "Tests/SGEntitlementTestSupport.swift",
        "Tests/SGEntitlementPolicyStubProtocol.swift",
        "Tests/SGEntitlementBackendOriginTests.swift",
        "Tests/SGEntitlementOriginIsolationTests.swift",
        "Tests/SGEntitlementOriginPolicyCacheTests.swift",
        "Tests/SGEntitlementClientRedirectTests.swift",
        "Tests/SGEntitlementStoreKitSnapshotScopeTests.swift",
        "Tests/SGEntitlementStoreKitManageTests.swift",
        "Tests/SGEntitlementAppleHoldTests.swift",
        "Tests/SGEntitlementAppleBackendFlagConfigTests.swift",
    ],
    deps = [
        ":SGEntitlement",
        "//Swiftgram/SGConfig:SGConfig",
        "//Swiftgram/SGProtectedStore:SGProtectedStore",
    ],
)

# An ios_unit_test here needs a runner pinned to a real device/OS: the default runner picks an
# invalid device and the test process exits 15 (see CLAUDE.md).
ios_test_runner(
    name = "SGEntitlementTestRunner",
    device_type = "iPhone 17",
    os_version = "27.0",
)

# Test-only floor required by Xcode 27 libc++; the app's deployment target is unchanged.
ios_unit_test(
    name = "SGEntitlementTests",
    minimum_os_version = "15.0",
    runner = ":SGEntitlementTestRunner",
    deps = [
        ":SGEntitlementTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Zenlygram — ONLY the public-policy activation and its anonymous transport (the explicit
# `public_policy_url` / `public_policy_keys` configuration) and the app-update policy fetched from
# the same origin (`refreshAppUpdatePolicy` end to end), so that change runs on its own without
# the accepted broad suite:
#   Make.py test ... --target //Swiftgram/SGEntitlement:SGEntitlementPublicPolicyTests
swift_library(
    name = "SGEntitlementPublicPolicyTestsLib",
    testonly = True,
    srcs = [
        "Tests/SGEntitlementTestSupport.swift",
        "Tests/SGEntitlementPolicyStubProtocol.swift",
        "Tests/SGEntitlementPolicyEndpointTests.swift",
        "Tests/SGEntitlementPublicPolicyTests.swift",
        "Tests/SGEntitlementPublicPolicyConfigTests.swift",
        "Tests/SGEntitlementAppUpdateTests.swift",
    ],
    deps = [
        ":SGEntitlement",
        "//Swiftgram/SGConfig:SGConfig",
        # The owned-store fixture in `SGEntitlementTestSupport.swift` answers with `SGKeychainReadResult`.
        "//Swiftgram/SGProtectedStore:SGProtectedStore",
    ],
)

ios_unit_test(
    name = "SGEntitlementPublicPolicyTests",
    minimum_os_version = "15.0",
    runner = ":SGEntitlementTestRunner",
    deps = [
        ":SGEntitlementPublicPolicyTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

ios_unit_test(
    name = "SGEntitlementOriginTests",
    minimum_os_version = "15.0",
    runner = ":SGEntitlementTestRunner",
    deps = [
        ":SGEntitlementOriginTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Zenlygram — ONLY the Tasks realtime hint channel (wire and endpoint validation, the Pusher 7 socket
# lifecycle and heartbeat, the two named realtime calls through the Tasks exchange, the change notice
# for re-adopting the same grant under a new session), so that change runs on its own without the
# accepted broad suite:
#   Make.py test ... --target //Swiftgram/SGEntitlement:SGEntitlementRealtimeTests
swift_library(
    name = "SGEntitlementRealtimeTestsLib",
    testonly = True,
    srcs = [
        "Tests/SGEntitlementTestSupport.swift",
        "Tests/SGTasksRealtimeTests.swift",
        "Tests/SGTasksRealtimeTransportTests.swift",
    ],
    deps = [
        ":SGEntitlement",
        # The owned-store fixture answers with `SGKeychainReadResult`.
        "//Swiftgram/SGProtectedStore:SGProtectedStore",
    ],
)

ios_unit_test(
    name = "SGEntitlementRealtimeTests",
    minimum_os_version = "15.0",
    runner = ":SGEntitlementTestRunner",
    deps = [
        ":SGEntitlementRealtimeTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Zenlygram — ONLY bind-attest v1 (the `/bind/start` attest block, the `tgWebAppData` fragment
# parsing, the attest body and its `bind-attest` device proof, the shared canonical vectors) so that
# change runs on its own:
#   Make.py test ... --target //Swiftgram/SGEntitlement:SGEntitlementBindAttestTests
swift_library(
    name = "SGEntitlementBindAttestTestsLib",
    testonly = True,
    srcs = [
        "Tests/SGEntitlementTestSupport.swift",
        "Tests/SGEntitlementPolicyStubProtocol.swift",
        "Tests/SGEntitlementBindAttestTests.swift",
        "Tests/SGEntitlementDeviceProofTests.swift",
    ],
    deps = [
        ":SGEntitlement",
        "//Swiftgram/SGProtectedStore:SGProtectedStore",
    ],
)

ios_unit_test(
    name = "SGEntitlementBindAttestTests",
    minimum_os_version = "15.0",
    runner = ":SGEntitlementTestRunner",
    deps = [
        ":SGEntitlementBindAttestTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Zenlygram — ONLY the customer-data half (the transport and its facade, the consent / permission /
# pre-revoke hooks of `/bind/start` and logout, the session end, bind attempts and the headless
# attested bind), so that change runs on its own:
#   Make.py test ... --target //Swiftgram/SGEntitlement:SGEntitlementCustomerDataTests
swift_library(
    name = "SGEntitlementCustomerDataTestsLib",
    testonly = True,
    srcs = [
        "Tests/SGEntitlementTestSupport.swift",
        "Tests/SGEntitlementPathStubProtocol.swift",
        "Tests/SGCustomerDataTransportTests.swift",
        "Tests/SGEntitlementCustomerDataTests.swift",
        "Tests/SGEntitlementAttestedBindTests.swift",
    ],
    deps = [
        ":SGEntitlement",
        # The owned-store fixture answers with `SGKeychainReadResult`.
        "//Swiftgram/SGProtectedStore:SGProtectedStore",
    ],
)

ios_unit_test(
    name = "SGEntitlementCustomerDataTests",
    minimum_os_version = "15.0",
    runner = ":SGEntitlementTestRunner",
    deps = [
        ":SGEntitlementCustomerDataTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

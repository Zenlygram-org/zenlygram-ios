import Foundation

// Host tests for the sync coordinator's pure decisions (Sources/SGTasksSyncPolicy.swift, design 30
// §5.1, §5.8) and, through SGTasksCutOverTests, the cut-over table (§7.5). Fail closed: only a build
// without a Tasks backend is `.legacy`; every unknown customer state is `.forbidden`.

enum PolicyTestFailure: Error {
    case assertion(String)
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw PolicyTestFailure.assertion(message)
    }
}

@main
private struct SGTasksSyncPolicyTests {
    static func main() throws {
        let cases: [(String, () throws -> Void)] = [
            ("permission: Tasks not configured is legacy, whatever the gate says", unconfiguredIsLegacy),
            ("permission: a pipeline inactive with Tasks configured is forbidden", inactivePipelineIsForbidden),
            ("permission: tasksSync allowed, recordEvents waiting, nothing (a failed activation) forbidden", clearanceTable),
            ("drive: only allowed drives; a driven account whose permission dropped stops", driveActions),
            ("re-grant resume: only allowed with the withdrawn flag", regrantResume),
            ("claim at consent: waiting/allowed without a record or with its own released one", claimDevice),
            ("write fence: migrating beats archived; read-only cut-overs are archived", writeFence),
            ("blocked-list read (wf15 review E-12): ends on canLoadMore false, on the total count, or on a page that added no peer — a sliced list never asks for ever", blockedListReadEnds)
        ] + SGTasksCutOverTests.cases
        var failures: [String] = []
        for (name, test) in cases {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                failures.append(name)
                print("FAIL: \(name): \(error)")
            }
        }
        guard failures.isEmpty else {
            print("FAIL: \(failures.count) of \(cases.count) sync policy tests")
            exit(1)
        }
        print("PASS: \(cases.count) sync policy tests")
    }

    /// The coordinator asks after every settled page of `BlockedPeersContext` (which answers
    /// `canLoadMore: true` for every slice) whether the one-time read is over.
    private static func blockedListReadEnds() throws {
        typealias Policy = SGTasksSyncPolicy
        // A short list: one answer, `canLoadMore == false`.
        try check(Policy.blockedListReadEnded(canLoadMore: false, peerCount: 3, totalCount: 3, peerCountAtLastRequest: nil), "a complete list did not end the read")
        try check(Policy.blockedListReadEnded(canLoadMore: false, peerCount: 0, totalCount: nil, peerCountAtLastRequest: nil), "an empty list did not end the read")
        // A sliced list: the first page (the context's own request) leaves more to read.
        try check(!Policy.blockedListReadEnded(canLoadMore: true, peerCount: 200, totalCount: 450, peerCountAtLastRequest: nil), "the first slice ended the read")
        try check(!Policy.blockedListReadEnded(canLoadMore: true, peerCount: 300, totalCount: 450, peerCountAtLastRequest: 200), "a slice that added peers ended the read")
        // The total is reached: ended although the slice still says "more".
        try check(Policy.blockedListReadEnded(canLoadMore: true, peerCount: 450, totalCount: 450, peerCountAtLastRequest: 400), "the total count did not end the read")
        try check(Policy.blockedListReadEnded(canLoadMore: true, peerCount: 451, totalCount: 450, peerCountAtLastRequest: 400), "more peers than the total did not end the read")
        // Peers the device could not read keep the count below the total: a page that adds nothing ends it.
        try check(Policy.blockedListReadEnded(canLoadMore: true, peerCount: 440, totalCount: 450, peerCountAtLastRequest: 440), "a page that added no peer did not end the read")
        try check(Policy.blockedListReadEnded(canLoadMore: true, peerCount: 0, totalCount: nil, peerCountAtLastRequest: 0), "an empty page without a total did not end the read")
        // Simulated: 450 blocked users, slices of 200 then 100, the server never says "no more".
        var peers = 0, asked: Int? = nil, requests = 1
        peers = 200
        while !Policy.blockedListReadEnded(canLoadMore: true, peerCount: peers, totalCount: 450, peerCountAtLastRequest: asked) {
            asked = peers
            peers = min(450, peers + 100)
            requests += 1
            try check(requests < 20, "the read did not end")
        }
        try check(peers == 450 && requests == 4, "the sliced read took \(requests) requests for \(peers) peers")
    }

    private static func inputs(configured: Bool, active: Bool, tasksSync: Bool, recordEvents: Bool) -> SGTasksSyncPolicy.GateInputs {
        return SGTasksSyncPolicy.GateInputs(isTasksConfigured: configured, isPipelineActive: active, tasksSync: tasksSync, recordEvents: recordEvents)
    }

    private static let bools = [false, true]

    private static func unconfiguredIsLegacy() throws {
        for active in Self.bools {
            for tasksSync in Self.bools {
                for recordEvents in Self.bools {
                    let permission = SGTasksSyncPolicy.permission(inputs(configured: false, active: active, tasksSync: tasksSync, recordEvents: recordEvents))
                    try check(permission == .legacy, "unconfigured (active \(active), tasksSync \(tasksSync), recordEvents \(recordEvents)) is \(permission)")
                }
            }
        }
    }

    private static func inactivePipelineIsForbidden() throws {
        for tasksSync in Self.bools {
            for recordEvents in Self.bools {
                let permission = SGTasksSyncPolicy.permission(inputs(configured: true, active: false, tasksSync: tasksSync, recordEvents: recordEvents))
                try check(permission == .forbidden, "inactive pipeline (tasksSync \(tasksSync), recordEvents \(recordEvents)) is \(permission)")
            }
        }
    }

    private static func clearanceTable() throws {
        try check(SGTasksSyncPolicy.permission(inputs(configured: true, active: true, tasksSync: true, recordEvents: true)) == .allowed, "tasksSync is not allowed")
        try check(SGTasksSyncPolicy.permission(inputs(configured: true, active: true, tasksSync: true, recordEvents: false)) == .allowed, "tasksSync alone is not allowed")
        try check(SGTasksSyncPolicy.permission(inputs(configured: true, active: true, tasksSync: false, recordEvents: true)) == .waiting, "recordEvents is not waiting")
        // `.failed` publishes isPipelineActive == true with `[]` for every account.
        try check(SGTasksSyncPolicy.permission(inputs(configured: true, active: true, tasksSync: false, recordEvents: false)) == .forbidden, "an empty clearance is not forbidden")
    }

    private static func driveActions() throws {
        try check(SGTasksSyncPolicy.driveAction(.allowed, isDriven: false) == .drive, "allowed does not start driving")
        try check(SGTasksSyncPolicy.driveAction(.allowed, isDriven: true) == .drive, "a driven allowed account gets no drive")
        for permission in [SGTasksSyncPermission.waiting, .forbidden, .legacy] {
            try check(SGTasksSyncPolicy.driveAction(permission, isDriven: true) == .stop, "\(permission) keeps driving")
            try check(SGTasksSyncPolicy.driveAction(permission, isDriven: false) == .none, "\(permission) does something to an undriven account")
        }
    }

    private static func regrantResume() throws {
        try check(SGTasksSyncPolicy.needsRegrantResume(.allowed, consentWithdrawnFlag: true), "the re-grant does not resume")
        try check(!SGTasksSyncPolicy.needsRegrantResume(.allowed, consentWithdrawnFlag: false), "a resume without a withdrawal")
        for permission in [SGTasksSyncPermission.waiting, .forbidden, .legacy] {
            try check(!SGTasksSyncPolicy.needsRegrantResume(permission, consentWithdrawnFlag: true), "\(permission) resumes a withdrawn account")
        }
    }

    private static func record(_ state: TodoCloudMigrationRecord.State) -> TodoCloudMigrationRecord {
        return TodoCloudMigrationRecord(accountPeerId: 7, state: state, normalizationLocale: .uz, claimedAt: 1_700_000_000)
    }

    private static func claimDevice() throws {
        for permission in [SGTasksSyncPermission.waiting, .allowed] {
            try check(SGTasksSyncPolicy.shouldClaimDevice(permission, record: nil), "\(permission) without a record does not claim")
            try check(SGTasksSyncPolicy.shouldClaimDevice(permission, record: record(.released)), "\(permission) does not re-claim its released record")
            for state in [TodoCloudMigrationRecord.State.claimed, .enqueued, .completed, .skipped] {
                try check(!SGTasksSyncPolicy.shouldClaimDevice(permission, record: record(state)), "\(permission) claims again over \(state)")
            }
        }
        for permission in [SGTasksSyncPermission.forbidden, .legacy] {
            try check(!SGTasksSyncPolicy.shouldClaimDevice(permission, record: nil), "\(permission) claims without consent")
            try check(!SGTasksSyncPolicy.shouldClaimDevice(permission, record: record(.released)), "\(permission) re-claims without consent")
        }
    }

    private static func writeFence() throws {
        let cutOvers: [TasksCutOver] = [.none, .archive(.migrating), .archive(.newRows(2)), .archive(.otherAccount), .retired]
        for cutOver in cutOvers {
            try check(SGTasksSyncPolicy.writeFence(migrationStepRunning: true, cutOver: cutOver) == .migrating, "a running step does not fence \(cutOver)")
            let expected: TodoWriteFence = cutOver == .none ? .open : .archived
            try check(SGTasksSyncPolicy.writeFence(migrationStepRunning: false, cutOver: cutOver) == expected, "\(cutOver) is not \(expected)")
        }
    }
}

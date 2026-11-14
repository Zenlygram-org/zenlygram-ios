import XCTest
import SGConfig
@testable import SGEntitlement

/// Zenlygram — `SGTasksShippedWire.requestWire` (wf15 §8.2): `sg_config.tasks_wire` clamped to the wires this
/// client speaks. Absent or 4 → 4 (today's production wire, byte-identical traffic); 5 → 5; anything the lenient
/// `SGConfig` decoder kept outside 4 ... 5 is clamped (BuildConfiguration.py refuses it before a build anyway).
final class SGTasksShippedWireTests: XCTestCase {
    /// The same decoder `parseSGConfig` uses.
    private func decode(_ json: String) -> SGConfig? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(SGConfig.self, from: Data(json.utf8))
    }

    private func requestWire(_ json: String) throws -> Int {
        return SGTasksShippedWire.requestWire(for: try XCTUnwrap(self.decode(json)))
    }

    func test_anAbsentKeyIsWireFour() throws {
        XCTAssertEqual(try self.requestWire("{}"), 4)
        XCTAssertEqual(try self.requestWire("{\"api_url\":\"https://api.zenlygram.org\"}"), SGTasksWire.wireRevision)
    }

    func test_fourAndFiveAreSentAsWritten() throws {
        XCTAssertEqual(try self.requestWire("{\"tasks_wire\":4}"), 4)
        XCTAssertEqual(try self.requestWire("{\"tasks_wire\":5}"), 5)
        XCTAssertEqual(try self.requestWire("{\"tasks_wire\":5}"), SGTasksWire.maximumWire)
    }

    func test_valuesOutsideTheClientsWiresAreClamped() throws {
        XCTAssertEqual(try self.requestWire("{\"tasks_wire\":6}"), 5)
        XCTAssertEqual(try self.requestWire("{\"tasks_wire\":3}"), 4)
        XCTAssertEqual(try self.requestWire("{\"tasks_wire\":0}"), 4)
        XCTAssertEqual(try self.requestWire("{\"tasks_wire\":-5}"), 4)
    }

    func test_aMistypedValueIsWireFour() throws {
        for value in ["\"5\"", "true", "null", "4.5", "[5]", "{\"wire\":5}"] {
            XCTAssertEqual(try self.requestWire("{\"tasks_wire\":\(value)}"), 4, value)
        }
    }

    func test_theShippedValueIsTheBuildsConfigClamped() {
        XCTAssertEqual(SGTasksShippedWire.requestWire, SGTasksShippedWire.requestWire(for: SG_CONFIG))
        XCTAssertGreaterThanOrEqual(SGTasksShippedWire.requestWire, SGTasksWire.wireRevision)
        XCTAssertLessThanOrEqual(SGTasksShippedWire.requestWire, SGTasksWire.maximumWire)
    }

    func test_theBoundsAreTheCoresOwn() {
        XCTAssertEqual(SGTasksWire.wireRevision, 4)
        XCTAssertEqual(SGTasksWire.maximumWire, 5)
    }
}

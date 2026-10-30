import XCTest
@testable import OralBKit

final class AdvertisementTests: XCTestCase {
    func testCoreBluetoothPayloadWithCompanyID() throws {
        // DC 00 + protocol 3, D700 6-mode, fw 4, running, normal, 1:05, deep clean, sector 2, timer, count
        let ad = try XCTUnwrap(Advertisement(manufacturerData: Data([0xDC, 0x00, 3, 41, 4, 3, 0x32, 1, 5, 5, 2, 10, 4])))
        XCTAssertEqual(ad.modelName, "D700 Smart/Pro Series (6 mode)")
        XCTAssertEqual(ad.stateName, "Running")
        XCTAssertTrue(ad.isRunning)
        XCTAssertEqual(ad.timeText, "1:05")
        XCTAssertEqual(ad.modeName, "Deep Clean")
        XCTAssertEqual(ad.sectorText, "Sector 2")
        XCTAssertEqual(ad.pressure, .normal)
    }

    func testStrippedNineBytePayload() throws {
        let ad = try XCTUnwrap(Advertisement(manufacturerData: Data([1, 0, 1, 2, 0, 0, 0, 1, 0])))
        XCTAssertNil(ad.sectorCount)
        XCTAssertEqual(ad.stateName, "Idle")
    }

    func testRejectsOtherLengths() {
        XCTAssertNil(Advertisement(manufacturerData: Data(count: 10)))
    }

    func testPressureFlags() {
        XCTAssertEqual(PressureStatus(flags: 0x88), .powerButton)
        XCTAssertEqual(PressureStatus(flags: 0x84), .button)
        XCTAssertEqual(PressureStatus(flags: 0xF2), .high)
        XCTAssertEqual(PressureStatus(flags: 0x72), .normal)
    }
}

final class CharacteristicTests: XCTestCase {
    func testUUID() {
        XCTAssertEqual(OralB.Char.availableModes, "A0F0FF25-5047-4D53-8208-4F72616C2D42")
    }

    func testBattery() throws {
        let b = try XCTUnwrap(Battery(Data([87, 0x10, 0x0E, 0])))
        XCTAssertEqual(b.percent, 87)
        XCTAssertEqual(b.secondsLeft, 3600)
    }

    func testModelInfo() throws {
        let m = try XCTUnwrap(ModelInfo(Data([41, 3, 4])))
        XCTAssertEqual(m.name, "D700 Smart/Pro Series (6 mode)")
        XCTAssertEqual(m.firmware, 4)
    }

    func testSessionRecord() throws {
        let bytes: [UInt8] = [0x80, 0x51, 0x01, 0x00, 120, 0, 3, 1, 55, 0, 2, 80, 0, 0, 0, 0]
        let s = try XCTUnwrap(SessionRecord(Data(bytes), protocolVersion: 4))
        XCTAssertEqual(s.durationSeconds, 120)
        XCTAssertEqual(s.mode, 1)
        XCTAssertEqual(s.pressureSeconds, 5.5)
        XCTAssertNil(SessionRecord(Data(repeating: 0xFF, count: 16), protocolVersion: 4))
    }
}

final class AvailableModesTests: XCTestCase {
    let current = Data([1, 2, 3, 4, 5, 7, 0xFF, 0xFF])

    func testPadsWithHandlesOwnFiller() throws {
        XCTAssertEqual(try AvailableModes.encode([1, 5], current: current), Data([1, 5, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
    }

    func testRefusesToGuessFiller() {
        XCTAssertThrowsError(try AvailableModes.encode([1], current: Data([1, 2, 3, 4, 5, 6, 7, 1])))
    }

    func testRejectsBadInput() {
        for bad: [UInt8] in [[], [0], [9], [255], [1, 1]] {
            XCTAssertThrowsError(try AvailableModes.encode(bad, current: current))
        }
    }

    func testEnabled() {
        XCTAssertEqual(AvailableModes.enabled(current), [1, 2, 3, 4, 5, 7])
    }
}

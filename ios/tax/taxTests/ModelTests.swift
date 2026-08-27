import XCTest
@testable import tax

final class ModelTests: XCTestCase {
    func testDecodesEveryPushMode() throws {
        for mode in PushMode.allCases {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(PushMode.self, from: data), mode)
        }
    }

    func testDeviceRegistrationUsesServerKeys() throws {
        let payload = DeviceTokenPayload(deviceToken: "token", preferences: DevicePreferences(pushMode: .taxOnly))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        XCTAssertEqual(object["device_token"] as? String, "token")
        XCTAssertEqual((object["preferences"] as? [String: Any])?["push_mode"] as? String, "tax")
    }
}

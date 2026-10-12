import XCTest
@testable import OneCursorCore

final class ConfigTests: XCTestCase {
    let sample = """
    # A typical Barrier configuration
    section: screens
    \tmacbook:
    \tpixel:
    \twinbox:
    \t\tsuper = ctrl
    \t\tctrl = super
    end
    section: aliases
    \tmacbook:
    \t\tMacBook-Pro.local
    end
    section: links
    \tmacbook:
    \t\tright = pixel
    \t\tleft(0,50) = winbox(50,100)
    \tpixel:
    \t\tleft = macbook
    \twinbox:
    \t\tright(50,100) = macbook(0,50)
    end
    section: options
    \tswitchDelay = 250
    \tkeystroke(alt+left) = switchInDirection(left)
    end
    """

    func testParseBarrierConfig() throws {
        let c = try ScreenConfig.parseBarrier(sample)
        XCTAssertEqual(c.screens.map(\.name), ["macbook", "pixel", "winbox"])
        XCTAssertEqual(c.canonicalName("macbook-pro.local"), "macbook")
        XCTAssertEqual(c.options.switchDelay, 250)
        XCTAssertEqual(c.screen(named: "winbox")?.modifierMap[.superKey], .control)

        let right = c.neighbor(of: "macbook", direction: .right, at: 0.3)
        XCTAssertEqual(right?.name, "pixel")
        XCTAssertEqual(right?.t ?? -1, 0.3, accuracy: 1e-9)

        let left = c.neighbor(of: "macbook", direction: .left, at: 0.25)
        XCTAssertEqual(left?.name, "winbox")
        XCTAssertEqual(left?.t ?? -1, 0.75, accuracy: 1e-9)
        XCTAssertNil(c.neighbor(of: "macbook", direction: .left, at: 0.75))
        XCTAssertNil(c.neighbor(of: "macbook", direction: .top, at: 0.5))
    }

    func testClientOptionsCarryModifierMap() throws {
        let c = try ScreenConfig.parseBarrier(sample)
        let opts = c.clientOptions(for: "winbox")
        XCTAssertEqual(opts, [OptionID.code("MMFC"), ModifierID.superKey.rawValue, OptionID.code("MMFR"), ModifierID.control.rawValue])
        XCTAssertEqual(c.clientOptions(for: "pixel"), [])
    }

    func testBarrierTextRoundTrip() throws {
        let c = try ScreenConfig.parseBarrier(sample)
        let again = try ScreenConfig.parseBarrier(c.barrierText())
        XCTAssertEqual(again, c)
    }

    func testJSONRoundTrip() throws {
        let c = try ScreenConfig.parseBarrier(sample)
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(ScreenConfig.self, from: data), c)
    }

    func testSyntaxError() {
        XCTAssertThrowsError(try ScreenConfig.parseBarrier("section: links\n\tright = x\nend"))
    }
}

import XCTest
@testable import LEDTicker

final class PayloadsTests: XCTestCase {

    // MARK: - wifi

    func test_wifi_formatsSsidPipePassword() throws {
        let data = try Payloads.wifi(ssid: "MyNet", password: "pw|with|pipes")
        XCTAssertEqual(String(data: data, encoding: .utf8), "MyNet|pw|with|pipes")
    }

    func test_wifi_trimsSsidWhitespace() throws {
        let data = try Payloads.wifi(ssid: "  Home  ", password: "pw")
        XCTAssertEqual(String(data: data, encoding: .utf8), "Home|pw")
    }

    func test_wifi_rejectsEmptySsid() {
        XCTAssertThrowsError(try Payloads.wifi(ssid: "   ", password: "pw")) { err in
            XCTAssertEqual(err as? PayloadError, .invalidSSID)
        }
    }

    func test_wifi_rejectsPipeInSsid() {
        XCTAssertThrowsError(try Payloads.wifi(ssid: "bad|ssid", password: "pw")) { err in
            XCTAssertEqual(err as? PayloadError, .invalidSSID)
        }
    }

    func test_wifi_rejectsOversizedSsid() {
        let big = String(repeating: "x", count: 64)
        XCTAssertThrowsError(try Payloads.wifi(ssid: big, password: "pw")) { err in
            XCTAssertEqual(err as? PayloadError, .invalidSSID)
        }
    }

    // MARK: - apiKey

    func test_apiKey_trimsAndEncodes() throws {
        let data = try Payloads.apiKey("  abc123  ")
        XCTAssertEqual(String(data: data, encoding: .utf8), "abc123")
    }

    func test_apiKey_rejectsEmpty() {
        XCTAssertThrowsError(try Payloads.apiKey("")) { err in
            XCTAssertEqual(err as? PayloadError, .empty(field: "API key"))
        }
    }

    func test_apiKey_rejectsOversized() {
        let big = String(repeating: "k", count: 64)
        XCTAssertThrowsError(try Payloads.apiKey(big))
    }

    // MARK: - tickers

    func test_tickers_uppercasesTrimsAndJoins() throws {
        let data = try Payloads.tickers(fromCSV: " aapl, msft ,googl ")
        XCTAssertEqual(String(data: data, encoding: .utf8), "AAPL,MSFT,GOOGL")
    }

    func test_tickers_dedupesPreservingOrder() throws {
        let data = try Payloads.tickers(fromCSV: "AAPL,aapl,MSFT,MSFT,NVDA")
        XCTAssertEqual(String(data: data, encoding: .utf8), "AAPL,MSFT,NVDA")
    }

    func test_tickers_capsAtTen() throws {
        let many = (1...15).map { "SYM\($0)" }.joined(separator: ",")
        let data = try Payloads.tickers(fromCSV: many)
        let str = String(data: data, encoding: .utf8)!
        XCTAssertEqual(str.split(separator: ",").count, 10)
        XCTAssertTrue(str.hasPrefix("SYM1,SYM2"))
    }

    func test_tickers_rejectsAllEmpty() {
        XCTAssertThrowsError(try Payloads.tickers(fromCSV: " , , "))
    }

    func test_tickers_dropsOversizedSymbol() throws {
        // tickerMaxLen == 15, so 16-char symbol is dropped silently.
        let data = try Payloads.tickers(fromCSV: "AAPL,THISISWAYTOOLONGXX,MSFT")
        XCTAssertEqual(String(data: data, encoding: .utf8), "AAPL,MSFT")
    }

    // MARK: - messages

    func test_messages_joinsWithPipe() throws {
        let data = try Payloads.messages(fromJoined: "a|b|c")
        XCTAssertEqual(String(data: data, encoding: .utf8), "a|b|c")
    }

    func test_messages_trimsAndDropsEmpty() throws {
        let data = try Payloads.messages(fromJoined: "  hi  ||  there  |")
        XCTAssertEqual(String(data: data, encoding: .utf8), "hi|there")
    }

    func test_messages_rejectsAllEmpty() {
        XCTAssertThrowsError(try Payloads.messages(fromJoined: " | | "))
    }

    func test_messages_rejectsOverMaxBytes() {
        let big = String(repeating: "x", count: Payloads.messagesMaxBytes + 1)
        XCTAssertThrowsError(try Payloads.messages([big])) { err in
            guard case .tooLong(_, let limit, let actual)? = err as? PayloadError else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertEqual(limit, Payloads.messagesMaxBytes)
            XCTAssertEqual(actual, Payloads.messagesMaxBytes + 1)
        }
    }

    func test_messages_capsAt20() throws {
        let many = (1...25).map { "m\($0)" }
        let data = try Payloads.messages(many)
        let str = String(data: data, encoding: .utf8)!
        XCTAssertEqual(str.split(separator: "|").count, 20)
    }

    // MARK: - locations

    func test_locations_joinsWithPipe() throws {
        let data = try Payloads.locations(["Redmond, WA", "Seattle, WA"])
        XCTAssertEqual(String(data: data, encoding: .utf8), "Redmond, WA|Seattle, WA")
    }

    func test_locations_trimsAndDropsEmpty() throws {
        let data = try Payloads.locations(fromJoined: "  Redmond, WA  ||  98052  |")
        XCTAssertEqual(String(data: data, encoding: .utf8), "Redmond, WA|98052")
    }

    func test_locations_rejectsPipeInEntry() {
        XCTAssertThrowsError(try Payloads.locations(["Redmond|WA"])) { err in
            guard case .invalidLocation? = err as? PayloadError else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }

    func test_locations_rejectsOversizedEntry() {
        let big = String(repeating: "x", count: Payloads.locationMaxLen + 1)
        XCTAssertThrowsError(try Payloads.locations([big])) { err in
            guard case .invalidLocation? = err as? PayloadError else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }

    func test_locations_rejectsAllEmpty() {
        XCTAssertThrowsError(try Payloads.locations(fromJoined: " | | "))
    }

    func test_locations_capsAt5() throws {
        let many = (1...10).map { "Loc\($0)" }
        let data = try Payloads.locations(many)
        let str = String(data: data, encoding: .utf8)!
        XCTAssertEqual(str.split(separator: "|").count, 5)
        XCTAssertTrue(str.hasPrefix("Loc1|Loc2"))
    }

    func test_parseLocations_splitsOnPipe() {
        let data = Data("Redmond, WA|98052|Paris, FR".utf8)
        XCTAssertEqual(Payloads.parseLocations(data), ["Redmond, WA", "98052", "Paris, FR"])
    }

    func test_parseLocations_emptyReturnsEmpty() {
        XCTAssertEqual(Payloads.parseLocations(Data()), [])
    }

    func test_parseLocations_roundTrip() throws {
        let original = ["Redmond, WA", "98052", "Paris, FR"]
        let encoded = try Payloads.locations(original)
        XCTAssertEqual(Payloads.parseLocations(encoded), original)
    }

    // MARK: - parsers (values read back from device)

    func test_parseString_stripsTrailingNuls() {
        var data = Data("hello".utf8)
        data.append(contentsOf: [0, 0, 0])
        XCTAssertEqual(Payloads.parseString(data), "hello")
    }

    func test_parseString_emptyData() {
        XCTAssertEqual(Payloads.parseString(Data()), "")
    }

    func test_parseTickers_splitsAndUppercases() {
        let data = Data("aapl,Msft,GOOGL".utf8)
        XCTAssertEqual(Payloads.parseTickers(data), ["AAPL", "MSFT", "GOOGL"])
    }

    func test_parseTickers_emptyReturnsEmpty() {
        XCTAssertEqual(Payloads.parseTickers(Data()), [])
        XCTAssertEqual(Payloads.parseTickers(Data("".utf8)), [])
    }

    func test_parseTickers_roundTrip() throws {
        let original = ["AAPL", "MSFT", "NVDA"]
        let encoded = try Payloads.tickers(original)
        XCTAssertEqual(Payloads.parseTickers(encoded), original)
    }

    func test_parseMessages_splitsOnPipe() {
        let data = Data("hi|there|friend".utf8)
        XCTAssertEqual(Payloads.parseMessages(data), ["hi", "there", "friend"])
    }

    func test_parseMessages_emptyReturnsEmpty() {
        XCTAssertEqual(Payloads.parseMessages(Data()), [])
    }

    func test_parseMessages_roundTrip() throws {
        let original = ["Take a break!", "Drink water!", "Stand up!"]
        let encoded = try Payloads.messages(original)
        XCTAssertEqual(Payloads.parseMessages(encoded), original)
    }

    // MARK: - command (unchanged)

    func test_command_passthrough() {
        XCTAssertEqual(String(data: Payloads.command("reload"), encoding: .utf8), "reload")
        XCTAssertEqual(String(data: Payloads.command("reset"), encoding: .utf8), "reset")
    }

    // MARK: - mode (Categories) encoder

    func test_mode_all() throws {
        let data = try Payloads.mode(.all)
        XCTAssertEqual(String(data: data, encoding: .utf8), "all")
    }

    func test_mode_singleStocks() throws {
        XCTAssertEqual(String(data: try Payloads.mode([.stocks]), encoding: .utf8), "stocks")
    }

    func test_mode_singleMessages() throws {
        XCTAssertEqual(String(data: try Payloads.mode([.messages]), encoding: .utf8), "messages")
    }

    func test_mode_singleWeather() throws {
        XCTAssertEqual(String(data: try Payloads.mode([.weather]), encoding: .utf8), "weather")
    }

    func test_mode_singleClock() throws {
        XCTAssertEqual(String(data: try Payloads.mode([.clock]), encoding: .utf8), "clock")
    }

    func test_mode_subsetCanonicalOrder() throws {
        let data = try Payloads.mode([.stocks, .weather])
        XCTAssertEqual(String(data: data, encoding: .utf8), "stocks,weather")
    }

    func test_mode_subsetOrderingIndependentOfInsertion() throws {
        var c: Categories = []
        c.insert(.weather)
        c.insert(.stocks)
        let data = try Payloads.mode(c)
        XCTAssertEqual(String(data: data, encoding: .utf8), "stocks,weather")
    }

    func test_mode_emptyThrows() {
        XCTAssertThrowsError(try Payloads.mode([])) { err in
            XCTAssertEqual(err as? PayloadError, .empty(field: "Mode"))
        }
    }

    // MARK: - parseMode

    func test_parseMode_all() {
        XCTAssertEqual(Payloads.parseMode(Data("all".utf8)), .content(.all))
    }

    func test_parseMode_setup() {
        XCTAssertEqual(Payloads.parseMode(Data("setup".utf8)), .setup)
    }

    func test_parseMode_singleStocks() {
        XCTAssertEqual(Payloads.parseMode(Data("stocks".utf8)), .content([.stocks]))
    }

    func test_parseMode_singleMessages() {
        XCTAssertEqual(Payloads.parseMode(Data("messages".utf8)), .content([.messages]))
    }

    func test_parseMode_singleWeather() {
        XCTAssertEqual(Payloads.parseMode(Data("weather".utf8)), .content([.weather]))
    }

    func test_parseMode_singleClock() {
        XCTAssertEqual(Payloads.parseMode(Data("clock".utf8)), .content([.clock]))
    }

    func test_parseMode_commaJoined() {
        XCTAssertEqual(Payloads.parseMode(Data("stocks,weather".utf8)),
                       .content([.stocks, .weather]))
    }

    func test_parseMode_whitespaceTolerance() {
        XCTAssertEqual(Payloads.parseMode(Data(" stocks , weather ".utf8)),
                       .content([.stocks, .weather]))
    }

    /// Firmware's `strtok` skips empty subsequences, so a stray trailing,
    /// leading, or doubled comma is tolerated. We match that.
    func test_parseMode_emptyCommasTolerated() {
        XCTAssertEqual(Payloads.parseMode(Data("stocks,".utf8)),
                       .content([.stocks]))
        XCTAssertEqual(Payloads.parseMode(Data(",stocks,weather,".utf8)),
                       .content([.stocks, .weather]))
        XCTAssertEqual(Payloads.parseMode(Data("stocks,,weather".utf8)),
                       .content([.stocks, .weather]))
    }

    func test_parseMode_unknownTokenInListReturnsUnknown() {
        XCTAssertEqual(Payloads.parseMode(Data("stocks,bogus".utf8)), .unknown)
    }

    func test_parseMode_unknownSingleTokenReturnsUnknown() {
        XCTAssertEqual(Payloads.parseMode(Data("wat".utf8)), .unknown)
    }

    func test_parseMode_empty() {
        XCTAssertEqual(Payloads.parseMode(Data()), .unknown)
    }

    func test_parseMode_nulOnly() {
        XCTAssertEqual(Payloads.parseMode(Data([0, 0, 0])), .unknown)
    }

    func test_parseMode_roundTripAllNonEmptyCategories() throws {
        let cases: [Categories] = [
            [.stocks], [.messages], [.weather], [.clock],
            [.stocks, .messages], [.stocks, .weather], [.stocks, .clock],
            [.messages, .weather], [.messages, .clock], [.weather, .clock],
            [.stocks, .messages, .weather], [.stocks, .messages, .clock],
            [.stocks, .weather, .clock], [.messages, .weather, .clock],
            .all,
        ]
        for c in cases {
            let encoded = try Payloads.mode(c)
            XCTAssertEqual(Payloads.parseMode(encoded), .content(c),
                           "round-trip failed for raw=\(c.rawValue)")
        }
    }
}

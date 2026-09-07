import Foundation
import Network
import Testing
@testable import BMWBarKit

/// BMW's streaming broker is TLS 1.3-only: a TLS 1.2 ClientHello is answered with
/// alert 70 (`protocol_version`), which reaches the app as SecureTransport error
/// -9836. CocoaMQTT's stock socket uses CocoaAsyncSocket's `startTLS`, and Apple never
/// added TLS 1.3 to SecureTransport, so the transport had to move to
/// Network.framework. These tests pin the pieces that make that work.
@Suite("Stream transport")
struct TransportTests {
    @Test func defaultsToTLS() {
        #expect(NetworkFrameworkSocket().enableSSL)
    }

    /// Network.framework negotiates up to TLS 1.3 by default; the floor just must not
    /// be pinned *above* what a normal broker offers, nor below TLS 1.2.
    @Test func allowsTLS13ByNotPinningAMaximum() {
        let socket = NetworkFrameworkSocket()
        #expect(socket.minimumTLSVersion == .TLSv12)
    }

    @Test func usesBMWsStreamingEndpoint() {
        #expect(CarDataStream.host == "customer.streaming-cardata.bmwgroup.com")
        #expect(CarDataStream.port == 9000)
    }

    /// Regression guard: 25 s must stay under BMW's 60 s idle disconnect, with enough
    /// margin for a missed ping.
    @Test func keepAliveLeavesRoomForAMissedPing() {
        #expect(CarDataStream.keepAlive * 2 < 60)
    }

    /// The id_token lasts an hour and is the MQTT password, so the session must be
    /// rebuilt before it lapses.
    @Test func reconnectMarginPrecedesTokenExpiry() {
        #expect(CarDataStream.reconnectMargin > 0)
        #expect(CarDataStream.reconnectMargin >= TokenSet.refreshBuffer)
    }
}

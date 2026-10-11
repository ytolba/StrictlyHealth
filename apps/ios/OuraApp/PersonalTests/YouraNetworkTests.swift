import XCTest
@testable import OuraApp

private final class YouraMockProtocol: URLProtocol {
    static let lock = NSLock()
    static var count = 0
    static var delay = false
    static var started: XCTestExpectation?
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let delay = Self.delay; let started = Self.started; Self.lock.unlock()
        started?.fulfill()
        if delay {
            let work = DispatchWorkItem { [weak self] in guard let self else { return }; self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
            self.work = work; DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: work)
        } else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    }
    override func stopLoading() { work?.cancel(); work = nil }
}
final class YouraNetworkTests: XCTestCase {
    private func client(delayed: Bool = false, started: XCTestExpectation? = nil) -> HermesClient {
        YouraMockProtocol.lock.lock(); YouraMockProtocol.count = 0; YouraMockProtocol.delay = delayed; YouraMockProtocol.started = started; YouraMockProtocol.lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [YouraMockProtocol.self]
        return HermesClient(session: URLSession(configuration: configuration))
    }
    private var requests: Int { YouraMockProtocol.lock.lock(); defer { YouraMockProtocol.lock.unlock() }; return YouraMockProtocol.count }
    func testNoNetworkBeforeSendAndOfflineErrorPreservesCallerData() async throws {
        let client = client()
        let config = HermesConfiguration(baseURL: "https://synthetic.invalid/v1")
        _ = try HermesClient.request(configuration: config, token: "synthetic-token", preview: "Synthetic approved message")
        XCTAssertEqual(requests, 0)
        do { _ = try await client.send(configuration: config, token: "synthetic-token", preview: "Synthetic approved message"); XCTFail("Offline request should fail") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertEqual(requests, 1)
    }
    func testInFlightCancellationStopsClientRequest() async throws {
        let started = expectation(description: "Mock request started")
        let client = client(delayed: true, started: started)
        let task = Task { try await client.send(configuration: .init(baseURL: "https://synthetic.invalid/v1"), token: "synthetic-token", preview: "Synthetic message") }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request succeeded") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
}

import XCTest
@testable import SpeechDock

/// Phase 2 tests for the VoxCPM local TTS provider. No live engine required — the client is exercised
/// against a mock URLProtocol, everything else is pure logic.
@MainActor
final class VoxCPMProviderTests: XCTestCase {

    // MARK: - Provider enum & factory

    func testFactoryBuildsVoxCPMProvider() {
        let service = TTSFactory.makeService(for: .voxCPM)
        XCTAssertTrue(service is VoxCPMTTS)
    }

    func testVoxCPMProviderMetadata() {
        XCTAssertEqual(TTSProvider.voxCPM.rawValue, "ScreenVoice")
        XCTAssertFalse(TTSProvider.voxCPM.requiresAPIKey)
        XCTAssertTrue(TTSProvider.voxCPM.isLocal)
        XCTAssertNil(TTSProvider.voxCPM.envKeyName)
        XCTAssertFalse(TTSProvider.voxCPM.description.isEmpty)
    }

    func testVoxCPMIsInAllCasesOnce() {
        XCTAssertEqual(TTSProvider.allCases.filter { $0 == .voxCPM }.count, 1)
    }

    func testProviderExposesDefaultVoiceAndModel() {
        let tts = VoxCPMTTS()
        XCTAssertEqual(tts.availableModels().first?.id, "openbmb/VoxCPM2")
        XCTAssertTrue(tts.availableVoices().contains { $0.id == "default" })
        XCTAssertEqual(tts.audioFileExtension, "wav")
        XCTAssertFalse(tts.useStreamingMode) // streaming is Phase 4
        XCTAssertTrue(tts.supportsSpeedControl)
    }

    // MARK: - Settings persistence

    func testSettingsPersistAcrossInstances() {
        let suite = "VoxCPMSettingsTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let s1 = VoxCPMSettings(defaults: defaults)
        XCTAssertEqual(s1.host, "127.0.0.1")
        XCTAssertEqual(s1.port, 8757)
        XCTAssertEqual(s1.quality, .balanced)

        s1.port = 9999
        s1.quality = .quality
        s1.defaultFrenchVoice = "quebec-fr"
        s1.languageMode = .frCA

        let s2 = VoxCPMSettings(defaults: defaults)
        XCTAssertEqual(s2.port, 9999)
        XCTAssertEqual(s2.quality, .quality)
        XCTAssertEqual(s2.defaultFrenchVoice, "quebec-fr")
        XCTAssertEqual(s2.languageMode, .frCA)
        XCTAssertEqual(s2.baseURL.absoluteString, "http://127.0.0.1:9999")
    }

    // MARK: - Engine state mapping

    func testEngineStateFromStatusStrings() {
        XCTAssertEqual(VoxCPMEngineState.from(status: "ready", detail: nil), .ready)
        XCTAssertEqual(VoxCPMEngineState.from(status: "loading_model", detail: nil), .loadingModel)
        XCTAssertEqual(VoxCPMEngineState.from(status: "generating", detail: nil), .generating)
        XCTAssertEqual(VoxCPMEngineState.from(status: "starting", detail: nil), .starting)
        XCTAssertEqual(VoxCPMEngineState.from(status: "crashed", detail: "boom"), .crashed("boom"))
        XCTAssertEqual(VoxCPMEngineState.from(status: "weird", detail: nil), .unknown)
        XCTAssertTrue(VoxCPMEngineState.ready.isReady)
        XCTAssertTrue(VoxCPMEngineState.generating.isReady)
        XCTAssertFalse(VoxCPMEngineState.loadingModel.isReady)
    }

    // MARK: - Fallback classification

    func testFallbackClassification() {
        XCTAssertTrue(VoxCPMTTS.shouldFallBackToNative(for: VoxCPMError.backendUnavailable("x")))
        XCTAssertTrue(VoxCPMTTS.shouldFallBackToNative(for: VoxCPMError.notReady("x")))
        XCTAssertFalse(VoxCPMTTS.shouldFallBackToNative(for: VoxCPMError.http(500, "x")))
        XCTAssertFalse(VoxCPMTTS.shouldFallBackToNative(for: TTSError.noTextProvided))
    }

    // MARK: - Voice profile decoding

    func testVoiceProfileTolerantDecoding() throws {
        let json = #"{"id":"v1","displayName":"Québec FR","language":"fr-CA","kind":"clone"}"#
        let profile = try JSONDecoder().decode(VoxCPMVoiceProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.id, "v1")
        XCTAssertEqual(profile.language, "fr-CA")
        XCTAssertFalse(profile.hasReferenceAudio) // defaulted
        let voice = profile.asTTSVoice
        XCTAssertEqual(voice.id, "v1")
        XCTAssertEqual(voice.language, "fr-CA")
    }

    func testGenerationOptionsRequestBody() {
        var opts = VoxCPMGenerationOptions()
        opts.voice = "default"
        opts.language = .fr
        opts.quality = .fast
        opts.speed = 1.25
        let body = opts.requestBody(input: "Bonjour", model: "openbmb/VoxCPM2")
        XCTAssertEqual(body["input"] as? String, "Bonjour")
        XCTAssertEqual(body["language"] as? String, "fr")
        XCTAssertEqual(body["quality"] as? String, "fast")
        XCTAssertEqual(body["response_format"] as? String, "wav")
        XCTAssertNil(body["seed"]) // omitted when nil
    }

    // MARK: - Client (mock URLProtocol)

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testClientHealthDecodes() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.path.hasSuffix("/health"))
            let json = #"{"status":"ready","ready":true,"model":"openbmb/VoxCPM2","device":"mps","sample_rate":48000,"version":"0.1.0"}"#
            return (Self.http(req, 200), Data(json.utf8))
        }
        let client = VoxCPMClient(baseURL: URL(string: "http://127.0.0.1:8757")!,
                                  tokenProvider: { "tok" }, session: mockSession())
        let health = try await client.health()
        XCTAssertEqual(health.status, "ready")
        XCTAssertEqual(health.sampleRate, 48000)
        XCTAssertEqual(health.device, "mps")
    }

    func testClientSynthesizeReturnsData() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            return (Self.http(req, 200), Data([0x52, 0x49, 0x46, 0x46])) // "RIFF"
        }
        let client = VoxCPMClient(baseURL: URL(string: "http://127.0.0.1:8757")!,
                                  tokenProvider: { "tok" }, session: mockSession())
        let data = try await client.synthesize(text: "hi", model: "openbmb/VoxCPM2",
                                                options: VoxCPMGenerationOptions())
        XCTAssertEqual(data.count, 4)
    }

    func testClientSynthesize503MapsToNotReady() async {
        MockURLProtocol.handler = { req in (Self.http(req, 503), Data("loading".utf8)) }
        let client = VoxCPMClient(baseURL: URL(string: "http://127.0.0.1:8757")!,
                                  tokenProvider: { "tok" }, session: mockSession())
        do {
            _ = try await client.synthesize(text: "hi", model: "m", options: VoxCPMGenerationOptions())
            XCTFail("expected notReady")
        } catch let error as VoxCPMError {
            XCTAssertTrue(error.shouldFallBackToNative)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testClientMissingTokenIsUnavailable() async {
        let client = VoxCPMClient(baseURL: URL(string: "http://127.0.0.1:8757")!,
                                  tokenProvider: { nil }, session: mockSession())
        do {
            _ = try await client.synthesize(text: "hi", model: "m", options: VoxCPMGenerationOptions())
            XCTFail("expected backendUnavailable")
        } catch let error as VoxCPMError {
            XCTAssertTrue(error.shouldFallBackToNative)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testClientImportVoiceDecodesProfile() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.path.hasSuffix("/v1/voices/import"))
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            let json = #"{"id":"voice-abc","displayName":"Québec FR","language":"fr-CA","kind":"clone","hasReferenceAudio":true}"#
            return (Self.http(req, 201), Data(json.utf8))
        }
        let client = VoxCPMClient(baseURL: URL(string: "http://127.0.0.1:8757")!,
                                  tokenProvider: { "tok" }, session: mockSession())
        let profile = try await client.importVoice(
            displayName: "Québec FR", language: "fr-CA", kind: "clone",
            audioData: Data([1, 2, 3]), filename: "q.wav", transcript: nil,
            control: nil, notes: nil, consentConfirmed: true)
        XCTAssertEqual(profile.id, "voice-abc")
        XCTAssertTrue(profile.hasReferenceAudio)
    }

    func testClientDeleteVoiceSucceedsOn204() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "DELETE")
            return (Self.http(req, 204), Data())
        }
        let client = VoxCPMClient(baseURL: URL(string: "http://127.0.0.1:8757")!,
                                  tokenProvider: { "tok" }, session: mockSession())
        try await client.deleteVoice(id: "voice-abc") // must not throw
    }

    func testClientModelStatusDecodes() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.path.hasSuffix("/v1/model/status"))
            let json = #"{"model_id":"openbmb/VoxCPM2","downloaded":true,"state":"ready","size_bytes":4960000000,"num_files":9,"error":null}"#
            return (Self.http(req, 200), Data(json.utf8))
        }
        let client = VoxCPMClient(baseURL: URL(string: "http://127.0.0.1:8757")!,
                                  tokenProvider: { "tok" }, session: mockSession())
        let status = try await client.modelStatus()
        XCTAssertTrue(status.downloaded)
        XCTAssertEqual(status.state, "ready")
        XCTAssertEqual(status.numFiles, 9)
        XCTAssertEqual(status.sizeGB, 4.96, accuracy: 0.01)
    }

    // MARK: - Process manager

    func testProcessManagerReportsExitCode() async {
        let pm = VoxCPMProcessManager()
        let exited = expectation(description: "process exited")
        var code: Int32?
        pm.onExit = { c in code = c; exited.fulfill() }
        pm.maxAutoRestarts = 0 // don't restart on this deliberate exit
        pm.start(command: "exit 3")
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(code, 3)
        XCTAssertFalse(pm.isRunning)
    }

    func testProcessManagerStartIgnoresEmptyCommand() {
        let pm = VoxCPMProcessManager()
        pm.start(command: "   ")
        XCTAssertFalse(pm.isRunning)
    }

    private static func http(_ req: URLRequest, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
    }
}

/// Minimal URLProtocol stub for exercising VoxCPMClient without a live server.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

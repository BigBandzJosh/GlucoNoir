//
//  DexcomShareClient.swift
//  GlucoNoir
//
//  Actor wrapping the Dexcom Share API. Serialises requests and session
//  refresh so concurrent callers cannot trigger duplicate logins.
//

import Foundation

actor DexcomShareClient {

    private let session: URLSession
    private var credentials: ShareCredentials?
    private var accountID: String?
    private var sessionID: String?

    /// Set once an auth attempt fails terminally. Blocks all further requests
    /// until credentials change — retrying a rejected password is what locks
    /// the Dexcom account, and that account is the official app's too.
    private var lockedOut: ShareError?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func configure(_ credentials: ShareCredentials?) {
        guard credentials != self.credentials else { return }
        self.credentials = credentials
        self.accountID = nil
        self.sessionID = nil
        self.lockedOut = nil
    }

    var isConfigured: Bool { credentials?.isComplete == true }

    // MARK: Public API

    /// Fetches recent readings, newest first.
    /// - Parameters:
    ///   - minutes: lookback window, 1...1440.
    ///   - maxCount: maximum readings, 1...288.
    func fetchReadings(minutes: Int = 60, maxCount: Int = 12) async throws -> [ShareGlucoseReading] {
        if let lockedOut { throw lockedOut }
        guard let credentials, credentials.isComplete else { throw ShareError.notConfigured }

        do {
            return try await readGlucose(minutes: minutes, maxCount: maxCount)
        } catch ShareError.sessionExpired {
            // One refresh, one retry. Any further failure propagates.
            sessionID = nil
            return try await readGlucose(minutes: minutes, maxCount: maxCount)
        }
    }

    /// Validates credentials by establishing a session. Used by the settings screen.
    func verifyCredentials() async throws {
        if let lockedOut { throw lockedOut }
        sessionID = nil
        accountID = nil
        _ = try await ensureSession()
    }

    // MARK: Session

    private func ensureSession() async throws -> String {
        if let sessionID { return sessionID }
        guard let credentials else { throw ShareError.notConfigured }

        let account: String
        if let accountID {
            account = accountID
        } else {
            account = try await post(
                endpoint: "General/AuthenticatePublisherAccount",
                body: [
                    "accountName": credentials.username,
                    "password": credentials.password,
                    "applicationId": credentials.region.applicationID
                ]
            )
            accountID = account
        }

        let sid: String = try await post(
            endpoint: "General/LoginPublisherAccountById",
            body: [
                "accountId": account,
                "password": credentials.password,
                "applicationId": credentials.region.applicationID
            ]
        )

        guard isValidUUID(sid), sid != "00000000-0000-0000-0000-000000000000" else {
            throw ShareError.authenticationFailed("Dexcom returned an invalid session")
        }
        sessionID = sid
        return sid
    }

    private func readGlucose(minutes: Int, maxCount: Int) async throws -> [ShareGlucoseReading] {
        let sid = try await ensureSession()
        let clampedMinutes = max(1, min(minutes, 1440))
        let clampedCount = max(1, min(maxCount, 288))

        guard let credentials else { throw ShareError.notConfigured }
        var components = URLComponents(
            url: credentials.region.baseURL.appendingPathComponent("Publisher/ReadPublisherLatestGlucoseValues"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "sessionId", value: sid),
            URLQueryItem(name: "minutes", value: String(clampedMinutes)),
            URLQueryItem(name: "maxCount", value: String(clampedCount))
        ]
        guard let url = components?.url else { throw ShareError.malformedResponse("bad URL") }

        let data = try await send(request(url: url, body: nil))

        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ShareError.malformedResponse(String(data: data.prefix(200), encoding: .utf8) ?? "unreadable")
        }
        // Skip unparseable entries rather than failing the whole batch; a shape
        // change should degrade, not blank the screen.
        return array.compactMap(ShareGlucoseReading.init(json:))
            .sorted { $0.sampleTime > $1.sampleTime }
    }

    // MARK: Transport

    private func post(endpoint: String, body: [String: String]) async throws -> String {
        guard let credentials else { throw ShareError.notConfigured }
        let url = credentials.region.baseURL.appendingPathComponent(endpoint)
        let data = try await send(request(url: url, body: body))

        // These endpoints return a bare JSON string.
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ShareError.malformedResponse("non-UTF8 response")
        }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"\n\r "))
        guard !trimmed.isEmpty else { throw ShareError.malformedResponse("empty response") }
        return trimmed
    }

    private func request(url: URL, body: [String: String]?) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            throw ShareError.network(error.localizedDescription)
        } catch {
            throw ShareError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ShareError.malformedResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, data: data)
        }
        return data
    }

    /// Splits terminal auth failures from transient ones. Getting this wrong is
    /// how an app locks its user out of Dexcom.
    private func mapError(status: Int, data: Data) -> ShareError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = json?["Code"] as? String ?? ""
        let message = json?["Message"] as? String ?? ""

        switch code {
        case "SessionIdNotFound", "SessionNotValid":
            return .sessionExpired
        case "AccountPasswordInvalid":
            let failure = ShareError.authenticationFailed("username or password rejected")
            lockedOut = failure
            return failure
        case "SSO_AuthenticateMaxAttemptsExceeded":
            lockedOut = .accountLocked
            return .accountLocked
        case "SSO_InternalError":
            if message.contains("Cannot Authenticate") {
                let failure = ShareError.authenticationFailed("account could not be authenticated")
                lockedOut = failure
                return failure
            }
            return .server(message.isEmpty ? code : message)
        case "InvalidArgument":
            let failure = ShareError.authenticationFailed(message.isEmpty ? "invalid argument" : message)
            lockedOut = failure
            return failure
        default:
            if status == 500, code.isEmpty {
                return .server("HTTP 500")
            }
            return .server(code.isEmpty ? "HTTP \(status)" : "\(code): \(message)")
        }
    }

    private func isValidUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }
}

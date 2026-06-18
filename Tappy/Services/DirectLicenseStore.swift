import Foundation

enum DirectPurchaseConfig {
    static let displayPrice = "$4.99"
    static let purchaseURL = URL(string: "https://tappy-plum.vercel.app/api/create-checkout")!
    static let checkoutLicenseURL = URL(string: "https://tappy-plum.vercel.app/api/checkout-license")!
    static let licenseVerificationURL = URL(string: "https://tappy-plum.vercel.app/api/verify-license")!
}

@MainActor
final class DirectLicenseStore: ObservableObject {
    private enum DefaultsKey {
        static let licenseKey = "Tappy.directLicenseKey"
        static let unlocked = "Tappy.directLicenseUnlocked"
    }

    @Published private(set) var hasUnlockedPremium: Bool
    @Published private(set) var isActivating = false
    @Published private(set) var isValidating = false
    @Published private(set) var lastMessage: String?

    var onUnlockStateChange: ((Bool) -> Void)?

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        hasUnlockedPremium = userDefaults.bool(forKey: DefaultsKey.unlocked)
            && userDefaults.string(forKey: DefaultsKey.licenseKey) != nil
    }

    var isBusy: Bool {
        isActivating || isValidating
    }

    var hasSavedLicense: Bool {
        storedLicenseKey != nil
    }

    func activate(licenseKey rawLicenseKey: String) async {
        let licenseKey = rawLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !licenseKey.isEmpty else {
            lastMessage = "Paste your Tappy license key first."
            return
        }

        guard !isBusy else {
            lastMessage = "A license check is already running."
            return
        }

        isActivating = true
        defer { isActivating = false }

        do {
            try await activateUnlockedLicense(licenseKey)
        } catch {
            lastMessage = "License activation failed: \(error.localizedDescription)"
        }
    }

    func activate(checkoutSessionID rawSessionID: String) async {
        let sessionID = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard sessionID.starts(with: "cs_") else {
            lastMessage = "Tappy could not read the completed Stripe checkout."
            return
        }

        guard !isBusy else {
            lastMessage = "A license check is already running."
            return
        }

        isActivating = true
        defer { isActivating = false }

        do {
            let licenseKey = try await licenseKey(forCheckoutSessionID: sessionID)
            try await activateUnlockedLicense(licenseKey)
        } catch {
            lastMessage = "Checkout activation failed: \(error.localizedDescription)"
        }
    }

    func validateSavedLicense() async {
        guard let licenseKey = storedLicenseKey else {
            lastMessage = nil
            applyUnlocked(false)
            return
        }

        guard !isBusy else { return }

        isValidating = true
        defer { isValidating = false }

        do {
            let response = try await verify(licenseKey: licenseKey)

            if response.grantsAccess {
                applyUnlocked(true)
                lastMessage = nil
            } else {
                clearSavedLicense()
                lastMessage = response.userFacingError ?? "That license is no longer valid."
            }
        } catch {
            if hasUnlockedPremium {
                lastMessage = "License could not be checked, so your activated ASMR packs remain available offline."
            } else {
                lastMessage = "License check failed: \(error.localizedDescription)"
            }
        }
    }

    func clearSavedLicense() {
        userDefaults.removeObject(forKey: DefaultsKey.licenseKey)
        applyUnlocked(false)
    }

    private var storedLicenseKey: String? {
        userDefaults.string(forKey: DefaultsKey.licenseKey)
    }

    private func activateUnlockedLicense(_ licenseKey: String) async throws {
        let response = try await verify(licenseKey: licenseKey)

        guard response.grantsAccess else {
            throw LicenseError.api(response.userFacingError ?? "That license key could not be activated.")
        }

        userDefaults.set(licenseKey, forKey: DefaultsKey.licenseKey)
        applyUnlocked(true)
        lastMessage = "Tappy license activated. Premium ASMR packs unlocked."
    }

    private func licenseKey(forCheckoutSessionID sessionID: String) async throws -> String {
        var components = URLComponents(url: DirectPurchaseConfig.checkoutLicenseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "session_id", value: sessionID),
        ]

        guard let url = components?.url else {
            throw LicenseError.api("Tappy could not build the checkout activation request.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            if let decoded = try? decoder.decode(CheckoutLicenseAPIResponse.self, from: data),
               let message = decoded.userFacingError {
                throw LicenseError.api(message)
            }

            throw LicenseError.api("The Tappy license server returned an unexpected response.")
        }

        let decoded = try decoder.decode(CheckoutLicenseAPIResponse.self, from: data)
        guard decoded.success, let licenseKey = decoded.licenseKey, !licenseKey.isEmpty else {
            throw LicenseError.api(decoded.userFacingError ?? "The Tappy license server did not return a license key.")
        }

        return licenseKey
    }

    private func verify(licenseKey: String) async throws -> LicenseAPIResponse {
        var request = URLRequest(url: DirectPurchaseConfig.licenseVerificationURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formURLEncoded([
            "license_key": licenseKey,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            if let decoded = try? decoder.decode(LicenseAPIResponse.self, from: data),
               let message = decoded.userFacingError {
                throw LicenseError.api(message)
            }

            throw LicenseError.api("The Tappy license server returned an unexpected response.")
        }

        return try decoder.decode(LicenseAPIResponse.self, from: data)
    }

    private func applyUnlocked(_ unlocked: Bool) {
        let changed = hasUnlockedPremium != unlocked
        hasUnlockedPremium = unlocked
        userDefaults.set(unlocked, forKey: DefaultsKey.unlocked)

        if changed {
            onUnlockStateChange?(unlocked)
        }
    }

    private static func formURLEncoded(_ parameters: [String: String]) -> Data? {
        parameters
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct CheckoutLicenseAPIResponse: Decodable {
    let success: Bool
    let licenseKey: String?
    let message: String?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case success
        case licenseKey = "license_key"
        case message
        case error
    }

    var userFacingError: String? {
        if let message, !message.isEmpty {
            return message
        }

        if let error, !error.isEmpty {
            return error
        }

        return nil
    }
}

private struct LicenseAPIResponse: Decodable {
    let success: Bool
    let active: Bool?
    let message: String?
    let error: String?
    let product: String?

    var grantsAccess: Bool {
        guard success else { return false }
        guard active != false else { return false }
        if let product, product != "tappy-asmr-pack-unlock" {
            return false
        }
        return true
    }

    var userFacingError: String? {
        if let message, !message.isEmpty {
            return message
        }

        if let error, !error.isEmpty {
            return error
        }

        return nil
    }
}

private enum LicenseError: LocalizedError {
    case api(String)

    var errorDescription: String? {
        switch self {
        case .api(let message):
            return message
        }
    }
}

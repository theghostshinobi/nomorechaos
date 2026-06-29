import Cocoa
import Foundation

// MARK: - GeminiService

final class GeminiService {
    static let shared = GeminiService()
    private init() {}

    /// Reads the key securely from the macOS Keychain.
    var apiKey: String {
        KeychainHelper.load() ?? ""
    }

    /// Asks Gemini Vision which project a window screenshot belongs to.
    /// Returns the exact project name if matched, `nil` otherwise.
    func suggestProject(
        image: NSImage,
        projectNames: [String]
    ) async -> String? {
        guard !apiKey.isEmpty else {
            print("[GeminiService] No API key — set one in the app wizard or manager Settings")
            return nil
        }
        guard !projectNames.isEmpty else { return nil }

        // Resize to keep request payload manageable (max 1024px wide)
        let resized = image.resizedForAPI(maxWidth: 1024)
        guard let base64 = resized.pngBase64() else {
            print("[GeminiService] Failed to encode image as PNG")
            return nil
        }

        let prompt = """
        Guarda questo screenshot di una finestra macOS. \
        I progetti disponibili sono: \(projectNames.joined(separator: ", ")). \
        A quale progetto appartiene questa finestra? \
        Rispondi SOLO con il nome esatto del progetto, nient'altro.
        """

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt],
                    ["inline_data": [
                        "mime_type": "image/png",
                        "data": base64
                    ]]
                ]
            ]]
        ]

        let endpoint = "https://generativelanguage.googleapis.com/v1beta/"
            + "models/gemini-2.0-flash:generateContent?key=\(apiKey)"

        guard let url = URL(string: endpoint) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("[GeminiService] JSON serialization error: \(error)")
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let text = String(data: data, encoding: .utf8) ?? ""
                print("[GeminiService] HTTP \(http.statusCode): \(text.prefix(300))")
                return nil
            }

            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let candidates = json["candidates"] as? [[String: Any]],
                let content = candidates.first?["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]],
                let text = parts.first?["text"] as? String
            else {
                print("[GeminiService] Unexpected response structure")
                return nil
            }

            let suggestion = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "'", with: "")

            // Case-insensitive match against real project names
            return projectNames.first {
                $0.lowercased() == suggestion.lowercased()
            }
        } catch {
            print("[GeminiService] Network error: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - NSImage Helpers

extension NSImage {
    /// PNG Data → base64-encoded String.
    func pngBase64() -> String? {
        guard let tiffData = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return png.base64EncodedString()
    }

    /// Returns a copy resized so the width is at most `maxWidth`, preserving aspect ratio.
    func resizedForAPI(maxWidth: CGFloat) -> NSImage {
        let srcSize = size
        guard srcSize.width > maxWidth else { return self }

        let scale = maxWidth / srcSize.width
        let newSize = NSSize(
            width: srcSize.width * scale,
            height: srcSize.height * scale
        )

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: srcSize),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }
}

// ============================================================================
// MARK: - KeychainHelper
//
// Secure Keychain storage for the Gemini API key. Uses macOS Security framework.
// ============================================================================
struct KeychainHelper {
    static let service = "com.nomorechaos.app.gemini"
    static let account = "geminiAPIKey"

    static func save(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete()
            return
        }
        
        guard let data = trimmed.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        var itemCopy: AnyObject?
        let statusCheck = SecItemCopyMatching(query as CFDictionary, &itemCopy)
        
        if statusCheck == errSecSuccess {
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            if status != errSecSuccess {
                print("[KeychainHelper] Error updating API key: \(status)")
            }
        } else {
            var newQuery = query
            newQuery[kSecValueData as String] = data
            newQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            
            let status = SecItemAdd(newQuery as CFDictionary, nil)
            if status != errSecSuccess {
                print("[KeychainHelper] Error adding API key: \(status)")
            }
        }
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func migrateFromUserDefaults() {
        if let legacyKey = UserDefaults.standard.string(forKey: "geminiAPIKey") {
            let trimmed = legacyKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                save(key: trimmed)
                print("[KeychainHelper] Migrated legacy Gemini API key to Keychain.")
            }
            UserDefaults.standard.removeObject(forKey: "geminiAPIKey")
        }
    }
}

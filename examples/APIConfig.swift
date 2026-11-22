import Foundation

enum APIConfig {
    /// Public hostname only. Never put service keys or origin credentials here.
    static let productionBaseURL = URL(string: "https://api.example.com")!
}

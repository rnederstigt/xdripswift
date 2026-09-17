import Foundation

/// Common record format for activity and complication logs; their writers remain separate.
struct Libre2DiagnosticEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let message: String
}

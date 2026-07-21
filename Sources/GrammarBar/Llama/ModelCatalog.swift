import Foundation

struct ModelEntry: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let hfRepo: String
    let filename: String
    let downloadURL: String
    let sizeMB: Int
    let minRAMGB: Int
    let chatTemplate: String
    let isRecommended: Bool

    var sizeDisplayString: String {
        if sizeMB >= 1024 {
            return String(format: "%.1f GB", Double(sizeMB) / 1024.0)
        }
        return "\(sizeMB) MB"
    }
}

enum ModelCatalog {
    static let all: [ModelEntry] = {
        guard let url = Bundle.main.url(forResource: "models", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([ModelEntry].self, from: data)
        else {
            return []
        }
        return entries
    }()

    static func model(for id: String) -> ModelEntry? {
        all.first { $0.id == id }
    }
}

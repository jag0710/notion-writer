import AppKit

struct DisplayPreferences: Codable, Equatable {
    var fontName: String? = nil
    var titleSize: Double = 20
    var bodySize: Double = 15
    var propertySize: Double = 12

    var overallPercent: Double = 100
    var fixedPosition: Bool = true
    // The former 120% appearance is the new 100% baseline.
    var sizeBaselineVersion: Int = 2
    var scale: CGFloat { 1.2 * CGFloat(overallPercent / 100) }

    init() {}
    private enum CodingKeys: String, CodingKey { case fontName, titleSize, bodySize, propertySize, overallPercent, fixedPosition, sizeBaselineVersion }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try values.decodeIfPresent(String.self, forKey: .fontName)
        titleSize = try values.decodeIfPresent(Double.self, forKey: .titleSize) ?? 20
        bodySize = try values.decodeIfPresent(Double.self, forKey: .bodySize) ?? 15
        propertySize = try values.decodeIfPresent(Double.self, forKey: .propertySize) ?? 12
        overallPercent = try values.decodeIfPresent(Double.self, forKey: .overallPercent) ?? 100
        fixedPosition = try values.decodeIfPresent(Bool.self, forKey: .fixedPosition) ?? true
        if (try values.decodeIfPresent(Int.self, forKey: .sizeBaselineVersion) ?? 1) < 2 {
            overallPercent = 100
        }
        sizeBaselineVersion = 2
    }
    func scaledFont(size: Double) -> NSFont { font(size: size * Double(scale)) }
    func font(size: Double) -> NSFont {
        let size = CGFloat(size)
        return fontName.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
    }
    var fontLabel: String { fontName.flatMap { NSFont(name: $0, size: 18)?.displayName } ?? "システム標準" }
    static func load() -> DisplayPreferences {
        guard let data = UserDefaults.standard.data(forKey: "displayPreferences"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { UserDefaults.standard.set(true, forKey: "displayDefault20Migrated"); return Self() }
        var migrated = value.normalized()
        if !UserDefaults.standard.bool(forKey: "displayDefault20Migrated") {
            if migrated.titleSize == 18 { migrated.titleSize = 20 }
            UserDefaults.standard.set(true, forKey: "displayDefault20Migrated")
            migrated.save()
        }
        if !UserDefaults.standard.bool(forKey: "compactPropertiesMigrated") {
            if migrated.propertySize == 14 { migrated.propertySize = 12 }
            UserDefaults.standard.set(true, forKey: "compactPropertiesMigrated")
            migrated.save()
        }
        migrated.save()
        return migrated
    }
    func normalized() -> DisplayPreferences {
        var value = self
        value.titleSize = min(36, max(10, titleSize.isFinite ? titleSize : 20))
        value.bodySize = min(30, max(10, bodySize.isFinite ? bodySize : 15))
        value.propertySize = min(24, max(10, propertySize.isFinite ? propertySize : 12))
        value.overallPercent = min(150, max(75, overallPercent.isFinite ? overallPercent.rounded() : 100))
        return value
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(normalized()), forKey: "displayPreferences") }
}

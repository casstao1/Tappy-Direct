import Foundation

struct TechPack: Identifiable, Equatable {
    let id: String
    let name: String
    let tagline: String
    let blurb: String
    let symbolName: String
    let isAvailable: Bool
    let isPremium: Bool

    static let plasticTapping = TechPack(
        id: "plastic-tapping",
        name: "Plastic Tapping",
        tagline: "Light feedback cues",
        blurb: "Light, glossy cues for clear low-latency typing feedback.",
        symbolName: "circle.hexagongrid.fill",
        isAvailable: true,
        isPremium: false
    )

    static let farming = TechPack(
        id: "farming",
        name: "Organic Taps",
        tagline: "Natural feedback cues",
        blurb: "Wood, stone, and soft organic taps shaped for typing awareness.",
        symbolName: "leaf.fill",
        isAvailable: true,
        isPremium: false
    )

    static let bubble = TechPack(
        id: "bubble",
        name: "Soft Pop",
        tagline: "Gentle feedback cues",
        blurb: "Glossy pops and airy blips for softer auditory typing feedback.",
        symbolName: "circle.grid.2x2.fill",
        isAvailable: true,
        isPremium: true
    )

    static let stars = TechPack(
        id: "stars",
        name: "Bright Cues",
        tagline: "High-clarity feedback cues",
        blurb: "Bright, lightweight cues for users who prefer more audible typing feedback.",
        symbolName: "sparkles",
        isAvailable: true,
        isPremium: true
    )

    static let woodBrush = TechPack(
        id: "wood-brush",
        name: "Wood Brush",
        tagline: "Dry tactile feedback cues",
        blurb: "Dry woody swipes and brushy desk passes shaped into soft tactile cues.",
        symbolName: "paintbrush.fill",
        isAvailable: true,
        isPremium: true
    )

    static let analogStopwatch = TechPack(
        id: "analog-stopwatch",
        name: "Mechanical Ticks",
        tagline: "Precise feedback cues",
        blurb: "Winding ratchets and compact metallic ticks for precise typing feedback.",
        symbolName: "stopwatch.fill",
        isAvailable: true,
        isPremium: true
    )

    static let all: [TechPack] = [
        .plasticTapping,
        .farming,
        .bubble,
        .analogStopwatch,
        .stars,
        .woodBrush
    ]
}

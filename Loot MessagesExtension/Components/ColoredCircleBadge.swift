//
//  ColoredCircleBadge.swift
//  Loot
//
//  Created by Assistant
//

import SwiftUI

/// A circular badge with colored background and white text
/// Used throughout the app to represent guests/participants
struct ColoredCircleBadge: View {
    let text: String
    let color: Color
    
    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.85))
                .frame(width: 28, height: 28)
            Text(text)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

/// Shared color palette for consistent slot/guest colors across the app
enum BadgeColors {
    // Use explicit RGB colors to ensure full opacity
    static let palette: [Color] = [
        Color(red: 0.0, green: 0.478, blue: 1.0),     // blue
        Color(red: 0.204, green: 0.780, blue: 0.349), // green
        Color(red: 1.0, green: 0.584, blue: 0.0),     // orange
        Color(red: 1.0, green: 0.176, blue: 0.333),   // pink
        Color(red: 0.686, green: 0.322, blue: 0.871), // purple
        Color(red: 0.188, green: 0.690, blue: 0.780), // teal
        Color(red: 0.345, green: 0.337, blue: 0.839), // indigo
        Color(red: 0.388, green: 0.902, blue: 0.886)  // mint
    ]

    /// Returns a color for `slotIndex`, with per-cycle hue + brightness +
    /// saturation modulation so consecutive cycles through the palette
    /// don't collide. Cycle 0 returns the literal palette color; each
    /// subsequent cycle offsets the hue by half a palette step (so its
    /// colors land between the originals on the hue wheel) and
    /// alternates lighter/darker brightness with a slight desaturation
    /// pull. Keeps "similar bright vibe" without two slots reading as
    /// the same color past 8 members.
    static func color(for slotIndex: Int) -> Color {
        let n = palette.count
        let cycle = max(0, slotIndex) / n
        let baseIdx = max(0, slotIndex) % n
        if cycle == 0 {
            return palette[baseIdx]
        }
        return shifted(palette[baseIdx], cycle: cycle, paletteCount: n)
    }

    private static func shifted(_ base: Color, cycle: Int, paletteCount n: Int) -> Color {
        let baseUI = UIColor(base)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard baseUI.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return base
        }
        // Hue: rotate by half a palette step per cycle so cycle-1 colors
        // sit between cycle-0 entries on the wheel; cycle-2 rotates a
        // full step further; etc. Wraps via truncatingRemainder.
        let hueShift = CGFloat(cycle) / CGFloat(2 * n)
        let newH = (h + hueShift).truncatingRemainder(dividingBy: 1.0)

        // Brightness: alternate lighter (even cycles >0) and darker (odd
        // cycles). Magnitude grows slightly with cycle but is clamped so
        // we never go invisibly dark or washed-out white.
        let magnitude = min(0.32, 0.16 + CGFloat(cycle - 1) * 0.04)
        let bDelta: CGFloat = (cycle % 2 == 1) ? -magnitude : magnitude
        let newB = max(0.42, min(0.98, b + bDelta))

        // Saturation: pull slightly toward mid-saturation each cycle so
        // colors keep a "soft pop" rather than fluorescent overload.
        let sTarget: CGFloat = 0.72
        let sBlend: CGFloat = min(0.45, 0.12 * CGFloat(cycle))
        let newS = max(0.45, min(1.0, s * (1 - sBlend) + sTarget * sBlend))

        return Color(UIColor(hue: newH, saturation: newS, brightness: newB, alpha: a))
    }
    
    /// Generate initials for a badge from a name
    /// - For empty names: returns the fallback number (e.g., "1", "2")
    /// - For single word names: returns first letter (e.g., "Guest" → "G")
    /// - For multi-word names: returns first letter of first two words (e.g., "Guest 1" → "G1", "John Doe" → "JD")
    static func initials(from name: String, fallback: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.isEmpty {
            return String(fallback + 1)
        }
        
        let parts = trimmed.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        
        return String(trimmed.prefix(1)).uppercased()
    }
}

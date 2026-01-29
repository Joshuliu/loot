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

    static func color(for slotIndex: Int) -> Color {
        palette[slotIndex % palette.count]
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

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
    static let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .mint]
    
    static func color(for slotIndex: Int) -> Color {
        palette[slotIndex % palette.count]
    }
}
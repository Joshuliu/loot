//
//  BillCardCircleButton.swift
//  Loot
//
//  A circular tap target (with an optional caption underneath) that flanks
//  the bill card on the confirmation screen (left = delete, right = tip,
//  below = edit split). Replaces both the old non-interactive peeking
//  arrow hints and the separate bottom action-button row, so the compact
//  layout no longer overflows vertically. The colored fill brightens as
//  the user drags the card in this button's direction (`progress` 0→1),
//  so each button doubles as the swipe-direction cue it used to sit next
//  to. The caption labels what the swipe/tap does.
//
import SwiftUI

struct BillCardCircleButton: View {
    let icon: String
    let theme: Color
    /// Drag progress toward this button's direction (0…1). Tints the fill
    /// and flips the icon to white past a small threshold.
    let progress: CGFloat
    /// True while the card is being dragged in this direction — keeps this
    /// button at full opacity while the others fade with `buttonsOpacity`.
    let isActiveDrag: Bool
    let buttonsOpacity: Double
    let buttonBase: Color
    /// Short caption rendered under the circle (e.g. "Delete", "Edit split").
    var label: String? = nil
    var diameter: CGFloat = 50
    var iconSize: CGFloat = 19
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(progress > 0.02 ? Color.white : theme)
                    .frame(width: diameter, height: diameter)
                    .background(
                        Circle()
                            .fill(buttonBase)
                            .overlay(
                                Circle()
                                    .fill(theme)
                                    .opacity(Double(progress))
                            )
                    )
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : (isActiveDrag ? 1 : buttonsOpacity))
    }
}

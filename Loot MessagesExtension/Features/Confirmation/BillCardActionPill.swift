//
//  BillCardActionPill.swift
//  Loot
//
//  The wide action labels above and below the bill card on the
//  confirmation screen: "↑ Swipe up to send ↑" and "↓ Modify splits ↓".
//  Each is both a cue and a tap target — you can swipe the card in that
//  direction or just press it. The flanking arrows can be faded
//  independently (`arrowsOpacity`) — used to dim the down arrows once
//  expanded, where the swipe-down gesture no longer applies.
//
//  `background` controls the chrome: `.none` is plain text+arrows (the
//  full-screen drag tint provides feedback), `.subtle` is a faint
//  GuestList-style rounded fill that brightens with drag `progress`.
//
import SwiftUI

struct BillCardActionPill: View {
    enum Background {
        /// No chrome — the full-screen drag tint provides the feedback.
        case none
        /// Faint GuestList-style rounded fill (tertiarySystemFill).
        case subtle
    }

    let text: String
    /// SF Symbol for the two flanking arrows (e.g. "chevron.up").
    let arrowSystemName: String
    let theme: Color
    /// Drag progress toward this pill's direction (0…1).
    let progress: CGFloat
    let isActiveDrag: Bool
    let buttonsOpacity: Double
    var background: Background = .none
    var arrowsOpacity: Double = 1
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: arrowSystemName)
                    .opacity(arrowsOpacity)
                Text(text)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: arrowSystemName)
                    .opacity(arrowsOpacity)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(progress > 0.02 ? Color.white : theme)
            .padding(.vertical, background == .subtle ? 7 : 8)
            .padding(.horizontal, background == .subtle ? 16 : 18)
            .background(pillBackground)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : (isActiveDrag ? 1 : buttonsOpacity))
    }

    @ViewBuilder
    private var pillBackground: some View {
        switch background {
        case .none:
            Color.clear
        case .subtle:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme)
                        .opacity(Double(progress))
                )
        }
    }
}

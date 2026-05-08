//
//  SwipeHintAnimator.swift
//  Loot
//
//  Plays the first-time-user "nudge" animation on the bill card so the user
//  discovers the swipe gestures (left = delete, right = tip, down = split).
//  Persists a `didSeeSwipeHint` UserDefaults flag once the full sequence runs,
//  so the nudge only happens on the very first scan after install.
//
//  Extracted from ConfirmationView in Phase 4.
//
import SwiftUI

enum SwipeHintAnimator {
    private static let didSeeKey = "didSeeSwipeHint"

    /// Runs the left/left/right/right/down/down nudge sequence on the bill
    /// card. The caller passes bindings to the card's offset/rotation @State
    /// and a `isCancelled` closure that the animator polls between steps —
    /// this lets the parent abort mid-sequence if the user sends or deletes
    /// the card.
    @MainActor
    static func play(
        cardOffset: Binding<CGSize>,
        cardRotation: Binding<Double>,
        isCancelled: @escaping () -> Bool
    ) {
        guard !UserDefaults.standard.bool(forKey: didSeeKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if isCancelled() { return }
            // Left #1
            withAnimation(.easeOut(duration: 0.18)) {
                cardOffset.wrappedValue = CGSize(width: -9, height: 0)
                cardRotation.wrappedValue = -1.8
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.38)) {
                    cardOffset.wrappedValue = .zero
                    cardRotation.wrappedValue = 0
                }
                // Left #2
                DispatchQueue.main.asyncAfter(deadline: .now()) {
                    if isCancelled() { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        cardOffset.wrappedValue = CGSize(width: -9, height: 0)
                        cardRotation.wrappedValue = -1.8
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.38)) {
                            cardOffset.wrappedValue = .zero
                            cardRotation.wrappedValue = 0
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            if isCancelled() { return }
                            // Right #1
                            withAnimation(.easeOut(duration: 0.18)) {
                                cardOffset.wrappedValue = CGSize(width: 9, height: 0)
                                cardRotation.wrappedValue = 1.8
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                withAnimation(.spring(response: 0.55, dampingFraction: 0.38)) {
                                    cardOffset.wrappedValue = .zero
                                    cardRotation.wrappedValue = 0
                                }
                                // Right #2
                                DispatchQueue.main.asyncAfter(deadline: .now()) {
                                    if isCancelled() { return }
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        cardOffset.wrappedValue = CGSize(width: 9, height: 0)
                                        cardRotation.wrappedValue = 1.8
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                        withAnimation(.spring(response: 0.55, dampingFraction: 0.38)) {
                                            cardOffset.wrappedValue = .zero
                                            cardRotation.wrappedValue = 0
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                                            if isCancelled() { return }
                                            // Down #1
                                            withAnimation(.easeOut(duration: 0.18)) {
                                                cardOffset.wrappedValue = CGSize(width: 0, height: 9)
                                            }
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                                withAnimation(.spring(response: 0.55, dampingFraction: 0.38)) {
                                                    cardOffset.wrappedValue = .zero
                                                }
                                                // Down #2
                                                DispatchQueue.main.asyncAfter(deadline: .now()) {
                                                    if isCancelled() { return }
                                                    withAnimation(.easeOut(duration: 0.18)) {
                                                        cardOffset.wrappedValue = CGSize(width: 0, height: 9)
                                                    }
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                                        withAnimation(.spring(response: 0.55, dampingFraction: 0.38)) {
                                                            cardOffset.wrappedValue = .zero
                                                        }
                                                        UserDefaults.standard.set(true, forKey: didSeeKey)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

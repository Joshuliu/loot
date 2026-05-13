//
//  SendCueView.swift
//  Loot
//
//  The animated up-arrow + sparkles cue that points at the bill card to
//  hint "swipe up to send." Self-contained — owns its own animation @State
//  and restarts the loop on appear. Extracted from ConfirmationView in
//  Phase 4.
//
import SwiftUI

struct SendCueView: View {
    @State private var animating: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(systemName: "arrow.up")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color(hex: "#06A77D"))
                .offset(y: animating ? -6 : 0)

            Circle()
                .fill(Color.white.opacity(0.95))
                .frame(width: 5, height: 5)
                .offset(x: -16, y: animating ? -22 : -8)
                .opacity(animating ? 0 : 0.9)

            Circle()
                .fill(Color.white.opacity(0.95))
                .frame(width: 4, height: 4)
                .offset(x: 0, y: animating ? -30 : -12)
                .opacity(animating ? 0.1 : 0.85)

            Circle()
                .fill(Color.white.opacity(0.95))
                .frame(width: 3.5, height: 3.5)
                .offset(x: 14, y: animating ? -18 : -6)
                .opacity(animating ? 0 : 0.75)
        }
        .frame(height: 28)
        .onAppear {
            animating = false
            withAnimation(.easeOut(duration: 1.05).repeatForever(autoreverses: false)) {
                animating = true
            }
        }
    }
}

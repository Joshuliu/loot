//
//  CardPhysicsModifier.swift
//  Loot MessagesExtension
//
//  Shared gyroscope tilt, nudge hint, and press-to-shrink effect for swipeable cards.
//

import SwiftUI
import CoreMotion
import Combine

// MARK: - Device tilt via CoreMotion

@MainActor
final class DeviceTiltManager: ObservableObject {
    @Published var xTilt: Double = 0   // left/right (roll)
    @Published var yTilt: Double = 0   // forward/back (pitch)

    private let motion = CMMotionManager()
    private var referencePitch: Double?
    private var referenceRoll: Double?

    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let attitude = data?.attitude else { return }

            if self.referencePitch == nil {
                self.referencePitch = attitude.pitch
                self.referenceRoll = attitude.roll
            }

            let maxRad = 0.25
            let dp = attitude.pitch - (self.referencePitch ?? 0)
            let dr = attitude.roll  - (self.referenceRoll  ?? 0)

            let k = 0.15
            self.yTilt += (max(-maxRad, min(maxRad, dp)) - self.yTilt) * k
            self.xTilt += (max(-maxRad, min(maxRad, dr)) - self.xTilt) * k
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        referencePitch = nil
        referenceRoll = nil
        xTilt = 0
        yTilt = 0
    }
}

// MARK: - Card physics modifier

/// Applies gyroscope tilt, a repeating upward nudge hint, dynamic shadow,
/// and press-to-shrink to any card view.
struct CardPhysicsModifier: ViewModifier {
    @StateObject private var tilt = DeviceTiltManager()
    @State private var nudgeOffset: CGFloat = 0
    @State private var hasInteracted: Bool = false
    @State private var isPressed: Bool = false

    /// External flag — set to `true` once the user starts dragging so nudge stops.
    var isDragging: Bool = false

    private var tiltXDeg: Double { tilt.xTilt * (180 / .pi) * 0.4 }
    private var tiltYDeg: Double { tilt.yTilt * (180 / .pi) * 0.4 }

    func body(content: Content) -> some View {
        content
            // 3D tilt from gyroscope
            .rotation3DEffect(.degrees(tiltYDeg), axis: (x: -1, y: 0, z: 0))
            .rotation3DEffect(.degrees(tiltXDeg), axis: (x: 0, y: 1, z: 0))
            // Dynamic shadow
            .shadow(
                color: .black.opacity(0.18),
                radius: 16,
                x: CGFloat(tiltXDeg) * 0.8,
                y: CGFloat(-tiltYDeg) * 0.8 + 4
            )
            // Press shrink
            .scaleEffect(isPressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPressed)
            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                isPressed = pressing
            }, perform: {})
            // Nudge hint offset
            .offset(y: nudgeOffset)
            .onAppear {
                tilt.start()
                startNudgeLoop()
            }
            .onDisappear { tilt.stop() }
            .onChange(of: isDragging) { _, dragging in
                if dragging && !hasInteracted {
                    hasInteracted = true
                    nudgeOffset = 0
                }
            }
    }

    // MARK: - Nudge loop

    private func startNudgeLoop() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard !hasInteracted else { return }
            performNudge()
        }
    }

    private func performNudge() {
        guard !hasInteracted else { return }

        // Gentle lift
        withAnimation(.easeOut(duration: 0.18)) {
            nudgeOffset = -9
        }
        // Spring back with soft bounce oscillation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard !hasInteracted else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.38)) {
                nudgeOffset = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                performNudge()
            }
        }
    }
}

extension View {
    /// Adds gyroscope tilt, nudge-up hint, press-to-shrink, and dynamic shadow.
    func cardPhysics(isDragging: Bool = false) -> some View {
        modifier(CardPhysicsModifier(isDragging: isDragging))
    }
}

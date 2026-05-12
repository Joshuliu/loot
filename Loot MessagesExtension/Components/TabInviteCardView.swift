import SwiftUI

struct TabInviteCardView: View {
    @Environment(\.colorScheme) var colorScheme
    let tabName: String
    let tabColorHex: String
    let creatorName: String
    let joinedCount: Int
    let targetCount: Int
    /// When true, surfaces a pulsing "Tap to Join" pill on the card.
    /// Set by the transcript bubble path so the live-layout invite signals
    /// interactivity; the confirmation preview and the static alternate-layout
    /// snapshot leave it off.
    var showJoinPulse: Bool = false

    @State private var pulseOn: Bool = false

    private var isDarkMode: Bool { colorScheme == .dark }

    private var progressText: String {
        let safeJoined = max(0, joinedCount)
        let safeTarget = max(1, targetCount)
        if safeJoined >= safeTarget {
            return "\(safeJoined) member\(safeJoined == 1 ? "" : "s") joined"
        }
        return "\(safeJoined)/\(safeTarget) joined"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 32))
                    .foregroundColor(.white)

                Text(tabName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            Text("Tab invite from \(creatorName)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            Text(progressText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))

            if showJoinPulse {
                tapToJoinPill
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .frame(width: 260, height: 160)
        .background(Color(hex: tabColorHex))
        .cornerRadius(13)
        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 2)
        .onAppear {
            guard showJoinPulse else { return }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulseOn = true
            }
        }
    }

    private var tapToJoinPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 11, weight: .bold))
            Text("Tap to Join")
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundColor(Color(hex: tabColorHex))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white)
        )
        .scaleEffect(pulseOn ? 1.06 : 1.0)
        .opacity(pulseOn ? 0.95 : 1.0)
        .shadow(color: Color.black.opacity(pulseOn ? 0.18 : 0.06),
                radius: pulseOn ? 8 : 3, x: 0, y: 2)
    }
}

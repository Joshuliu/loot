import SwiftUI

struct TabInviteCardView: View {
    @Environment(\.colorScheme) var colorScheme
    let tabName: String
    let tabColorHex: String
    let creatorName: String
    let joinedCount: Int
    let targetCount: Int

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
        VStack(spacing: 12) {
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
                .foregroundColor(.white)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .frame(width: 250, height: 150)
        .background(Color(hex: tabColorHex))
        .cornerRadius(13)
        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 2)
    }
}

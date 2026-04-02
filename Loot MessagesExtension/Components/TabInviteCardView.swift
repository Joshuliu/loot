import SwiftUI

struct TabInviteCardView: View {
    @Environment(\.colorScheme) var colorScheme
    let tabName: String
    let tabColorHex: String
    let creatorName: String

    private var isDarkMode: Bool { colorScheme == .dark }

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

            Text("Tap to join")
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

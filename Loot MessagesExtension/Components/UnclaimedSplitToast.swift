//
//  UnclaimedSplitToast.swift
//  Loot MessagesExtension
//
//  Shared non-obstructive top toast surfaced after Save when a non-claim
//  by-items bill still has unclaimed item cents. It tells the user that
//  the unclaimed amount ($X) gets split evenly between guests, so the
//  resulting math doesn't read as an error. Used by both the compose
//  flow (ConfirmationView) and the post-send Edit Splits flow
//  (MessageReceiptViewer) so the two stay identical.
//

import SwiftUI

struct UnclaimedSplitToast: View {
    let amountCents: Int

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Remaining \(ReceiptDisplay.money(amountCents)) split evenly between guests.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.78))
            )
            .padding(.horizontal, 24)
            .padding(.top, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

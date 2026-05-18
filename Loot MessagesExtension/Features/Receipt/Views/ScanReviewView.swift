//
//  ScanReviewView.swift
//  Loot MessagesExtension
//
//  Post-capture review: preview the photo, retake/reselect, pick payer +
//  split mode, then continue. Transcript + Phase 1 are already running in
//  the background (started when this screen was entered), so confirmation
//  is near-instant once "Use Photo" is tapped.
//

import SwiftUI

struct ScanReviewView: View {
    @ObservedObject var receiptDraftVM: ReceiptDraftViewModel
    let onRetake: () -> Void
    let onContinue: () -> Void
    let onSelectMode: (SplitDraft.Mode) -> Void
    let onSelectPayer: (PersonID) -> Void

    private let myUid = KeychainHelper.getOrCreateUserId()

    private var draft: SplitDraft? { receiptDraftVM.currentSplitDraft }

    private func guestLabel(_ person: Person, index: Int) -> String {
        if person.isMe(localUserId: myUid) { return "You" }
        return person.resolvedDisplayName(guestIndex: index)
    }

    private var payerLabel: String {
        guard let draft else { return "—" }
        if let idx = draft.guests.firstIndex(where: { $0.id == draft.payerID }) {
            return guestLabel(draft.guests[idx], index: idx)
        }
        return "—"
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    if let img = receiptDraftVM.scanImageCropped ?? receiptDraftVM.scanImageOriginal {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                controls
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                HStack(spacing: 12) {
                    Button(action: onRetake) {
                        Text("Retake")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(UIColor.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button(action: onContinue) {
                        Text("Use Photo")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if let draft {
            VStack(spacing: 10) {
                HStack {
                    Text("Paid by")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Menu {
                        ForEach(Array(draft.guests.enumerated()), id: \.element.id) { idx, person in
                            Button(guestLabel(person, index: idx)) {
                                onSelectPayer(person.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(payerLabel)
                                .font(.system(size: 15, weight: .semibold))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 8) {
                    modeButton(.equally, "Evenly")
                    modeButton(.byItems, "By items")
                    modeButton(.custom, "Custom")
                }
            }
        }
    }

    @ViewBuilder
    private func modeButton(_ mode: SplitDraft.Mode, _ title: String) -> some View {
        let selected = draft?.mode == mode
        Button(action: { onSelectMode(mode) }) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(selected ? .white : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? Color.blue : Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

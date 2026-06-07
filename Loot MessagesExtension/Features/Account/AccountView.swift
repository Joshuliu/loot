//
//  AccountView.swift
//  Loot MessagesExtension
//

import SwiftUI

struct AccountView: View {
    let onBack: () -> Void
    let onRequestExpand: () -> Void
    let onPaymentMethods: () -> Void

    @AppStorage(DefaultsKeys.myDisplayName) private var displayName: String = ""
    @State private var editedName: String = ""
    @FocusState private var nameFocused: Bool

    private var trimmed: String {
        editedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmed != displayName && !trimmed.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.vertical, 10)

            Text("Account Settings")
                .font(.system(size: 24, weight: .bold))

            Text("Display Name")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Enter display name", text: $editedName)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
                .submitLabel(.done)
                .focused($nameFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.separator), lineWidth: 1)
                )
                .onSubmit { save() }

            Button(action: save) {
                Text("Save")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasChanges)
            .opacity(hasChanges ? 1.0 : 0.4)

            Divider()
                .padding(.vertical, 4)

            Button(action: onPaymentMethods) {
                HStack(spacing: 12) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.primary)
                    Text("Payment Methods")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    let count = savedPaymentMethods().count
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            editedName = displayName
        }
        .task {
            onRequestExpand()
        }
    }

    private func save() {
        guard hasChanges else { return }
        let newName = trimmed
        displayName = newName

        // Mirror the change to every place that the splits summary, the
        // transcript bubble, the baked card image, and the tab receipts
        // list might look. Previously this function only wrote to
        // `@AppStorage` locally — so the live splits summary picked up
        // the new name immediately (uid → @AppStorage) while every
        // frozen surface (g[i].n in shipped payloads, tab.members[i]
        // .displayName at join time) stayed at the old value.
        let myUid = KeychainHelper.getOrCreateUserId()
        DisplayNameCache.remember(uid: myUid, name: newName)
        Task {
            try? await TabService.shared.createOrUpdateUser(
                userId: myUid,
                displayName: newName
            )
            await TabService.shared.updateMyDisplayNameAcrossTabs(newName)
        }
        onBack()
    }
}

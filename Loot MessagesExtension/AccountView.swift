//
//  AccountView.swift
//  Loot MessagesExtension
//

import SwiftUI

struct AccountView: View {
    let onBack: () -> Void
    let onRequestExpand: () -> Void

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
        displayName = trimmed
        onBack()
    }
}

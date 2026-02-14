//
//  NewTabView.swift
//  Loot MessagesExtension
//

import SwiftUI

struct NewTabView: View {
    @ObservedObject var uiModel: LootUIModel
    var isExpanded: Bool
    
    let onRequestExpand: () -> Void
    let onBack: () -> Void
    let onNext: (String, String) -> Void  // passes (tab name, colorHex)

    @Binding var tabName: String
    @Binding var selectedColor: String
    @FocusState private var nameFocused: Bool

    private var trimmed: String {
        tabName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canContinue: Bool {
        !trimmed.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer().frame(height: 8)

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

            Text("New Loot Tab")
                .font(.system(size: 28, weight: .bold))

            if isExpanded {
                Text("Create a running tab for your group chat. Everyone can add receipts and track what's owed.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Text("Tab Name")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            TextField("E.g. Joshua / Jasmine, Vegas Trip 26, Room 248", text: $tabName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
                .submitLabel(.continue)
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
                .onSubmit {
                    guard canContinue else { return }
                    onNext(trimmed, selectedColor)
                }

            // Color picker
            Text("Tab Color")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ForEach(TabColorOptions.all, id: \.self) { hex in
                    Button(action: { selectedColor = hex }) {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 40, height: 40)
                            .overlay(
                                selectedColor == hex
                                    ? Image(systemName: "checkmark")
                                        .foregroundColor(.white)
                                        .font(.system(size: 14, weight: .bold))
                                    : nil
                            )
                            .overlay(
                                Circle()
                                    .stroke(selectedColor == hex ? Color.primary : Color.clear, lineWidth: 2.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                onNext(trimmed, selectedColor)
            } label: {
                Text("Next")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue)
            .opacity(canContinue ? 1.0 : 0.4)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            onRequestExpand()
            try? await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run { nameFocused = true }
            try? await Task.sleep(nanoseconds: 450_000_000)
            await MainActor.run { nameFocused = true }
        }
    }
}

// MARK: - Tab Invite Card (rendered into MSMessage layout image)

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

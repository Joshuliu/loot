//
//  BankPickerView.swift
//  Loot MessagesExtension
//

import SwiftUI

struct BankEntry: Identifiable {
    let id: String
    let name: String
    let url: String
}

struct BankPickerView: View {
    let onSelect: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var banks: [BankEntry] = []
    @State private var searchText: String = ""

    private static let popularBankNames: Set<String> = [
        "Bank of America",
        "Capital One",
        "Chase Bank",
        "PNC Bank",
        "Truist",
        "U.S. Bank",
        "Wells Fargo Bank"
    ]

    private var popularBanks: [BankEntry] {
        banks.filter { Self.popularBankNames.contains($0.name) }
            .sorted { $0.name < $1.name }
    }

    private var filteredBanks: [BankEntry] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        return banks.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        NavigationView {
            List {
                if searchText.isEmpty {
                    Section("Popular Banks") {
                        ForEach(popularBanks) { bank in
                            bankRow(bank)
                        }
                    }
                } else {
                    Section("Results") {
                        if filteredBanks.isEmpty {
                            Text("No banks found")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(filteredBanks) { bank in
                                bankRow(bank)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search banks")
            .navigationTitle("Select Your Bank")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { loadBanks() }
    }

    @ViewBuilder
    private func bankRow(_ bank: BankEntry) -> some View {
        Button {
            onSelect(bank.name, bank.url)
            dismiss()
        } label: {
            HStack {
                Image(systemName: "building.columns")
                    .foregroundStyle(.secondary)
                Text(bank.name)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func loadBanks() {
        guard let url = Bundle.main.url(forResource: "Banks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else { return }

        banks = dict.compactMap { name, info in
            guard let bankURL = info["data-bankurl"], !bankURL.isEmpty else { return nil }
            return BankEntry(id: name, name: name, url: bankURL)
        }
    }
}

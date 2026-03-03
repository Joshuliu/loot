//
//  BankPickerView.swift
//  Loot MessagesExtension
//

import SwiftUI

struct BankEntry: Identifiable {
    let id: String
    let name: String
    let url: String
    /// True when the bank uses the override_8471 modal — meaning the Zelle QR
    /// can only be obtained by opening the bank's native app directly.
    let isOverride: Bool
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
        let query = searchText.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return banks.filter { bank in
            let name = bank.name.lowercased()
            return name.contains(query) || matchesWordPrefix(query, in: bank.name)
        }
    }

    /// Matches a query against a bank name using word-prefix subsequence logic.
    /// Each character of the query must either extend the current word's prefix match
    /// or start matching at the beginning of the next word (words can be skipped).
    ///
    /// Examples:
    ///   "bo"     → Bank of America  (b=Bank, o=of)
    ///   "bofa"   → Bank of America  (b=Bank, of=of, a=America)
    ///   "bfsfcu" → Bank-Fund Staff FCU  (b=Bank, f=Fund, s=Staff, fcu=FCU)
    ///   "bsf"    → Bank-Fund Staff FCU  (b=Bank, [skip Fund], s=Staff, f=FCU)
    private func matchesWordPrefix(_ query: String, in bankName: String) -> Bool {
        let q = Array(query.lowercased())
        let words = bankName.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard !q.isEmpty, !words.isEmpty else { return false }

        var qi = 0   // position in query
        var wi = 0   // current word index
        var wci = 0  // position within current word

        while qi < q.count {
            guard wi < words.count else { return false }
            let word = Array(words[wi])

            if wci < word.count && word[wci] == q[qi] {
                // Extend the match inside the current word
                qi += 1
                wci += 1
            } else {
                // Can't continue in this word — jump to the start of the next word
                wi += 1
                wci = 0
                // Don't advance qi: retry the same character against the new word's start
            }
        }

        return true
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
            let isOverride = info["data-modaloverride"] == "override_8471"
            return BankEntry(id: name, name: name, url: bankURL, isOverride: isOverride)
        }
    }
}

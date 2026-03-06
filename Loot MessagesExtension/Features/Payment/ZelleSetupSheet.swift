//
//  ZelleSetupSheet.swift
//  Loot MessagesExtension
//

import SwiftUI
import PhotosUI
import Vision

struct ZelleSetupSheet: View {
    let onComplete: (_ bankName: String, _ bankURL: String, _ identifier: String, _ zelleData: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // Step 1: Bank
    @State private var bankName: String
    @State private var bankURL: String
    @State private var bankIsOverride: Bool = false
    @State private var bankConfirmed: Bool
    @State private var bankSearchText: String = ""
    @State private var allBanks: [BankEntry] = []

    // Step 2: QR
    @State private var qrURLText: String = ""
    @State private var extractedName: String
    @State private var extractedToken: String
    @State private var zelleData: String
    @State private var parseError: String? = nil
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @State private var didSaveReturnFlag: Bool = false

    init(existing: PaymentMethod? = nil,
         onComplete: @escaping (_ bankName: String, _ bankURL: String, _ identifier: String, _ zelleData: String) -> Void) {
        self.onComplete = onComplete
        self._bankName = State(initialValue: existing?.bankName ?? "")
        self._bankURL = State(initialValue: existing?.bankURL ?? "")
        self._bankConfirmed = State(initialValue: !(existing?.bankURL ?? "").isEmpty)

        if let data = existing?.zelleData, !data.isEmpty,
           let info = Self.decodeZelleInfo(data) {
            self._zelleData = State(initialValue: data)
            self._extractedName = State(initialValue: info.name)
            self._extractedToken = State(initialValue: info.token)
        } else {
            self._zelleData = State(initialValue: "")
            self._extractedName = State(initialValue: "")
            self._extractedToken = State(initialValue: "")
        }
    }

    private static let popularBankNames: Set<String> = [
        "Bank of America", "Capital One", "Chase Bank",
        "PNC Bank", "Truist", "U.S. Bank", "Wells Fargo Bank"
    ]

    private var popularBanks: [BankEntry] {
        allBanks.filter { Self.popularBankNames.contains($0.name) }
            .sorted { $0.name < $1.name }
    }

    private var filteredBanks: [BankEntry] {
        let q = bankSearchText.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return allBanks.filter { bank in
            let name = bank.name.lowercased()
            return name.contains(q) || matchesWordPrefix(q, in: bank.name)
        }
    }

    private var canDone: Bool { bankConfirmed && !zelleData.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Step 1 — Bank
                Section {
                    if bankConfirmed {
                        HStack {
                            Image(systemName: "building.columns.fill")
                                .foregroundStyle(.blue)
                                .frame(width: 22)
                            Text(bankName)
                                .font(.system(size: 15, weight: .medium))
                            Spacer()
                            Button("Change") {
                                bankConfirmed = false
                                bankIsOverride = false
                                bankSearchText = ""
                                didSaveReturnFlag = false
                            }
                            .font(.system(size: 14))
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.tertiary)
                            TextField("Search your bank…", text: $bankSearchText)
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.never)
                        }
                        let displayBanks = bankSearchText.isEmpty
                            ? popularBanks
                            : Array(filteredBanks.prefix(8))
                        if !bankSearchText.isEmpty && filteredBanks.isEmpty {
                            Text("No banks found")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 14))
                        } else {
                            ForEach(displayBanks) { bank in
                                Button {
                                    bankName = bank.name
                                    bankURL = bank.url
                                    bankIsOverride = bank.isOverride
                                    bankConfirmed = true
                                    bankSearchText = ""
                                } label: {
                                    HStack {
                                        Text(bank.name).foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Label("1. Your Bank", systemImage: "1.circle.fill")
                }

                // MARK: Step 2 — QR Code
                Section {
                    if bankConfirmed {
                        if bankIsOverride {
                            // Override banks require the native app — show step-by-step instructions
                            overrideInstructions
                        } else {
                            // Non-override banks have a web Zelle page — link straight to it
                            if let url = URL(string: bankURL) {
                                Button {
                                    UserDefaults.standard.set(true, forKey: DefaultsKeys.pendingReturnToPaymentMethods)
                                    UserDefaults.standard.set(true, forKey: DefaultsKeys.pendingZelleReopen)
                                    UserDefaults.standard.set(bankName, forKey: DefaultsKeys.pendingZelleBankName)
                                    UserDefaults.standard.set(bankURL, forKey: DefaultsKeys.pendingZelleBankURL)
                                    openURL(url)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "qrcode.viewfinder")
                                            .font(.system(size: 18))
                                            .foregroundStyle(.blue)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Open \(bankName)")
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundStyle(.blue)
                                            Text("Navigate to your Zelle QR code")
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !bankIsOverride {
                            HStack(spacing: 10) {
                                TextField("Paste QR link or upload image", text: $qrURLText)
                                    .autocorrectionDisabled(true)
                                    .textInputAutocapitalization(.never)
                                    .onChange(of: qrURLText) { _, newValue in
                                        tryParseZelleURL(newValue)
                                    }
                                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.blue)
                                }
                                .onChange(of: photoPickerItem) { _, item in
                                    Task { await readQRFromPhoto(item) }
                                }
                            }
                        }

                        if let err = parseError {
                            Text(err)
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                        }

                        if !zelleData.isEmpty {
                            HStack {
                                Text("Name")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 14))
                                Spacer()
                                Text(extractedName)
                                    .font(.system(size: 14, weight: .medium))
                            }
                            HStack {
                                Text(extractedToken.contains("@") ? "Email" : "Phone")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 14))
                                Spacer()
                                Text(extractedToken)
                                    .font(.system(size: 14, weight: .medium))
                            }
                        }
                    } else {
                        Text("Complete step 1 first")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 14))
                    }
                } header: {
                    Label("2. Your Zelle QR Code", systemImage: "2.circle.fill")
                } footer: {
                    if bankConfirmed && !bankIsOverride && zelleData.isEmpty {
                        Text("In your bank app, go to Zelle → tap your QR icon → tap Share → copy the link or save the QR image, then paste or upload it above.")
                            .font(.system(size: 12))
                    }
                }
            }
            .navigationTitle("Set Up Zelle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onComplete(bankName, bankURL, extractedToken, zelleData)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canDone)
                }
            }
        }
        .onAppear { loadBanks() }
    }

    // MARK: - Override Instructions

    @ViewBuilder
    private var overrideInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("To get your Zelle QR code:")
                    .font(.system(size: 14, weight: .semibold))
                instructionStep(number: "1", text: "Close Loot (minimize this app)")
                instructionStep(number: "2", text: "Open the \(bankName) app")
                instructionStep(number: "3", text: "Go to Zelle → tap your profile or QR icon")
                instructionStep(number: "4", text: "Tap Share → Copy Link")
                instructionStep(number: "5", text: "Reopen Loot — you'll land right here")
            }

            if didSaveReturnFlag {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 14))
                    Text("Loot will reopen to Payment Methods")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    UserDefaults.standard.set(true, forKey: DefaultsKeys.pendingReturnToPaymentMethods)
                    didSaveReturnFlag = true
                } label: {
                    Label("I'll get my QR code →", systemImage: "arrow.up.right.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func instructionStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.blue)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - QR Parsing

    private func tryParseZelleURL(_ urlString: String) {
        parseError = nil
        zelleData = ""
        extractedName = ""
        extractedToken = ""

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard trimmed.lowercased().contains("zellepay.com") else {
            parseError = "URL must be from zellepay.com"
            return
        }
        guard let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dataParam = components.queryItems?.first(where: { $0.name == "data" })?.value,
              !dataParam.isEmpty
        else {
            parseError = "Couldn't read the link — copy the full zellepay.com URL"
            return
        }
        applyZelleData(dataParam)
    }

    private func applyZelleData(_ data: String) {
        guard let info = Self.decodeZelleInfo(data) else {
            parseError = "Couldn't decode QR data"
            return
        }
        extractedName = info.name
        extractedToken = info.token
        zelleData = data
        parseError = nil
    }

    /// Decodes a raw base64 Zelle data string into name + token.
    static func decodeZelleInfo(_ data: String) -> (name: String, token: String)? {
        // Normalize URL-safe base64 and add padding
        var base64 = data
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = base64.count % 4
        if rem != 0 { base64 += String(repeating: "=", count: 4 - rem) }

        guard let decoded = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: String],
              let name = json["name"], !name.isEmpty,
              let token = json["token"], !token.isEmpty
        else { return nil }
        return (name: name, token: token)
    }

    private func readQRFromPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let imageData = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: imageData),
              let cgImage = uiImage.cgImage
        else {
            await MainActor.run { parseError = "Couldn't load image" }
            return
        }

        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            await MainActor.run { parseError = "QR scan failed" }
            return
        }

        guard let payload = request.results?.first?.payloadStringValue else {
            await MainActor.run { parseError = "No QR code found in image" }
            return
        }

        await MainActor.run {
            qrURLText = payload
            tryParseZelleURL(payload)
        }
    }

    // MARK: - Bank Loading

    private func loadBanks() {
        guard let url = Bundle.main.url(forResource: "Banks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else { return }
        allBanks = dict.compactMap { name, info in
            guard let bankURL = info["data-bankurl"], !bankURL.isEmpty else { return nil }
            let isOverride = info["data-modaloverride"] == "override_8471"
            return BankEntry(id: name, name: name, url: bankURL, isOverride: isOverride)
        }
        // Restore override status for existing (pre-confirmed) bank
        if bankConfirmed, !bankName.isEmpty,
           let entry = allBanks.first(where: { $0.name == bankName }) {
            bankIsOverride = entry.isOverride
        }
    }

    private func matchesWordPrefix(_ query: String, in bankName: String) -> Bool {
        let q = Array(query.lowercased())
        let words = bankName.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !q.isEmpty, !words.isEmpty else { return false }
        var qi = 0, wi = 0, wci = 0
        while qi < q.count {
            guard wi < words.count else { return false }
            let word = Array(words[wi])
            if wci < word.count && word[wci] == q[qi] {
                qi += 1; wci += 1
            } else {
                wi += 1; wci = 0
            }
        }
        return true
    }
}

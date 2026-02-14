//
//  SharedReceiptService.swift
//  Loot MessagesExtension
//
//  Created by Joshua Liu on 2/6/26.
//

import Foundation
import UIKit
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

final class SharedReceiptService {
    static let shared = SharedReceiptService()
    private init() {}

    private lazy var db = Firestore.firestore()
    private let collection = "sharedReceipts"

    // MARK: - Firebase bootstrap

    static func configureFirebaseIfNeeded() {
        guard FirebaseApp.app() == nil else { return }
        FirebaseApp.configure()
    }

    func ensureAnonymousAuth() async throws {
        Self.configureFirebaseIfNeeded()
        if Auth.auth().currentUser != nil { return }
        try await Auth.auth().signInAnonymously()
    }

    // MARK: - Upload / Fetch

    /// Pre-generates a Firestore document ID (no network call).
    func generateDocId() -> String {
        db.collection(collection).document().documentID
    }

    /// Uploads the payload to a pre-generated document ID.
    func upload(_ payload: LootMessagePayload, captureImage: UIImage? = nil, docId: String) async throws {
        try await ensureAnonymousAuth()

        let data = try JSONEncoder().encode(payload)
        guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "SharedReceiptService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to serialize payload"])
        }

        dict["_createdAt"] = FieldValue.serverTimestamp()
        dict["_uid"] = Auth.auth().currentUser?.uid ?? "unknown"

        if let image = captureImage, let encoded = compressForSharing(image) {
            dict["_captureImage"] = encoded
        }

        try await db.collection(collection).document(docId).setData(dict)
        print("[SharedReceiptService] uploaded doc: \(docId)")
    }

    func fetch(id: String) async throws -> (LootMessagePayload, UIImage?) {
        try await ensureAnonymousAuth()

        let snapshot = try await db.collection(collection).document(id).getDocument()
        guard var dict = snapshot.data() else {
            throw NSError(domain: "SharedReceiptService", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Document not found"])
        }

        // Extract capture image before stripping
        var captureImage: UIImage?
        if let base64 = dict["_captureImage"] as? String,
           let imageData = Data(base64Encoded: base64) {
            captureImage = UIImage(data: imageData)
        }

        // Strip metadata fields before decoding
        dict.removeValue(forKey: "_createdAt")
        dict.removeValue(forKey: "_uid")
        dict.removeValue(forKey: "_captureImage")

        let data = try JSONSerialization.data(withJSONObject: dict)
        let payload = try JSONDecoder().decode(LootMessagePayload.self, from: data)
        return (payload, captureImage)
    }

    // MARK: - Update (slot claims, etc.)

    /// Merges updated payload fields into existing Firestore doc (preserves _createdAt, _uid, _captureImage).
    func updatePayload(_ payload: LootMessagePayload, docId: String) async throws {
        try await ensureAnonymousAuth()

        let data = try JSONEncoder().encode(payload)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "SharedReceiptService", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to serialize payload for update"])
        }

        try await db.collection(collection).document(docId).setData(dict, merge: true)
        print("[SharedReceiptService] updated doc: \(docId)")
    }

    // MARK: - Image compression

    private func compressForSharing(_ image: UIImage) -> String? {
        let maxEdge: CGFloat = 800
        let size = image.size
        let scale: CGFloat
        if max(size.width, size.height) > maxEdge {
            scale = maxEdge / max(size.width, size.height)
        } else {
            scale = 1
        }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        guard let jpegData = resized.jpegData(compressionQuality: 0.3) else { return nil }
        return jpegData.base64EncodedString()
    }
}

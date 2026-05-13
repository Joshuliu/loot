//
//  TabReceiptAdapter.swift
//  Loot
//
//  Adapter that builds a `TabReceipt` (Firestore document shape) from a
//  sent `LootMessagePayload` (wire format) plus its associated `LootTab`.
//
//  Phase 5 step 19a: relocated from `Models/TabModels.swift` (was
//  `extension TabReceipt { static func from(...) }`) into the Storage
//  layer so wire→storage adapters live next to other storage adapters
//  and the Domain types they will eventually consume. Signature kept on
//  wire types for now — migrating to Domain `Receipt` + `SplitConfiguration`
//  is blocked on `ReceiptDisplay → Receipt` public-type migration, which
//  is out of scope for Phase 5.
//
import FirebaseFirestore
import Foundation

enum TabReceiptAdapter {
    /// Creates a `TabReceipt` from a sent message payload and the active tab.
    static func fromPayload(_ payload: LootMessagePayload, messagePayloadId: String, tab: LootTab) -> TabReceipt {
        let myId = KeychainHelper.getOrCreateUserId()
        let split = payload.s
        let receipt = payload.r

        // Build a lookup from guest uid → tab memberId. `uniquingKeysWith`
        // (rather than `uniqueKeysWithValues`) keeps this from trapping if the
        // tab somehow still contains two members with the same userId — first
        // entry wins, which matches `dedupedMembers()`'s behavior.
        let uidToMemberId: [String: String] = Dictionary(
            tab.members.compactMap { m in
                guard let uid = m.userId, !uid.isEmpty else { return nil }
                return (uid, m.memberId)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Map payer slot to memberId
        let payerUid = split.g[split.pi].uid ?? myId
        let payerMemberId = uidToMemberId[payerUid] ?? myId

        // Carry the payer's display name straight from the payload so the UI
        // doesn't depend on activeTab.members being in sync at render time
        // (live listener catch-up race produced "Paid by <UUID>" rows).
        let payerDisplayName: String? = {
            guard split.g.indices.contains(split.pi) else { return nil }
            let raw = split.g[split.pi].n.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        }()

        // Map split mode
        let splitMode: SplitMode = {
            switch split.m {
            case .equally: return .equally
            case .custom: return .custom
            case .byItems: return .byItems
            }
        }()

        // Build splits: for each included guest, map to tab member
        let splits: [ReceiptSplit] = split.g.enumerated().compactMap { idx, guest in
            guard guest.inc, split.o.indices.contains(idx), split.o[idx] > 0 else { return nil }
            let uid = guest.uid ?? ""
            let memberId = uidToMemberId[uid] ?? uid
            guard !memberId.isEmpty else { return nil }
            return ReceiptSplit(memberId: memberId, owedCents: split.o[idx])
        }

        // Build items (if by-items mode). Both legacy assignedMemberIds and
        // the new ReceiptItemPartition are populated — old readers fall back
        // to assignedMemberIds, new readers prefer partition.
        let memberIdForSlot: (Int) -> String? = { slotIdx in
            guard split.g.indices.contains(slotIdx) else { return nil }
            let uid = split.g[slotIdx].uid ?? ""
            return uidToMemberId[uid] ?? (uid.isEmpty ? nil : uid)
        }

        let items: [ReceiptItem]? = splitMode == .byItems ? receipt.i.map { item -> ReceiptItem in
            let assignedMemberIds = item.rs.compactMap(memberIdForSlot)

            let partition: ReceiptItemPartition? = {
                if let cu = item.cu, !cu.isEmpty {
                    let claims = cu.compactMap { wire -> ReceiptItemCustomClaim? in
                        guard let mid = memberIdForSlot(wire.s) else { return nil }
                        return ReceiptItemCustomClaim(memberId: mid, cents: wire.c)
                    }
                    return claims.isEmpty ? nil : .custom(claims: claims)
                }
                if let sh = item.sh, !sh.isEmpty {
                    let slots: [String?] = sh.map { slotOpt in
                        slotOpt.flatMap(memberIdForSlot)
                    }
                    return .shares(denominator: sh.count, slots: slots)
                }
                return nil  // legacy rs-only — assignedMemberIds covers it
            }()

            return ReceiptItem(
                label: item.l,
                priceCents: item.p,
                quantity: 1,
                assignedMemberIds: assignedMemberIds,
                partition: partition
            )
        } : nil

        return TabReceipt(
            title: receipt.t,
            createdBy: myId,
            createdAt: Timestamp(date: Date(timeIntervalSince1970: receipt.c)),
            totalCents: receipt.tot,
            subtotalCents: receipt.sub,
            taxCents: receipt.tx,
            tipCents: receipt.tip,
            feesCents: receipt.f,
            discountCents: receipt.d == 0 ? nil : receipt.d,
            splitMode: splitMode,
            payerMemberId: payerMemberId,
            splits: splits,
            items: items,
            imageUrl: nil,
            messagePayloadId: messagePayloadId,
            payerDisplayName: payerDisplayName
        )
    }
}

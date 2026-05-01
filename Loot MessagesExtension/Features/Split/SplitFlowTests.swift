//
//  SplitFlowTests.swift
//  Loot
//
//  Created by Sunny Lee on 4/30/26.
//


//
//  SplitFlowTests.swift
//  Loot
//
//  Compile-time verifiable split-math + send-payload tests.
//  Call SplitFlowTests.runAll() from a debug launch to verify.
//
//  Pattern matches TabBalanceTests: no XCTest target needed; plain `assert()`
//  inside a DEBUG-only enum. Failures crash the debug build immediately.
//

import Foundation

#if DEBUG
enum SplitFlowTests {

    static func runAll() {
        testEqualSplitMath()
        testEqualSplitRemainderToFirst()
        testCustomSplitSumMatchesTotal()
        testCustomSplitClampsDifferenceToPayer()
        testByItemsSimple()
        testByItemsWithSharedItemAndExtras()
        testSendPayloadMatchesInAppForEqual()
        testSendPayloadMatchesInAppForCustom()
        testSendPayloadMatchesInAppForByItems()
        testStaleDraftTotalCorruptsPayerOwed()
        testRoundTripDraftThroughSendPath()
        print("[SplitFlowTests] All tests passed")
    }

    // MARK: - Helpers

    private static func makeGuests(_ names: [String]) -> [SplitGuest] {
        names.enumerated().map { idx, name in
            SplitGuest(id: UUID(), name: name, isIncluded: true, isMe: idx == 0, uid: nil)
        }
    }

    private static func payloadGuests(from guests: [SplitGuest]) -> [SplitPayload.Guest] {
        guests.map { SplitPayload.Guest(n: $0.name, inc: $0.isIncluded, uid: $0.uid) }
    }

    /// Mirrors the in-app `ConfirmationView.owedAmounts` derivation so we can
    /// compare it against `SplitPayload.from(...)` (the send path).
    private static func inAppOwed(draft: SplitDraft) -> [Int] {
        let mode: SplitPayload.Mode = {
            switch draft.mode {
            case .equally: return .equally
            case .custom:  return .custom
            case .byItems: return .byItems
            }
        }()
        let guests = payloadGuests(from: draft.guests)
        let payerIndex = draft.guests.firstIndex(where: { $0.id == draft.payerGuestId }) ?? 0
        let items: [(label: String, priceCents: Int, assignedSlots: [Int])] = draft.items.map { item in
            let slots = item.assignedGuestIds.compactMap { gid in
                draft.guests.firstIndex(where: { $0.id == gid })
            }
            return (label: item.label, priceCents: item.priceCents, assignedSlots: slots)
        }
        return SplitMath.computeOwedCents(
            mode: mode,
            guests: guests,
            payerIndex: payerIndex,
            totalCents: draft.totalCents,
            perGuestActive: draft.perGuestCents,
            items: items,
            feesCents: draft.feesCents,
            taxCents: draft.taxCents,
            tipCents: draft.tipCents,
            discountCents: draft.discountCents
        )
    }

    private static func sendOwed(draft: SplitDraft, totalCents: Int) -> [Int] {
        let payload = SplitPayload.from(
            draft: draft,
            participantCount: draft.guests.count,
            totalCents: totalCents
        )
        return payload.o
    }

    private static func makeDraft(
        mode: SplitDraft.Mode,
        guestNames: [String],
        totalCents: Int,
        perGuestCents: [Int] = [],
        items: [SplitDraft.Item] = [],
        fees: Int = 0,
        tax: Int = 0,
        tip: Int = 0,
        discount: Int = 0,
        payerIndex: Int = 0
    ) -> SplitDraft {
        let guests = makeGuests(guestNames)
        return SplitDraft(
            guests: guests,
            payerGuestId: guests[payerIndex].id,
            mode: mode,
            totalCents: totalCents,
            perGuestCents: perGuestCents,
            items: items,
            feesCents: fees,
            taxCents: tax,
            tipCents: tip,
            discountCents: discount
        )
    }

    // MARK: - Pure math: equal split

    private static func testEqualSplitMath() {
        let draft = makeDraft(
            mode: .equally,
            guestNames: ["Alice", "Bob", "Charlie"],
            totalCents: 3000
        )
        let owed = inAppOwed(draft: draft)
        assert(owed == [1000, 1000, 1000], "equal split of 3000/3 should be 1000 each, got \(owed)")
        assert(owed.reduce(0, +) == 3000, "equal split must sum to total")
        print("  [PASS] testEqualSplitMath")
    }

    private static func testEqualSplitRemainderToFirst() {
        // 1001 / 3 = 333 with 2 remainder; first two guests should each get +1.
        let draft = makeDraft(
            mode: .equally,
            guestNames: ["Alice", "Bob", "Charlie"],
            totalCents: 1001
        )
        let owed = inAppOwed(draft: draft)
        assert(owed == [334, 334, 333], "1001/3 with remainder distribution should be [334,334,333], got \(owed)")
        assert(owed.reduce(0, +) == 1001, "must sum to total")
        print("  [PASS] testEqualSplitRemainderToFirst")
    }

    // MARK: - Pure math: custom split

    private static func testCustomSplitSumMatchesTotal() {
        let draft = makeDraft(
            mode: .custom,
            guestNames: ["Alice", "Bob"],
            totalCents: 5000,
            perGuestCents: [3000, 2000]
        )
        let owed = inAppOwed(draft: draft)
        assert(owed == [3000, 2000], "custom amounts should pass through, got \(owed)")
        assert(owed.reduce(0, +) == 5000)
        print("  [PASS] testCustomSplitSumMatchesTotal")
    }

    private static func testCustomSplitClampsDifferenceToPayer() {
        // Payer = Alice (index 0). perGuest sums to 4000 but total is 5000;
        // SplitMath.clampToTotal puts the +1000 difference on the payer.
        let draft = makeDraft(
            mode: .custom,
            guestNames: ["Alice", "Bob"],
            totalCents: 5000,
            perGuestCents: [2000, 2000],
            payerIndex: 0
        )
        let owed = inAppOwed(draft: draft)
        assert(owed == [3000, 2000], "payer should absorb +1000 to make sum=5000, got \(owed)")
        assert(owed.reduce(0, +) == 5000)
        print("  [PASS] testCustomSplitClampsDifferenceToPayer")
    }

    // MARK: - Pure math: by items

    private static func testByItemsSimple() {
        // Two items, one each. No extras. Total equals subtotal.
        let guests = makeGuests(["Alice", "Bob"])
        let items = [
            SplitDraft.Item(id: UUID(), label: "Burger",  priceCents: 1200, assignedGuestIds: [guests[0].id]),
            SplitDraft.Item(id: UUID(), label: "Salad",   priceCents:  800, assignedGuestIds: [guests[1].id]),
        ]
        let draft = SplitDraft(
            guests: guests,
            payerGuestId: guests[0].id,
            mode: .byItems,
            totalCents: 2000,
            perGuestCents: [],
            items: items,
            feesCents: 0, taxCents: 0, tipCents: 0, discountCents: 0
        )
        let owed = inAppOwed(draft: draft)
        assert(owed == [1200, 800], "by-items simple: each owes their item, got \(owed)")
        assert(owed.reduce(0, +) == 2000)
        print("  [PASS] testByItemsSimple")
    }

    private static func testByItemsWithSharedItemAndExtras() {
        // Alice: burger 1000. Bob: salad 1000. Shared appetizer 1000 (split evenly: 500/500).
        // Subtotals: Alice 1500, Bob 1500.
        // Tax 200 + tip 300 = 500 extras, allocated proportionally (50/50): 250 each.
        // Owed: Alice 1750, Bob 1750. Total 3500.
        let guests = makeGuests(["Alice", "Bob"])
        let items = [
            SplitDraft.Item(id: UUID(), label: "Burger",     priceCents: 1000, assignedGuestIds: [guests[0].id]),
            SplitDraft.Item(id: UUID(), label: "Salad",      priceCents: 1000, assignedGuestIds: [guests[1].id]),
            SplitDraft.Item(id: UUID(), label: "Appetizer",  priceCents: 1000, assignedGuestIds: [guests[0].id, guests[1].id]),
        ]
        let draft = SplitDraft(
            guests: guests,
            payerGuestId: guests[0].id,
            mode: .byItems,
            totalCents: 3500,
            perGuestCents: [],
            items: items,
            feesCents: 0, taxCents: 200, tipCents: 300, discountCents: 0
        )
        let owed = inAppOwed(draft: draft)
        assert(owed == [1750, 1750], "by-items with shared+extras should be [1750,1750], got \(owed)")
        assert(owed.reduce(0, +) == 3500)
        print("  [PASS] testByItemsWithSharedItemAndExtras")
    }

    // MARK: - In-app vs. send-path equivalence
    //
    // These are the regression sentinels for the bug where the bill card sent to
    // iMessage showed different per-person numbers than the in-app preview. The
    // contract is: when `draft.totalCents` matches the receipt total used at send
    // time, both code paths must produce identical owed arrays.

    private static func testSendPayloadMatchesInAppForEqual() {
        let draft = makeDraft(
            mode: .equally,
            guestNames: ["Me", "Bob", "Cat", "Dee"],
            totalCents: 9999
        )
        let inApp = inAppOwed(draft: draft)
        let send  = sendOwed(draft: draft, totalCents: draft.totalCents)
        assert(inApp == send, "equal-mode in-app vs send mismatch: \(inApp) vs \(send)")
        print("  [PASS] testSendPayloadMatchesInAppForEqual")
    }

    private static func testSendPayloadMatchesInAppForCustom() {
        let draft = makeDraft(
            mode: .custom,
            guestNames: ["Me", "Bob", "Cat"],
            totalCents: 6000,
            perGuestCents: [2500, 2000, 1500]
        )
        let inApp = inAppOwed(draft: draft)
        let send  = sendOwed(draft: draft, totalCents: draft.totalCents)
        assert(inApp == send, "custom-mode in-app vs send mismatch: \(inApp) vs \(send)")
        print("  [PASS] testSendPayloadMatchesInAppForCustom")
    }

    private static func testSendPayloadMatchesInAppForByItems() {
        let guests = makeGuests(["Me", "Bob"])
        let items = [
            SplitDraft.Item(id: UUID(), label: "Pizza", priceCents: 1800, assignedGuestIds: [guests[0].id, guests[1].id]),
            SplitDraft.Item(id: UUID(), label: "Beer",  priceCents:  600, assignedGuestIds: [guests[0].id]),
        ]
        let draft = SplitDraft(
            guests: guests,
            payerGuestId: guests[0].id,
            mode: .byItems,
            totalCents: 2700,  // 2400 subtotal + 100 tax + 200 tip
            perGuestCents: [],
            items: items,
            feesCents: 0, taxCents: 100, tipCents: 200, discountCents: 0
        )
        let inApp = inAppOwed(draft: draft)
        let send  = sendOwed(draft: draft, totalCents: draft.totalCents)
        assert(inApp == send, "by-items in-app vs send mismatch: \(inApp) vs \(send)")
        print("  [PASS] testSendPayloadMatchesInAppForByItems")
    }

    /// Regression sentinel for the original bug: if the send path is handed a
    /// `totalCents` that doesn't match the draft (e.g. EditReceiptView changed
    /// the override total but `onTipChanged` only adjusted by tip-delta), the
    /// payer's owed amount silently absorbs the difference and the on-card
    /// numbers diverge from the in-app preview. The fix keeps them in sync via
    /// `reconcileSplitDraftWithLiveReceipt`; this test pins the failure mode so
    /// regressions are visible.
    private static func testStaleDraftTotalCorruptsPayerOwed() {
        let draft = makeDraft(
            mode: .custom,
            guestNames: ["Me", "Bob"],
            totalCents: 5000,
            perGuestCents: [2500, 2500],
            payerIndex: 0
        )
        let inApp = inAppOwed(draft: draft)
        // Pretend the receipt's total drifted +1000 (e.g. user added an override)
        // but the draft was never reconciled.
        let staleSend = sendOwed(draft: draft, totalCents: 6000)
        assert(inApp == [2500, 2500])
        assert(staleSend == [3500, 2500],
               "stale total should push +1000 onto payer (regression sentinel), got \(staleSend)")
        assert(inApp != staleSend, "this divergence is the bug — keep draft.totalCents synced")
        // And the consistent-input case still matches:
        let consistentSend = sendOwed(draft: draft, totalCents: draft.totalCents)
        assert(inApp == consistentSend, "with synced totals, in-app and send must agree")
        print("  [PASS] testStaleDraftTotalCorruptsPayerOwed")
    }

    /// End-to-end: build a draft, run it through `SplitPayload.from`, and verify
    /// the payload's metadata round-trips correctly (mode, guests, payer index,
    /// breakdown fields, total).
    private static func testRoundTripDraftThroughSendPath() {
        let draft = makeDraft(
            mode: .equally,
            guestNames: ["Me", "Bob", "Cat"],
            totalCents: 3300,
            tax: 100,
            tip: 200,
            payerIndex: 1
        )
        let payload = SplitPayload.from(
            draft: draft,
            participantCount: 3,
            totalCents: draft.totalCents
        )
        assert(payload.m == .equally, "mode round-trip failed")
        assert(payload.g.count == 3, "guest count round-trip failed")
        assert(payload.pi == 1, "payer index round-trip failed, got \(payload.pi)")
        assert(payload.tot == 3300, "total round-trip failed")
        assert(payload.tx == 100, "tax round-trip failed")
        assert(payload.tip == 200, "tip round-trip failed")
        assert(payload.o.reduce(0, +) == 3300, "owed must sum to total, got \(payload.o)")
        print("  [PASS] testRoundTripDraftThroughSendPath")
    }
}
#endif
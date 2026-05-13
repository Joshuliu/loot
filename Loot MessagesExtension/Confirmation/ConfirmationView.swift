import SwiftUI
import UIKit

struct ConfirmationView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var receiptDraftVM: ReceiptDraftViewModel
    @ObservedObject var tabContextVM: TabContextViewModel
    @StateObject var splitEditorVM: SplitEditorViewModel

    let receiptName: String
    let amount: String
    let participantCount: Int
    let splitMode: SplitDraft.Mode?
    let splitDraft: SplitDraft?

    let tipAmount: String
    let cameFromManual: Bool

    let onBack: () -> Void
    let onSend: () -> Void

    let onDeleteToLanding: () -> Void
    let onGoToSplit: () -> Void
    let onAddTip: () -> Void
    let onTipChanged: (String, String) -> Void  // (tipAmount, newTotal)
    let onSelectMode: (SplitDraft.Mode) -> Void
    let onGuestsChanged: ([Person], Set<PersonID>, PersonID) -> Void  // (guests, includedIDs, payerID)
    let collapsedHeight: CGFloat = 132
    let onRequestCollapse: () -> Void
    let onRequestExpand: () -> Void

    init(
        coordinator: AppCoordinator,
        receiptDraftVM: ReceiptDraftViewModel,
        tabContextVM: TabContextViewModel,
        receiptName: String,
        amount: String,
        participantCount: Int,
        splitMode: SplitDraft.Mode?,
        splitDraft: SplitDraft?,
        tipAmount: String,
        cameFromManual: Bool,
        onBack: @escaping () -> Void,
        onSend: @escaping () -> Void,
        onDeleteToLanding: @escaping () -> Void,
        onGoToSplit: @escaping () -> Void,
        onAddTip: @escaping () -> Void,
        onTipChanged: @escaping (String, String) -> Void,
        onSelectMode: @escaping (SplitDraft.Mode) -> Void,
        onGuestsChanged: @escaping ([Person], Set<PersonID>, PersonID) -> Void,
        onRequestCollapse: @escaping () -> Void,
        onRequestExpand: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.receiptDraftVM = receiptDraftVM
        self.tabContextVM = tabContextVM
        self.receiptName = receiptName
        self.amount = amount
        self.participantCount = participantCount
        self.splitMode = splitMode
        self.splitDraft = splitDraft
        self.tipAmount = tipAmount
        self.cameFromManual = cameFromManual
        self.onBack = onBack
        self.onSend = onSend
        self.onDeleteToLanding = onDeleteToLanding
        self.onGoToSplit = onGoToSplit
        self.onAddTip = onAddTip
        self.onTipChanged = onTipChanged
        self.onSelectMode = onSelectMode
        self.onGuestsChanged = onGuestsChanged
        self.onRequestCollapse = onRequestCollapse
        self.onRequestExpand = onRequestExpand
        // The VM holds split-editor @Published state (mode, guests, included,
        // amounts, etc.) and the math/mutation logic that used to live as
        // `extension ConfirmationView`. @FocusState properties remain on the
        // view because property wrappers tied to focus only work on Views.
        _splitEditorVM = StateObject(wrappedValue: SplitEditorViewModel(
            receiptDraftVM: receiptDraftVM,
            tabContextVM: tabContextVM,
            onSelectModeBroadcast: onSelectMode,
            onGuestsChangedBroadcast: onGuestsChanged
        ))
    }

    var isLoadingItems: Bool {
        receiptDraftVM.itemsLoadingState.isLoading
    }

    @State private var cardOffset: CGSize = .zero
    @State private var cardRotation: Double = 0
    @State private var hasSent: Bool = false
    @State private var showSuccess: Bool = false
    @State private var dragIntent: BillCardDragIntent = .none
    @State private var isBottomHeaderExpanded: Bool = false
    @State private var showTipPanel: Bool = false

    // Focus state stays on the view — @FocusState cannot live on an
    // ObservableObject. View methods that wire focus into TextFields read
    // from the VM but bind their `.focused(...)` modifiers to these.
    @FocusState var isAmountFieldFocused: Bool
    @FocusState var guestNameFocusedID: PersonID?

    @State private var keyboardHeight: CGFloat = 0
    @State private var billCardRefreshNonce: Int = 0
    @State private var billCardBounceYOffset: CGFloat = 0
    @State private var billCardBounceToken: Int = 0
    @State var introAnimationDone: Bool = false
    @State var showEditReceipt: Bool = false
    /// Item ID currently presenting the split-denominator picker, or nil if hidden.
    @State var splitPickerItemId: UUID? = nil
    /// Non-obstructive toast shown after Save when there are still unclaimed
    /// item cents in non-claim byItems mode — surfaces the "remaining items
    /// split evenly" rule that the bill card will apply.
    @State var showSplitEvenlyBanner: Bool = false


//    private let collapsedHeight: CGFloat = 60

    private func clamp01(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }

    private var upProgress: CGFloat {
        dragIntent == .up ? clamp01((-cardOffset.height) / 180) : 0
    }
    private var leftProgress: CGFloat {
        dragIntent == .left ? clamp01((-cardOffset.width) / 180) : 0
    }
    private var rightProgress: CGFloat {
        dragIntent == .right ? clamp01((cardOffset.width) / 180) : 0
    }
    private var downProgress: CGFloat {
        dragIntent == .down ? clamp01((cardOffset.height) / 180) : 0
    }

    var buttonBase: Color { Color(.secondarySystemBackground) }
    private var gold: Color { Color(hex: "#DAA806") }

    private var shouldShowSendCue: Bool {
        dragIntent == .none && !receiptDraftVM.isLoadingReceipt && !isLoadingItems && !hasSent
    }

    private var guidanceText: String {
        if dragIntent == .left { return "Swipe left to delete" }
        if dragIntent == .right { return "Swipe right to tip" }
        if dragIntent == .down { return "Swipe down for split options" }
        if receiptDraftVM.isLoadingReceipt { return "Swipe left to delete" }
        if isLoadingItems { return "Swipe up to send without items" }
        return "To send, swipe the receipt card up"
    }

    private var buttonsOpacity: Double {
        if dragIntent == .up { return Double(1 - upProgress) }
        // drag left: fade everything except trash button (if it is trash)
        if dragIntent == .left { return Double(1 - leftProgress) }
        // drag right: fade everything except modify (split) button
        if dragIntent == .right { return Double(1 - rightProgress) }
        if dragIntent == .down { return Double (1 - downProgress) }
        return 1
    }

    // Left button “selected” styling when trash + dragging left
    private var trashSelectProgress: CGFloat {
        dragIntent == .left ? leftProgress : 0
    }

    private var splitLabel: String {
        switch splitMode {
        case .byItems: return "Split by items"
        case .custom: return "Custom split"
        case .equally, .none: return "Split evenly"
        }
    }
    private var splitType: String {
        switch splitMode {
        case .byItems: return "Items"
        case .custom: return "Custom"
        case .equally, .none: return "Equal"
        }
    }
    private var displayAmount: String { "$" + formatAmount(amount) }
    private var hasTip: Bool {
        !tipAmount.isEmpty && tipAmount != "$0" && tipAmount != "$0.00"
    }

    private var owedAmounts: [Int]? {
        SplitMath.owedFromDraft(
            splitDraft,
            fallbackTotalCents: stringToCents(amount),
            participantCount: participantCount
        )
    }

    var totalCents: Int {
        if let draft = splitDraft, draft.totalCents > 0 {
            return draft.totalCents
        }
        return stringToCents(amount)
    }

    // MARK: - onAppear / onChange helpers (extracted to keep body's
    // type-checker workload bounded — three onChange closures plus an
    // inline seeding block was past the limit).

    private func notifyGuestsChanged() {
        onGuestsChanged(splitEditorVM.draftGuests, splitEditorVM.draftIncludedIDs, splitEditorVM.draftPayerID)
    }

    private func handleOnAppear() {
        cardOffset = .zero
        cardRotation = 0
        hasSent = false
        showSuccess = false
        billCardBounceToken += 1
        billCardBounceYOffset = 0

        // Reset loading animation state each time screen appears.
        // For manual entry, skip loading card immediately.
        if cameFromManual || !receiptDraftVM.isLoadingReceipt {
            introAnimationDone = true
        } else {
            introAnimationDone = false
        }

        // Refresh the VM's stored closures in case the parent view's @State
        // captures changed since this view was first created. Stored
        // @StateObject persists across re-renders; the closures need to
        // pick up the current capture context.
        splitEditorVM.onSelectModeBroadcast = onSelectMode
        splitEditorVM.onGuestsChangedBroadcast = onGuestsChanged

        seedDraftGuestsIfNeeded()
        splitEditorVM.initializeSplitState(
            splitDraft: splitDraft,
            participantCount: participantCount,
            totalCents: totalCents
        )
    }

    private func handleKeyboardWillShow(_ notif: Notification) {
        if let frame = notif.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            keyboardHeight = frame.height
        }
    }

    private func handleConfirmedChange(_ newValue: Bool) {
        guard newValue else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            splitEditorVM.splitModesExpanded = false
        }
    }

    private func handleIsExpandedChange(_ isNowExpanded: Bool) {
        // When collapsing while mid-edit, commit so the ZStack is never empty
        if !isNowExpanded && !splitEditorVM.confirmed {
            splitEditorVM.confirmed = true
            splitEditorVM.splitModesExpanded = false
        }
    }

    private func handleAmountChange(_ newAmount: String) {
        billCardRefreshNonce += 1
        let newTotal = stringToCents(newAmount)
        // When Phase 1 completes and the total arrives, recalculate amounts if they
        // were seeded as zeros (because the view appeared before the total was known).
        guard newTotal > 0,
              splitEditorVM.guestAmountsCents.allSatisfy({ $0 == 0 }),
              !splitEditorVM.guests.isEmpty else { return }
        switch splitEditorVM.mode {
        case .equally, .custom:
            splitEditorVM.guestAmountsCents = splitCentsEvenly(total: newTotal, count: splitEditorVM.activeCount)
        case .byItems:
            break
        }
    }

    private func handleItemsLoadingStateChange(isNowLoading: Bool) {
        guard !isNowLoading else { return }
        billCardRefreshNonce += 1
        if receiptDraftVM.itemsLoadingState.value != nil {
            triggerBillCardBounce()
        }
        // Phase 2 just finished. Re-seed items immediately if already in byItems mode,
        // otherwise reset the flag so entering byItems mode later will seed from real data.
        if splitEditorVM.mode == .byItems {
            splitEditorVM.seedByItemsFromReceipt()
        } else {
            splitEditorVM.didInitByItem = false
        }
    }

    private func seedDraftGuestsIfNeeded() {
        guard splitEditorVM.draftGuests.isEmpty else { return }

        if let draft = splitDraft, !draft.guests.isEmpty {
            splitEditorVM.draftGuests = draft.guests
            splitEditorVM.draftIncludedIDs = draft.includedIDs
            splitEditorVM.draftPayerID = draft.payerID
            return
        }

        let myUid = KeychainHelper.getOrCreateUserId()

        if let tab = tabContextVM.activeTab {
            let seeded: [Person] = tab.members.filter(\.isActive).map { member in
                let uid = (member.userId?.isEmpty == false) ? member.userId! : member.memberId
                return Person.identified(userId: uid, displayName: member.displayName)
            }
            splitEditorVM.draftGuests = seeded
            splitEditorVM.draftIncludedIDs = Set(seeded.map(\.id))
            splitEditorVM.draftPayerID = seeded.first(where: { $0.isMe(localUserId: myUid) })?.id
                ?? seeded.first?.id
                ?? PersonID(rawValue: myUid)
            return
        }

        let meName = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
        var seeded: [Person] = [Person.identified(userId: myUid, displayName: meName)]
        if participantCount > 1 {
            for _ in 1..<participantCount {
                seeded.append(Person.newGuest(displayName: ""))
            }
        }
        splitEditorVM.draftGuests = seeded
        splitEditorVM.draftIncludedIDs = Set(seeded.map(\.id))
        splitEditorVM.draftPayerID = seeded.first?.id ?? PersonID(rawValue: myUid)
    }

    private func formatAmount(_ str: String) -> String {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "0.00" }

        // normalize to 2 decimals if user typed decimals
        if trimmed.contains(".") {
            let parts = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let dollars = parts.first ?? "0"
            let centsRaw = parts.count > 1 ? String(parts[1]) : ""
            let cents2 = centsRaw.padding(toLength: 2, withPad: "0", startingAt: 0)
            return "\(dollars).\(String(cents2.prefix(2)))"
        } else {
            return "\(trimmed).00"
        }
    }

    @ViewBuilder
    private func expandedBody() -> some View {
        VStack(spacing: 12) {
            Text("Additional split options will appear here")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Up-swipe outcome handed to ReceiptCardView. The card animation already
    /// fired by the time we get here; we just trigger the success overlay and
    /// the parent send callback.
    private func performSwipeUpSend() {
        withAnimation(.easeInOut(duration: 0.2)) { showSuccess = true }
        onSend()
    }

    /// Down-swipe (and Edit-Split-button) outcome: enter the split editor
    /// expanded state. Order mirrors the historical inline gesture body.
    private func performSwipeDownExpand() {
        splitEditorVM.splitModesExpanded = true
        onRequestExpand()
        splitEditorVM.captureSnapshot()
        splitEditorVM.selectMode(splitEditorVM.mode, totalCents: totalCents)
        splitEditorVM.confirmed = false
    }

    /// Right-swipe outcome: open the tip panel.
    private func performSwipeRightTip() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            showTipPanel = true
        }
    }

    private func animateDeleteThenAct() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            cardOffset = CGSize(width: -500, height: 0)
            cardRotation = -6
        }

        // Ensure transient tip edits are cleared before we reset to landing.
        // This keeps parent state (`tipAmount`, receipt tip cents, and split draft tip)
        // from leaking into the next receipt flow.
        let resetTotalCents = max(0, stringToCents(amount) - stringToCents(tipAmount))
        onTipChanged("0", centsToDecimalString(resetTotalCents))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onDeleteToLanding()
        }
    }

    /// Tap-Add-Tip outcome: matches the right-swipe gesture's animation
    /// before opening the tip panel. Used by the BillActionButtons row.
    private func animateAddTipThenAct() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            cardOffset = CGSize(width: 500, height: 0)
            cardRotation = 6
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            performSwipeRightTip()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                cardOffset = .zero
                cardRotation = 0
            }
        }
    }

    /// Tap-Edit-Split outcome: matches the down-swipe gesture. Skips the
    /// drop-down card animation when the drawer is already expanded (the
    /// panel will swallow the card visually anyway).
    private func animateEditSplitThenAct() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        if !coordinator.isExpanded {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                cardOffset = CGSize(width: 0, height: 500)
                cardRotation = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            performSwipeDownExpand()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                cardOffset = .zero
                cardRotation = 0
            }
        }
    }

    private func triggerBillCardBounce() {
        guard !hasSent else { return }
        billCardBounceToken += 1
        let token = billCardBounceToken
        billCardBounceYOffset = 0

        withAnimation(.easeOut(duration: 0.18)) {
            billCardBounceYOffset = -18
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard billCardBounceToken == token else { return }
            withAnimation(.easeIn(duration: 0.14)) {
                billCardBounceYOffset = 8
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                guard billCardBounceToken == token else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) {
                    billCardBounceYOffset = 0
                }
            }
        }
    }

    // MARK: - Tip Panel (delegates to shared TipPanelView)
    private func tipPanel() -> some View {
        let preTip = stringToCents(amount) - stringToCents(tipAmount)
        let existing = stringToCents(tipAmount)
        return TipPanelView(
            preTipTotalCents: preTip,
            existingTipCents: existing,
            isExpanded: coordinator.isExpanded,
            onBack: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    showTipPanel = false
                }
            },
            onApply: { tipStr, totalStr in
                onTipChanged(tipStr, totalStr)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    showTipPanel = false
                }
            }
        )
    }

    // MARK: - Confirmation Panel (card + swipe-to-send + bottom buttons)
    private func confirmationPanel() -> some View {
        let cardScale: CGFloat = !coordinator.isExpanded ? 0.9 : 0.9 //1.1
        let cardH: CGFloat = 160 * cardScale

        return VStack(spacing: 0) {
            if coordinator.isExpanded {
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            Text(guidanceText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.top, 10)

            if shouldShowSendCue {
                SendCueView()
                    .padding(.top, 10)
            } else {
                Color.clear.frame(height: 28)
            }

            ReceiptCardView(
                receiptName: receiptName,
                displayAmount: displayAmount,
                payerName: splitEditorVM.payerDisplayName(),
                splitLabel: splitLabel,
                owedAmounts: owedAmounts,
                totalCents: totalCents,
                tabName: tabContextVM.activeTab?.name,
                tabColorHex: tabContextVM.activeTab?.colorHex,
                participantCount: participantCount,
                isLoadingReceipt: receiptDraftVM.isLoadingReceipt,
                isLoadingItems: isLoadingItems,
                cardScale: cardScale,
                cardHeight: cardH,
                billCardRefreshNonce: billCardRefreshNonce,
                arrowHintsOpacity: buttonsOpacity,
                cardOffset: $cardOffset,
                cardRotation: $cardRotation,
                dragIntent: $dragIntent,
                hasSent: $hasSent,
                introAnimationDone: $introAnimationDone,
                billCardBounceYOffset: $billCardBounceYOffset,
                onSwipeUpSend: { performSwipeUpSend() },
                onSwipeLeftDelete: { onDeleteToLanding() },
                onSwipeRightTip: { performSwipeRightTip() },
                onSwipeDownExpand: { performSwipeDownExpand() },
                onTap: {
                    // Don't open the editor while Phase 1 is still running —
                    // there's no real receipt to edit yet, and the prompt text
                    // below already reads "Loading receipt items..." rather
                    // than "Tap to edit receipt" during this window.
                    guard !receiptDraftVM.isLoadingReceipt else { return }
                    showEditReceipt = true
                }
            )

            VStack(spacing: 6) {
                Text(isLoadingItems ? "Loading receipt items..." : "Tap to edit receipt")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 12)
            .opacity(buttonsOpacity)

            if coordinator.isExpanded { Spacer(minLength: 0) }

            Group {
                if splitEditorVM.splitModesExpanded {
                    splitModePicker(closesExpanded: true, capturesSnapshot: true)
                        .padding(.bottom, 7)
                } else {
                    BillActionButtons(
                        hasTip: hasTip,
                        tipAmount: tipAmount,
                        isTipDisabled: displayAmount == "$0" || amount.isEmpty || amount == "0" || receiptDraftVM.isLoadingReceipt,
                        trashProgress: dragIntent == .left ? leftProgress : 0,
                        splitProgress: dragIntent == .down ? downProgress : 0,
                        tipProgress: dragIntent == .right ? rightProgress : 0,
                        isLeftDrag: dragIntent == .left,
                        isDownDrag: dragIntent == .down,
                        isRightDrag: dragIntent == .right,
                        buttonsOpacity: buttonsOpacity,
                        buttonBase: buttonBase,
                        gold: gold,
                        onTrash: { animateDeleteThenAct() },
                        onEditSplit: { animateEditSplitThenAct() },
                        onAddTip: { animateAddTipThenAct() }
                    )
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 16)
            .animation(.spring(response: 0.35, dampingFraction: 0.9), value: splitEditorVM.splitModesExpanded)

        }
    }

    @ViewBuilder private var panelViews: some View {
        // Donut panel (equally / custom)
        if coordinator.isExpanded && splitEditorVM.confirmed == false && (splitEditorVM.mode == .equally || splitEditorVM.mode == .custom) {
            byGuestPanel(
                interactive: splitEditorVM.mode == .custom
            )
            .padding(.horizontal, 24)
            .padding(.top, 6)
        }
        // Items panel
        if coordinator.isExpanded && splitEditorVM.confirmed == false && splitEditorVM.mode == .byItems {
            byItemPanel()
                .padding(.horizontal, 24)
                .padding(.top, 6)
        }
        // Tip panel
        if showTipPanel {
            tipPanel()
        }
        // Confirmation card: always in compact mode, or when confirmed in expanded mode
        if (splitEditorVM.confirmed == true || !coordinator.isExpanded) && !showTipPanel {
            confirmationPanel()
                .padding(.top, 10)
        }
    }

    var body: some View {
        GeometryReader { geo in
            bodyStack(panelH: min(geo.size.height * 0.55, 500),
                      topPad: coordinator.isExpanded ? 20 : 4)
        }
    }

    @ViewBuilder
    private func bodyStack(panelH: CGFloat, topPad: CGFloat) -> some View {
        ZStack {
            mainScrollContent(panelH: panelH, topPad: topPad)
            keyboardOverlay
            successOverlay
            splitEvenlyBannerOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { dragBackground }
        .ignoresSafeArea()
        .ignoresSafeArea(edges: .bottom)
        .animation(.easeInOut(duration: 0.12), value: dragIntent)
        .animation(.easeInOut(duration: 0.12), value: cardOffset)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification), perform: handleKeyboardWillShow)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardHeight = 0 }
        .task { onRequestCollapse() }
        .onAppear(perform: handleOnAppear)
        .onChange(of: splitEditorVM.draftGuests) { _, _ in notifyGuestsChanged() }
        .onChange(of: splitEditorVM.draftIncludedIDs) { _, _ in notifyGuestsChanged() }
        .onChange(of: splitEditorVM.draftPayerID) { _, _ in notifyGuestsChanged() }
        .onChange(of: splitEditorVM.confirmed) { _, newValue in handleConfirmedChange(newValue) }
        .onChange(of: coordinator.isExpanded) { _, isNowExpanded in handleIsExpandedChange(isNowExpanded) }
        .onChange(of: amount) { _, newAmount in handleAmountChange(newAmount) }
        .onChange(of: receiptDraftVM.isLoadingReceipt) { _, isNowLoading in
            if !isNowLoading { introAnimationDone = true }
        }
        .onChange(of: receiptDraftVM.itemsLoadingState.isLoading) { _, isNowLoading in
            handleItemsLoadingStateChange(isNowLoading: isNowLoading)
        }
        .onChange(of: introAnimationDone) { _, isDone in handleIntroAnimationDoneChange(isDone) }
        .onChange(of: liveTabMembersFingerprint) { _, _ in mergeLiveTabMembers() }
        .onChange(of: splitEditorVM.isEditingAmount) { _, isNow in
            // The VM owns the editing state; @FocusState lives on the view.
            // Sync the focus binding to whatever the VM decided.
            isAmountFieldFocused = isNow
        }
        .sheet(isPresented: $showEditReceipt) { editReceiptSheet }
    }

    /// Identity for the live tab's member set. Cheap, value-typed, and
    /// type-inferred without optional chaining gymnastics — keeps SwiftUI's
    /// `.onChange(of:)` away from the type-checker timeout that
    /// `tabContextVM.activeTab?.members` triggers when threaded through the long
    /// `bodyStack` modifier chain.
    private var liveTabMembersFingerprint: String {
        guard let tab = tabContextVM.activeTab else { return "" }
        return tab.members
            .map { "\($0.memberId):\($0.displayName):\($0.isActive ? 1 : 0)" }
            .joined(separator: "|")
    }

    /// When `tabContextVM.activeTab` updates (e.g. another participant accepted the
    /// invite mid-flow), append any newly-arrived tab members into the working
    /// guest lists so the user doesn't have to bail out and restart the
    /// receipt. Existing guests are preserved verbatim — this is additive only.
    private func mergeLiveTabMembers() {
        guard let tab = tabContextVM.activeTab else { return }
        let existingUserIds = Set(splitEditorVM.draftGuests.compactMap(\.userId))
        let newMembers = tab.members.filter { member in
            guard member.isActive else { return false }
            let uid = (member.userId?.isEmpty == false) ? member.userId! : member.memberId
            return !existingUserIds.contains(uid)
        }
        guard !newMembers.isEmpty else { return }
        let newPersons: [Person] = newMembers.map { member in
            let uid = (member.userId?.isEmpty == false) ? member.userId! : member.memberId
            return Person.identified(userId: uid, displayName: member.displayName)
        }
        splitEditorVM.draftGuests.append(contentsOf: newPersons)
        splitEditorVM.draftIncludedIDs.formUnion(newPersons.map(\.id))
        // Also reflect the new members into the split-panel mirror (which
        // initializeSplitState() set from draftGuests on first appear and is
        // otherwise independent until applyGuestEdits()).
        splitEditorVM.guests.append(contentsOf: newPersons)
        splitEditorVM.includedIDs.formUnion(newPersons.map(\.id))
        splitEditorVM.ensureGuestArrays()
    }

    @ViewBuilder
    private func mainScrollContent(panelH: CGFloat, topPad: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Single ZStack keeps view identity so animations survive the
                // compact↔expanded transition. In expanded, minHeight==maxHeight==panelH
                // pins the frame (Spacer fills, buttons land at a consistent position).
                // In compact, min=0/max=∞ lets it size naturally so nothing gets clipped.
                ZStack(alignment: .top) { panelViews }
                    .frame(
                        minHeight: coordinator.isExpanded ? panelH : 0,
                        maxHeight: coordinator.isExpanded ? panelH : .infinity
                    )

                if coordinator.isExpanded {
                    guestList()
                        .padding(.horizontal, 10)
                        .padding(.top, 16)
                        .padding(.bottom, 50)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.top, topPad)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var keyboardOverlay: some View {
        // Amount editing overlay — follows keyboard by offsetting up
        VStack {
            Spacer()
            amountEditingOverlay()
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.9), value: splitEditorVM.isEditingAmount)
        }
        .offset(y: -keyboardHeight)
        .animation(.easeOut(duration: 0.22), value: keyboardHeight)
        .ignoresSafeArea(edges: .bottom)
    }

    @ViewBuilder
    private var successOverlay: some View {
        if showSuccess {
            VStack {
                Text("Sent!")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(hex: "#06A77D"))
            .transition(.opacity)
        }
    }

    /// Non-obstructive toast that surfaces after Save when items are left
    /// unassigned in non-claim byItems mode. Anchored to the top of the screen
    /// so it doesn't cover the bill card; auto-dismisses ~3.5s after Save.
    @ViewBuilder
    private var splitEvenlyBannerOverlay: some View {
        if showSplitEvenlyBanner {
            VStack {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("Remaining items split evenly between guests.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.78))
                )
                .padding(.horizontal, 24)
                .padding(.top, 12)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var dragBackground: some View {
        ZStack {
            Color.black.opacity(0.10)
            Color(hex: "#06A77D").opacity(dragBackgroundOpacity(for: .up))
            Color(hex: "#C76767").opacity(dragBackgroundOpacity(for: .left))
            Color(hex: "#5f8bc9").opacity(dragBackgroundOpacity(for: .right))
            Color(hex: "#D5C67A").opacity(dragBackgroundOpacity(for: .down))
        }
    }

    private func dragBackgroundOpacity(for intent: BillCardDragIntent) -> Double {
        guard dragIntent == intent else { return 0 }
        switch intent {
        case .up: return Double(upProgress)
        case .left: return Double(leftProgress)
        case .right: return Double(rightProgress)
        case .down: return Double(downProgress)
        case .none: return 0
        }
    }

    @ViewBuilder
    private var editReceiptSheet: some View {
        EditReceiptView(
            coordinator: coordinator,
            receiptDraftVM: receiptDraftVM,
            onSave: handleEditReceiptSave,
            onCancel: { showEditReceipt = false }
        )
    }

    private func handleEditReceiptSave(_ updatedReceipt: ReceiptDisplay) {
        let updatedTipAmount = updatedReceipt.tipCents > 0
            ? centsToDecimalString(updatedReceipt.tipCents)
            : ""
        onTipChanged(updatedTipAmount, centsToDecimalString(updatedReceipt.totalCents))
        // Keep byItemItems in sync even when currently in equally/custom mode.
        // Otherwise, switching to by-items after editing receipt fields can show
        // stale labels/prices until the user re-opens edit-receipt from by-items.
        var matched = Set<UUID>()
        splitEditorVM.byItemItems = updatedReceipt.items.map { newItem in
            if let existing = splitEditorVM.byItemItems.first(where: {
                $0.label == newItem.label && !matched.contains($0.id)
            }) {
                matched.insert(existing.id)
                var updated = existing
                updated.priceText = Money(cents: newItem.priceCents).inputString
                return updated
            }
            return LineItemForm(
                id: UUID(),
                label: newItem.label,
                priceText: Money(cents: newItem.priceCents).inputString,
                assignedGuestIds: []
            )
        }
        splitEditorVM.didInitByItem = true
        receiptDraftVM.currentReceipt = updatedReceipt
        // Sync splitDraft fields from the edited receipt.
        if var draft = receiptDraftVM.currentSplitDraft {
            draft.feesCents = updatedReceipt.feesCents
            draft.discountCents = updatedReceipt.discountCents
            draft.taxCents = updatedReceipt.taxCents
            draft.tipCents = updatedReceipt.tipCents
            draft.totalCents = updatedReceipt.totalCents
            draft.items = splitEditorVM.byItemItems
                .filter { $0.isComplete }
                .map { item in
                    SplitDraft.Item(
                        id: item.id,
                        label: item.label,
                        priceCents: item.priceCents,
                        assignedGuestIds: item.assignedGuestIds.sorted { $0.rawValue < $1.rawValue }
                    )
                }
            receiptDraftVM.currentSplitDraft = draft
        }
        // In by-items mode, also run the canonical sync path so owed/ring state
        // updates immediately while the panel is open.
        if splitEditorVM.mode == .byItems {
            splitEditorVM.syncByItemsToSplitDraft(totalCents: totalCents, tipAmount: tipAmount)
        }
        showEditReceipt = false
    }

    private func handleIntroAnimationDoneChange(_ isDone: Bool) {
        guard isDone else { return }
        SwipeHintAnimator.play(
            cardOffset: $cardOffset,
            cardRotation: $cardRotation,
            isCancelled: { hasSent }
        )
    }
}

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)

        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

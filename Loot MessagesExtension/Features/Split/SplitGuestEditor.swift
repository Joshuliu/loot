import SwiftUI

// MARK: - Guest model used by SplitView

struct SplitGuest: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var isIncluded: Bool
    var isMe: Bool
    var uid: String?

    init(id: UUID = UUID(), name: String = "", isIncluded: Bool = true, isMe: Bool = false, uid: String? = nil) {
        self.id = id
        self.name = name
        self.isIncluded = isIncluded
        self.isMe = isMe
        self.uid = uid
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Bottom bar
enum GuestEditorMode { case splitWith, paidBy }

struct SplitGuestDrawer: View {
    // Drawer state
    @Binding var isExpanded: Bool
    @Binding var mode: GuestEditorMode?

    // Working draft bindings (changes auto-save via bindings)
    @Binding var guests: [Person]
    @Binding var includedIDs: Set<PersonID>
    @Binding var payerID: PersonID

    private let collapsedHeight: CGFloat = 132

    @FocusState private var focusedGuestID: PersonID?
    @State private var pendingPayerID: PersonID?  // Track guest we're trying to make payer (waiting for name)

    // Keyboard height tracking
    @State private var keyboardHeight: CGFloat = 0

    private var localUserId: String { KeychainHelper.getOrCreateUserId() }

    // MARK: - Header computed values
    private var splitCount: Int { includedIDs.count }
    private var payerName: String {
        if let g = guests.first(where: { $0.id == payerID }) {
            if g.isMe(localUserId: localUserId) { return "Me" }
            let trimmed = g.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Select payer" : trimmed
        }
        return "Select payer"
    }

    private func sheetHeight(maxH: CGFloat) -> CGFloat {
        let rowH: CGFloat = 58
        let addRowH: CGFloat = (mode == .some(.splitWith)) ? 48 : 8
        let bottomPadding: CGFloat = 40
        let estimated = collapsedHeight + addRowH + (rowH * CGFloat(guests.count)) + bottomPadding

        // Don't reduce height for keyboard - we'll offset instead
        return min(maxH, estimated)
    }

    // MARK: - Guest helpers
    private func defaultLabel(for index: Int) -> String {
        if index == 0 { return "Me" }
        return "Guest \(index + 1)"
    }

    private func addGuest() {
        let new = Person.newGuest(displayName: "")
        guests.append(new)
        includedIDs.insert(new.id)
    }

    private func removeGuest(at index: Int) {
        guard guests.indices.contains(index),
              !guests[index].isMe(localUserId: localUserId)
        else { return }
        let removedId = guests[index].id
        guests.remove(at: index)
        includedIDs.remove(removedId)

        if payerID == removedId {
            if let me = guests.first(where: { $0.isMe(localUserId: localUserId) }) { payerID = me.id }
            else if let first = guests.first { payerID = first.id }
        }
    }

    private func toggleMode(_ m: GuestEditorMode) {
        // Check pending payer before any mode change
        checkPendingPayerChange()

        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            if mode == m {
                // pressing same button again -> turn off + collapse
                mode = nil
                isExpanded = false
                focusedGuestID = nil  // Dismiss keyboard
            } else {
                // switch to other mode -> expand
                mode = m
                isExpanded = true
                focusedGuestID = nil  // Dismiss keyboard when switching
            }
        }
    }

    private func toggleIncluded(at index: Int) {
        guard guests.indices.contains(index) else { return }
        let g = guests[index]
        let isIncluded = includedIDs.contains(g.id)
        if isIncluded && includedIDs.count <= 1 { return } // keep at least 1

        if isIncluded {
            includedIDs.remove(g.id)
        } else {
            includedIDs.insert(g.id)
        }

        // if payer excluded, move payer to an included guest
        if !includedIDs.contains(payerID) {
            if let me = guests.first(where: { $0.isMe(localUserId: localUserId) && includedIDs.contains($0.id) }) {
                payerID = me.id
            } else if let first = guests.first(where: { includedIDs.contains($0.id) }) {
                payerID = first.id
            }
        }
    }

    private func tapPaidBy(at index: Int) {
        guard guests.indices.contains(index) else { return }
        let g = guests[index]
        let trimmed = g.displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        // If guest has no name and isn't "Me", focus field and set as pending payer
        if trimmed.isEmpty && !g.isMe(localUserId: localUserId) {
            pendingPayerID = g.id
            // Defer focus slightly so TextField disabled state updates first
            DispatchQueue.main.async {
                focusedGuestID = g.id
            }
            return
        }

        // Guest has a name (or is "Me"), set as payer immediately
        includedIDs.insert(g.id)
        payerID = g.id
        pendingPayerID = nil  // Clear any pending payer
    }

    // MARK: - Keyboard navigation
    private func focusNextGuest(after currentId: PersonID) {
        guard let currentIndex = guests.firstIndex(where: { $0.id == currentId }) else { return }

        // Find next editable guest (excluding "Me")
        let nextEditableIndex = guests[(currentIndex + 1)...].firstIndex { guest in
            !guest.isMe(localUserId: localUserId)
        }

        if let nextIndex = nextEditableIndex {
            focusedGuestID = guests[nextIndex].id
        } else {
            // No more guests, dismiss keyboard
            focusedGuestID = nil
        }
    }

    private func focusPreviousGuest(before currentId: PersonID) {
        guard let currentIndex = guests.firstIndex(where: { $0.id == currentId }) else { return }

        // Find previous editable guest (excluding "Me")
        // Search backwards from current index
        var prevIndex: Int? = nil
        for i in (0..<currentIndex).reversed() {
            if !guests[i].isMe(localUserId: localUserId) {
                prevIndex = i
                break
            }
        }

        if let index = prevIndex {
            focusedGuestID = guests[index].id
        }
    }

    private func toolbarDisplayName(for guestId: PersonID) -> String {
        guard let index = guests.firstIndex(where: { $0.id == guestId }) else { return "" }
        let guest = guests[index]

        let trimmed = guest.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        // Default to "Guest #"
        return defaultLabel(for: index)
    }

    private func checkPendingPayerChange() {
        // If we have a pending payer and they now have a name, set them as payer
        if let pendingId = pendingPayerID,
           let index = guests.firstIndex(where: { $0.id == pendingId }) {

            let guest = guests[index]
            let trimmed = guest.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Guest now has a name, set as payer
                includedIDs.insert(guest.id)
                payerID = guest.id
            }
            // If still no name, do nothing (payer doesn't change)

            // Clear pending payer
            pendingPayerID = nil
        }

        // Also check if current payer has no name - if so, revert to default
        let currentPayer = payerID
        if let index = guests.firstIndex(where: { $0.id == currentPayer }) {
            let payer = guests[index]
            let trimmed = payer.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && !payer.isMe(localUserId: localUserId) {
                // Current payer has no name, revert to Me or first guest
                if let me = guests.first(where: { $0.isMe(localUserId: localUserId) && includedIDs.contains($0.id) }) {
                    payerID = me.id
                } else if let first = guests.first(where: { includedIDs.contains($0.id) }) {
                    payerID = first.id
                }
            }
        }
    }

    // MARK: - UI pieces
    private func headerButton(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(isActive ? Color.blue.opacity(0.14) : Color(.tertiarySystemFill))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isActive ? Color.blue.opacity(0.6) : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        GeometryReader { geo in
            let maxH = geo.size.height
            let targetH = isExpanded ? sheetHeight(maxH: maxH) : collapsedHeight

            ZStack(alignment: .bottom) {

                if isExpanded {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture {
                            // Check pending payer before closing
                            checkPendingPayerChange()

                            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                                isExpanded = false
                                mode = nil
                                focusedGuestID = nil  // Dismiss keyboard
                            }
                        }
                }

                VStack(spacing: 0) {
                    header()
                        .frame(height: collapsedHeight)

                    if isExpanded, mode != nil {
                        Divider()
                        expandedBody()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: targetH, alignment: .top)
                .clipped()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedCorner(radius: 22, corners: [.topLeft, .topRight]))
                .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: -2)
                .offset(y: -keyboardHeight)  // ✅ Push entire sheet up by keyboard height
                .animation(.spring(response: 0.35, dampingFraction: 0.9), value: isExpanded)
                .animation(.easeInOut(duration: 0.25), value: keyboardHeight)  // ✅ Animate keyboard offset
                .animation(.easeInOut(duration: 0.15), value: mode)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .onAppear {
            // Subscribe to keyboard notifications
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil,
                queue: .main
            ) { notification in
                if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                    keyboardHeight = keyboardFrame.height
                }
            }
            
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { _ in
                keyboardHeight = 0
            }
        }
    }


    func header() -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Split with")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                headerButton(
                  title: "\(splitCount) \(splitCount == 1 ? "person" : "people")",
                  isActive: mode == .some(.splitWith)
                ) { toggleMode(.splitWith) }
            }
            .frame(maxWidth: .infinity)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Paid by")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                headerButton(
                  title: payerName,
                  isActive: mode == .some(.paidBy)
                ) { toggleMode(.paidBy) }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
    
    @ViewBuilder
    private func expandedBody() -> some View {
        
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(guests.enumerated()), id: \.element.id) { (idx, _) in
                        let g = guests[idx]
                        let isMe = g.isMe(localUserId: localUserId)
                        let trimmed = g.displayName.trimmingCharacters(in: .whitespacesAndNewlines)

                        HStack(spacing: 12) {
                            ZStack(alignment: .leading) {
                                if trimmed.isEmpty && !isMe {
                                    Text(defaultLabel(for: idx))
                                        .foregroundStyle(.secondary)
                                }
                                TextField("", text: Binding(
                                    get: { guests[idx].displayName },
                                    set: { guests[idx].displayName = $0 }
                                ))
                                .disabled(isMe || (mode == .paidBy && pendingPayerID != g.id))
                                .textInputAutocapitalization(.words)
                                .focused($focusedGuestID, equals: g.id)
                                .submitLabel(.done)  // Use .done to prevent default behavior
                                .foregroundStyle((trimmed.isEmpty && !isMe) ? .secondary : .primary)
                            }

                            Spacer(minLength: 8)

                            // Right side - consistent height container
                            ZStack(alignment: .trailing) {
                                if mode == .splitWith {
                                    let isIncluded = includedIDs.contains(g.id)
                                    Button { toggleIncluded(at: idx) } label: {
                                        Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 22, weight: .semibold))
                                            .foregroundStyle(isIncluded ? Color.blue : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    // In Paid by mode
                                    if payerID == g.id {
                                        Text("Payer")
                                            .font(.system(size: 12, weight: .semibold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color(.tertiarySystemFill))
                                            .clipShape(Capsule())
                                    } else {
                                        // Empty space to maintain consistent row height
                                        Color.clear.frame(width: 1, height: 30)
                                    }
                                }
                            }
                            .frame(minWidth: 44, minHeight: 30)  // Consistent minimum size
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Handle taps on entire row
                            if mode == .splitWith {
                                if !isMe { focusedGuestID = g.id }
                            } else if mode == .paidBy {
                                tapPaidBy(at: idx)
                            }
                        }
                        .id(g.id)  // For ScrollViewReader
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if mode == .splitWith, !isMe {
                                Button(role: .destructive) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                                        // clear focus if needed (prevents "focused index" bugs)
                                        if focusedGuestID == g.id { focusedGuestID = nil }
                                        removeGuest(at: idx)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .listRowInsets(EdgeInsets())
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
                .listStyle(.plain)
                .onChange(of: focusedGuestID) { oldValue, newValue in
                    // Check if we should apply pending payer change
                    // (when navigating away from a pending payer field)
                    if let pendingId = pendingPayerID, oldValue == pendingId, newValue != pendingId {
                        checkPendingPayerChange()
                    }

                    // Scroll to focused field when keyboard appears
                    if let guestId = newValue {
                        withAnimation {
                            proxy.scrollTo(guestId, anchor: .center)
                        }
                    }
                }
                .onChange(of: guests) { _, newValue in
                    // Watch for changes to pending payer's name
                    if let pendingId = pendingPayerID,
                       let index = newValue.firstIndex(where: { $0.id == pendingId }) {
                        let guest = newValue[index]
                        let trimmed = guest.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            // Guest now has a name, set as payer immediately
                            includedIDs.insert(guest.id)
                            payerID = guest.id
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    // Only show toolbar when editing a non-Me guest
                    if let currentFocusedId = focusedGuestID,
                       let currentIndex = guests.firstIndex(where: { $0.id == currentFocusedId }),
                       !guests[currentIndex].isMe(localUserId: localUserId),
                       mode == .splitWith {

                        // Previous button
                        Button {
                            focusPreviousGuest(before: currentFocusedId)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .disabled(currentIndex == 0 || guests[..<currentIndex].allSatisfy { $0.isMe(localUserId: localUserId) })

                        Spacer()

                        // Current guest name (live updating)
                        Text(toolbarDisplayName(for: currentFocusedId))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer()

                        // Next button
                        Button {
                            focusNextGuest(after: currentFocusedId)
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .disabled(guests[(currentIndex + 1)...].allSatisfy { $0.isMe(localUserId: localUserId) })
                    }
                }
            }
            
            if mode == .splitWith {
                Button { addGuest() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                        Text("Add guest")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.15))
                    .foregroundStyle(Color.blue)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.blue.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
    }
}
// MARK: - Rounded corner helper

struct RoundedCorner: Shape {
    var radius: CGFloat = 0
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

import SwiftUI

// MARK: - Guest model used by SplitView

struct SplitGuest: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isIncluded: Bool
    var isMe: Bool

    init(id: UUID = UUID(), name: String = "", isIncluded: Bool = true, isMe: Bool = false) {
        self.id = id
        self.name = name
        self.isIncluded = isIncluded
        self.isMe = isMe
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

    // Working draft bindings
    @Binding var guests: [SplitGuest]
    @Binding var payerGuestId: UUID

    // Save logic
    let canSave: Bool
    let onSave: () -> Void

    private let collapsedHeight: CGFloat = 132
    
    @FocusState private var focusedGuestId: UUID?
    @State private var pendingPayerGuestId: UUID?  // Track guest we're trying to make payer (waiting for name)
    
    // Keyboard height tracking
    @State private var keyboardHeight: CGFloat = 0

    // MARK: - Header computed values
    private var splitCount: Int { guests.filter { $0.isIncluded }.count }
    private var payerName: String {
        if let g = guests.first(where: { $0.id == payerGuestId }) {
            return g.isMe ? "Me" : (g.trimmedName.isEmpty ? "Select payer" : g.trimmedName)
        }
        return "Select payer"
    }

    private func sheetHeight(maxH: CGFloat) -> CGFloat {
        let rowH: CGFloat = 58
        let addRowH: CGFloat = (mode == .some(.splitWith)) ? 48 : 8
        let saveH: CGFloat = 75
        let estimated = collapsedHeight + addRowH + (rowH * CGFloat(guests.count)) + saveH
        
        // Don't reduce height for keyboard - we'll offset instead
        return min(maxH, estimated)
    }

    // MARK: - Guest helpers
    private func defaultLabel(for index: Int) -> String {
        if index == 0 { return "Me" }
        return "Guest \(index + 1)"
    }

    private func addGuest() {
        let new = SplitGuest(name: "", isIncluded: true, isMe: false)
        guests.append(new)
    }

    private func removeGuest(at index: Int) {
        guard guests.indices.contains(index), !guests[index].isMe else { return }
        let removedId = guests[index].id
        guests.remove(at: index)

        if payerGuestId == removedId {
            if let me = guests.first(where: { $0.isMe }) { payerGuestId = me.id }
            else if let first = guests.first { payerGuestId = first.id }
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
                focusedGuestId = nil  // Dismiss keyboard
            } else {
                // switch to other mode -> expand
                mode = m
                isExpanded = true
                focusedGuestId = nil  // Dismiss keyboard when switching
            }
        }
    }

    private func toggleIncluded(at index: Int) {
        guard guests.indices.contains(index) else { return }
        let includedCount = guests.filter { $0.isIncluded }.count
        if guests[index].isIncluded && includedCount <= 1 { return } // keep at least 1

        guests[index].isIncluded.toggle()

        // if payer excluded, move payer to an included guest
        if !guests.contains(where: { $0.id == payerGuestId && $0.isIncluded }) {
            if let me = guests.first(where: { $0.isMe && $0.isIncluded }) { payerGuestId = me.id }
            else if let first = guests.first(where: { $0.isIncluded }) { payerGuestId = first.id }
        }
    }

    private func tapPaidBy(at index: Int) {
        guard guests.indices.contains(index) else { return }
        let g = guests[index]
        
        // If guest has no name and isn't "Me", focus field and set as pending payer
        if g.trimmedName.isEmpty && !g.isMe {
            pendingPayerGuestId = g.id
            // Defer focus slightly so TextField disabled state updates first
            DispatchQueue.main.async {
                focusedGuestId = g.id
            }
            return
        }
        
        // Guest has a name (or is "Me"), set as payer immediately
        if !guests[index].isIncluded {
            guests[index].isIncluded = true
        }
        payerGuestId = g.id
        pendingPayerGuestId = nil  // Clear any pending payer
    }
    
    // MARK: - Keyboard navigation
    private func focusNextGuest(after currentId: UUID) {
        guard let currentIndex = guests.firstIndex(where: { $0.id == currentId }) else { return }
        
        // Find next editable guest (excluding "Me")
        let nextEditableIndex = guests[(currentIndex + 1)...].firstIndex { guest in
            !guest.isMe
        }
        
        if let nextIndex = nextEditableIndex {
            focusedGuestId = guests[nextIndex].id
        } else {
            // No more guests, dismiss keyboard
            focusedGuestId = nil
        }
    }
    
    private func focusPreviousGuest(before currentId: UUID) {
        guard let currentIndex = guests.firstIndex(where: { $0.id == currentId }) else { return }
        
        // Find previous editable guest (excluding "Me")
        // Search backwards from current index
        var prevIndex: Int? = nil
        for i in (0..<currentIndex).reversed() {
            if !guests[i].isMe {
                prevIndex = i
                break
            }
        }
        
        if let index = prevIndex {
            focusedGuestId = guests[index].id
        }
    }
    
    private func toolbarDisplayName(for guestId: UUID) -> String {
        guard let index = guests.firstIndex(where: { $0.id == guestId }) else { return "" }
        let guest = guests[index]
        
        let trimmed = guest.trimmedName
        if !trimmed.isEmpty {
            return trimmed
        }
        
        // Default to "Guest #"
        return defaultLabel(for: index)
    }
    
    private func checkPendingPayerChange() {
        // If we have a pending payer and they now have a name, set them as payer
        if let pendingId = pendingPayerGuestId,
           let index = guests.firstIndex(where: { $0.id == pendingId }) {
            
            let guest = guests[index]
            if !guest.trimmedName.isEmpty {
                // Guest now has a name, set as payer
                if !guests[index].isIncluded {
                    guests[index].isIncluded = true
                }
                payerGuestId = guest.id
            }
            // If still no name, do nothing (payer doesn't change)
            
            // Clear pending payer
            pendingPayerGuestId = nil
        }
        
        // Also check if current payer has no name - if so, revert to default
        let payerId = payerGuestId
        if let index = guests.firstIndex(where: { $0.id == payerId }) {
            let payer = guests[index]
            if payer.trimmedName.isEmpty && !payer.isMe {
                // Current payer has no name, revert to Me or first guest
                if let me = guests.first(where: { $0.isMe && $0.isIncluded }) {
                    payerGuestId = me.id
                } else if let first = guests.first(where: { $0.isIncluded }) {
                    payerGuestId = first.id
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
                                focusedGuestId = nil  // Dismiss keyboard
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


    private func header() -> some View {
        
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
                        
                        HStack(spacing: 12) {
                            ZStack(alignment: .leading) {
                                if g.trimmedName.isEmpty && !g.isMe {
                                    Text(defaultLabel(for: idx))
                                        .foregroundStyle(.secondary)
                                }
                                TextField("", text: Binding(
                                    get: { guests[idx].name },
                                    set: { guests[idx].name = $0 }
                                ))
                                .disabled(g.isMe || (mode == .paidBy && pendingPayerGuestId != g.id))
                                .textInputAutocapitalization(.words)
                                .focused($focusedGuestId, equals: g.id)
                                .submitLabel(.done)  // Use .done to prevent default behavior
                                .foregroundStyle((g.trimmedName.isEmpty && !g.isMe) ? .secondary : .primary)
                            }
                            
                            Spacer(minLength: 8)
                            
                            // Right side - consistent height container
                            ZStack(alignment: .trailing) {
                                if mode == .splitWith {
                                    Button { toggleIncluded(at: idx) } label: {
                                        Image(systemName: guests[idx].isIncluded ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 22, weight: .semibold))
                                            .foregroundStyle(guests[idx].isIncluded ? Color.blue : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    // In Paid by mode
                                    if payerGuestId == g.id {
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
                                if !g.isMe { focusedGuestId = g.id }
                            } else if mode == .paidBy {
                                tapPaidBy(at: idx)
                            }
                        }
                        .id(g.id)  // For ScrollViewReader
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if mode == .splitWith, !g.isMe {
                                Button(role: .destructive) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                                        // clear focus if needed (prevents "focused index" bugs)
                                        if focusedGuestId == g.id { focusedGuestId = nil }
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
                .onChange(of: focusedGuestId) { oldValue, newValue in
                    // Check if we should apply pending payer change
                    // (when navigating away from a pending payer field)
                    if let pendingId = pendingPayerGuestId, oldValue == pendingId, newValue != pendingId {
                        checkPendingPayerChange()
                    }
                    
                    // Scroll to focused field when keyboard appears
                    if let guestId = newValue {
                        withAnimation {
                            proxy.scrollTo(guestId, anchor: .center)
                        }
                    }
                }
                .onChange(of: guests) { oldValue, newValue in
                    // Watch for changes to pending payer's name
                    if let pendingId = pendingPayerGuestId,
                       let index = newValue.firstIndex(where: { $0.id == pendingId }) {
                        let guest = newValue[index]
                        if !guest.trimmedName.isEmpty {
                            // Guest now has a name, set as payer immediately
                            if !guests[index].isIncluded {
                                guests[index].isIncluded = true
                            }
                            payerGuestId = guest.id
                            pendingPayerGuestId = nil
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    // Only show toolbar when editing a non-Me guest
                    if let currentFocusedId = focusedGuestId,
                       let currentIndex = guests.firstIndex(where: { $0.id == currentFocusedId }),
                       !guests[currentIndex].isMe {
                        
                        // Previous button
                        Button {
                            focusPreviousGuest(before: currentFocusedId)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .disabled(currentIndex == 0 || guests[..<currentIndex].allSatisfy { $0.isMe })
                        
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
                        .disabled(guests[(currentIndex + 1)...].allSatisfy { $0.isMe })
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
                .padding(.top, 8)
            }

            Button {
                // Check pending payer before saving
                checkPendingPayerChange()
                
                onSave()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    isExpanded = false
                    focusedGuestId = nil  // Dismiss keyboard
                }
            } label: {
                Text("Save")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canSave ? Color.blue : Color(.systemGray4))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
    }
}
// MARK: - Rounded corner helper

private struct RoundedCorner: Shape {
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

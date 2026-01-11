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
private struct HeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

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

    @State private var measuredExpandedHeight: CGFloat = 0
    private let collapsedHeight: CGFloat = 132
    
    @FocusState private var focusedGuestId: UUID?

    // MARK: - Header computed values
    private var splitCount: Int { guests.filter { $0.isIncluded }.count }
    private var payerName: String {
        if let g = guests.first(where: { $0.id == payerGuestId }) {
            return g.isMe ? "Me" : (g.trimmedName.isEmpty ? "Select payer" : g.trimmedName)
        }
        return "Select payer"
    }

    private func sheetHeight(maxH: CGFloat) -> CGFloat {
        let rowH: CGFloat = 55
        let addRowH: CGFloat = (mode == .some(.splitWith)) ? 48 : 0
        let saveH: CGFloat = 75
        let estimated = collapsedHeight + addRowH + (rowH * CGFloat(guests.count)) + saveH
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            if mode == m {
                // pressing same button again -> turn off + collapse
                mode = nil
                isExpanded = false
            } else {
                // switch to other mode -> expand
                mode = m
                isExpanded = true
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
        if g.trimmedName.isEmpty && !g.isMe {
            focusedGuestId = g.id
            return
        }
        if !guests[index].isIncluded { guests[index].isIncluded = true }
        payerGuestId = g.id
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
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                                isExpanded = false
                                mode = nil
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
                .animation(.spring(response: 0.35, dampingFraction: 0.9), value: isExpanded)
                .animation(.easeInOut(duration: 0.15), value: mode)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
                            .disabled(g.isMe)
                            .textInputAutocapitalization(.words)
                            .focused($focusedGuestId, equals: g.id)
                            .submitLabel(.done)
                            .foregroundStyle((g.trimmedName.isEmpty && !g.isMe) ? .secondary : .primary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if !g.isMe { focusedGuestId = g.id } }
                        
                        Spacer(minLength: 8)
                        
                        if mode == .splitWith {
                            Button { toggleIncluded(at: idx) } label: {
                                Image(systemName: guests[idx].isIncluded ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(guests[idx].isIncluded ? Color.blue : .secondary)
                            }
                            .buttonStyle(.plain)
                        } else {
                            if payerGuestId == g.id {
                                Text("Payer")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(.tertiarySystemFill))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if mode == .splitWith, !g.isMe {
                            Button(role: .destructive) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                                    // clear focus if needed (prevents “focused index” bugs)
                                    if focusedGuestId == g.id { focusedGuestId = nil }
                                    removeGuest(at: idx)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onTapGesture {
                        if mode == .paidBy { tapPaidBy(at: idx) }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .listRowInsets(EdgeInsets())
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            }
            .listStyle(.plain)
            
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
            }

            Button {
                onSave()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    isExpanded = false
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

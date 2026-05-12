//
//  BillActionButtons.swift
//  Loot
//
//  The 3-button action row below the bill card on the confirmation screen:
//  Trash (delete) / Edit Split / Add Tip. Tints brighten as the user drags
//  the card in the matching direction. Extracted from ConfirmationView in
//  Phase 4. Pure UI; the parent owns the swipe-state bindings and supplies
//  three callbacks for the actual button taps.
//
import SwiftUI

struct BillActionButtons: View {
    // Add-Tip button display
    let hasTip: Bool
    let tipAmount: String
    let isTipDisabled: Bool

    // Drag-tint inputs (parent computes from dragIntent + offset)
    let trashProgress: CGFloat
    let splitProgress: CGFloat
    let tipProgress: CGFloat

    // Per-button "active" tint (true when the user is dragging in the
    // matching direction — keeps the button at full opacity even when the
    // others fade with `buttonsOpacity`).
    let isLeftDrag: Bool
    let isDownDrag: Bool
    let isRightDrag: Bool
    let buttonsOpacity: Double

    // Theme
    let buttonBase: Color
    let gold: Color

    // Actions
    let onTrash: () -> Void
    let onEditSplit: () -> Void
    let onAddTip: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            trashButton
            editSplitButton
            addTipButton
        }
    }

    // MARK: - Trash

    private var trashButton: some View {
        Button(action: onTrash) {
            HStack(spacing: 6) {
                Image(systemName: "trash")
            }
            .font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(
                trashProgress > 0.02 ? Color.white : Color.red
            )
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(buttonBase)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.red)
                            .opacity(Double(trashProgress))
                    )
            )
        }
        .buttonStyle(.plain)
        .opacity(isLeftDrag ? 1 : buttonsOpacity)
    }

    // MARK: - Edit Split

    private var editSplitButton: some View {
        Button(action: onEditSplit) {
            Text("Edit Split")
                .multilineTextAlignment(.center)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(minWidth: 100)
                .padding(.vertical, 12)
                .padding(.horizontal, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(buttonBase)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(gold)
                                .opacity(Double(splitProgress))
                        )
                )
        }
        .buttonStyle(.plain)
        .opacity(isDownDrag ? 1 : buttonsOpacity)
    }

    // MARK: - Add Tip

    private var addTipButton: some View {
        Button(action: onAddTip) {
            Text(hasTip ? "Tip: \(tipAmount)" : "Add Tip")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .cornerRadius(18)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(buttonBase)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(.blue)
                                .opacity(Double(tipProgress))
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(isTipDisabled)
        .opacity(isTipDisabled ? 0.4 : 1.0)
        .opacity(isRightDrag ? 1 : buttonsOpacity)
    }
}

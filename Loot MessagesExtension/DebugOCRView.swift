//
//  DebugOCRView.swift
//  Loot
//
//  Created by Joshua Liu on 1/30/26.
//

import SwiftUI

struct DebugOCRView: View {
    let result: OCRResult
    let originalImage: UIImage?
    let onDismiss: () -> Void

    @State private var showOriginalImage = false
    @State private var showConnections = true
    @State private var scale: CGFloat = 1.0

    /// Represents a connection between an item and its amount, including sub-items
    struct ItemAmountPair {
        let itemBlock: OCRBlock
        let amountBlock: OCRBlock
        var subItems: [OCRBlock] = []  // Blocks merged with this item (modifiers, descriptions)

        /// Full item text including sub-items
        var fullItemText: String {
            if subItems.isEmpty {
                return itemBlock.text
            }
            let subTexts = subItems.map { $0.text }.joined(separator: " | ")
            return "\(itemBlock.text) [\(subTexts)]"
        }
    }

    /// Check if a block looks like a price (clean decimal format)
    private func isAmountBlock(_ block: OCRBlock) -> Bool {
        let text = block.text.trimmingCharacters(in: .whitespaces)
        // Match clean decimal format: 12.99, 1234.56, etc.
        let pattern = #"^\d+\.\d{2}$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Find item-amount pairs by testing combinations and picking the best one
    /// Priority: 1) Match all amounts, 2) Most horizontal lines (lowest slope)
    private var itemAmountPairs: [ItemAmountPair] {
        let amounts = result.blocks.filter { isAmountBlock($0) }
            .sorted { $0.boundingBox.y > $1.boundingBox.y }  // Top to bottom

        // Find the leftmost amount X position - items must be to the left of this
        let leftmostAmountX = amounts.map { $0.boundingBox.x }.min() ?? 0.5

        // Potential items: not amounts, and left edge is to the left of the leftmost amount
        let potentialItems = result.blocks
            .filter { !isAmountBlock($0) }
            .filter { $0.boundingBox.x < leftmostAmountX }

        guard !amounts.isEmpty && !potentialItems.isEmpty else { return [] }

        // Track best solution found
        var bestPairs: [ItemAmountPair] = []
        var bestScore: (matchCount: Int, avgSlope: Double) = (0, Double.infinity)
        var iterations = 0
        let maxIterations = 10000  // Increased limit

        // Recursive backtracking
        func tryMatch(amountIndex: Int, usedItems: Set<Int>, currentPairs: inout [ItemAmountPair]) {
            iterations += 1
            if iterations > maxIterations { return }

            // Base case: all amounts processed
            if amountIndex >= amounts.count {
                let score = calculateScore(currentPairs, totalAmounts: amounts.count)
                if isBetterScore(score, than: bestScore) {
                    bestScore = score
                    bestPairs = currentPairs
                }
                return
            }

            let amount = amounts[amountIndex]
            let amountY = amount.boundingBox.y + amount.boundingBox.height / 2
            let amountX = amount.boundingBox.x

            // Find candidate items: must be to the left of THIS amount, sorted by Y distance
            var candidates: [(index: Int, item: OCRBlock, distance: Double)] = []
            for (i, item) in potentialItems.enumerated() {
                guard !usedItems.contains(i) else { continue }
                // Item's right edge must be to the left of amount's left edge
                let itemRightX = item.boundingBox.x + item.boundingBox.width
                guard itemRightX < amountX else { continue }

                let itemY = item.boundingBox.y + item.boundingBox.height / 2
                let distance = abs(itemY - amountY)
                candidates.append((i, item, distance))
            }
            candidates.sort { $0.distance < $1.distance }

            // Try top candidates (limit branching factor)
            let maxBranches = 4  // Increased branching
            let branchThreshold = 0.08  // Wider threshold

            var branchCount = 0
            for candidate in candidates {
                if branchCount > 0 && candidate.distance > candidates[0].distance + branchThreshold {
                    break
                }
                if branchCount >= maxBranches { break }

                var newUsed = usedItems
                newUsed.insert(candidate.index)
                currentPairs.append(ItemAmountPair(itemBlock: candidate.item, amountBlock: amount))

                tryMatch(amountIndex: amountIndex + 1, usedItems: newUsed, currentPairs: &currentPairs)

                currentPairs.removeLast()
                branchCount += 1
            }

            // Also try skipping this amount if no good candidates or not enough items
            if candidates.isEmpty {
                tryMatch(amountIndex: amountIndex + 1, usedItems: usedItems, currentPairs: &currentPairs)
            }
        }

        var pairs: [ItemAmountPair] = []
        tryMatch(amountIndex: 0, usedItems: [], currentPairs: &pairs)

        print("[Pairing] Tested \(iterations) combinations, best: \(bestScore.matchCount)/\(amounts.count) matches, slope: \(String(format: "%.4f", bestScore.avgSlope))")

        // Sort pairs by Y (top to bottom)
        let sortedPairs = bestPairs.sorted { $0.amountBlock.boundingBox.y > $1.amountBlock.boundingBox.y }

        // Merge unmatched blocks as sub-items
        return mergeSubItems(pairs: sortedPairs, allBlocks: result.blocks, amounts: amounts, potentialItems: potentialItems)
    }

    /// Merge unmatched blocks into their parent items as sub-items
    /// A block becomes a sub-item if it's on the same row as an item, or between that item and the next
    private func mergeSubItems(pairs: [ItemAmountPair], allBlocks: [OCRBlock], amounts: [OCRBlock], potentialItems: [OCRBlock]) -> [ItemAmountPair] {
        guard !pairs.isEmpty else { return pairs }

        // Find all blocks that are already matched (items or amounts)
        let matchedItemTexts = Set(pairs.map { $0.itemBlock.text + String($0.itemBlock.boundingBox.x) })
        let amountTexts = Set(amounts.map { $0.text + String($0.boundingBox.x) })

        // Get unmatched blocks (not an amount, not a matched item)
        let unmatchedBlocks = allBlocks.filter { block in
            let key = block.text + String(block.boundingBox.x)
            return !amountTexts.contains(key) && !matchedItemTexts.contains(key) && !isAmountBlock(block)
        }

        var result = pairs

        // For each pair, find unmatched blocks that belong to it
        for i in 0..<result.count {
            let currentItemY = result[i].itemBlock.boundingBox.y
            let currentAmountY = result[i].amountBlock.boundingBox.y

            // Find Y boundary for next item (or 0 if this is the last item)
            let nextItemY: Double
            if i + 1 < result.count {
                nextItemY = result[i + 1].itemBlock.boundingBox.y
            } else {
                nextItemY = 0  // Bottom of image
            }

            // Find unmatched blocks that belong to this item:
            // - Y is between this item and next item (or same row)
            // - X is in the left portion (not overlapping with amounts)
            let rowTolerance = 0.02
            let subItems = unmatchedBlocks.filter { block in
                let blockY = block.boundingBox.y + block.boundingBox.height / 2
                let itemCenterY = currentItemY + result[i].itemBlock.boundingBox.height / 2

                // Same row as item
                let sameRow = abs(blockY - itemCenterY) < rowTolerance

                // Below item but above next item
                let belowCurrent = blockY < currentItemY - rowTolerance
                let aboveNext = blockY > nextItemY + rowTolerance

                // Must be in left portion (before amounts)
                let leftmostAmountX = result[i].amountBlock.boundingBox.x
                let inLeftPortion = block.boundingBox.x < leftmostAmountX

                return inLeftPortion && (sameRow || (belowCurrent && aboveNext))
            }

            // Sort sub-items by Y (top to bottom) then X (left to right)
            let sortedSubItems = subItems.sorted { a, b in
                if abs(a.boundingBox.y - b.boundingBox.y) > 0.01 {
                    return a.boundingBox.y > b.boundingBox.y
                }
                return a.boundingBox.x < b.boundingBox.x
            }

            result[i].subItems = sortedSubItems
        }

        return result
    }

    /// Calculate score for a set of pairs (lower = better)
    /// Priority: 1) Most matches, 2) Lowest average slope
    /// Uses a two-tier scoring: matchCount is primary, slope is secondary
    private func calculateScore(_ pairs: [ItemAmountPair], totalAmounts: Int) -> (matchCount: Int, avgSlope: Double) {
        guard !pairs.isEmpty else { return (0, Double.infinity) }

        var totalAbsSlope = 0.0
        for pair in pairs {
            let itemY = pair.itemBlock.boundingBox.y + pair.itemBlock.boundingBox.height / 2
            let amountY = pair.amountBlock.boundingBox.y + pair.amountBlock.boundingBox.height / 2
            let itemRightX = pair.itemBlock.boundingBox.x + pair.itemBlock.boundingBox.width
            let amountLeftX = pair.amountBlock.boundingBox.x

            let dY = amountY - itemY
            let dX = amountLeftX - itemRightX

            if abs(dX) > 0.001 {
                totalAbsSlope += abs(dY / dX)
            }
        }

        let avgSlope = totalAbsSlope / Double(pairs.count)
        return (pairs.count, avgSlope)
    }

    /// Compare two scores - returns true if score1 is better than score2
    /// Priority: more matches first, then lower slope
    private func isBetterScore(_ score1: (matchCount: Int, avgSlope: Double),
                               than score2: (matchCount: Int, avgSlope: Double)) -> Bool {
        if score1.matchCount != score2.matchCount {
            return score1.matchCount > score2.matchCount  // More matches = better
        }
        return score1.avgSlope < score2.avgSlope  // Lower slope = better
    }

    private func computeSize(geo: GeometryProxy) -> CGSize {
        let imageAspect = CGFloat(result.imageWidth) / CGFloat(result.imageHeight)
        let screenAspect = geo.size.width / geo.size.height

        if imageAspect > screenAspect {
            let w = geo.size.width
            return CGSize(width: w, height: w / imageAspect)
        } else {
            let h = geo.size.height
            return CGSize(width: h * imageAspect, height: h)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = computeSize(geo: geo)
            mainContent(viewWidth: size.width, viewHeight: size.height, geoSize: geo.size)
        }
        .overlay(alignment: .topTrailing) { toolbarOverlay }
        .overlay(alignment: .bottomLeading) { statsOverlay }
        .ignoresSafeArea()
    }

    // MARK: - Subviews

    @ViewBuilder
    private func mainContent(viewWidth: CGFloat, viewHeight: CGFloat, geoSize: CGSize) -> some View {
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                backgroundView(viewWidth: viewWidth, viewHeight: viewHeight)
                textBlocksView(viewWidth: viewWidth, viewHeight: viewHeight)
                if showConnections {
                    connectionLinesView(viewWidth: viewWidth, viewHeight: viewHeight)
                }
            }
            .frame(width: viewWidth, height: viewHeight)
        }
        .frame(width: geoSize.width, height: geoSize.height)
        .background(Color.gray.opacity(0.1))
    }

    @ViewBuilder
    private func backgroundView(viewWidth: CGFloat, viewHeight: CGFloat) -> some View {
        if showOriginalImage, let img = originalImage {
            Image(uiImage: img)
                .resizable()
                .frame(width: viewWidth, height: viewHeight)
        } else {
            Rectangle()
                .fill(Color.white)
                .frame(width: viewWidth, height: viewHeight)
        }
    }

    @ViewBuilder
    private func textBlocksView(viewWidth: CGFloat, viewHeight: CGFloat) -> some View {
        ForEach(0..<result.blocks.count, id: \.self) { index in
            textBlockView(block: result.blocks[index], viewWidth: viewWidth, viewHeight: viewHeight)
        }
    }

    @ViewBuilder
    private func textBlockView(block: OCRBlock, viewWidth: CGFloat, viewHeight: CGFloat) -> some View {
        let bbox = block.boundingBox
        let x = bbox.x * viewWidth
        let y = (1 - bbox.y - bbox.height) * viewHeight
        let width = bbox.width * viewWidth
        let height = bbox.height * viewHeight
        let isAmount = isAmountBlock(block)

        Text(block.text)
            .font(.system(size: max(8, height * 0.7 * scale)))
            .foregroundColor(.black)
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .rotationEffect(.degrees(-block.angle))
            .frame(width: width, height: height, alignment: .leading)
            .background(isAmount ? Color.green.opacity(0.3) : Color.yellow.opacity(0.2))
            .border(isAmount ? Color.green : Color.red.opacity(0.3), width: isAmount ? 1.5 : 0.5)
            .position(x: x + width/2, y: y + height/2)
    }

    @ViewBuilder
    private func connectionLinesView(viewWidth: CGFloat, viewHeight: CGFloat) -> some View {
        let pairs = itemAmountPairs
        ForEach(0..<pairs.count, id: \.self) { index in
            connectionLineView(pair: pairs[index], viewWidth: viewWidth, viewHeight: viewHeight)
        }
    }

    @ViewBuilder
    private func connectionLineView(pair: ItemAmountPair, viewWidth: CGFloat, viewHeight: CGFloat) -> some View {
        let itemBox = pair.itemBlock.boundingBox
        let amountBox = pair.amountBlock.boundingBox

        let itemRightX = (itemBox.x + itemBox.width) * viewWidth
        let itemCenterY = (1 - itemBox.y - itemBox.height / 2) * viewHeight
        let amountLeftX = amountBox.x * viewWidth
        let amountCenterY = (1 - amountBox.y - amountBox.height / 2) * viewHeight

        Path { path in
            path.move(to: CGPoint(x: itemRightX, y: itemCenterY))
            path.addLine(to: CGPoint(x: amountLeftX, y: amountCenterY))
        }
        .stroke(Color.blue.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))

        Circle()
            .fill(Color.blue)
            .frame(width: 6, height: 6)
            .position(x: itemRightX, y: itemCenterY)

        Circle()
            .fill(Color.blue)
            .frame(width: 6, height: 6)
            .position(x: amountLeftX, y: amountCenterY)
    }

    private var toolbarOverlay: some View {
        VStack(spacing: 12) {
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.gray)
            }

            Button {
                showOriginalImage.toggle()
            } label: {
                Image(systemName: showOriginalImage ? "doc.text" : "photo")
                    .font(.system(size: 24))
                    .padding(10)
                    .background(Color(.systemBackground))
                    .clipShape(Circle())
                    .shadow(radius: 2)
            }

            Button {
                showConnections.toggle()
            } label: {
                Image(systemName: showConnections ? "link" : "link.badge.plus")
                    .font(.system(size: 24))
                    .padding(10)
                    .background(showConnections ? Color.blue.opacity(0.2) : Color(.systemBackground))
                    .clipShape(Circle())
                    .shadow(radius: 2)
            }

            VStack(spacing: 4) {
                Button {
                    scale = min(3.0, scale + 0.25)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .bold))
                        .padding(8)
                        .background(Color(.systemBackground))
                        .clipShape(Circle())
                        .shadow(radius: 2)
                }
                Button {
                    scale = max(0.25, scale - 0.25)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 20, weight: .bold))
                        .padding(8)
                        .background(Color(.systemBackground))
                        .clipShape(Circle())
                        .shadow(radius: 2)
                }
            }
        }
        .padding(20)
    }

    private var statsOverlay: some View {
        let amounts = result.blocks.filter { isAmountBlock($0) }.count
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(result.blocks.count) blocks")
            Text("\(result.imageWidth)×\(result.imageHeight)")
            Text("Scale: \(String(format: "%.0f%%", scale * 100))")
            Text("\(amounts) amounts, \(itemAmountPairs.count) pairs")
                .foregroundColor(.blue)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .padding(8)
        .background(Color(.systemBackground).opacity(0.9))
        .cornerRadius(8)
        .padding()
    }
}

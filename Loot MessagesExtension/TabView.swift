//
//  TabView.swift
//  Loot
//
//  Created by Joshua Liu on 1/1/26.
//


//
//  TabView.swift
//  Loot
//
//  Created by Joshua Liu on 12/9/25.
//

import SwiftUI

struct TabView: View {
    @Binding var tabName: String

    var onUpload: () -> Void
    var onScan: () -> Void
    var onFill: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Loot")
            .font(.system(size: 24, weight: .semibold))
            .padding(.bottom, 12)
            .padding(.horizontal, 16)

            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    Button(action: onUpload) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 48, weight: .regular))
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .frame(height: 32)

                    Button(action: onScan) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 48, weight: .regular))
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .frame(height: 32)

                    Button(action: onFill) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 48, weight: .regular))
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.blue)
                            .offset(y: -4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(18)

                HStack(spacing: 0) {
                    Text("Upload")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity)

                    Text("Scan")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity)

                    Text("Fill In")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .padding(.top, 30)
    }
}

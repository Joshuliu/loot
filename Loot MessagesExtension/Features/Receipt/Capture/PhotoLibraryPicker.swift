//
//  PhotoLibraryPicker.swift
//  Loot
//
//  Created by Joshua Liu on 1/18/26.
//
//  Callback-based and intentionally NON-self-dismissing: it lives as a step
//  inside the unified scan sheet, so picking must hand the image up and let
//  SwiftUI swap the sheet's content to the review step — calling
//  `picker.dismiss` here would tear down the whole sheet.
//

import SwiftUI
import UIKit

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    var onPicked: (UIImage) -> Void
    var onCancel: () -> Void

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        var parent: PhotoLibraryPicker

        init(_ parent: PhotoLibraryPicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let img = (info[.editedImage] ?? info[.originalImage]) as? UIImage {
                parent.onPicked(img)
            } else {
                parent.onCancel()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        picker.mediaTypes = ["public.image"]
        picker.sourceType = .photoLibrary
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}

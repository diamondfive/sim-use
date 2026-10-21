// SPDX-License-Identifier: Apache-2.0
//
//  PasteTestView.swift
//  SimUsePlayground
//
//  Created by Cameron on 23/05/2025.
//

import SwiftUI

// MARK: - Paste Test View
struct PasteTestView: View {
    @State private var inputText = ""
    @State private var multiline = false
    @State private var restrictSelectAll = false
    @State private var decoyTapCount = 0
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Paste Playground")
                    .font(.title2)
                    .fontWeight(.bold)
                    .accessibilityIdentifier("paste-test-title")
                Text("Paste text via the simulator pasteboard")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("paste-test-description")
            }
            .padding()
            .background(Color.white.opacity(0.9))
            .cornerRadius(12)
            .shadow(radius: 4)

            VStack(spacing: 16) {
                Group {
                    if restrictSelectAll {
                        PasteWithoutSelectAll(text: $inputText)
                            .frame(height: 36)
                    } else if multiline {
                        TextEditor(text: $inputText)
                            .frame(height: 90)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary))
                    } else {
                        TextField("Paste target...", text: $inputText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                }
                    .font(.title2)
                    .focused($isTextFieldFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("paste-input-field")
                    .accessibilityValue(inputText)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Characters: \(inputText.count)")
                        .font(.headline)
                        .accessibilityIdentifier("paste-char-count")
                        .accessibilityValue("\(inputText.count)")
                    Text("Content: \(inputText)")
                        .lineLimit(2)
                        .accessibilityIdentifier("paste-content-echo")
                        .accessibilityValue(inputText.isEmpty ? "empty" : inputText)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Button("Clear") {
                        inputText = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("paste-clear-button")
                    Button(restrictSelectAll ? "Standard actions" : "No Select All") {
                        restrictSelectAll.toggle()
                    }
                    .accessibilityIdentifier("paste-restrict-select-all")
                }
            }
            .padding()

            Spacer()
        }
        .padding()
        .navigationTitle("Paste Test")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A same-label app control must not be mistaken for an edit menu.
            ToolbarItem(placement: .topBarLeading) {
                Button("Paste") {
                    isTextFieldFocused = false
                    decoyTapCount += 1
                }
                .accessibilityIdentifier("paste-decoy-button")
                .accessibilityValue("\(decoyTapCount)")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(multiline ? "Single line" : "Multiline") {
                    multiline.toggle()
                }
                .accessibilityIdentifier("paste-multiline-toggle")
            }
        }
        // No screen-level accessibilityIdentifier: applied to the root it
        // propagates down and overrides every child's own id, which the
        // per-element E2E selectors (paste-input-field, paste-content-echo,
        // …) depend on.
        .onAppear {
            isTextFieldFocused = true
        }
    }
}

/// A native control that permits Paste but refuses Select All.
private struct PasteWithoutSelectAll: UIViewRepresentable {
    @Binding var text: String

    final class Field: UITextField {
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(selectAll(_:)) { return false }
            return super.canPerformAction(action, withSender: sender)
        }
    }

    final class Coordinator: NSObject {
        var parent: PasteWithoutSelectAll
        init(_ parent: PasteWithoutSelectAll) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.accessibilityIdentifier = "paste-input-field"
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.accessibilityValue = text
    }
}

#Preview {
    NavigationStack {
        PasteTestView()
    }
}

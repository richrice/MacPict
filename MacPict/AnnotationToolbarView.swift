import SwiftUI

/// The 44 pt strip above the canvas. Every control here has a keyboard equivalent handled by
/// `AnnotationCanvasView`; the buttons exist so the state is visible at a glance, and the
/// shortcut is in each tooltip so the mouse is a way to learn the keyboard, not a habit.
struct AnnotationToolbarView: View {
    @ObservedObject var document: AnnotationDocument
    let onCopyImage: () -> Void
    let onCopyPath: () -> Void
    let onSaveAs: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            tools
            separator
            colors
            separator
            sizes
            separator
            history
            separator
            output
            Spacer(minLength: 8)
            finishActions
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var separator: some View {
        Divider().frame(height: 22)
    }

    private var tools: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                iconButton(
                    tool.symbolName,
                    isOn: document.tool == tool,
                    help: "\(tool.title) (\(tool.keyEquivalent))"
                ) {
                    document.tool = tool
                }
            }
        }
    }

    private var colors: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationColor.allCases) { color in
                Button {
                    document.style.color = color
                } label: {
                    Circle()
                        .fill(Color(nsColor: color.nsColor))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.3), lineWidth: 0.5))
                        .padding(3)
                        .overlay(
                            Circle().strokeBorder(
                                document.style.color == color ? Color.accentColor : .clear,
                                lineWidth: 2
                            )
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(color.rawValue.capitalized)
            }
        }
    }

    private var sizes: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationSize.allCases) { size in
                let isOn = document.style.size == size
                Button {
                    document.style.size = size
                } label: {
                    Circle()
                        .frame(width: dotDiameter(size), height: dotDiameter(size))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .background(
                            isOn ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(size.title) ([ / ])")
            }
        }
    }

    private var history: some View {
        HStack(spacing: 2) {
            iconButton("arrow.uturn.backward", isEnabled: document.canUndo, help: "Undo (⌘Z)") {
                document.undo()
            }
            iconButton("arrow.uturn.forward", isEnabled: document.canRedo, help: "Redo (⇧⌘Z)") {
                document.redo()
            }
            iconButton("trash", isEnabled: !document.isEmpty, help: "Clear all (⌘⌫)") {
                document.clear()
            }
        }
    }

    /// The pixel readout is how the user judges whether the image is tight enough to be worth
    /// an agent's attention, which is the whole reason crop exists (PLAN §11.3).
    private var output: some View {
        HStack(spacing: 4) {
            Text(outputText)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(document.isCropped ? Color.accentColor : Color.secondary)
                .help("Size delivered to the agent")
            if document.isCropped {
                iconButton(
                    "arrow.up.left.and.arrow.down.right",
                    help: "Reset crop to the full image (⇧⌘R)"
                ) {
                    document.resetCrop()
                }
            }
        }
    }

    private var finishActions: some View {
        HStack(spacing: 4) {
            iconButton(
                "square.and.arrow.down",
                help: "Save As… — write the PNG where you choose (⇧⌘S)",
                action: onSaveAs
            )
            iconButton("folder", help: "Copy PNG file path (⌥⌘↩)", action: onCopyPath)
            Button(action: onCopyImage) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.clipboard")
                    Text("Copy")
                }
                .font(.system(size: 12, weight: .semibold))
            }
            .controlSize(.small)
            .help("Copy the annotated image to the clipboard (⌘↩)")
            iconButton("xmark", help: "Close without copying (Esc)", action: onCancel)
        }
    }

    private var outputText: String {
        let size = document.outputSize
        return "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) px"
    }

    private func dotDiameter(_ size: AnnotationSize) -> CGFloat {
        switch size {
        case .small: 5
        case .medium: 8
        case .large: 11
        }
    }

    private func iconButton(
        _ symbolName: String,
        isOn: Bool = false,
        isEnabled: Bool = true,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .opacity(isEnabled ? 1 : 0.3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
    }
}

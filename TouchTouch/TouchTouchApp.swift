import SwiftUI

@main
struct TouchTouchApp: App {
    @State private var engine = TouchTouchEngine()

    var body: some Scene {
        MenuBarExtra("TouchTouch", systemImage: engine.isEnabled ? "hand.tap.fill" : "hand.tap") {
            Toggle("Enabled", isOn: $engine.isEnabled)

            Menu("Copy Bind") {
                ForEach(GestureBinding.allCases) { binding in
                    Toggle(
                        binding.title,
                        isOn: Binding(
                            get: { engine.isCopyBindingEnabled(binding) },
                            set: { engine.setCopyBinding(binding, isEnabled: $0) }
                        )
                    )
                    .disabled(engine.isCopyBindingDisabled(binding))
                }
            }

            Menu("Paste Bind") {
                ForEach(GestureBinding.allCases) { binding in
                    Toggle(
                        binding.title,
                        isOn: Binding(
                            get: { engine.isPasteBindingEnabled(binding) },
                            set: { engine.setPasteBinding(binding, isEnabled: $0) }
                        )
                    )
                    .disabled(engine.isPasteBindingDisabled(binding))
                }
            }

            Divider()

            Button("Quit TouchTouch") {
                engine.quit()
            }
            .keyboardShortcut("q")
        }
    }
}

import Foundation
import ProseKit
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Tiny arg parser

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first.map { $0.hasPrefix("-") ? "run" : $0 } ?? "run"

func flag(_ name: String) -> String? {
    guard let idx = arguments.firstIndex(of: name), idx + 1 < arguments.count else { return nil }
    return arguments[idx + 1]
}
func hasFlag(_ name: String) -> Bool { arguments.contains(name) }

let sampleText = "i think we should maybe consider possibly doing the deploy later tonight if thats ok with everyone and nobody objects to it"

func resolveConfig() -> ProseConfig {
    var config = ConfigLoader.load()
    if hasFlag("--local") {
        config.ollamaBaseURL = "http://localhost:11434"
        config.model = "llama3.2:3b"
        config.apiKey = nil
    }
    if let model = flag("--model") { config.model = model }
    if let url = flag("--url") { config.ollamaBaseURL = url }
    return config
}

func printUsage() {
    print("""
    prose — force-click to improve your writing (Ollama-backed)

    USAGE:
      prose [run]                 Launch the menu-bar app (default)
      prose selftest [opts]       Headless: capture→rewrite→stdout against Ollama
      prose capture-test          Print the currently selected text (needs Accessibility)
      prose snapshot [--out P]    Render the panel UI to a PNG (default /tmp/prose-panel.png)
      prose config                Show resolved configuration (key redacted)
      prose version

    OPTIONS (selftest):
      --text "…"    Text to rewrite (default: a messy sample)
      --local       Force local Ollama (http://localhost:11434, llama3.2:3b)
      --model M     Override model
      --url U       Override Ollama base URL
    """)
}

// MARK: - Commands

@MainActor
func runSelftest() async -> Int32 {
    let config = resolveConfig()
    let text = flag("--text") ?? sampleText
    let backend = (config.apiKey?.isEmpty == false) ? "cloud" : "local"
    FileHandle.standardError.write(Data("prose selftest → \(config.normalizedBaseURL) model=\(config.model) [\(backend)]\n".utf8))
    let presenter = StdoutPresenter()
    let pipeline = RewritePipeline(
        capture: FixedTextCapture(text),
        rewriter: OllamaRewriter(config: config),
        presenter: presenter
    )
    await pipeline.runAndWait()
    return presenter.failed ? 1 : 0
}

@MainActor
func runConfig() {
    let config = resolveConfig()
    let hasKey = (config.apiKey?.isEmpty == false)
    print("""
    endpoint:   \(config.normalizedBaseURL)
    model:      \(config.model)
    backend:    \(hasKey ? "cloud (ollama.com)" : "local")
    apiKey:     \(hasKey ? "set (from Keychain/env)" : "none")
    temperature:\(config.temperature)
    hotkey:     \(config.hotkey.label)
    forceClick: \(config.forceClickEnabled)
    configFile: \(ConfigLoader.defaultPath.path)
    """)
    #if canImport(AppKit)
    print("accessibility: \(Permissions.isAccessibilityTrusted ? "granted" : "NOT granted")")
    #endif
}

#if canImport(AppKit)
@MainActor
func runCaptureTest() async -> Int32 {
    guard Permissions.isAccessibilityTrusted else {
        FileHandle.standardError.write(Data("Accessibility not granted — capture requires it.\n".utf8))
        return 2
    }
    let capture = CompositeCapture([AXSelectionCapture(), ClipboardCopyCapture()])
    if let text = await capture.capturedSelection() {
        print("captured (\(text.count) chars):")
        print(text)
        return 0
    } else {
        FileHandle.standardError.write(Data("no selection captured\n".utf8))
        return 1
    }
}

@MainActor
func runSnapshot() -> Int32 {
    let out = flag("--out") ?? "/tmp/prose-panel.png"
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.finishLaunching()
    let presenter = PanelPresenter()
    let original = flag("--text") ?? sampleText
    let rewrite = "I think we should consider doing the deploy later tonight, if that works for everyone."
    guard let image = presenter.renderForSnapshot(original: original, rewrite: rewrite, phase: .done),
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("snapshot failed to render\n".utf8))
        return 1
    }
    do {
        try png.write(to: URL(fileURLWithPath: out))
        print("wrote \(out) (\(Int(image.size.width))×\(Int(image.size.height)))")
        return 0
    } catch {
        FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
        return 1
    }
}
#endif

// MARK: - Dispatch

switch command {
case "help", "-h", "--help":
    printUsage()

case "version", "--version":
    print("prose 0.1.0")

case "config":
    runConfig()

case "selftest":
    let code = await runSelftest()
    exit(code)

case "capture-test":
    #if canImport(AppKit)
    let code = await runCaptureTest()
    exit(code)
    #else
    print("unsupported platform"); exit(2)
    #endif

case "snapshot":
    #if canImport(AppKit)
    let code = runSnapshot()
    exit(code)
    #else
    print("unsupported platform"); exit(2)
    #endif

case "run":
    #if canImport(AppKit)
    MenuBarApp.launch(config: ConfigLoader.load())
    #else
    print("GUI requires macOS"); exit(2)
    #endif

default:
    FileHandle.standardError.write(Data("unknown command: \(command)\n".utf8))
    printUsage()
    exit(2)
}

import AppKit
import SwiftUI

@main
struct CappyApp: App {
    @StateObject private var model: AppModel

    init() {
        if let flag = CommandLine.arguments.firstIndex(of: "--render-preview"),
            CommandLine.arguments.indices.contains(flag + 1)
        {
            PreviewRenderer.render(to: CommandLine.arguments[flag + 1])
            exit(0)
        }
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView(model: model)
        } label: {
            Label(model.menuSummary ?? "Cappy", systemImage: "gauge.with.dots.needle.50percent")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private enum PreviewRenderer {
    static func render(to path: String) {
        _ = NSApplication.shared
        let renderer = ImageRenderer(content: PreviewDashboardFixture().frame(width: 390))
        renderer.scale = 2
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

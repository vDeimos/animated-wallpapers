import AppKit
import SwiftUI

struct AccountPicturePanel: View {
    let wallpaper: Wallpaper

    var body: some View {
        VStack(alignment: .center, spacing: 9) {
            if let icon = NSImage(contentsOf: wallpaper.icon) {
                Image(nsImage: icon)
                    .resizable().scaledToFill()
                    .frame(width: 66, height: 66)
                    .clipShape(Circle())
                    .overlay { Circle().strokeBorder(.primary.opacity(0.16)) }
                    .onDrag {
                        NSItemProvider(object: wallpaper.icon as NSURL)
                    } preview: {
                        Image(nsImage: icon).resizable().scaledToFit()
                            .frame(width: 66, height: 66).clipShape(.rect(cornerRadius: 10))
                    }
                    .accessibilityLabel("\(wallpaper.title) icon")
                    .help("Drag this icon to your Apple Account picture")
            }
            Text(wallpaper.title).font(.headline).lineLimit(1)
            Text("Drag the icon onto your picture in the System Settings sidebar, then click Save.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show Icon in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([wallpaper.icon])
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

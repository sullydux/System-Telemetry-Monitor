import SwiftUI

struct RemoteShareWindow: View {
    @ObservedObject private var mgr = RemoteShareManager.shared
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing:12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Remote View")
                        .font(Theme.mono(Theme.FontSize.huge).bold())
                        .foregroundColor(Theme.primaryText)
                    Text("Share a read-only view over the local Wi‑Fi")
                        .font(Theme.mono(Theme.FontSize.body))
                        .foregroundColor(Theme.mutedText)
                }
                Spacer()
            }

            VStack(alignment:.leading, spacing:8) {
                Text("Viewer page").font(.caption).foregroundColor(Theme.mutedText)
                HStack {
                    Text("https://sullydux.github.io/System-Telemetry-Monitor/")
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Button(action: { mgr.copyLinkToPasteboard() }) { Image(systemName: "doc.on.doc") }
                        .buttonStyle(PlainButtonStyle())
                }
            }

            VStack(alignment:.leading, spacing:8) {
                Text("Connection key").font(.caption).foregroundColor(Theme.mutedText)
                HStack(spacing:10) {
                    Text(mgr.key)
                        .font(.system(.title2, design: .monospaced)).bold()
                        .textSelection(.enabled)
                    Button(action: { mgr.copyKeyToPasteboard() }) { Text("Copy") }.buttonStyle(FlatButton())
                }
            }

            Text("Open the viewer page on another device, enter the server address shown by the app (for example https://192.168.1.23:8765) and this connection key. Read-only view.")
                .font(Theme.mono(9)).foregroundColor(Theme.mutedText).fixedSize(horizontal:false, vertical:true)

            Spacer()
        }
        .padding(18)
        .onAppear { mgr.maybeRefreshIfExpired() }
        .frame(minWidth:460, minHeight:180)
    }
}

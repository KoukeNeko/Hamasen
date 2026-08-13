import HamasenCore
import SwiftUI

/// Protocol selector for a server form, shared by the add sheet and the
/// detail pane so both offer the same choices and port behaviour.
struct ProtocolPicker: View {
    @Binding var transferProtocol: ServerConfig.TransferProtocol
    /// Bound to the form's port field so switching protocol can move a port
    /// the user never edited.
    @Binding var portText: String

    var body: some View {
        Picker("協定", selection: $transferProtocol) {
            ForEach(ServerConfig.TransferProtocol.allCases, id: \.self) { transferProtocol in
                Text(transferProtocol.displayName).tag(transferProtocol)
            }
        }
        .onChange(of: transferProtocol) { previous, updated in
            // A port the user typed themselves is left alone; only the
            // previous protocol's default follows the switch.
            if portText == String(previous.defaultPort) {
                portText = String(updated.defaultPort)
            }
        }
    }
}

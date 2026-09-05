import Foundation
import AVFoundation
import MediaToolbox
MTRegisterProfessionalVideoWorkflowFormatReaders()
for path in CommandLine.arguments.dropFirst() {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    print(URL(fileURLWithPath: path).lastPathComponent)
    do {
        print(try await asset.loadMediaSelectionGroup(for: .legible) as Any)
    } catch { print(error) }
}

import Foundation
import AVFoundation
import MediaToolbox

// Diagnostic only: inspect asset selection metadata separately from rendering.
// An asset query failure does not prove QuickTime cannot toggle subtitles.
MTRegisterProfessionalVideoWorkflowFormatReaders()
let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("usage: selection-probe FILE...\n".utf8))
    exit(64)
}

for path in paths {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    print("ASSET", url.lastPathComponent)
    do {
        for track in try await asset.load(.tracks) {
            let characteristics = try await track.load(.mediaCharacteristics)
            guard characteristics.contains(.legible) else { continue }
            print("  LEGIBLE track=\(track.trackID) type=\(track.mediaType.rawValue)")
            print("    enabled=\(try await track.load(.isEnabled))")
            do {
                print("    language=\(try await track.load(.extendedLanguageTag) ?? "unspecified")")
            } catch {
                print("    language ERROR", error)
            }
            for format in try await track.load(.formatDescriptions) {
                var flags: CMTextDisplayFlags = 0
                if CMTextFormatDescriptionGetDisplayFlags(format, displayFlagsOut: &flags) == noErr {
                    print("    text-display-flags=\(flags)")
                }
            }
        }
    } catch {
        print("  TRACK ERROR", error)
    }
    do {
        if let group = try await asset.loadMediaSelectionGroup(for: .legible) {
            print("  GROUP options=\(group.options.count) allows-off=\(group.allowsEmptySelection)")
            for option in group.options {
                print("    option=\(option.displayName) language=\(option.extendedLanguageTag ?? "unspecified") default=\(option == group.defaultOption)")
            }
        } else {
            print("  GROUP none")
        }
    } catch {
        print("  GROUP ERROR", error)
    }
}

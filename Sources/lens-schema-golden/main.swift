import Foundation
import LensCore
import LensSchemaGoldenKit

// Regenerates `shared/golden/`. Run from the repository root:
//
//     swift run lens-schema-golden
//
// `PortableSchemaGoldenTests` re-encodes the same samples in memory and fails
// if the committed files drift, so a forgotten regeneration is caught by
// `swift test` rather than by a Windows implementer.

let arguments = CommandLine.arguments
let outputDirectory: URL
if arguments.count > 1 {
    outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
} else {
    outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("shared/golden", isDirectory: true)
}

do {
    try FileManager.default.createDirectory(
        at: outputDirectory,
        withIntermediateDirectories: true
    )

    let documents = try PortableSchemaGoldens.all()
        + PortableSchemaGoldens.allCompact()
    for document in documents {
        let destination = outputDirectory.appendingPathComponent(document.name)
        // Golden files are newline-terminated so they behave in diffs and editors.
        var bytes = document.data
        if bytes.last != UInt8(ascii: "\n") {
            bytes.append(UInt8(ascii: "\n"))
        }
        try bytes.write(to: destination, options: .atomic)
        print("wrote \(document.name) (\(bytes.count) bytes)")
    }

    // A machine-readable index of the registry so a non-Swift implementation can
    // discover paths and supported version ranges without parsing Swift source.
    let registry = LensProjectSchema.portableDocuments.map { descriptor in
        [
            "identifier": descriptor.identifier,
            "relativePath": descriptor.relativePath,
            "minimumReadableVersion": descriptor.minimumReadableVersion,
            "currentVersion": descriptor.currentVersion
        ]
    }
    let indexData = try JSONSerialization.data(
        withJSONObject: ["schemaRegistryVersion": 1, "documents": registry],
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    var indexBytes = indexData
    indexBytes.append(UInt8(ascii: "\n"))
    try indexBytes.write(
        to: outputDirectory.appendingPathComponent("schema-registry.json"),
        options: .atomic
    )
    print("wrote schema-registry.json (\(indexBytes.count) bytes)")
} catch {
    FileHandle.standardError.write(
        Data("lens-schema-golden failed: \(error)\n".utf8)
    )
    exit(1)
}

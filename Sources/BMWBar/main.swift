import BMWBarKit
import Foundation

// `--cli` runs headless so every layer can be verified from a terminal.
// Anything else launches the status bar app.
let arguments = Array(CommandLine.arguments.dropFirst())

if let index = arguments.firstIndex(of: "--cli") {
    let code = await DebugCLI.run(arguments: Array(arguments[(index + 1)...]))
    exit(code)
}

BMWBarApp.main()

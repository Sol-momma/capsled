import Foundation

public enum LEDMode: String, Equatable {
    case on
    case off
    case automatic = "auto"

    /// The HID event-system filter accepts these title-cased values. They are
    /// intentionally kept out of the CLI parser so user-facing spelling can
    /// remain stable if the private SPI representation changes later.
    var eventSystemValue: String {
        switch self {
        case .on: "On"
        case .off: "Off"
        case .automatic: "Auto"
        }
    }
}

public enum CLICommand: Equatable {
    case set(LEDMode)
    case run([String])
    case watch
    case help
}

public struct CLIParseError: LocalizedError, Equatable {
    public let message: String

    public var errorDescription: String? { message }
}

public enum CLIParser {
    public static let usage = """
    Usage:
      capsled on
      capsled off
      capsled auto
      capsled run -- <command> [arguments...]
      capsled watch

    Commands:
      on      Keep the physical Caps Lock LED on in the background.
      off     Force the physical Caps Lock LED off.
      auto    Return LED ownership to macOS.
      run     Keep the LED on while a child command runs, then return to auto.
      watch   Toggle the LED when the physical Caps Lock key is pressed.
    """

    public static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let first = arguments.first else { return .help }

        switch first {
        case "on":
            try requireNoTrailingArguments(arguments)
            return .set(.on)
        case "off":
            try requireNoTrailingArguments(arguments)
            return .set(.off)
        case "auto":
            try requireNoTrailingArguments(arguments)
            return .set(.automatic)
        case "run":
            var childArguments = Array(arguments.dropFirst())
            if childArguments.first == "--" {
                childArguments.removeFirst()
            }
            guard !childArguments.isEmpty else {
                throw CLIParseError(message: "capsled run requires a command")
            }
            return .run(childArguments)
        case "watch":
            try requireNoTrailingArguments(arguments)
            return .watch
        case "help", "-h", "--help":
            return .help
        default:
            throw CLIParseError(message: "unknown command: \(first)")
        }
    }

    private static func requireNoTrailingArguments(_ arguments: [String]) throws {
        guard arguments.count == 1 else {
            throw CLIParseError(message: "\(arguments[0]) does not accept arguments")
        }
    }
}

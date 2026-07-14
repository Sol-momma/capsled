import Foundation

@main
enum CommandParserCheck {
    static func main() throws {
        let on = try CLIParser.parse(["on"])
        let off = try CLIParser.parse(["off"])
        let automatic = try CLIParser.parse(["auto"])
        let run = try CLIParser.parse(["run", "--", "npm", "test"])
        let help = try CLIParser.parse(["--help"])

        precondition(on == .set(.on))
        precondition(off == .set(.off))
        precondition(automatic == .set(.automatic))
        precondition(run == .run(["npm", "test"]))
        precondition(help == .help)

        do {
            _ = try CLIParser.parse(["run"])
            preconditionFailure("run without a child command must fail")
        } catch is CLIParseError {
            // Expected: argument validation must finish before any LED backend
            // is created, so malformed commands can never alter hardware state.
        }

        print("Command parser checks passed")
    }
}

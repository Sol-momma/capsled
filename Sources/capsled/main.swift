import CapsLEDCore
import Darwin
import Foundation

let status = CapsLEDApplication.execute(
    arguments: Array(CommandLine.arguments.dropFirst())
)
exit(status)

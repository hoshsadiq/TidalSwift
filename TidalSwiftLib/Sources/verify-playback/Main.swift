//
//  Main.swift
//  verify-playback
//
//  Entry point: parse the options and run the verifier.
//

import Darwin
import Foundation

@main
struct VerifyPlaybackTool {
	static func main() async {
		let arguments = Array(CommandLine.arguments.dropFirst())
		if arguments.contains("--help") || arguments.contains("-h") {
			print(Options.usage)
			exit(0)
		}

		let options: Options
		do {
			options = try Options.parse(arguments)
		} catch {
			FileHandle.standardError.write(Data("verify-playback: \(error)\n\n\(Options.usage)\n".utf8))
			exit(2)
		}

		let code = await Verifier.run(options: options)
		exit(Int32(code))
	}
}

//
//  PreferencesSettingsTests.swift
//  TidalSwiftLibTests
//

import XCTest

/// The Playback settings tab is app-target SwiftUI with no test host, so this pins the settings
/// shape at the source: the two quality halves are named for what they change, and each Atmos
/// switch says which of playback and download it affects. A guard against a silent rename that
/// would leave the two switches indistinguishable.
@MainActor
final class PreferencesSettingsTests: XCTestCase {
	/// The app target's settings file, reached from this test file so the guard needs no build
	/// product. A moved file fails loudly rather than skipping.
	private func preferencesSource() throws -> String {
		let repositoryRoot = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
		let file = repositoryRoot.appendingPathComponent("TidalSwift/Preferences/PreferencesView.swift")
		return try String(contentsOf: file, encoding: .utf8)
	}

	func testTheTwoQualityHalvesAreNamedStreamAndDownload() throws {
		let source = try preferencesSource()
		XCTAssertTrue(
			source.contains("Text(\"Stream\").tag(QualityTarget.stream)"),
			"the streaming half must be named Stream"
		)
		XCTAssertTrue(
			source.contains("Text(\"Download\").tag(QualityTarget.download)"),
			"the download half must be named Download"
		)
	}

	func testEachAtmosSwitchNamesTheEffectItHas() throws {
		let source = try preferencesSource()
		XCTAssertTrue(
			source.contains("Prefer Dolby Atmos for streaming"),
			"the playback switch must say it affects streaming"
		)
		XCTAssertTrue(
			source.contains("Prefer Dolby Atmos for downloads"),
			"the offline switch must say it affects downloads"
		)
	}

	func testTheStreamingAtmosHelpStatesTheCeilingRule() throws {
		let source = try preferencesSource()
		// Unique to the streaming help: the download help says "never saves", so this phrase keeps
		// the guard discriminating if the streaming help is ever deleted.
		XCTAssertTrue(
			source.contains("below that, Atmos is never played"),
			"the help text must say a lower ceiling never plays Atmos"
		)
	}

	/// The download switch is gated by the offline ceiling too, so its help must state the same
	/// rule the streaming half does rather than leaving a switch that does nothing unexplained.
	func testTheDownloadAtmosHelpStatesTheCeilingRule() throws {
		let source = try preferencesSource()
		XCTAssertTrue(
			source.contains("so a lower quality setting never saves Atmos"),
			"the download help text must say a lower ceiling never stores Atmos"
		)
	}
}

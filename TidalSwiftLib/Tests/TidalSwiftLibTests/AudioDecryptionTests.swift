//
//  AudioDecryptionTests.swift
//  TidalSwiftLibTests
//

import AVFoundation
import CommonCrypto
import XCTest
@testable import TidalSwiftLib

/// Checks `AudioDecryption` against an independent AES implementation.
///
/// The fixtures are built here with CommonCrypto's *native* CTR mode and a CBC-encrypt
/// wrap, so the tests never reuse the decryption paths they are checking: the code under
/// test builds its keystream from hand-assembled counter blocks and ECB, while the tests
/// ask CommonCrypto to run the counter itself.
final class AudioDecryptionTests: XCTestCase {
	private enum TestError: Error {
		case crypto(CCCryptorStatus)
		case malformed(String)
	}

	private let unwrapKey = Data(base64Encoded: AudioDecryption.unwrapKeyBase64)!

	// MARK: - Temporary files

	private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("AudioDecryptionTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		try body(directory)
	}

	private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
		try XCTUnwrap(
			Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
			"Missing fixture \(name).\(ext)"
		)
	}

	private func write(_ data: Data, to directory: URL, named name: String) throws -> URL {
		let url = directory.appendingPathComponent(name)
		try data.write(to: url)
		return url
	}

	// MARK: - Independent AES

	private func randomBytes(_ count: Int) -> Data {
		Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
	}

	/// AES-128-CTR with CommonCrypto's own big-endian counter, keystream starting at zero.
	private func ctrEncrypt(_ plaintext: Data, key: Data, nonce: Data) throws -> Data {
		var counter = nonce
		counter.append(Data(count: 8))
		var cryptor: CCCryptorRef?
		let status = key.withUnsafeBytes { keyBuffer in
			counter.withUnsafeBytes { counterBuffer in
				CCCryptorCreateWithMode(
					CCOperation(kCCEncrypt),
					CCMode(kCCModeCTR),
					CCAlgorithm(kCCAlgorithmAES),
					CCPadding(ccNoPadding),
					counterBuffer.baseAddress,
					keyBuffer.baseAddress, key.count,
					nil, 0, 0,
					CCModeOptions(kCCModeOptionCTR_BE),
					&cryptor
				)
			}
		}
		guard status == kCCSuccess, let cryptor else { throw TestError.crypto(status) }
		defer { CCCryptorRelease(cryptor) }

		var output = Data(count: plaintext.count + 16)
		var moved = 0
		let updateStatus = plaintext.withUnsafeBytes { plaintextBuffer in
			output.withUnsafeMutableBytes { outputBuffer in
				CCCryptorUpdate(cryptor, plaintextBuffer.baseAddress, plaintext.count, outputBuffer.baseAddress, outputBuffer.count, &moved)
			}
		}
		guard updateStatus == kCCSuccess else { throw TestError.crypto(updateStatus) }
		return output.prefix(moved)
	}

	/// Wraps `key || nonce` into a synthetic `keyId` the way Tidal does: AES-256-CBC/PKCS7 under the master key, prefixed with the raw IV.
	private func wrapKeyId(key: Data, nonce: Data) throws -> String {
		var plaintext = key
		plaintext.append(nonce)
		let iv = randomBytes(16)
		var output = Data(count: plaintext.count + 16)
		var moved = 0
		let status = output.withUnsafeMutableBytes { outputBuffer in
			plaintext.withUnsafeBytes { plaintextBuffer in
				unwrapKey.withUnsafeBytes { keyBuffer in
					iv.withUnsafeBytes { ivBuffer in
						CCCrypt(
							CCOperation(kCCEncrypt),
							CCAlgorithm(kCCAlgorithmAES),
							CCOptions(kCCOptionPKCS7Padding),
							keyBuffer.baseAddress, unwrapKey.count, ivBuffer.baseAddress,
							plaintextBuffer.baseAddress, plaintext.count,
							outputBuffer.baseAddress, outputBuffer.count, &moved
						)
					}
				}
			}
		}
		guard status == kCCSuccess else { throw TestError.crypto(status) }
		var token = iv
		token.append(output.prefix(moved))
		return token.base64EncodedString()
	}

	// MARK: - Unwrap

	func testUnwrapKeyIdRecoversTheWrappedKeyAndNonce() throws {
		let key = randomBytes(16)
		let nonce = randomBytes(8)
		let keyId = try wrapKeyId(key: key, nonce: nonce)

		let unwrapped = try AudioDecryption.unwrapKeyId(keyId)

		XCTAssertEqual(unwrapped.key, key)
		XCTAssertEqual(unwrapped.nonce, nonce)
	}

	func testUnwrapKeyIdRejectsNonBase64() throws {
		XCTAssertThrowsError(try AudioDecryption.unwrapKeyId("not base64 !!")) { error in
			guard case AudioDecryptionError.malformedKeyId = error else {
				return XCTFail("expected malformedKeyId, got \(error)")
			}
		}
	}

	func testUnwrapKeyIdRejectsATooShortToken() throws {
		// 16-byte IV plus a single 16-byte block: a whole block, but not enough for a key and nonce.
		let keyId = randomBytes(32).base64EncodedString()
		XCTAssertThrowsError(try AudioDecryption.unwrapKeyId(keyId)) { error in
			guard case AudioDecryptionError.malformedKeyId = error else {
				return XCTFail("expected malformedKeyId, got \(error)")
			}
		}
	}

	func testUnwrapKeyIdRejectsALengthThatIsNotABlockMultipleAfterTheIV() throws {
		// 16-byte IV plus 49 ciphertext bytes: long enough, but CBC cannot run on a partial block.
		let keyId = randomBytes(65).base64EncodedString()
		XCTAssertThrowsError(try AudioDecryption.unwrapKeyId(keyId)) { error in
			guard case AudioDecryptionError.malformedKeyId = error else {
				return XCTFail("expected malformedKeyId, got \(error)")
			}
		}
	}

	func testUnwrapKeyIdRejectsAnEmptyToken() throws {
		XCTAssertThrowsError(try AudioDecryption.unwrapKeyId("")) { error in
			guard case AudioDecryptionError.malformedKeyId = error else {
				return XCTFail("expected malformedKeyId, got \(error)")
			}
		}
	}

	// MARK: - In-memory decrypt

	func testDecryptRestoresTheOriginalBytes() throws {
		let original = try Data(contentsOf: try fixtureURL("silent", "flac"))
		let key = randomBytes(16)
		let nonce = randomBytes(8)
		let keyId = try wrapKeyId(key: key, nonce: nonce)

		let ciphertext = try ctrEncrypt(original, key: key, nonce: nonce)
		XCTAssertNotEqual(ciphertext, original, "the fixture should actually be encrypted")

		let decrypted = try AudioDecryption.decrypt(ciphertext, keyId: keyId)
		XCTAssertEqual(decrypted, original)
	}

	func testDecryptedFLACDecodesAsTheSameAudio() throws {
		let original = try Data(contentsOf: try fixtureURL("silent", "flac"))
		let key = randomBytes(16)
		let nonce = randomBytes(8)
		let keyId = try wrapKeyId(key: key, nonce: nonce)
		let ciphertext = try ctrEncrypt(original, key: key, nonce: nonce)

		try withTemporaryDirectory { directory in
			let decryptedURL = try write(AudioDecryption.decrypt(ciphertext, keyId: keyId), to: directory, named: "decrypted.flac")
			let originalURL = try write(original, to: directory, named: "original.flac")

			let originalFile = try AVAudioFile(forReading: originalURL)
			let decryptedFile = try AVAudioFile(forReading: decryptedURL)

			XCTAssertEqual(decryptedFile.length, originalFile.length)
			XCTAssertGreaterThan(decryptedFile.length, 0)
			XCTAssertEqual(decryptedFile.fileFormat.sampleRate, originalFile.fileFormat.sampleRate)
		}
	}

	// MARK: - Block boundary and chunking

	func testDecryptHandlesALengthThatIsNotABlockMultiple() throws {
		// 12345 bytes: 771 whole blocks plus 9 trailing bytes. A stream cipher must still
		// produce all 12345 bytes; a block-cipher-style implementation would pad or truncate.
		let plaintext = randomBytes(12345)
		XCTAssertEqual(plaintext.count % 16, 9, "fixture should end mid-block")
		let key = randomBytes(16)
		let nonce = randomBytes(8)
		let keyId = try wrapKeyId(key: key, nonce: nonce)
		let ciphertext = try ctrEncrypt(plaintext, key: key, nonce: nonce)

		try withTemporaryDirectory { directory in
			let source = try write(ciphertext, to: directory, named: "partial.enc")
			let destination = directory.appendingPathComponent("partial.flac")
			try AudioDecryption.decrypt(fileAt: source, to: destination, keyId: keyId)

			XCTAssertEqual(try Data(contentsOf: destination), plaintext)
		}
	}

	func testDecryptHandlesAFileSpanningManyChunks() throws {
		// 512 KiB spans eight 64 KiB reads, so the counter has to keep counting across them.
		let plaintext = randomBytes(512 * 1024)
		let key = randomBytes(16)
		let nonce = randomBytes(8)
		let keyId = try wrapKeyId(key: key, nonce: nonce)
		let ciphertext = try ctrEncrypt(plaintext, key: key, nonce: nonce)

		try withTemporaryDirectory { directory in
			let source = try write(ciphertext, to: directory, named: "large.enc")
			let destination = directory.appendingPathComponent("large.flac")
			try AudioDecryption.decrypt(fileAt: source, to: destination, keyId: keyId)

			let decrypted = try Data(contentsOf: destination)
			XCTAssertEqual(decrypted.count, plaintext.count)
			XCTAssertEqual(decrypted, plaintext)
			// A counter reset at a chunk boundary would leave the first block of every chunk right and the rest wrong.
			XCTAssertEqual(decrypted, try AudioDecryption.decrypt(ciphertext, key: key, nonce: nonce))
		}
	}

	func testDecryptRejectsAKeyOfTheWrongLength() throws {
		XCTAssertThrowsError(try AudioDecryption.decrypt(Data(repeating: 0, count: 32), key: randomBytes(8), nonce: randomBytes(8))) { error in
			guard case AudioDecryptionError.invalidKeyLength = error else {
				return XCTFail("expected invalidKeyLength, got \(error)")
			}
		}
	}

	func testDecryptRejectsANonceOfTheWrongLength() throws {
		XCTAssertThrowsError(try AudioDecryption.decrypt(Data(repeating: 0, count: 32), key: randomBytes(16), nonce: randomBytes(12))) { error in
			guard case AudioDecryptionError.invalidNonceLength = error else {
				return XCTFail("expected invalidNonceLength, got \(error)")
			}
		}
	}
}

//
//  EncryptedFLACFixture.swift
//  TidalSwiftLibTests
//

import CommonCrypto
import Foundation
@testable import TidalSwiftLib

/// Builds an `OLD_AES`-encrypted copy of the `silent.flac` fixture with its matching `keyId`,
/// so the download-and-decrypt path can be driven without a live account. Encryption uses
/// CommonCrypto's own CTR mode, not the module's hand-built counter blocks.
enum EncryptedFLACFixture {
	struct Encrypted {
		let url: URL
		let keyId: String
	}

	private static let unwrapKey = Data(base64Encoded: AudioDecryption.unwrapKeyBase64)!

	static func make(in directory: URL, named name: String = "encrypted.flac") throws -> Encrypted {
		try build(in: directory, named: name)
	}

	private static func build(in directory: URL, named name: String) throws -> Encrypted {
		guard let plaintextURL = Bundle.module.url(forResource: "silent", withExtension: "flac", subdirectory: "Fixtures"),
			  let plaintext = try? Data(contentsOf: plaintextURL) else {
			throw FixtureError.missingSilentFLAC
		}
		let key = randomBytes(16)
		let nonce = randomBytes(8)
		let ciphertext = try ctrEncrypt(plaintext, key: key, nonce: nonce)
		let url = directory.appendingPathComponent(name)
		try ciphertext.write(to: url)
		return Encrypted(url: url, keyId: try wrapKeyId(key: key, nonce: nonce))
	}

	enum FixtureError: Error {
		case missingSilentFLAC
		case crypto(CCCryptorStatus)
	}

	private static func randomBytes(_ count: Int) -> Data {
		Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
	}

	/// AES-128-CTR with CommonCrypto's own big-endian counter, keystream starting at zero.
	private static func ctrEncrypt(_ plaintext: Data, key: Data, nonce: Data) throws -> Data {
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
		guard status == kCCSuccess, let cryptor else { throw FixtureError.crypto(status) }
		defer { CCCryptorRelease(cryptor) }

		var output = Data(count: plaintext.count + 16)
		var moved = 0
		let updateStatus = plaintext.withUnsafeBytes { plaintextBuffer in
			output.withUnsafeMutableBytes { outputBuffer in
				CCCryptorUpdate(cryptor, plaintextBuffer.baseAddress, plaintext.count, outputBuffer.baseAddress, outputBuffer.count, &moved)
			}
		}
		guard updateStatus == kCCSuccess else { throw FixtureError.crypto(updateStatus) }
		return output.prefix(moved)
	}

	/// Wraps `key || nonce` into a synthetic `keyId` the way Tidal does: AES-256-CBC/PKCS7
	/// under the master key, prefixed with the raw IV.
	private static func wrapKeyId(key: Data, nonce: Data) throws -> String {
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
		guard status == kCCSuccess else { throw FixtureError.crypto(status) }
		var token = iv
		token.append(output.prefix(moved))
		return token.base64EncodedString()
	}
}

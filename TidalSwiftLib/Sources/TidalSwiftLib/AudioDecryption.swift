//
//  AudioDecryption.swift
//  TidalSwiftLib
//

import CommonCrypto
import Foundation

/// Something went wrong while unwrapping or applying Tidal's content encryption.
enum AudioDecryptionError: Swift.Error, Equatable {
	/// The base64 `keyId` could not be decoded, or its length does not describe an IV plus a whole number of AES blocks.
	case malformedKeyId(String)
	/// The master-key step did not return enough plaintext to hold a content key and nonce.
	case keyUnwrapFailed
	/// An AES key had the wrong length for the operation (128-bit for the stream, 256-bit for the master key).
	case invalidKeyLength(Int)
	/// The nonce was not the 8 bytes the Tidal counter reserves for it.
	case invalidNonceLength(Int)
	/// CommonCrypto refused the operation.
	case cryptoFailed(Int32)
	/// The decrypted bytes were empty, too short, or did not begin with the FLAC marker, so
	/// they were discarded instead of left where a later existence-only cache hit would
	/// serve the truncated file as a finished stream.
	case notFLAC
}

/// Removes Tidal's legacy content encryption (`OLD_AES`) so a downloaded file becomes
/// a playable FLAC.
///
/// Tidal never hands out the content key directly. `playbackinfo` returns a base64
/// `keyId`; inside it are a random 16-byte content key and its 8-byte nonce, themselves
/// encrypted with a single fixed master key. That master key ships in every third-party
/// Tidal client and is public only because those tools published it — it is not a secret
/// in this codebase.
///
/// Format of the decoded `keyId`:
/// - `token[0..<16]` is the random IV of the outer AES-256-CBC layer.
/// - `token[16...]` is a whole number of AES blocks: the 24 bytes `contentKey || nonce`,
///   PKCS7-padded to 32. The padding is ignored, not unpadded.
///
/// The downloaded file is that content key used as AES-128-CTR. The 128-bit counter is
/// `nonce` (8 bytes) followed by a big-endian counter that starts at zero and increments
/// once per 16-byte block to the end of the file.
///
/// This is DRM circumvention: the service encrypted the bytes on purpose and this type
/// removes that encryption. Whoever ships it should make that call deliberately.
nonisolated enum AudioDecryption {
	/// The fixed key (base64) that unwraps the content key — the "master key" of the
	/// third-party Tidal tools. Public knowledge, not a secret here.
	static let unwrapKeyBase64 = "UIlTTEMmmLfGowo/UC60x2H45W6MdGgTRfo/umg4754="

	private static let blockLength = 16
	private static let nonceLength = 8
	private static let contentKeyLength = 16
	/// A content key plus its nonce, the plaintext of the master-key step.
	private static let unwrappedLength = contentKeyLength + nonceLength
	/// 64 KiB, a multiple of the AES block size so chunked CTR stays block-aligned.
	private static let chunkLength = 1 << 16
	/// The four bytes that begin every FLAC stream.
	private static let flacMagic = Data("fLaC".utf8)
	/// The shortest FLAC prefix: the marker, the STREAMINFO metadata block header (4 bytes)
	/// and its fixed 34-byte body. Anything shorter cannot be a FLAC stream.
	private static let minimumFLACLength = 42

	/// Unwraps a base64 `keyId` into the content key and its nonce.
	///
	/// Throws ``AudioDecryptionError/malformedKeyId(_:)`` when the token is not base64, is
	/// too short to hold an IV plus a full unwrapped key, or leaves a partial AES block
	/// after the IV. Throws ``AudioDecryptionError/keyUnwrapFailed`` when the master-key
	/// step returns too little plaintext.
	static func unwrapKeyId(_ keyId: String) throws -> (key: Data, nonce: Data) {
		guard let token = Data(base64Encoded: keyId) else {
			throw AudioDecryptionError.malformedKeyId("not base64")
		}
		guard token.count >= blockLength + unwrappedLength else {
			throw AudioDecryptionError.malformedKeyId("\(token.count) bytes is too short for an IV and a key")
		}
		let ciphertextLength = token.count - blockLength
		guard ciphertextLength % blockLength == 0 else {
			throw AudioDecryptionError.malformedKeyId("\(ciphertextLength) ciphertext bytes is not a whole number of blocks")
		}

		let unwrapKey = Data(base64Encoded: unwrapKeyBase64)!
		let iv = token.prefix(blockLength)
		let ciphertext = token.suffix(from: blockLength)
		let plaintext = try aes256CBCDecrypt(Data(ciphertext), key: unwrapKey, iv: Data(iv))
		guard plaintext.count >= unwrappedLength else {
			throw AudioDecryptionError.keyUnwrapFailed
		}
		return (
			key: plaintext.prefix(contentKeyLength),
			nonce: plaintext.subdata(in: contentKeyLength..<unwrappedLength)
		)
	}

	/// Decrypts an in-memory buffer with an already-unwrapped key and nonce.
	static func decrypt(_ ciphertext: Data, key: Data, nonce: Data) throws -> Data {
		try ctrApply(ciphertext, key: key, nonce: nonce, startingBlockIndex: 0)
	}

	/// Unwraps `keyId` and decrypts an in-memory buffer with it.
	static func decrypt(_ ciphertext: Data, keyId: String) throws -> Data {
		let (key, nonce) = try unwrapKeyId(keyId)
		return try decrypt(ciphertext, key: key, nonce: nonce)
	}

	/// Unwraps `keyId` and decrypts the file at `source` into `destination`.
	static func decrypt(fileAt source: URL, to destination: URL, keyId: String) throws {
		let (key, nonce) = try unwrapKeyId(keyId)
		try decrypt(fileAt: source, to: destination, key: key, nonce: nonce)
	}

	/// Decrypts the file at `source` into `destination` with an already-unwrapped key and nonce.
	///
	/// Reads and writes in blocks so a 30 MB file never has to sit in memory whole. The
	/// counter keeps running across reads, so chunk boundaries are invisible to the output.
	///
	/// The bytes land in a temporary sibling of `destination` and are moved onto it only
	/// after they verify as FLAC. A kill, a cancel or a full disk midway therefore leaves
	/// nothing at `destination`, instead of a truncated file that a later existence-only
	/// cache hit would serve as a finished stream forever. Cancellation is checked once per
	/// block, so a cancelled task throws `CancellationError` and the temporary file goes away.
	static func decrypt(fileAt source: URL, to destination: URL, key: Data, nonce: Data) throws {
		let temporary = destination
			.deletingLastPathComponent()
			.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: temporary) }

		let input = try FileHandle(forReadingFrom: source)
		defer { try? input.close() }
		FileManager.default.createFile(atPath: temporary.path, contents: nil)
		let output = try FileHandle(forWritingTo: temporary)
		defer { try? output.close() }

		var blockIndex: UInt64 = 0
		while true {
			try Task.checkCancellation()
			var chunk = Data()
			while chunk.count < chunkLength {
				guard let part = try input.read(upToCount: chunkLength - chunk.count), !part.isEmpty else { break }
				chunk.append(part)
			}
			if chunk.isEmpty { break }
			try output.write(contentsOf: ctrApply(chunk, key: key, nonce: nonce, startingBlockIndex: blockIndex))
			blockIndex += UInt64((chunk.count + blockLength - 1) / blockLength)
		}
		try output.close()

		try verifyFLAC(at: temporary)
		try install(temporary, at: destination)
	}

	/// Rejects an empty, truncated or non-FLAC decrypt so it can never become a cache entry.
	private static func verifyFLAC(at url: URL) throws {
		let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
		guard size >= minimumFLACLength else { throw AudioDecryptionError.notFLAC }
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		guard try handle.read(upToCount: flacMagic.count) == flacMagic else {
			throw AudioDecryptionError.notFLAC
		}
	}

	/// Moves the verified temporary file onto `destination` in one step, replacing any file
	/// already there rather than appending to it.
	private static func install(_ temporary: URL, at destination: URL) throws {
		if FileManager.default.fileExists(atPath: destination.path) {
			_ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
		} else {
			try FileManager.default.moveItem(at: temporary, to: destination)
		}
	}

	// MARK: - AES primitives

	/// XORs `input` with the AES-128-CTR keystream whose counter starts at `startingBlockIndex`.
	private static func ctrApply(_ input: Data, key: Data, nonce: Data, startingBlockIndex: UInt64) throws -> Data {
		guard key.count == kCCKeySizeAES128 else {
			throw AudioDecryptionError.invalidKeyLength(key.count)
		}
		guard nonce.count == nonceLength else {
			throw AudioDecryptionError.invalidNonceLength(nonce.count)
		}
		guard !input.isEmpty else { return Data() }

		let blockCount = (input.count + blockLength - 1) / blockLength
		var counters = Data(capacity: blockCount * blockLength)
		for offset in 0..<blockCount {
			var index = (startingBlockIndex + UInt64(offset)).bigEndian
			counters.append(nonce)
			withUnsafeBytes(of: &index) { counters.append(contentsOf: $0) }
		}
		let keystream = try aesECBEncrypt(counters, key: key)

		var output = Data(count: input.count)
		input.withUnsafeBytes { inputBuffer in
			keystream.withUnsafeBytes { keystreamBuffer in
				output.withUnsafeMutableBytes { outputBuffer in
					let inputBytes = inputBuffer.bindMemory(to: UInt8.self).baseAddress!
					let keystreamBytes = keystreamBuffer.bindMemory(to: UInt8.self).baseAddress!
					let outputBytes = outputBuffer.bindMemory(to: UInt8.self).baseAddress!
					for index in 0..<input.count {
						outputBytes[index] = inputBytes[index] ^ keystreamBytes[index]
					}
				}
			}
		}
		return output
	}

	/// One-shot AES-ECB with no padding, used to turn counter blocks into keystream.
	private static func aesECBEncrypt(_ plaintext: Data, key: Data) throws -> Data {
		var output = Data(count: plaintext.count)
		var moved = 0
		let status = output.withUnsafeMutableBytes { outputBuffer in
			plaintext.withUnsafeBytes { plaintextBuffer in
				key.withUnsafeBytes { keyBuffer in
					CCCrypt(
						CCOperation(kCCEncrypt),
						CCAlgorithm(kCCAlgorithmAES),
						CCOptions(kCCOptionECBMode),
						keyBuffer.baseAddress, key.count, nil,
						plaintextBuffer.baseAddress, plaintext.count,
						outputBuffer.baseAddress, outputBuffer.count, &moved
					)
				}
			}
		}
		guard status == kCCSuccess, moved == plaintext.count else {
			throw AudioDecryptionError.cryptoFailed(status)
		}
		return output
	}

	/// One-shot AES-256-CBC with no padding. The caller only consumes the first 24 bytes.
	private static func aes256CBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
		guard key.count == kCCKeySizeAES256 else {
			throw AudioDecryptionError.invalidKeyLength(key.count)
		}
		guard iv.count == blockLength else {
			throw AudioDecryptionError.malformedKeyId("IV is \(iv.count) bytes, not \(blockLength)")
		}
		var output = Data(count: ciphertext.count)
		var moved = 0
		let status = output.withUnsafeMutableBytes { outputBuffer in
			ciphertext.withUnsafeBytes { ciphertextBuffer in
				key.withUnsafeBytes { keyBuffer in
					iv.withUnsafeBytes { ivBuffer in
						CCCrypt(
							CCOperation(kCCDecrypt),
							CCAlgorithm(kCCAlgorithmAES),
							CCOptions(0),
							keyBuffer.baseAddress, key.count, ivBuffer.baseAddress,
							ciphertextBuffer.baseAddress, ciphertext.count,
							outputBuffer.baseAddress, outputBuffer.count, &moved
						)
					}
				}
			}
		}
		guard status == kCCSuccess else {
			throw AudioDecryptionError.cryptoFailed(status)
		}
		guard moved == ciphertext.count else {
			throw AudioDecryptionError.keyUnwrapFailed
		}
		return output
	}
}

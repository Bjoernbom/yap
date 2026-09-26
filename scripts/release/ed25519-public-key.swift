// Reads a Sparkle EdDSA private key (base64 of the 32-byte seed, as
// `generate_keys -x` exports it) on stdin and prints its public key in the
// base64 form SUPublicEDKey uses. package.sh runs it to catch a mismatched
// key pair before a release ships that no installed app can verify.
import CryptoKit
import Foundation

let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
	.trimmingCharacters(in: .whitespacesAndNewlines)
guard let seed = Data(base64Encoded: input) else {
	FileHandle.standardError.write(Data("error: the private key isn't base64\n".utf8))
	exit(1)
}
guard seed.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
	FileHandle.standardError.write(Data("error: expected a 32-byte ed25519 seed, got \(seed.count) bytes\n".utf8))
	exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())

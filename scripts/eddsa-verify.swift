// swift scripts/eddsa-verify.swift <public key, base64> <file> <signature, base64>
//
// Checks a file against an EdDSA signature with the public key alone — what an installed copy
// does with SUPublicEDKey. Sparkle's own `sign_update --verify` needs the private key, which the
// published-release probe must never have.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
    let keyData = Data(base64Encoded: args[1]),
    let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
    let file = FileManager.default.contents(atPath: args[2]),
    let signature = Data(base64Encoded: args[3])
else {
    FileHandle.standardError.write(Data("usage: eddsa-verify.swift <public key> <file> <signature>\n".utf8))
    exit(2)
}
if key.isValidSignature(signature, for: file) {
    print("EdDSA signature matches")
} else {
    FileHandle.standardError.write(Data("EdDSA signature does not match\n".utf8))
    exit(1)
}

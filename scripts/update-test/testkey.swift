// Writes a throwaway EdDSA pair for the update test: <dir>/private.key (base64 seed) and prints
// the public key (base64), the form Info.plist's SUPublicEDKey takes. Never a real release key.
import CryptoKit
import Foundation

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(
    toFile: dir + "/private.key", atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())

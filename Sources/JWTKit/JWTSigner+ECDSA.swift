import CJWTKitCrypto

extension JWTSigner {
    // MARK: ECDSA

    public static func es256(key: ECDSAKey) -> JWTSigner {
        return .init(algorithm: ECDSASigner(
            key: key,
            algorithm: convert(EVP_sha256()),
            name: "ES256"
        ))
    }

    public static func es384(key: ECDSAKey) -> JWTSigner {
        return .init(algorithm: ECDSASigner(
            key: key,
            algorithm: convert(EVP_sha384()),
            name: "ES384"
        ))
    }

    public static func es512(key: ECDSAKey) -> JWTSigner {
        return .init(algorithm: ECDSASigner(
            key: key,
            algorithm: convert(EVP_sha512()),
            name: "ES512"
        ))
    }
}

public final class ECDSAKey: OpenSSLKey {
    public static func generate() throws -> ECDSAKey {
        guard let c = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1) else {
            throw JWTError.signingAlgorithmFailure(ECDSAError.newKeyByCurveFailure)
        }
        guard EC_KEY_generate_key(c) != 0 else {
            throw JWTError.signingAlgorithmFailure(ECDSAError.generateKeyFailure)
        }
        return .init(c)
    }

    public static func `public`<Data>(pem data: Data) throws -> ECDSAKey
        where Data: DataProtocol
    {
        let c = try self.load(pem: data) { bio in
            PEM_read_bio_EC_PUBKEY(convert(bio), nil, nil, nil)
        }
        return self.init(c)
    }

    public static func `private`<Data>(pem data: Data) throws -> ECDSAKey
        where Data: DataProtocol
    {
        let c = try self.load(pem: data) { bio in
            PEM_read_bio_ECPrivateKey(convert(bio), nil, nil, nil)
        }
        return self.init(c)
    }

    let c: OpaquePointer

    init(_ c: OpaquePointer) {
        self.c = c
    }

    deinit {
        EC_KEY_free(self.c)
    }
}

// MARK: Private

private enum ECDSAError: Error {
    case newKeyByCurveFailure
    case generateKeyFailure
    case signFailure
}

private struct ECDSASigner: JWTAlgorithm, OpenSSLSigner {
    let key: ECDSAKey
    let algorithm: OpaquePointer
    let name: String

    func sign<Plaintext>(_ plaintext: Plaintext) throws -> [UInt8]
        where Plaintext: DataProtocol
    {
        let digest = try self.digest(plaintext)
        guard let signature = ECDSA_do_sign(
            digest,
            numericCast(digest.count),
            self.key.c
        ) else {
            throw JWTError.signingAlgorithmFailure(ECDSAError.signFailure)
        }
        defer { ECDSA_SIG_free(signature) }

        // serialize r+s values
        // see: https://tools.ietf.org/html/rfc7515#appendix-A.3
        let r = jwtkit_ECDSA_SIG_get0_r(signature)
        let s = jwtkit_ECDSA_SIG_get0_s(signature)
        var rBytes = [UInt8](repeating: 0, count: Int(BN_num_bits(r) + 7) / 8)
        var sBytes = [UInt8](repeating: 0, count: Int(BN_num_bits(s) + 7) / 8)
        let rCount = Int(BN_bn2bin(r, &rBytes))
        let sCount = Int(BN_bn2bin(s, &sBytes))
        return .init(rBytes.prefix(rCount) + sBytes.prefix(sCount))
    }

    func verify<Signature, Plaintext>(
        _ signature: Signature,
        signs plaintext: Plaintext
    ) throws -> Bool
        where Signature: DataProtocol, Plaintext: DataProtocol
    {
        let digest = try self.digest(plaintext)

        // parse r+s values
        // see: https://tools.ietf.org/html/rfc7515#appendix-A.3
        let signatureBytes = signature.copyBytes()
        let rsSize = signatureBytes.count / 2
        let signature = ECDSA_SIG_new()
        defer { ECDSA_SIG_free(signature) }

        try signatureBytes.prefix(rsSize).withUnsafeBufferPointer { r in
            try signatureBytes.suffix(rsSize).withUnsafeBufferPointer { s in
                // passing bignums to this method transfers ownership
                // (they will be freed when the signature is freed)
                guard jwtkit_ECDSA_SIG_set0(
                    signature,
                    BN_bin2bn(r.baseAddress, numericCast(rsSize), nil),
                    BN_bin2bn(s.baseAddress, numericCast(rsSize), nil)
                ) == 1 else {
                    throw JWTError.signingAlgorithmFailure(ECDSAError.signFailure)
                }
            }
        }

        return ECDSA_do_verify(
            digest,
            numericCast(digest.count),
            signature,
            self.key.c
        ) == 1
    }
}

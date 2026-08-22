# tip

A private, mobile-native wallet for Starknet, built on STRK20.

Shield, unshield, and send privately, from your phone. Non-custodial. Your
keys and your viewing key never leave your device.

## Why

STRK20 ships a real privacy pool on Starknet mainnet, but the only client
implementation is TypeScript, so today the pool is reachable from a browser
extension or the SDK and nowhere else. tip is the consumer wallet on top of it,
and the Dart client it needs in order to exist.

## Packages

### `packages/tip_privacy`

A native Dart client for the STRK20 privacy pool.

**Protocol crypto**

- The domain-separated Poseidon hash suite (note ids, nullifiers, channel keys,
  markers, and the encryption masks)
- STARK-curve key derivation, point recovery from a bare x-coordinate, and ECDH
- A deterministic modular square root, since pointycastle's is randomised and
  requires a registered `SecureRandom`
- Additive masking for channel info, subchannel info, note amounts, and the
  auditor escrow

**Services**

- Discovery client with cursor pagination, per-token balances, and reorg
  handling
- Proving client over JSON-RPC, with exponential backoff when the prover is busy

**Private transport**

- HPKE (RFC 9180) base mode for DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 /
  AES-128-GCM
- Binary HTTP (RFC 9292) and QUIC variable-length integers (RFC 9000)
- Oblivious HTTP (RFC 9458), so the viewing key is never visible to whatever
  terminates TLS

Transport is an interface. `PlainJsonTransport` is fine against a service you
operate; `OhttpTransport` is a one-line swap for anything touching a real user's
viewing key.

**On testing.** Nothing here is checked against my own expectations. The
protocol crypto is verified against reference values generated from the Cairo
contracts in starkware-libs/starknet-privacy, and the transport stack against
the worked examples published in the RFCs themselves: RFC 9180 Appendix A.1,
RFC 9292 Figure 8, and the complete RFC 9458 Appendix A exchange, all reproduced
byte for byte. Fixtures are vendored, so the suite runs with no network and no
Cairo toolchain.

```sh
cd packages/tip_privacy
dart pub get
dart test
```

## Status

In progress during the STRK20 Private Sprint. The client library is landing
first because the app is a thin layer over it.

Still to come: action compilation against the pool contract, and the Flutter app
itself.

## Stack

Flutter and Dart, on `starknet.dart` for the account layer.

## License

MIT

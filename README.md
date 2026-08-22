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

A native Dart client for the STRK20 privacy pool. Currently implements:

- The domain-separated Poseidon hash suite (note ids, nullifiers, channel keys,
  markers, and the encryption masks)
- STARK-curve key derivation, point recovery from a bare x-coordinate, and ECDH
- A deterministic modular square root, since pointycastle's is randomised and
  requires a registered `SecureRandom`
- Additive masking for channel info, subchannel info, note amounts, and the
  auditor escrow

Every primitive is checked against reference values generated from the Cairo
contracts in starkware-libs/starknet-privacy, vendored into `test/fixtures` so
the suite runs without a network or a Cairo toolchain.

```
cd packages/tip_privacy
dart pub get
dart test
```

## Status

Early build, in progress during the STRK20 Private Sprint. The crypto layer is
landing first because everything else depends on it.

Still to come: the Oblivious HTTP client for the discovery and proving
services, action compilation against the pool contract, and the Flutter app
itself.

## Stack

Flutter and Dart, on `starknet.dart` for the account layer.

## License

MIT

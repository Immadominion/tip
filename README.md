# tip

A private wallet for Starknet, on your phone. Built on STRK20.

Send money without publishing who you paid or how much you hold. Hold, send,
and tip from a phone, non-custodially: the recovery phrase and the viewing key
are generated on the device and never leave it.

## Why

STRK20 ships a real privacy pool on Starknet mainnet, but the only client
implementation is TypeScript, so today the pool is reachable from a browser
extension or the SDK and nowhere else. tip is the consumer wallet on top of it,
and the Dart client it needs in order to exist.

## `app`

The wallet. Flutter, iOS and Android.

- Balances read live from the chain, with failover across several RPC
  endpoints, because the free ones do go down mid-session
- Send any listed token, priced before it is signed, so the fee shown is the
  fee signed for
- Tip links: a tip that can be sent to someone who has no wallet at all. A
  random secret derives a throwaway Starknet account, the sender funds it, and
  the link carries the secret. Nothing is escrowed or custodied, and the
  recipient needs no account until they claim
- Recovery phrase generated on device and held in the platform keystore, with
  restore, backup, and removal
- An activity log, also in the keystore, since Starknet's RPC cannot be asked
  what transactions involved an address

```sh
cd app
flutter pub get
flutter run
```

Sepolia by default. `--dart-define=TIP_CHAIN=mainnet` for the real thing, so
pointing at real money is deliberate rather than a default.

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

Built during the STRK20 Private Sprint.

**The shielded side works, and it has been done for real rather than in a
test.** On Sepolia, against the live pool: a viewing key registered, a deposit
shielded, a private transfer to another wallet, and an unshield back out. The
balance tracked every move, and the last transfer was driven through the same
code the screens call rather than through a script written for the occasion.

    register    0x27db4ee66b994c211f31326361bdb8d44740f95262be4c6ace563ec5ca5e59f
    shield      0x3be9a8a80607f1403359a8468bd9ac6dcd7200f5dbfe1ff290945187fefd295
    transfer    0x19cf143c2ab459807f3c0ebab40b4d444964a354aa07d2ef34999750a272af2
    unshield    0x50b26f277aab15d83dc83f2bf9eb426a92f496cf45e74812fe1366de8899654

The public wallet is checked the same way, against the chain rather than
against mocks: transfers, account deployment, and the whole tip link round
trip, funded and then claimed into a wallet that had never touched the chain.

Proofs come from a proving service, because a phone cannot build a STARK in
reasonable time and the protocol is designed around that. The service is meant
to be run by whoever runs the wallet, and standing one up is the remaining
piece. When it cannot be reached the app says so, before a minute is spent
finding out, and says whether anything moved.

## Stack

Flutter and Dart, on `starknet.dart` for the account layer.

## License

MIT

# tip

A private, mobile-native wallet for Starknet, built on STRK20.

Shield, unshield, and send privately, from your phone. Non-custodial. Your
keys and your viewing key never leave your device.

## Why

STRK20 ships a real privacy pool on Starknet mainnet, but the only way to use
it today is through the SDK directly or a browser extension. tip is the
consumer wallet on top of it, aimed at making private send and receive feel
as easy as any other mobile payments app.

## Status

Early build, in progress during the STRK20 Private Sprint.

## Stack

Flutter and Dart, built on `starknet.dart` for the account layer, with a new
native Dart implementation of the STRK20 privacy client underneath.

## License

MIT

/// Sending tokens. The ordinary, public kind.
///
/// Two properties this is built around. A quote is produced before anything is
/// signed, and the transaction is then signed against that same quote rather
/// than a fresh estimate, so the fee the user approved is the fee they pay.
/// And the checks that stop a transfer happen before the signature, not as a
/// revert the user pays for.
library;

import 'package:starknet/starknet.dart';
import 'package:starknet_provider/starknet_provider.dart';

import 'amount.dart';
import 'chain_client.dart';
import 'fee_bounds.dart';
import 'signing_account.dart';
import 'token.dart';

/// A priced transfer, and everything standing in its way.
class TransferQuote {
  const TransferQuote({
    required this.token,
    required this.recipient,
    required this.amount,
    required this.fee,
    required this.maxFee,
    required this.blockers,
    required this.needsDeployment,
    this.bounds,
  });

  final TipToken token;
  final Felt recipient;
  final TokenAmount amount;

  /// What the transfer is expected to cost, in the fee token. This is the
  /// number to show a user: it is close to what they will actually be charged.
  /// Null when it could not be estimated.
  final TokenAmount? fee;

  /// The ceiling the transaction is signed for.
  ///
  /// Higher than [fee], and not what the user pays. It matters because
  /// validation requires the account to hold at least this much, so it is the
  /// figure the balance check has to use.
  final TokenAmount? maxFee;

  /// Reasons this cannot be sent, in words a user can act on. Empty means go.
  final List<String> blockers;

  /// The account contract does not exist yet and must be deployed first.
  final bool needsDeployment;

  /// The bounds to sign with, carried so that signing cannot drift from the
  /// quote the user approved.
  final FeeBounds? bounds;

  bool get canSend => blockers.isEmpty && !needsDeployment;
}

class TransferService {
  const TransferService({required this.client});

  final ChainClient client;

  TipToken get _feeToken => client.network.feeToken;

  /// Prices a transfer and checks it, without signing anything.
  Future<TransferQuote> quote({
    required SigningAccount from,
    required TipToken token,
    required Felt recipient,
    required TokenAmount amount,
  }) async {
    final blockers = <String>[];

    if (amount.isZero || amount.isNegative) {
      blockers.add('Enter an amount above zero');
    }

    final deployed = await client.isDeployed(from.address);
    if (!deployed) {
      return TransferQuote(
        token: token,
        recipient: recipient,
        amount: amount,
        fee: null,
        maxFee: null,
        blockers: blockers,
        needsDeployment: true,
      );
    }

    final balance = await client.balanceOf(
      token: token,
      address: from.address,
    );
    if (amount > balance) {
      blockers.add(
        'You have ${balance.formatWithSymbol()}, which is less than that',
      );
    }

    FeeBounds? bounds;
    TokenAmount? fee;
    TokenAmount? maxFee;

    // Estimating a transfer the account cannot afford reverts inside the
    // estimate, so there is nothing useful to price until the amount fits.
    if (blockers.isEmpty) {
      try {
        bounds = FeeBounds.from(
          await client.accountFor(from).getEstimateMaxFeeForInvokeTx(
                functionCalls: [_transferCall(token, recipient, amount)],
              ),
        );
        fee = TokenAmount(bounds.estimatedFee, _feeToken);
        maxFee = TokenAmount(bounds.maxFee, _feeToken);
      } catch (error) {
        blockers.add('Could not work out the fee: $error');
      }
    }

    if (maxFee != null) {
      final feeBalance = token == _feeToken
          ? balance
          : await client.balanceOf(
              token: _feeToken,
              address: from.address,
            );

      // When the token being sent is also the fee token, the amount and the
      // fee come out of the same pot. Checking them separately is how a wallet
      // ends up letting someone send their entire balance and then fail to pay
      // for the transaction that sends it.
      final needed = token == _feeToken
          ? TokenAmount(amount.raw + maxFee.raw, _feeToken)
          : maxFee;

      if (needed.raw > feeBalance.raw) {
        blockers.add(
          token == _feeToken
              ? 'That leaves nothing for the fee. Try ${_spendable(balance, maxFee).format()} or less.'
              : 'You need ${maxFee.formatWithSymbol()} free to cover the fee',
        );
      }
    }

    return TransferQuote(
      token: token,
      recipient: recipient,
      amount: amount,
      fee: fee,
      maxFee: maxFee,
      blockers: blockers,
      needsDeployment: false,
      bounds: bounds,
    );
  }

  /// The most of [balance] that can be sent once [fee] is kept back.
  ///
  /// What a "max" button should fill in for the fee token.
  TokenAmount _spendable(TokenAmount balance, TokenAmount fee) {
    final left = balance.raw - fee.raw;
    return TokenAmount(left.isNegative ? BigInt.zero : left, balance.token);
  }

  /// The largest amount of [token] that can actually be sent right now.
  ///
  /// [recipient] matters more than it looks. Paying an address that already
  /// holds the token updates a storage slot; paying one that does not creates
  /// it, and the second costs more gas. Pricing against the sender's own
  /// address, which certainly holds a balance, produces a maximum that is
  /// too large to actually send. When the recipient is not known yet, this
  /// prices against an address that holds nothing, which is the expensive
  /// case and therefore the safe one.
  Future<TokenAmount> maxSendable({
    required SigningAccount from,
    required TipToken token,
    Felt? recipient,
  }) async {
    final balance = await client.balanceOf(
      token: token,
      address: from.address,
    );
    if (token != _feeToken || balance.isZero) return balance;

    // Price a transfer of everything to find the fee, then subtract it. The
    // estimate is against an amount that cannot actually be sent, which is
    // fine: the fee for an ERC-20 transfer does not depend on the amount.
    try {
      final bounds = FeeBounds.from(
        await client.accountFor(from).getEstimateMaxFeeForInvokeTx(
              functionCalls: [
                _transferCall(token, recipient ?? coldAddress, balance),
              ],
            ),
      );
      // Held back at the ceiling, not the estimate: an account that cannot
      // cover the ceiling fails validation, so a "max" computed from the
      // estimate is a max that will not send.
      return _spendable(balance, TokenAmount(bounds.maxFee, _feeToken));
    } catch (_) {
      // No estimate, so no honest maximum. Zero is wrong and the full balance
      // is a transfer that will fail, so hand back the balance and let the
      // quote's own check say no.
      return balance;
    }
  }

  /// Deploys the account contract. Once per wallet, before the first send.
  ///
  /// The account pays its own deployment fee, so the address has to hold STRK
  /// already. It can, because the address is derivable and payable before the
  /// contract exists.
  ///
  /// The bounds are estimated here and margined rather than left to the SDK.
  /// Left to itself, `deployAccount` auto-estimates only when all six bounds
  /// are zero and then signs for exactly the estimate. Validation runs for
  /// real and costs slightly more, and the transaction comes back as
  /// VALIDATION_FAILURE with nothing useful to say about why. A claim account
  /// funded to the penny fails on this every time.
  Future<Felt> deployAccount(SigningAccount from) async {
    final signer = StarkAccountSigner(
      signer: StarkSigner(privateKey: from.privateKey),
    );

    final bounds = FeeBounds.from(
      await client.accountFor(from).getEstimateMaxFeeForDeployAccountTx(
            constructorCalldata: [from.publicKey],
            classHash: client.network.accountClassHash,
            contractAddressSalt: from.publicKey,
            contractAddress: from.address,
            accountSigner: signer,
            provider: client.submissionProvider,
          ),
    );

    final response = await Account.deployAccount(
      accountSigner: signer,
      provider: client.submissionProvider,
      constructorCalldata: [from.publicKey],
      classHash: client.network.accountClassHash,
      contractAddressSalt: from.publicKey,
      // Passing the address is what makes an estimate run against this account
      // rather than against address zero, which fails validation with nothing
      // useful to say about why.
      contractAddress: from.address,
      l1GasConsumed: bounds.l1GasConsumed,
      l1GasPrice: bounds.l1GasPrice,
      l1DataGasConsumed: bounds.l1DataGasConsumed,
      l1DataGasPrice: bounds.l1DataGasPrice,
      l2GasConsumed: bounds.l2GasConsumed,
      l2GasPrice: bounds.l2GasPrice,
    );

    return response.when(
      result: (result) => result.transactionHash,
      error: (error) => throw ChainException(
        'Could not deploy your account: ${error.message}',
        code: error.code,
      ),
    );
  }

  /// What deploying an account will cost, at the ceiling.
  Future<TokenAmount> deploymentCeiling(SigningAccount from) async {
    final bounds = FeeBounds.from(
      await client.accountFor(from).getEstimateMaxFeeForDeployAccountTx(
            constructorCalldata: [from.publicKey],
            classHash: client.network.accountClassHash,
            contractAddressSalt: from.publicKey,
            contractAddress: from.address,
            accountSigner: StarkAccountSigner(
              signer: StarkSigner(privateKey: from.privateKey),
            ),
            provider: client.submissionProvider,
          ),
    );
    return TokenAmount(bounds.maxFee, _feeToken);
  }

  /// Signs and submits [quote]. Returns the transaction hash.
  Future<Felt> send({
    required SigningAccount from,
    required TransferQuote quote,
  }) async {
    if (!quote.canSend) {
      throw ChainException(
        quote.blockers.isEmpty
            ? 'Deploy your account before sending'
            : quote.blockers.first,
      );
    }
    final bounds = quote.bounds;
    if (bounds == null) {
      throw const ChainException('This transfer has not been priced yet');
    }

    final response = await client.accountFor(from).execute(
          functionCalls: [
            _transferCall(quote.token, quote.recipient, quote.amount),
          ],
          // The bounds from the quote, not a fresh estimate. Re-estimating
          // here would let the fee the user approved differ from the one they
          // sign for.
          l1GasConsumed: bounds.l1GasConsumed,
          l1GasPrice: bounds.l1GasPrice,
          l1DataGasConsumed: bounds.l1DataGasConsumed,
          l1DataGasPrice: bounds.l1DataGasPrice,
          l2GasConsumed: bounds.l2GasConsumed,
          l2GasPrice: bounds.l2GasPrice,
        );

    return response.when(
      result: (result) => result.transactionHash,
      error: (error) => throw ChainException(
        error.message,
        code: error.code,
      ),
    );
  }

  /// `transfer(recipient, amount)`, with the amount split into u256 limbs.
  FunctionCall _transferCall(
    TipToken token,
    Felt recipient,
    TokenAmount amount,
  ) {
    final mask = (BigInt.one << 128) - BigInt.one;
    return FunctionCall(
      contractAddress: token.address,
      entryPointSelector: getSelectorByName('transfer'),
      calldata: [
        recipient,
        Felt(amount.raw & mask),
        Felt(amount.raw >> 128),
      ],
    );
  }
}


/// An address that holds nothing, for pricing the expensive case.
///
/// Used when a transfer has to be priced before the recipient is known. It has
/// to be an address no token has ever been sent to, so that the estimate
/// includes the cost of creating the recipient's balance slot rather than
/// updating one. This one is derived from a phrase, not from a key: nobody
/// holds it, and nothing should ever be sent to it.
final coldAddress = Felt.fromHexString(
  '0x7469700000000000000000000000000000000000000000000000636f6c64',
);

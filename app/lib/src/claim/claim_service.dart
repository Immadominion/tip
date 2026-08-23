/// Creating and claiming tips.
///
/// A tip is two ordinary transfers with a throwaway account in between. The
/// sender pays an address derived from a secret; whoever holds the secret
/// deploys that account and sweeps it. Nothing is custodied and no contract is
/// involved, which is what makes it work for a recipient who has never used
/// Starknet.
///
/// The cost of that is fees at both ends, paid out of the tip. This file's job
/// is to be exact about them, and to refuse a tip too small to be claimed
/// rather than issue a link that cannot be redeemed.
library;

import 'package:starknet/starknet.dart';

import '../chain/amount.dart';
import '../chain/chain_client.dart';
import '../chain/signing_account.dart';
import '../chain/token.dart';
import '../chain/transfer_service.dart';
import 'claim_link.dart';

/// What a claim link is worth, and whether it can be redeemed.
class ClaimStatus {
  const ClaimStatus({
    required this.balance,
    required this.deployed,
    required this.claimable,
    this.shortfall,
  });

  /// What is sitting at the claim address.
  final TokenAmount balance;

  /// Whether the throwaway account has already been deployed. True usually
  /// means a claim was started and interrupted.
  final bool deployed;

  /// What the recipient would actually receive, after the fees to get it out.
  final TokenAmount claimable;

  /// Set when the balance cannot cover the fees. The link is not redeemable
  /// and saying so plainly beats a claim that reverts.
  final TokenAmount? shortfall;

  bool get isEmpty => balance.isZero;
  bool get canClaim => shortfall == null && !claimable.isZero;
}

class ClaimService {
  ClaimService({required this.client})
      : _transfers = TransferService(client: client);

  final ChainClient client;
  final TransferService _transfers;

  TipToken get _token => client.network.feeToken;

  /// Fees a claim costs, as a worst case.
  ///
  /// Two transactions: deploying the throwaway account and emptying it. Both
  /// are priced at their ceiling rather than their estimate, because the
  /// sequencer requires the account to cover the ceiling and a tip that only
  /// covers the estimate is a tip that cannot be spent.
  ///
  /// Estimating against an account with nothing in it is not possible, so this
  /// is measured once against the wallet's own account and reused. The two
  /// transactions are a deploy and an ERC-20 transfer either way, and neither
  /// cost depends on the amount.
  Future<TokenAmount> estimateClaimCost(SigningAccount reference) async {
    final quote = await _transfers.quote(
      from: reference,
      token: _token,
      recipient: reference.address,
      amount: TokenAmount(BigInt.one, _token),
    );
    final transferCeiling = quote.maxFee;
    if (transferCeiling == null) {
      throw const ChainException(
        'Could not work out what a claim would cost right now',
      );
    }
    // Three times the transfer ceiling, which is a deliberate over-estimate.
    // The exact deployment cost cannot be measured yet: the claim account
    // does not exist and has no balance, and an estimate against it would be
    // refused. Over-funding is the safe direction, and the surplus is not
    // ours: whatever is not spent on fees goes to the recipient.
    return TokenAmount(transferCeiling.raw * BigInt.from(3), _token);
  }

  /// Sends [amount] to a fresh claim address, and hands back the link.
  ///
  /// [amount] is what the recipient sees at the address. The fees to get it
  /// out come from it, so [estimateClaimCost] is what the caller should be
  /// adding on top before it gets here.
  Future<ClaimIssue> createTip({
    required SigningAccount from,
    required TokenAmount amount,
  }) async {
    final key = ClaimLinks.create(
      accountClassHash: client.network.accountClassHash,
    );

    final quote = await _transfers.quote(
      from: from,
      token: amount.token,
      recipient: key.address,
      amount: amount,
    );
    if (!quote.canSend) {
      throw ChainException(
        quote.needsDeployment
            ? 'Deploy your account before sending a tip'
            : quote.blockers.first,
      );
    }

    final hash = await _transfers.send(from: from, quote: quote);
    return ClaimIssue(key: key, transactionHash: hash, amount: amount);
  }

  /// What a link is worth right now.
  ///
  /// [reference] is a deployed account used only to price the claim. An
  /// unclaimed link's account does not exist yet, so it cannot be used to
  /// estimate anything, and guessing zero would tell the recipient the whole
  /// balance is theirs when the fees have yet to come out of it.
  Future<ClaimStatus> inspect(
    ClaimKey key, {
    required SigningAccount reference,
  }) async {
    final balance = await client.balanceOf(
      token: _token,
      address: key.address,
    );
    final deployed = await client.isDeployed(key.address);

    if (balance.isZero) {
      return ClaimStatus(
        balance: balance,
        deployed: deployed,
        claimable: balance,
      );
    }

    // Once funded, the claim account can price its own deployment even though
    // it does not exist yet, which is what makes this figure accurate rather
    // than the sender's conservative budget. The sweep itself still has to be
    // priced against the reference account, since a contract that is not
    // deployed cannot be asked to estimate an invoke.
    final cost = deployed
        ? await _sweepCeiling(key)
        : TokenAmount(
            (await _deploymentCeiling(key)).raw +
                (await _transferCeiling(reference)).raw,
            _token,
          );

    final left = balance.raw - cost.raw;
    if (!left.isNegative && left > BigInt.zero) {
      return ClaimStatus(
        balance: balance,
        deployed: deployed,
        claimable: TokenAmount(left, _token),
      );
    }
    return ClaimStatus(
      balance: balance,
      deployed: deployed,
      claimable: TokenAmount.zero(_token),
      shortfall: TokenAmount(cost.raw - balance.raw, _token),
    );
  }

  /// What deploying this claim account will cost, at the ceiling.
  ///
  /// Falls back to the conservative budget if the estimate is refused, which
  /// happens when the link has not been funded yet.
  Future<TokenAmount> _deploymentCeiling(ClaimKey key) async {
    try {
      return await _transfers.deploymentCeiling(key.signing);
    } catch (_) {
      return _transferCeiling(key.signing);
    }
  }

  Future<TokenAmount> _transferCeiling(SigningAccount who) async {
    final quote = await _transfers.quote(
      from: who,
      token: _token,
      recipient: coldAddress,
      amount: TokenAmount(BigInt.one, _token),
    );
    return quote.maxFee ?? TokenAmount.zero(_token);
  }

  Future<TokenAmount> _sweepCeiling(ClaimKey key) async {
    final quote = await _transfers.quote(
      from: key.signing,
      token: _token,
      recipient: coldAddress,
      amount: TokenAmount(BigInt.one, _token),
    );
    return quote.maxFee ?? TokenAmount.zero(_token);
  }

  /// Moves everything a link holds into [recipient].
  ///
  /// Deploys the throwaway account first when it has to. A claim interrupted
  /// after the deployment is safe to retry: the deployment is skipped and the
  /// sweep runs on its own.
  Future<ClaimResult> claim({
    required ClaimKey key,
    required SigningAccount recipient,
  }) async {
    final signing = key.signing;

    if (!await client.isDeployed(key.address)) {
      final deployHash = await _transfers.deployAccount(signing);
      final deployed = await client.awaitTransaction(deployHash);
      if (deployed.outcome != TransactionOutcome.succeeded) {
        throw ChainException(
          'The claim account could not be set up: '
          '${deployed.failureReason ?? deployed.outcome.name}',
        );
      }
    }

    final balance = await client.balanceOf(
      token: _token,
      address: key.address,
    );

    var sweepable = await _transfers.maxSendable(
      from: signing,
      token: _token,
      recipient: recipient.address,
    );

    // Converge on an amount the account can actually afford. Each attempt
    // prices the sweep, and if the fee ceiling came out higher than the last
    // guess allowed for, the next attempt subtracts the ceiling the chain just
    // quoted. Two rounds is enough unless gas is moving under us.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (sweepable.isZero || sweepable.isNegative) {
        throw const ChainException(
          'There is not enough left in this link to cover the fee to move it',
        );
      }

      final quote = await _transfers.quote(
        from: signing,
        token: _token,
        recipient: recipient.address,
        amount: sweepable,
      );

      if (quote.canSend) {
        final hash = await _transfers.send(from: signing, quote: quote);
        return ClaimResult(transactionHash: hash, amount: sweepable);
      }

      final ceiling = quote.maxFee;
      if (ceiling == null) throw ChainException(quote.blockers.first);
      sweepable = TokenAmount(balance.raw - ceiling.raw, _token);
    }

    throw const ChainException(
      'The fee kept moving while claiming. Try again in a moment.',
    );
  }
}

class ClaimIssue {
  const ClaimIssue({
    required this.key,
    required this.transactionHash,
    required this.amount,
  });

  final ClaimKey key;
  final Felt transactionHash;
  final TokenAmount amount;
}

class ClaimResult {
  const ClaimResult({required this.transactionHash, required this.amount});

  final Felt transactionHash;
  final TokenAmount amount;
}

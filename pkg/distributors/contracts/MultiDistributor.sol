// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "@balancer-labs/v2-solidity-utils/contracts/math/Math.sol";
import "@balancer-labs/v2-solidity-utils/contracts/math/FixedPoint.sol";
import "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/ReentrancyGuard.sol";
import "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/EnumerableSet.sol";
import "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/SafeERC20.sol";
import "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/IERC20Permit.sol";

import "@balancer-labs/v2-vault/contracts/interfaces/IVault.sol";
import "@balancer-labs/v2-vault/contracts/interfaces/IAsset.sol";

import "./MultiDistributorAuthorization.sol";

import "./interfaces/IMultiDistributor.sol";
import "./interfaces/IDistributorCallback.sol";

// solhint-disable not-rely-on-time

/**
 * @title MultiDistributor
 * Based on Curve Finance's MultiRewards contract updated to be compatible with solc 0.7.0:
 * https://github.com/curvefi/multi-rewards/blob/master/contracts/MultiRewards.sol commit #9947623
 */
contract MultiDistributor is IMultiDistributor, ReentrancyGuard, MultiDistributorAuthorization {
    using FixedPoint for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /*
     * Distribution accounting explanation:
     *
     * Distributors can start a distribution channel with a set amount of tokens to be distributed over a period,
     * from this a `paymentRate` may be easily calculated.
     *
     * Two pieces of global information are stored for the amount of tokens paid out:
     * `globalTokensPerStake` is the number of tokens claimable from a single staking token staked from the start.
     * `lastUpdateTime` represents the timestamp of the last time `globalTokensPerStake` was updated.
     *
     * `globalTokensPerStake` can be calculated by:
     * 1. Calculating the amount of tokens distributed by multiplying `paymentRate` by the time since `lastUpdateTime`
     * 2. Dividing this by the supply of staked tokens to get payment per staked token
     * The existing `globalTokensPerStake` then incremented by this amount.
     *
     * Updating these two values locks in the number of tokens which the current stakers can claim.
     * This MUST be done whenever the total supply of staked tokens changes otherwise new stakers
     * will gain a portion of rewards distributed before they staked.
     *
     * Each user tracks their own `userRatePerStake` which determines how many tokens they can claim.
     * This is done by comparing the global `globalTokensPerStake` with their own `userRatePerStake`,
     * the difference between these two values times their staked balance is their balance of rewards
     * since `userRatePerStake` was last updated.
     *
     * This calculation is only correct in the case where the user's staked balance does not change.
     * Therefore before any stake/unstake/subscribe/unsubscribe they must sync their local rate to the global rate.
     * Before `userRatePerStake` is updated to match `globalTokensPerStake`, the unaccounted rewards
     * which they have earned is stored in `unclaimedTokens` to be claimed later.
     *
     * If staking for the first time `userRatePerStake` is set to `globalTokensPerStake` with zero `unclaimedTokens`
     * to reflect that the user will only start accumulating tokens from that point on.
     *
     * After performing the above updates, claiming tokens is handled simply by just zeroing out the users
     * `unclaimedTokens` and releasing that amount of tokens to them.
     */

    mapping(bytes32 => Distribution) internal _distributions;
    mapping(IERC20 => mapping(address => UserStaking)) internal _userStakings;

    /**
     * @dev Updates the payment rate for all the distributions that a user has signed up for a staking token
     */
    modifier updateDistributions(IERC20 stakingToken, address user) {
        _updateDistributions(stakingToken, user);
        _;
    }

    constructor(IVault vault) Authentication(bytes32(uint256(address(this)))) MultiDistributorAuthorization(vault) {
        // solhint-disable-previous-line no-empty-blocks
        // MultiDistributor is a singleton, so it simply uses its own address to disambiguate action identifiers
    }

    /**
     * @dev Returns the identifier used for a specific distribution
     * @param stakingToken The staking token of the distribution
     * @param distributionToken The token which is being distributed
     * @param distributor The owner of the distribution
     */
    function getDistributionId(
        IERC20 stakingToken,
        IERC20 distributionToken,
        address distributor
    ) public pure override returns (bytes32) {
        return keccak256(abi.encodePacked(stakingToken, distributionToken, distributor));
    }

    /**
     * @dev Returns the information of a distribution
     * @param distributionId ID of the distribution being queried
     */
    function getDistribution(bytes32 distributionId) external view override returns (Distribution memory) {
        return _getDistribution(distributionId);
    }

    /**
     * @dev Calculates the payment per token for a distribution
     * @param distributionId ID of the distribution being queried
     */
    function tokensPerStake(bytes32 distributionId) public view override returns (uint256) {
        return _globalTokensPerStake(_getDistribution(distributionId));
    }

    /**
     * @dev Returns the total supply of tokens subscribed to a distribution
     * @param distributionId ID of the distribution being queried
     */
    function totalSupply(bytes32 distributionId) external view override returns (uint256) {
        return _getDistribution(distributionId).totalSupply;
    }

    /**
     * @dev Returns the timestamp up to which a distribution has been distributing tokens
     * @param distributionId ID of the distribution being queried
     */
    function lastTimePaymentApplicable(bytes32 distributionId) public view override returns (uint256) {
        return _lastTimePaymentApplicable(_getDistribution(distributionId));
    }

    /**
     * @dev Returns if a user is subscribed to a distribution or not
     * @param distributionId ID of the distribution being queried
     * @param user The address of the user being queried
     */
    function isSubscribed(bytes32 distributionId, address user) external view override returns (bool) {
        IERC20 stakingToken = _getDistribution(distributionId).stakingToken;
        return _userStakings[stakingToken][user].subscribedDistributions.contains(distributionId);
    }

    /**
     * @dev Returns the information of a distribution for a user
     * @param distributionId ID of the distribution being queried
     * @param user Address of the user being queried
     */
    function getUserDistribution(bytes32 distributionId, address user)
        external
        view
        override
        returns (UserDistribution memory)
    {
        IERC20 stakingToken = _getDistribution(distributionId).stakingToken;
        return _userStakings[stakingToken][user].distributions[distributionId];
    }

    /**
     * @dev Returns the unaccounted earned payment for a user until now for a particular distribution
     * @param distributionId ID of the distribution being queried
     * @param user Address of the user being queried
     */
    function unaccountedUnclaimedTokens(bytes32 distributionId, address user) external view override returns (uint256) {
        IERC20 stakingToken = _getDistribution(distributionId).stakingToken;
        UserStaking storage userStaking = _userStakings[stakingToken][user];
        return _unaccountedUnclaimedTokens(userStaking, distributionId);
    }

    /**
     * @dev Returns the total unclaimed payment for a user for a particular distribution
     * @param distributionId ID of the distribution being queried
     * @param user Address of the user being queried
     */
    function totalUnclaimedTokens(bytes32 distributionId, address user) external view override returns (uint256) {
        IERC20 stakingToken = _getDistribution(distributionId).stakingToken;
        UserStaking storage userStaking = _userStakings[stakingToken][user];
        return _totalUnclaimedTokens(userStaking, distributionId);
    }

    /**
     * @dev Returns the staked balance of a user for a staking token
     * @param stakingToken The staking token being queried
     * @param user Address of the user being queried
     */
    function balanceOf(IERC20 stakingToken, address user) external view override returns (uint256) {
        return _userStakings[stakingToken][user].balance;
    }

    /**
     * @dev Creates a new distribution
     * @param stakingToken The staking token that will be eligible for this distribution
     * @param distributionToken The token to be distributed to users
     * @param duration The duration over which each distribution is spread
     */
    function create(
        IERC20 stakingToken,
        IERC20 distributionToken,
        uint256 duration
    ) external override returns (bytes32 distributionId) {
        require(duration > 0, "DISTRIBUTION_DURATION_ZERO");
        require(address(stakingToken) != address(0), "STAKING_TOKEN_ZERO_ADDRESS");
        require(address(distributionToken) != address(0), "DISTRIBUTION_TOKEN_ZERO_ADDRESS");

        distributionId = getDistributionId(stakingToken, distributionToken, msg.sender);
        Distribution storage distribution = _getDistribution(distributionId);
        require(distribution.duration == 0, "DISTRIBUTION_ALREADY_CREATED");
        distribution.duration = duration;
        distribution.owner = msg.sender;
        distribution.distributionToken = distributionToken;
        distribution.stakingToken = stakingToken;

        emit NewDistribution(distributionId, stakingToken, distributionToken, msg.sender);
    }

    /**
     * @dev Sets the duration for a distribution
     * @param distributionId ID of the distribution to be set
     * @param duration Duration over which each distribution is spread
     */
    function setDistributionDuration(bytes32 distributionId, uint256 duration) external override {
        require(duration > 0, "DISTRIBUTION_DURATION_ZERO");

        Distribution storage distribution = _getDistribution(distributionId);
        require(distribution.duration > 0, "DISTRIBUTION_DOES_NOT_EXIST");
        // TODO: add test for this
        require(distribution.owner == msg.sender, "SENDER_NOT_OWNER");
        require(distribution.periodFinish < block.timestamp, "DISTRIBUTION_STILL_ACTIVE");

        distribution.duration = duration;
        emit DistributionDurationSet(distributionId, duration);
    }

    /**
     * @notice Deposits tokens to be distributed to stakers subscribed to distribution channel `distributionId`
     * @dev Starts a new distribution period for `duration` seconds from now.
     *      If the previous period is still active its undistributed tokens are rolled over into the new period.
     * @param distributionId ID of the distribution to be funded
     * @param amount The amount of tokens to deposit
     */
    function fundDistribution(bytes32 distributionId, uint256 amount) external override {
        _updateDistributionRate(distributionId);

        Distribution storage distribution = _getDistribution(distributionId);
        require(distribution.duration > 0, "DISTRIBUTION_DOES_NOT_EXIST");
        // TODO: add test for this
        require(distribution.owner == msg.sender, "SENDER_NOT_DISTRIBUTOR");

        IERC20 distributionToken = distribution.distributionToken;
        distributionToken.safeTransferFrom(msg.sender, address(this), amount);
        distributionToken.approve(address(getVault()), amount);

        IVault.UserBalanceOp[] memory ops = new IVault.UserBalanceOp[](1);
        ops[0] = IVault.UserBalanceOp({
            asset: IAsset(address(distributionToken)),
            amount: amount,
            sender: address(this),
            recipient: payable(address(this)),
            kind: IVault.UserBalanceOpKind.DEPOSIT_INTERNAL
        });

        getVault().manageUserBalance(ops);

        uint256 duration = distribution.duration;
        uint256 periodFinish = distribution.periodFinish;

        if (block.timestamp >= periodFinish) {
            // Current distribution period has ended so new period consists only of amount provided.
            distribution.paymentRate = Math.divDown(amount, duration);
        } else {
            // Current distribution period is still in progress.
            // Calculate number of tokens which haven't been distributed yet and
            // apply these to the new distribution period being funded.

            // Checked arithmetic is not required due to the if
            uint256 remainingTime = periodFinish - block.timestamp;
            uint256 leftoverTokens = Math.mul(remainingTime, distribution.paymentRate);
            distribution.paymentRate = Math.divDown(amount.add(leftoverTokens), duration);
        }

        distribution.lastUpdateTime = block.timestamp;
        distribution.periodFinish = block.timestamp.add(duration);
        emit DistributionFunded(distributionId, amount);
    }

    /**
     * @dev Subscribes a user to a list of distributions
     * @param distributionIds List of distributions to subscribe
     */
    function subscribe(bytes32[] memory distributionIds) external override {
        for (uint256 i; i < distributionIds.length; i++) {
            bytes32 distributionId = distributionIds[i];
            Distribution storage distribution = _getDistribution(distributionId);
            require(distribution.duration > 0, "DISTRIBUTION_DOES_NOT_EXIST");

            IERC20 stakingToken = distribution.stakingToken;
            UserStaking storage userStaking = _userStakings[stakingToken][msg.sender];
            EnumerableSet.Bytes32Set storage subscribedDistributions = userStaking.subscribedDistributions;
            require(subscribedDistributions.add(distributionId), "ALREADY_SUBSCRIBED_DISTRIBUTION");

            uint256 amount = userStaking.balance;
            if (amount > 0) {
                subscribedDistributions.add(distributionId);
                // The unclaimed tokens remains the same because the user was not subscribed to the distribution
                userStaking.distributions[distributionId].userTokensPerStake = _updateDistributionRate(distributionId);
                distribution.totalSupply = distribution.totalSupply.add(amount);
                emit Staked(distributionId, msg.sender, amount);
            }
        }
    }

    /**
     * @dev Unsubscribes a user to a list of distributions
     * @param distributionIds List of distributions to unsubscribe
     */
    function unsubscribe(bytes32[] memory distributionIds) external override {
        for (uint256 i; i < distributionIds.length; i++) {
            bytes32 distributionId = distributionIds[i];
            Distribution storage distribution = _getDistribution(distributionId);
            require(distribution.duration > 0, "DISTRIBUTION_DOES_NOT_EXIST");

            UserStaking storage userStaking = _userStakings[distribution.stakingToken][msg.sender];
            EnumerableSet.Bytes32Set storage subscribedDistributions = userStaking.subscribedDistributions;

            // If the user had tokens staked that applied to this distribution, we need to update their standing before
            // unsubscribing, which is effectively an unstake.
            uint256 amount = userStaking.balance;
            if (amount > 0) {
                _updateUserPaymentRatePerToken(userStaking, distributionId);
            }

            require(subscribedDistributions.remove(distributionId), "DISTRIBUTION_NOT_SUBSCRIBED");

            if (amount > 0) {
                _updateUserPaymentRatePerToken(userStaking, distributionId);
                userStaking.subscribedDistributions.remove(distributionId);
                distribution.totalSupply = distribution.totalSupply.sub(amount);
                emit Withdrawn(distributionId, msg.sender, amount);
            }
        }
    }

    /**
     * @dev Stakes tokens
     * @param stakingToken The token to be staked to be eligible for distributions
     * @param amount Amount of tokens to be staked
     */
    function stake(IERC20 stakingToken, uint256 amount) external override nonReentrant {
        _stakeFor(stakingToken, amount, msg.sender, msg.sender);
    }

    /**
     * @notice Stakes tokens on behalf of other user
     * @param stakingToken The token to be staked to be eligible for distributions
     * @param amount Amount of tokens to be staked
     * @param user The user staking on behalf of
     */
    function stakeFor(
        IERC20 stakingToken,
        uint256 amount,
        address user
    ) external override nonReentrant {
        _stakeFor(stakingToken, amount, user, msg.sender);
    }

    /**
     * @dev Stakes tokens using a permit signature for approval
     * @param stakingToken The token to be staked to be eligible for distributions
     * @param user User staking tokens for
     * @param amount Amount of tokens to be staked
     * @param deadline The time at which this expires (unix time)
     * @param v V of the signature
     * @param r R of the signature
     * @param s S of the signature
     */
    function stakeWithPermit(
        IERC20 stakingToken,
        uint256 amount,
        address user,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override nonReentrant {
        IERC20Permit(address(stakingToken)).permit(user, address(this), amount, deadline, v, r, s);
        _stakeFor(stakingToken, amount, user, user);
    }

    /**
     * @dev Withdraw tokens
     * @param stakingToken The token to be withdrawn
     * @param amount Amount of tokens to be withdrawn
     * @param receiver The recipient of the staked tokens
     */
    function withdraw(
        IERC20 stakingToken,
        uint256 amount,
        address receiver
    ) public override nonReentrant updateDistributions(stakingToken, msg.sender) {
        require(amount > 0, "WITHDRAW_AMOUNT_ZERO");

        UserStaking storage userStaking = _userStakings[stakingToken][msg.sender];
        uint256 currentBalance = userStaking.balance;
        require(currentBalance >= amount, "WITHDRAW_AMOUNT_UNAVAILABLE");
        userStaking.balance = userStaking.balance.sub(amount);

        EnumerableSet.Bytes32Set storage distributions = userStaking.subscribedDistributions;
        uint256 distributionsLength = distributions.length();

        for (uint256 i; i < distributionsLength; i++) {
            bytes32 distributionId = distributions.unchecked_at(i);
            Distribution storage distribution = _getDistribution(distributionId);
            distribution.totalSupply = distribution.totalSupply.sub(amount);
            emit Withdrawn(distributionId, msg.sender, amount);
        }

        stakingToken.safeTransfer(receiver, amount);
    }

    /**
     * @dev Claims earned distribution tokens for a list of distributions
     * @param distributionIds List of distributions to claim
     */
    function claim(bytes32[] memory distributionIds) external override nonReentrant {
        _claim(distributionIds, msg.sender, IVault.UserBalanceOpKind.WITHDRAW_INTERNAL);
    }

    /**
     * @dev Claims earned tokens for a list of distributions to internal balance
     * @param distributionIds List of distributions to claim
     */
    function claimAsInternalBalance(bytes32[] memory distributionIds) external override nonReentrant {
        _claim(distributionIds, msg.sender, IVault.UserBalanceOpKind.TRANSFER_INTERNAL);
    }

    /**
     * @dev Claims earned tokens for a list of distributions to a callback contract
     * @param distributionIds List of distributions to claim
     * @param callbackContract The contract where tokens will be transferred
     * @param callbackData The data that is used to call the callback contract's 'callback' method
     */
    function claimWithCallback(
        bytes32[] memory distributionIds,
        IDistributorCallback callbackContract,
        bytes memory callbackData
    ) external override nonReentrant {
        _claim(distributionIds, address(callbackContract), IVault.UserBalanceOpKind.TRANSFER_INTERNAL);
        callbackContract.distributorCallback(callbackData);
    }

    /**
     * @dev Withdraws staking tokens and claims for a list of distributions
     * @param stakingTokens The staking tokens to withdraw tokens from
     * @param distributionIds The distributions to claim for
     */
    function exit(IERC20[] memory stakingTokens, bytes32[] memory distributionIds) external override {
        for (uint256 i; i < stakingTokens.length; i++) {
            IERC20 stakingToken = stakingTokens[i];
            UserStaking storage userStaking = _userStakings[stakingToken][msg.sender];
            withdraw(stakingToken, userStaking.balance, msg.sender);
        }

        _claim(distributionIds, msg.sender, IVault.UserBalanceOpKind.WITHDRAW_INTERNAL);
    }

    /**
     * @dev Withdraws staking tokens and claims for a list of distributions to a callback contract
     * @param stakingTokens The staking tokens to withdraw tokens from
     * @param distributionIds The distributions to claim  for
     * @param callbackContract The contract where tokens will be transferred
     * @param callbackData The data that is used to call the callback contract's 'callback' method
     */
    function exitWithCallback(
        IERC20[] memory stakingTokens,
        bytes32[] memory distributionIds,
        IDistributorCallback callbackContract,
        bytes memory callbackData
    ) external override {
        for (uint256 i; i < stakingTokens.length; i++) {
            IERC20 stakingToken = stakingTokens[i];
            UserStaking storage userStaking = _userStakings[stakingToken][msg.sender];
            withdraw(stakingToken, userStaking.balance, msg.sender);
        }

        _claim(distributionIds, address(callbackContract), IVault.UserBalanceOpKind.TRANSFER_INTERNAL);
        callbackContract.distributorCallback(callbackData);
    }

    function _stakeFor(
        IERC20 stakingToken,
        uint256 amount,
        address user,
        address from
    ) internal updateDistributions(stakingToken, user) {
        require(amount > 0, "STAKE_AMOUNT_ZERO");

        UserStaking storage userStaking = _userStakings[stakingToken][user];
        userStaking.balance = userStaking.balance.add(amount);

        EnumerableSet.Bytes32Set storage distributions = userStaking.subscribedDistributions;
        uint256 distributionsLength = distributions.length();

        for (uint256 i; i < distributionsLength; i++) {
            bytes32 distributionId = distributions.unchecked_at(i);
            Distribution storage distribution = _getDistribution(distributionId);
            distribution.totalSupply = distribution.totalSupply.add(amount);
            emit Staked(distributionId, user, amount);
        }

        // We hold stakingTokens in an external balance as BPT needs to be external anyway
        // in the case where a user is exiting the pool after unstaking.
        // TODO: consider a TRANSFER_EXTERNAL call
        stakingToken.safeTransferFrom(from, address(this), amount);
    }

    function _claim(
        bytes32[] memory distributionIds,
        address recipient,
        IVault.UserBalanceOpKind kind
    ) internal {
        IVault.UserBalanceOp[] memory ops = new IVault.UserBalanceOp[](distributionIds.length);

        for (uint256 i; i < distributionIds.length; i++) {
            bytes32 distributionId = distributionIds[i];
            Distribution storage distribution = _getDistribution(distributionId);

            IERC20 stakingToken = distribution.stakingToken;
            UserStaking storage userStaking = _userStakings[stakingToken][msg.sender];

            if (userStaking.subscribedDistributions.contains(distributionId)) {
                // Update user distribution rates only if the user is still subscribed
                _updateUserPaymentRatePerToken(userStaking, distributionId);
            }

            UserDistribution storage userDistribution = userStaking.distributions[distributionId];
            uint256 unclaimedTokens = userDistribution.unclaimedTokens;
            address distributionToken = address(distribution.distributionToken);

            if (unclaimedTokens > 0) {
                userDistribution.unclaimedTokens = 0;
                emit TokensClaimed(msg.sender, distributionToken, unclaimedTokens);
            }

            ops[i] = IVault.UserBalanceOp({
                asset: IAsset(distributionToken),
                amount: unclaimedTokens,
                sender: address(this),
                recipient: payable(recipient),
                kind: kind
            });
        }

        getVault().manageUserBalance(ops);
    }

    function _updateDistributions(IERC20 stakingToken, address user) internal {
        UserStaking storage userStaking = _userStakings[stakingToken][user];
        EnumerableSet.Bytes32Set storage distributions = userStaking.subscribedDistributions;
        uint256 distributionsLength = distributions.length();

        for (uint256 i; i < distributionsLength; i++) {
            bytes32 distributionId = distributions.unchecked_at(i);
            _updateUserPaymentRatePerToken(userStaking, distributionId);
        }
    }

    function _updateUserPaymentRatePerToken(UserStaking storage userStaking, bytes32 distributionId) internal {
        uint256 globalTokensPerStake = _updateDistributionRate(distributionId);
        UserDistribution storage userDistribution = userStaking.distributions[distributionId];
        userDistribution.unclaimedTokens = _totalUnclaimedTokens(userStaking, distributionId);
        userDistribution.userTokensPerStake = globalTokensPerStake;
    }

    /**
     * @notice Updates the amount of distribution tokens paid per token staked for a distribution
     * @dev This is expected to be called whenever a user's applicable staked balance changes,
     *      either through adding/removing tokens or subscribing/unsubscribing from the distribution.
     * @param distributionId ID of the distribution being updated
     * @return globalTokensPerStake The updated number of distribution tokens paid per staked token
     */
    function _updateDistributionRate(bytes32 distributionId) internal returns (uint256 globalTokensPerStake) {
        Distribution storage distribution = _getDistribution(distributionId);
        globalTokensPerStake = _globalTokensPerStake(distribution);
        distribution.globalTokensPerStake = globalTokensPerStake;
        distribution.lastUpdateTime = _lastTimePaymentApplicable(distribution);
    }

    function _globalTokensPerStake(Distribution storage distribution) internal view returns (uint256) {
        uint256 supply = distribution.totalSupply;
        if (supply == 0) {
            return distribution.globalTokensPerStake;
        }

        // Underflow is impossible here because _lastTimePaymentApplicable(...) is always greater than last update time
        uint256 unpaidDuration = _lastTimePaymentApplicable(distribution) - distribution.lastUpdateTime;
        uint256 unpaidAmountPerToken = Math.mul(unpaidDuration, distribution.paymentRate).divDown(supply);
        return distribution.globalTokensPerStake.add(unpaidAmountPerToken);
    }

    function _lastTimePaymentApplicable(Distribution storage distribution) internal view returns (uint256) {
        return Math.min(block.timestamp, distribution.periodFinish);
    }

    /**
     * @dev Returns the total unclaimed tokens for a user for a particular distribution
     * @param userStaking Storage pointer to user's staked position information
     * @param distributionId ID of the distribution being queried
     */
    function _totalUnclaimedTokens(UserStaking storage userStaking, bytes32 distributionId)
        internal
        view
        returns (uint256)
    {
        uint256 unclaimedTokens = userStaking.distributions[distributionId].unclaimedTokens;
        return _unaccountedUnclaimedTokens(userStaking, distributionId).add(unclaimedTokens);
    }

    /**
     * @dev Returns the tokens earned for a particular distribution between
     *      the last time the user updated their position and now
     * @param userStaking Storage pointer to user's staked position information
     * @param distributionId ID of the distribution being queried
     */
    function _unaccountedUnclaimedTokens(UserStaking storage userStaking, bytes32 distributionId)
        internal
        view
        returns (uint256)
    {
        // If the user is not subscribed to the queried distribution, it should be handled as if the user has no stake.
        // Then, it can be short cut to zero.
        if (!userStaking.subscribedDistributions.contains(distributionId)) {
            return 0;
        }

        uint256 userTokensPerStake = userStaking.distributions[distributionId].userTokensPerStake;
        uint256 unaccountedPaymentPerToken = _globalTokensPerStake(_getDistribution(distributionId)).sub(
            userTokensPerStake
        );
        return userStaking.balance.mulDown(unaccountedPaymentPerToken);
    }

    function _getDistribution(
        IERC20 stakingToken,
        IERC20 distributionToken,
        address distributor
    ) internal view returns (Distribution storage) {
        return _getDistribution(getDistributionId(stakingToken, distributionToken, distributor));
    }

    function _getDistribution(bytes32 id) internal view returns (Distribution storage) {
        return _distributions[id];
    }
}
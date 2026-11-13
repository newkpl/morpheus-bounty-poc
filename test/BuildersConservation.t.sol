// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Harness, IERC20} from "./Harness.sol";

interface IBuilders {
    struct Subnet {
        string name;
        address admin;
        uint128 unused1;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unused2;
        uint256 minimalDeposit;
        address claimAdmin;
    }
    struct SubnetMetadata {
        string slug;
        string description;
        string website;
        string image;
    }
    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function getSubnetId(string memory name_) external view returns (bytes32);
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function claim(bytes32 subnetId_, address receiver_) external;
    function getCurrentSubnetRewards(bytes32 subnetId_) external view returns (uint256);
    function allSubnetsData() external view returns (uint256, uint256, uint256, uint256);
    function allSubnetsDataV4() external view returns (uint256, uint256, uint256, uint128);
}

/// @title Builders V4 (Base) — accounting conservation evidence for H3
/// @notice Fork test against the DEPLOYED Builders proxy at Base block 56,849,002.
///         Creates a fresh permissionless subnet, deposits, accrues, claims and withdraws,
///         asserting stake + reward conservation at live parameters
///         (networkShare 80%, 7-day global withdraw lock, RewardPool pool-3 emissions).
contract BuildersConservationTest is Harness {
    address internal constant BUILDERS = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address internal constant TREASURY = 0x9eba628581896ce086cb8f1A513ea6097A8FC561;
    address internal constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 internal constant BASE_FORK_BLOCK = 56849002;

    IBuilders internal builders = IBuilders(BUILDERS);
    IERC20 internal mor = IERC20(MOR);

    function _dealMor(address account_, uint256 amount_) internal {
        bytes32 loc = keccak256(abi.encode(account_, uint256(5)));
        vm.store(MOR, loc, bytes32(amount_));
    }

    function test_conservation() public {
        vm.createSelectFork("base", BASE_FORK_BLOCK);
        address admin = vm.addr(0xAD111);
        address user = vm.addr(0x1234);
        _dealMor(user, 1000 ether);

        (, , uint256 totalDepositedBefore, ) = builders.allSubnetsData();
        assertEq(mor.balanceOf(BUILDERS), totalDepositedBefore, "pre: proxy balance == totalDeposited");

        // Permissionless subnet creation at the live global withdraw-lock floor (7 days).
        IBuilders.Subnet memory subnet = IBuilders.Subnet({
            name: "poc-conservation-subnet",
            admin: admin,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: 604800,
            unused2: 0,
            minimalDeposit: 0,
            claimAdmin: admin
        });
        IBuilders.SubnetMetadata memory meta = IBuilders.SubnetMetadata("poc", "", "", "");
        vm.prank(admin);
        builders.createSubnet(subnet, meta);
        bytes32 subnetId = builders.getSubnetId("poc-conservation-subnet");

        // Deposit: stake conservation tracks 1:1.
        vm.startPrank(user);
        mor.approve(BUILDERS, type(uint256).max);
        builders.deposit(subnetId, 500 ether);
        vm.stopPrank();
        (, , uint256 totalDepositedAfter, ) = builders.allSubnetsData();
        assertEq(totalDepositedAfter, totalDepositedBefore + 500 ether, "deposit tracked");
        assertEq(mor.balanceOf(BUILDERS), totalDepositedAfter, "post-deposit conservation");

        // Rewards accrue at live emission parameters.
        vm.warp(block.timestamp + 3 days);
        uint256 claimable = builders.getCurrentSubnetRewards(subnetId);
        assertGt(claimable, 0, "rewards accrued over 3 days");

        // Claim pays exactly the view amount out of the treasury; claimed counter tracks it.
        (uint256 distributedBefore, , uint256 claimedBefore, ) = builders.allSubnetsDataV4();
        uint256 treasuryBefore = mor.balanceOf(TREASURY);
        uint256 adminBefore = mor.balanceOf(admin);
        vm.prank(admin);
        builders.claim(subnetId, admin);
        assertEq(mor.balanceOf(admin), adminBefore + claimable, "claim pays exact pending rewards");
        assertEq(mor.balanceOf(TREASURY), treasuryBefore - claimable, "treasury is the claim source");
        (, , uint256 claimedAfter, ) = builders.allSubnetsDataV4();
        assertEq(claimedAfter, claimedBefore + claimable, "claimedRewards counter tracks payout");
        assertGt(distributedBefore, 0, "distribution counter live");

        // Withdraw after the 7-day lock returns the full stake; conservation restored.
        vm.warp(block.timestamp + 8 days);
        uint256 userBefore = mor.balanceOf(user);
        vm.prank(user);
        builders.withdraw(subnetId, 500 ether);
        assertEq(mor.balanceOf(user), userBefore + 500 ether, "full stake withdrawn after lock");
        (, , uint256 totalDepositedFinal, ) = builders.allSubnetsData();
        assertEq(totalDepositedFinal, totalDepositedBefore, "totalDeposited restored");
        assertEq(mor.balanceOf(BUILDERS), totalDepositedFinal, "final conservation");
    }
}

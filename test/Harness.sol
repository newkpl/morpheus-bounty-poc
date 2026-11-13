// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal cheatcode interface (avoids forge-std dependency).
interface Vm {
    function createSelectFork(string calldata urlOrAlias, uint256 blockNumber) external returns (uint256);
    function deal(address account, uint256 newBalance) external;
    function load(address target, bytes32 slot) external returns (bytes32);
    function store(address target, bytes32 slot, bytes32 value) external;
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 privateKey) external returns (address);
    function warp(uint256 newTimestamp) external;
    function expectRevert(bytes calldata revertData) external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert() external;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function deposit() external payable;
    function submit(address referral) external payable returns (uint256);
}

abstract contract Harness {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function _fail(string memory msg_) internal pure returns (bool) {
        revert(string(abi.encodePacked("ASSERT FAIL: ", msg_)));
    }

    function assertTrue(bool cond, string memory msg_) internal pure {
        if (!cond) _fail(msg_);
    }

    function assertEq(uint256 a, uint256 b, string memory msg_) internal pure {
        if (a != b) {
            revert(string(abi.encodePacked("ASSERT FAIL: ", msg_, " (", _u2s(a), " != ", _u2s(b), ")")));
        }
    }

    function assertGt(uint256 a, uint256 b, string memory msg_) internal pure {
        if (!(a > b)) _fail(msg_);
    }

    function assertGe(uint256 a, uint256 b, string memory msg_) internal pure {
        if (!(a >= b)) _fail(msg_);
    }

    function _u2s(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 digits;
        uint256 t = v;
        while (t != 0) {
            digits++;
            t /= 10;
        }
        bytes memory buf = new bytes(digits);
        while (v != 0) {
            digits--;
            buf[digits] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(buf);
    }

    function _signEth(bytes32 hash_, uint256 pk_) internal returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash_));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk_, digest);
        return abi.encodePacked(r, s, v);
    }
}

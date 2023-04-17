// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "solmate/tokens/ERC20.sol";
import "../src/FixedIncentiveRelayer.sol";
import "./MockTreasury.sol";

contract MockToken is ERC20 {
    constructor() ERC20("TAI", "TAI", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Target {
    uint public callsReceived;
    bool revertOnCalls;

    function noParamsCall() external {
        callsReceived++;
    }

    function withParamsCall(address, uint) external {
        callsReceived++;
    }

    function setRevert(bool val) external {
        revertOnCalls = val;
    }
}

contract FixedIncentiveRelayerTest is Test {
    FixedIncentiveRelayer relayer;
    Target target;
    MockToken coin;
    MockTreasury treasury;

    function setUp() public {
        vm.warp(1e6);

        coin = new MockToken();

        treasury = new MockTreasury(address(coin));
        coin.mint(address(treasury), 1e6 ether);

        target = new Target();

        relayer = new FixedIncentiveRelayer(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            1 ether,
            1 hours
        );

        treasury.setTotalAllowance(address(relayer), type(uint).max);
        treasury.setPerBlockAllowance(address(relayer), type(uint).max);
    }

    function testConstructor() external {
        assertEq(address(relayer.treasury()), address(treasury));
        assertEq(address(relayer.target()), address(target));
        assertEq(relayer.callSig(), target.withParamsCall.selector);
        assertEq(relayer.fixedReward(), 1 ether);
        assertEq(relayer.callDelay(), 1 hours);
        assertEq(relayer.lastCallMade(), 0);
    }

    function testConstructorNullTreasury() external {
        vm.expectRevert("invalid-treasury");
        relayer = new FixedIncentiveRelayer(
            address(0),
            address(target),
            target.withParamsCall.selector,
            1 ether,
            1 hours
        );
    }

    function testConstructorNullTarget() external {
        vm.expectRevert("invalid-target");
        relayer = new FixedIncentiveRelayer(
            address(treasury),
            address(0),
            target.withParamsCall.selector,
            1 ether,
            1 hours
        );
    }

    function testConstructorNullSig() external {
        vm.expectRevert("invalid-call-signature");
        relayer = new FixedIncentiveRelayer(
            address(treasury),
            address(target),
            bytes4(0),
            1 ether,
            1 hours
        );
    }

    function testConstructorNullReward() external {
        vm.expectRevert("invalid-reward");
        relayer = new FixedIncentiveRelayer(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            0,
            1 hours
        );
    }

    function testModifyParameters() external {
        relayer.modifyParameters("fixedReward", 2 ether);
        assertEq(relayer.fixedReward(), 2 ether);

        relayer.modifyParameters("callDelay", 2 weeks);
        assertEq(relayer.callDelay(), 2 weeks);

        vm.expectRevert("invalid-param");
        relayer.modifyParameters("inv", 2 weeks);
    }

    function testIncentivizedCall() external {
        bytes memory data = abi.encodeWithSelector(
            target.withParamsCall.selector,
            address(123),
            uint(1001)
        );

        vm.prank(address(0x0ddaf));
        address(relayer).call(data);

        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), 1 ether); // incentives paid
        assertEq(relayer.lastCallMade(), block.timestamp);
    }

    function testIncentivizedCallTooSoon() external {
        bytes memory data = abi.encodeWithSelector(
            target.withParamsCall.selector,
            address(123),
            uint(1001)
        );

        vm.prank(address(0x0ddaf));
        address(relayer).call(data);

        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), 1 ether); // incentives paid
        assertEq(relayer.lastCallMade(), block.timestamp);

        vm.warp(block.timestamp + 1);
        address(relayer).call(data);

        assertEq(target.callsReceived(), 2); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), 1 ether); // incentives not paid (too soon)
        assertEq(relayer.lastCallMade(), block.timestamp);
    }

    function testIncentivizedCallNoParams() external {
        relayer = new FixedIncentiveRelayer(
            address(treasury),
            address(target),
            target.noParamsCall.selector,
            2 ether,
            1 hours
        );

        treasury.setTotalAllowance(address(relayer), type(uint).max);
        treasury.setPerBlockAllowance(address(relayer), type(uint).max);

        bytes memory data = abi.encodeWithSelector(
            target.noParamsCall.selector
        );

        vm.prank(address(0x0ddaf));
        address(relayer).call(data);

        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), 2 ether); // incentives paid
        assertEq(relayer.lastCallMade(), block.timestamp);
    }

    function testIncentivizedCallWrongSig() external {
        bytes memory data = abi.encodeWithSelector(
            bytes4("0dd"),
            address(123),
            uint(1001)
        );

        vm.expectRevert("invalid-call");
        address(relayer).call(data);
    }

    function testIncentivizedCallTargetReverts() external {
        bytes memory data = abi.encodeWithSelector(
            target.withParamsCall.selector,
            address(123),
            uint(1001)
        );

        target.setRevert(true);

        vm.prank(address(0x0ddaf));
        vm.expectRevert("call-failed");
        address(relayer).call(data);
    }

    function testIncentivizedCallNoAllowance() external {
        bytes memory data = abi.encodeWithSelector(
            target.withParamsCall.selector,
            address(123),
            uint(1001)
        );
        treasury.setTotalAllowance(address(relayer), 0);

        vm.prank(address(0x0ddaf));
        address(relayer).call(data);

        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), 0); // incentives not paid
        assertEq(relayer.lastCallMade(), block.timestamp); // call made, so delay enforced
    }

    function testIncentivizedCallTreasuryReverts() external {
        MockRevertableTreasury revertTreasury = new MockRevertableTreasury();

        relayer = new FixedIncentiveRelayer(
            address(revertTreasury),
            address(target),
            target.withParamsCall.selector,
            1 ether,
            1 hours
        );

        bytes memory data = abi.encodeWithSelector(
            target.withParamsCall.selector,
            address(123),
            uint(1001)
        );

        vm.prank(address(0x0ddaf));
        address(relayer).call(data);

        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), 0); // incentives not paid
        assertEq(relayer.lastCallMade(), block.timestamp); // call made, so delay enforced
    }

    function testIncentivizedCallMultipleSameBlock() external {
        bytes memory data = abi.encodeWithSelector(
            target.withParamsCall.selector,
            address(123),
            uint(1001)
        );

        relayer.modifyParameters("callDelay", 0);

        vm.prank(address(0x0ddaf));
        address(relayer).call(data);

        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), 1 ether); // incentives paid
        assertEq(relayer.lastCallMade(), block.timestamp);

        vm.prank(address(0x0ddaf));
        address(relayer).call(data);

        assertEq(target.callsReceived(), 2); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), 2 ether); // incentives paid
        assertEq(relayer.lastCallMade(), block.timestamp);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "solmate/tokens/ERC20.sol";
import "../src/IncreasingIncentiveRelayer.sol";
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

contract IncreasingIncentiveRelayerTest is Test {
    IncreasingIncentiveRelayer relayer;
    Target target;
    MockToken coin;
    MockTreasury treasury;

    uint256 startTime = 1577836800;
    uint256 baseCallerReward = 1 ether;
    uint256 maxCallerReward = 10 ether;
    uint256 maxRewardIncreaseDelay = 6 hours;
    uint256 initTokenAmount = 100000000 ether;
    uint256 perSecondCallerRewardIncrease = 1000192559420674483977255848; // 100% over one hour
    uint256 RAY = 10 ** 27;

    function setUp() public {
        vm.warp(startTime);

        coin = new MockToken();

        treasury = new MockTreasury(address(coin));
        coin.mint(address(treasury), initTokenAmount);

        target = new Target();

        relayer = new IncreasingIncentiveRelayer(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            baseCallerReward,
            maxCallerReward,
            maxRewardIncreaseDelay,
            perSecondCallerRewardIncrease,
            1 hours
        );

        treasury.setTotalAllowance(address(relayer), type(uint).max);
        treasury.setPerBlockAllowance(address(relayer), type(uint).max);
    }

    function testConstructor() external {
        assertEq(address(relayer.treasury()), address(treasury));
        assertEq(address(relayer.target()), address(target));
        assertEq(relayer.callSig(), target.withParamsCall.selector);

        assertEq(relayer.baseUpdateCallerReward(), baseCallerReward);
        assertEq(relayer.maxUpdateCallerReward(), maxCallerReward);
        assertEq(relayer.maxRewardIncreaseDelay(), maxRewardIncreaseDelay);
        assertEq(
            relayer.perSecondCallerRewardIncrease(),
            perSecondCallerRewardIncrease
        );

        assertEq(relayer.callDelay(), 1 hours);
        assertEq(relayer.lastCallMade(), 0);
    }

    function testConstructorNullTreasury() external {
        vm.expectRevert("invalid-treasury");
        relayer = new IncreasingIncentiveRelayer(
            address(0),
            address(target),
            target.withParamsCall.selector,
            baseCallerReward,
            maxCallerReward,
            maxRewardIncreaseDelay,
            perSecondCallerRewardIncrease,
            1 hours
        );
    }

    function testConstructorNullTarget() external {
        vm.expectRevert("invalid-target");
        relayer = new IncreasingIncentiveRelayer(
            address(treasury),
            address(0),
            target.withParamsCall.selector,
            baseCallerReward,
            maxCallerReward,
            maxRewardIncreaseDelay,
            perSecondCallerRewardIncrease,
            1 hours
        );
    }

    function testConstructorNullSig() external {
        vm.expectRevert("invalid-call-signature");
        relayer = new IncreasingIncentiveRelayer(
            address(treasury),
            address(target),
            bytes4(0),
            baseCallerReward,
            maxCallerReward,
            maxRewardIncreaseDelay,
            perSecondCallerRewardIncrease,
            1 hours
        );
    }

    function testConstructorBaseReward() external {
        vm.expectRevert("invalid-base-reward");
        relayer = new IncreasingIncentiveRelayer(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            0,
            maxCallerReward,
            maxRewardIncreaseDelay,
            perSecondCallerRewardIncrease,
            1 hours
        );
    }

    function testConstructorNullMaxReward() external {
        vm.expectRevert("invalid-max-reward");
        relayer = new IncreasingIncentiveRelayer(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            baseCallerReward,
            0,
            maxRewardIncreaseDelay,
            perSecondCallerRewardIncrease,
            1 hours
        );
    }

    function testConstructorNullRewardIncreaseDelay() external {
        vm.expectRevert("invalid-reward-increase-delay");
        relayer = new IncreasingIncentiveRelayer(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            baseCallerReward,
            maxCallerReward,
            0,
            perSecondCallerRewardIncrease,
            1 hours
        );
    }

    function testConstructorNullIncreaseRate() external {
        vm.expectRevert("invalid-reward-rate");
        relayer = new IncreasingIncentiveRelayer(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            baseCallerReward,
            maxCallerReward,
            maxRewardIncreaseDelay,
            0,
            1 hours
        );
    }

    function testConstructorNullIncreaseDelay() external {
        vm.expectRevert("invalid-delay");
        relayer = new IncreasingIncentiveRelayer(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            baseCallerReward,
            maxCallerReward,
            maxRewardIncreaseDelay,
            perSecondCallerRewardIncrease,
            0
        );
    }

    function testConstructorInvalidRewards() external {
        vm.expectRevert("invalid-max-caller-reward");
        relayer = new IncreasingIncentiveRelayer(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            baseCallerReward,
            baseCallerReward - 1,
            maxRewardIncreaseDelay,
            perSecondCallerRewardIncrease,
            1 hours
        );
    }

    function testConstructorInvalidIncreaseRate() external {
        vm.expectRevert("invalid-per-second-reward-increase");
        relayer = new IncreasingIncentiveRelayer(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            baseCallerReward,
            maxCallerReward,
            maxRewardIncreaseDelay,
            RAY - 1,
            1 hours
        );
    }

    function testConstructorParamsOverflow() external {
        vm.expectRevert();
        relayer = new IncreasingIncentiveRelayer(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            baseCallerReward,
            maxCallerReward,
            1000 weeks, // long delay, will cause it to overflow
            perSecondCallerRewardIncrease,
            1 hours
        );
    }

    function testModifyParameters() external {
        relayer.modifyParameters(
            "baseUpdateCallerReward",
            baseCallerReward - 1
        );
        assertEq(relayer.baseUpdateCallerReward(), baseCallerReward - 1);

        vm.expectRevert("invalid-base-caller-reward");
        relayer.modifyParameters("baseUpdateCallerReward", 0);

        vm.expectRevert("invalid-base-caller-reward");
        relayer.modifyParameters("baseUpdateCallerReward", maxCallerReward + 1);

        relayer.modifyParameters("maxUpdateCallerReward", maxCallerReward + 1);
        assertEq(relayer.maxUpdateCallerReward(), maxCallerReward + 1);

        vm.expectRevert("invalid-max-caller-reward");
        relayer.modifyParameters("maxUpdateCallerReward", baseCallerReward - 2);

        relayer.modifyParameters("maxRewardIncreaseDelay", 1 days);
        assertEq(relayer.maxRewardIncreaseDelay(), 1 days);

        vm.expectRevert("invalid-max-reward-increase-delay");
        relayer.modifyParameters("maxRewardIncreaseDelay", 0);

        relayer.modifyParameters("perSecondCallerRewardIncrease", RAY);
        assertEq(relayer.perSecondCallerRewardIncrease(), RAY);

        vm.expectRevert("invalid-per-second-reward-increase");
        relayer.modifyParameters("perSecondCallerRewardIncrease", RAY - 1);

        relayer.modifyParameters("callDelay", 2 weeks);
        assertEq(relayer.callDelay(), 2 weeks);

        vm.expectRevert("invalid-call-delay");
        relayer.modifyParameters("callDelay", 0);

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
        assertEq(coin.balanceOf(address(0x0ddaf)), maxCallerReward); // incentives paid, first one will pay max
        assertEq(relayer.lastCallMade(), block.timestamp);

        vm.warp(relayer.lastCallMade() + relayer.callDelay() - 1); // just before it will start paying rewards
        vm.prank(address(0x0ddaf));
        address(relayer).call(data);
        assertEq(target.callsReceived(), 2); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), maxCallerReward); // no payment, too early
        assertEq(relayer.lastCallMade(), block.timestamp);

        vm.warp(relayer.lastCallMade() + relayer.callDelay()); // right at the second it starts paying
        vm.prank(address(0x0ddaf));
        address(relayer).call(data);
        assertEq(target.callsReceived(), 3); // call made
        assertEq(
            coin.balanceOf(address(0x0ddaf)),
            maxCallerReward + baseCallerReward
        );
        assertEq(relayer.lastCallMade(), block.timestamp);

        vm.warp(relayer.lastCallMade() + relayer.callDelay() + 1 hours); // one hour after it starts paying
        vm.prank(address(0x0ddaf));
        address(relayer).call(data);
        assertEq(target.callsReceived(), 4); // call made
        assertTrue(
            coin.balanceOf(address(0x0ddaf)) ==
                maxCallerReward + 3 * baseCallerReward || // allow for 1 wei difference due to loss of precision by int division
                coin.balanceOf(address(0x0ddaf)) ==
                maxCallerReward - 1 + 3 * baseCallerReward
        );
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

        relayer = new IncreasingIncentiveRelayer(
            address(revertTreasury),
            address(target),
            target.withParamsCall.selector,
            baseCallerReward,
            maxCallerReward,
            maxRewardIncreaseDelay,
            perSecondCallerRewardIncrease,
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
}

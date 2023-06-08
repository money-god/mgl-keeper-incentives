// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "solmate/tokens/ERC20.sol";
import "../src/Callers/BasefeeIncentiveCaller.sol";
import "./MockTreasury.sol";

contract MockToken is ERC20 {
    constructor() ERC20("TAI", "TAI", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockOracle {
    uint public read;

    constructor(uint price) {
        read = price;
    }

    function setPrice(uint price) external {
        read = price;
    }
}

contract Target {
    uint public callsReceived;
    bool revertOnCalls;

    function noParamsCall() external {
        require(!revertOnCalls);
        callsReceived++;
    }

    function withParamsCall(address, uint) external {
        require(!revertOnCalls);
        callsReceived++;
    }

    function setRevert(bool val) external {
        revertOnCalls = val;
    }
}

contract BasefeeIncentiveCallerTest is Test {
    BasefeeIncentiveCaller caller;
    Target target;
    MockToken coin;
    MockTreasury treasury;

    MockOracle coinOracle;
    MockOracle ethOracle;

    uint256 basefee = 30 * 10 ** 9;
    uint256 gasCost = 31780; // gas cost of the call to the mock contract. cheap! :)

    function setUp() public {
        vm.warp(1e6);

        coin = new MockToken();

        treasury = new MockTreasury(address(coin));
        coin.mint(address(treasury), 1e6 ether);

        coinOracle = new MockOracle(3 * 10 ** 18);
        ethOracle = new MockOracle(1500 * 10 ** 18);

        target = new Target();

        caller = new BasefeeIncentiveCaller(
            address(treasury),
            address(target),
            target.noParamsCall.selector,
            1 ether,
            1 hours,
            address(coinOracle),
            address(ethOracle)
        );

        treasury.setTotalAllowance(address(caller), type(uint).max);
        treasury.setPerBlockAllowance(address(caller), type(uint).max);

        vm.fee(basefee);
    }

    function testConstructor2() external {
        assertEq(address(caller.treasury()), address(treasury));
        assertEq(address(caller.target()), address(target));
        assertEq(caller.callData(), target.noParamsCall.selector);
        assertEq(caller.fixedReward(), 1 ether);
        assertEq(caller.callDelay(), 1 hours);
        assertEq(caller.lastCallMade(), 0);
        assertEq(address(caller.coinOracle()), address(coinOracle));
        assertEq(address(caller.ethOracle()), address(ethOracle));
    }

    function testConstructorNullTreasury() external {
        vm.expectRevert("invalid-treasury");
        caller = new BasefeeIncentiveCaller(
            address(0),
            address(target),
            target.withParamsCall.selector,
            1 ether,
            1 hours,
            address(coinOracle),
            address(ethOracle)
        );
    }

    function testConstructorNullTarget() external {
        vm.expectRevert("invalid-target");
        caller = new BasefeeIncentiveCaller(
            address(treasury),
            address(0),
            target.withParamsCall.selector,
            1 ether,
            1 hours,
            address(coinOracle),
            address(ethOracle)
        );
    }

    function testConstructorNullData() external {
        vm.expectRevert("invalid-call-data");
        caller = new BasefeeIncentiveCaller(
            address(treasury),
            address(target),
            bytes4(0),
            1 ether,
            1 hours,
            address(coinOracle),
            address(ethOracle)
        );
    }

    function testConstructorNullReward() external {
        vm.expectRevert("invalid-reward");
        caller = new BasefeeIncentiveCaller(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            0,
            1 hours,
            address(coinOracle),
            address(ethOracle)
        );
    }

    function testConstructorNullCoinOracle() external {
        vm.expectRevert("invalid-coin-oracle");
        caller = new BasefeeIncentiveCaller(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            1 ether,
            1 hours,
            address(0),
            address(ethOracle)
        );
    }

    function testConstructorNullEthOracle() external {
        vm.expectRevert("invalid-eth-oracle");
        caller = new BasefeeIncentiveCaller(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            1 ether,
            1 hours,
            address(coinOracle),
            address(0)
        );
    }

    function testModifyParameters() external {
        caller.modifyParameters("fixedReward", 2 ether);
        assertEq(caller.fixedReward(), 2 ether);

        caller.modifyParameters("callDelay", 2 weeks);
        assertEq(caller.callDelay(), 2 weeks);

        vm.expectRevert("invalid-param");
        caller.modifyParameters("inv", 2 weeks);

        caller.modifyParameters("coinOracle", address(1));
        assertEq(address(caller.coinOracle()), address(1));

        caller.modifyParameters("ethOracle", address(2));
        assertEq(address(caller.ethOracle()), address(2));

        vm.expectRevert("invalid-param");
        caller.modifyParameters("inv", address(666));

        vm.expectRevert("invalid-data");
        caller.modifyParameters("ethOracle", address(0));

        vm.expectRevert("invalid-data");
        caller.modifyParameters("coinOracle", address(0));
    }

    function testIncentivizedCall() external {
        vm.prank(address(0x0ddaf));
        address(caller).call(""); // anything goes on the data field as long as the sigs do not match any of the contract's functions

        uint callCostInCoin = (gasCost * basefee * ethOracle.read()) /
            coinOracle.read();
        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), callCostInCoin + 1 ether); // incentives paid
        assertEq(caller.lastCallMade(), block.timestamp);
    }

    function testIncentivizedCallTooSoon() external {
        vm.prank(address(0x0ddaf));
        address(caller).call("");

        uint callCostInCoin = (gasCost * basefee * ethOracle.read()) /
            coinOracle.read();
        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), callCostInCoin + 1 ether); // incentives paid
        assertEq(caller.lastCallMade(), block.timestamp);

        vm.warp(block.timestamp + 1);
        address(caller).call("");

        assertEq(target.callsReceived(), 2); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), callCostInCoin + 1 ether); // incentives not paid (too soon)
        assertEq(caller.lastCallMade(), block.timestamp);
    }

    function testIncentivizedCallNoParams() external {
        caller = new BasefeeIncentiveCaller(
            address(treasury),
            address(target),
            target.noParamsCall.selector,
            2 ether,
            1 hours,
            address(coinOracle),
            address(ethOracle)
        );

        treasury.setTotalAllowance(address(caller), type(uint).max);
        treasury.setPerBlockAllowance(address(caller), type(uint).max);

        vm.prank(address(0x0ddaf));
        address(caller).call("");

        uint callCostInCoin = (((29780 * basefee * ethOracle.read()) /
            10 ** 18) * 10 ** 18) / coinOracle.read(); // gas cost for non param call cheaper
        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), callCostInCoin + 2 ether); // incentives paid
        assertEq(caller.lastCallMade(), block.timestamp);
    }

    function testIncentivizedCallTargetReverts() external {
        target.setRevert(true);

        vm.prank(address(0x0ddaf));
        vm.expectRevert("call-failed");
        address(caller).call("");
    }

    function testIncentivizedCallNoAllowance() external {
        treasury.setTotalAllowance(address(caller), 0);

        vm.prank(address(0x0ddaf));
        address(caller).call("");

        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), 0); // incentives not paid
        assertEq(caller.lastCallMade(), block.timestamp); // call made, so delay enforced
    }

    function testIncentivizedCallTreasuryReverts() external {
        MockRevertableTreasury revertTreasury = new MockRevertableTreasury();

        caller = new BasefeeIncentiveCaller(
            address(revertTreasury),
            address(target),
            target.noParamsCall.selector,
            1 ether,
            1 hours,
            address(coinOracle),
            address(ethOracle)
        );

        vm.prank(address(0x0ddaf));
        address(caller).call("0x0ddaf");

        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), 0); // incentives not paid
        assertEq(caller.lastCallMade(), block.timestamp); // call made, so delay enforced
    }

    function testIncentivizedCallMultipleSameBlock() external {
        vm.prank(address(0x0ddaf));
        address(caller).call("");

        uint reward = ((gasCost * basefee * ethOracle.read()) /
            coinOracle.read()) + 1 ether;
        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), reward); // incentives paid
        assertEq(caller.lastCallMade(), block.timestamp);

        caller.modifyParameters("callDelay", 0);

        vm.prank(address(0x0ddaf));
        address(caller).call("");

        reward +=
            ((1380 * basefee * ethOracle.read()) / coinOracle.read()) +
            1 ether; // warm sslot
        assertEq(target.callsReceived(), 2); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), reward); // incentives paid
        assertEq(caller.lastCallMade(), block.timestamp);
    }
}

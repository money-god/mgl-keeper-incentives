// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "solmate/tokens/ERC20.sol";
import "../src/Callers/BasefeeIncentiveCallBundler.sol";
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

contract BasefeeIncentiveCallBundlerTest is Test {
    BasefeeIncentiveCallBundler caller;
    Target target0;
    Target target1;
    MockToken coin;
    MockTreasury treasury;

    MockOracle coinOracle;
    MockOracle ethOracle;

    uint256 basefee = 30 * 10 ** 9;
    uint256 gasCost = 59230;

    function setUp() public {
        vm.warp(1e6);

        coin = new MockToken();

        treasury = new MockTreasury(address(coin));
        coin.mint(address(treasury), 1e6 ether);

        coinOracle = new MockOracle(3 * 10 ** 18);
        ethOracle = new MockOracle(1500 * 10 ** 18);

        target0 = new Target();
        target1 = new Target();

        caller = new BasefeeIncentiveCallBundler(
            address(treasury),
            [address(target0), address(target1)],
            [
                bytes32(target0.noParamsCall.selector),
                bytes32(target1.noParamsCall.selector)
            ],
            1 ether,
            0, // delay
            address(coinOracle),
            address(ethOracle)
        );

        treasury.setTotalAllowance(address(caller), type(uint).max);
        treasury.setPerBlockAllowance(address(caller), type(uint).max);

        vm.fee(basefee);
    }

    function testConstructor() external {
        assertEq(address(caller.treasury()), address(treasury));
        assertEq(address(caller.target0()), address(target0));
        assertEq(address(caller.target1()), address(target1));
        assertEq(caller.callData0(), target0.noParamsCall.selector);
        assertEq(caller.callData1(), target1.noParamsCall.selector);
        assertEq(caller.fixedReward(), 1 ether);
        assertEq(caller.callDelay(), 0);
        assertEq(caller.lastCallMade(), 0);
        assertEq(address(caller.coinOracle()), address(coinOracle));
        assertEq(address(caller.ethOracle()), address(ethOracle));
    }

    function testConstructorNullTreasury() external {
        vm.expectRevert("invalid-treasury");
        caller = new BasefeeIncentiveCallBundler(
            address(0),
            [address(target0), address(target1)],
            [
                bytes32(target0.noParamsCall.selector),
                bytes32(target1.noParamsCall.selector)
            ],
            1 ether,
            1 hours, // delay
            address(coinOracle),
            address(ethOracle)
        );
    }

    function testConstructorNullTarget0() external {
        vm.expectRevert("invalid-target");
        caller = new BasefeeIncentiveCallBundler(
            address(treasury),
            [address(0), address(target1)],
            [
                bytes32(target0.noParamsCall.selector),
                bytes32(target1.noParamsCall.selector)
            ],
            1 ether,
            1 hours, // delay
            address(coinOracle),
            address(ethOracle)
        );
    }

    function testConstructorNullTarget1() external {
        vm.expectRevert("invalid-target");
        caller = new BasefeeIncentiveCallBundler(
            address(treasury),
            [address(target0), address(0)],
            [
                bytes32(target0.noParamsCall.selector),
                bytes32(target1.noParamsCall.selector)
            ],
            1 ether,
            0, // delay
            address(coinOracle),
            address(ethOracle)
        );
    }

    function testConstructorNullData0() external {
        vm.expectRevert("invalid-call-data");
        caller = new BasefeeIncentiveCallBundler(
            address(treasury),
            [address(target0), address(target1)],
            [bytes32(0), bytes32(target1.noParamsCall.selector)],
            1 ether,
            0, // delay
            address(coinOracle),
            address(ethOracle)
        );
    }

    function testConstructorNullData1() external {
        vm.expectRevert("invalid-call-data");
        caller = new BasefeeIncentiveCallBundler(
            address(treasury),
            [address(target0), address(target1)],
            [bytes32(target0.noParamsCall.selector), bytes32(0)],
            1 ether,
            0, // delay
            address(coinOracle),
            address(ethOracle)
        );
    }

    function testConstructorNullReward() external {
        vm.expectRevert("invalid-reward");
        caller = new BasefeeIncentiveCallBundler(
            address(treasury),
            [address(target0), address(target1)],
            [
                bytes32(target0.noParamsCall.selector),
                bytes32(target1.noParamsCall.selector)
            ],
            0,
            0, // delay
            address(coinOracle),
            address(ethOracle)
        );
    }

    function testConstructorNullCoinOracle() external {
        vm.expectRevert("invalid-coin-oracle");
        caller = new BasefeeIncentiveCallBundler(
            address(treasury),
            [address(target0), address(target1)],
            [
                bytes32(target0.noParamsCall.selector),
                bytes32(target1.noParamsCall.selector)
            ],
            1 ether,
            0, // delay
            address(0),
            address(ethOracle)
        );
    }

    function testConstructorNullEthOracle() external {
        vm.expectRevert("invalid-eth-oracle");
        caller = new BasefeeIncentiveCallBundler(
            address(treasury),
            [address(target0), address(target1)],
            [
                bytes32(target0.noParamsCall.selector),
                bytes32(target1.noParamsCall.selector)
            ],
            1 ether,
            0, // delay
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
        assertEq(target0.callsReceived(), 1); // call made
        assertEq(target1.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), callCostInCoin + 1 ether); // incentives paid
        assertEq(caller.lastCallMade(), block.timestamp);
    }

    function testIncentivizedCallTooSoon() external {
        vm.prank(address(0x0ddaf));
        address(caller).call("");

        uint callCostInCoin = (gasCost * basefee * ethOracle.read()) /
            coinOracle.read();
        assertEq(target0.callsReceived(), 1); // call made
        assertEq(target1.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), callCostInCoin + 1 ether); // incentives paid
        assertEq(caller.lastCallMade(), block.timestamp);

        vm.warp(block.timestamp + 1);
        address(caller).call("");

        assertEq(target0.callsReceived(), 2); // call made
        assertEq(target1.callsReceived(), 2); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), callCostInCoin + 1 ether); // incentives not paid (too soon)
        assertEq(caller.lastCallMade(), block.timestamp);
    }

    function testIncentivizedCallTarget0Reverts() external {
        target0.setRevert(true);

        vm.prank(address(0x0ddaf));
        vm.expectRevert("call-failed");
        address(caller).call("");
    }

    function testIncentivizedCallTarget1Reverts() external {
        target1.setRevert(true);

        vm.prank(address(0x0ddaf));
        vm.expectRevert("call-failed");
        address(caller).call("");
    }

    function testIncentivizedCallNoAllowance() external {
        treasury.setTotalAllowance(address(caller), 0);

        vm.prank(address(0x0ddaf));
        address(caller).call("");

        assertEq(target0.callsReceived(), 1); // call made
        assertEq(target1.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), 0); // incentives not paid
        assertEq(caller.lastCallMade(), block.timestamp); // call made, so delay enforced
    }

    function testIncentivizedCallTreasuryReverts() external {
        MockRevertableTreasury revertTreasury = new MockRevertableTreasury();

        caller = new BasefeeIncentiveCallBundler(
            address(revertTreasury),
            [address(target0), address(target1)],
            [
                bytes32(target0.noParamsCall.selector),
                bytes32(target1.noParamsCall.selector)
            ],
            1 ether,
            1 hours,
            address(coinOracle),
            address(ethOracle)
        );

        vm.prank(address(0x0ddaf));
        address(caller).call("0x0ddaf");

        assertEq(target0.callsReceived(), 1); // call made
        assertEq(target1.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), 0); // incentives not paid
        assertEq(caller.lastCallMade(), block.timestamp); // call made, so delay enforced
    }

    function testIncentivizedCallMultipleSameBlock2() external {
        vm.prank(address(0x0ddaf));
        address(caller).call("");

        uint reward = ((gasCost * basefee * ethOracle.read()) /
            coinOracle.read()) + 1 ether;
        assertEq(target0.callsReceived(), 1); // call made
        assertEq(target1.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), reward); // incentives paid
        assertEq(caller.lastCallMade(), block.timestamp);

        caller.modifyParameters("callDelay", 0);

        vm.prank(address(0x0ddaf));
        address(caller).call("");

        assertEq(target0.callsReceived(), 2); // call made
        assertEq(target1.callsReceived(), 2); // call made
        assertEq(caller.lastCallMade(), block.timestamp);
    }
}

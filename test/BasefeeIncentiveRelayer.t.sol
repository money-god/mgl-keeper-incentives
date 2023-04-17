// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "solmate/tokens/ERC20.sol";
import "../src/BasefeeIncentiveRelayer.sol";
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
        callsReceived++;
    }

    function withParamsCall(address, uint) external {
        callsReceived++;
    }

    function setRevert(bool val) external {
        revertOnCalls = val;
    }
}

contract BasefeeIncentiveRelayerTest is Test {
    BasefeeIncentiveRelayer relayer;
    Target target;
    MockToken coin;
    MockTreasury treasury;

    MockOracle coinOracle;
    MockOracle ethOracle;

    uint256 basefee = 30 * 10 ** 9;
    uint256 gasCost = 29746; // gas cost of the call to the mock contract. cheap! :)

    function setUp() public {
        vm.warp(1e6);

        coin = new MockToken();

        treasury = new MockTreasury(address(coin));
        coin.mint(address(treasury), 1e6 ether);

        coinOracle = new MockOracle(3 * 10 ** 18);
        ethOracle = new MockOracle(1500 * 10 ** 18);

        target = new Target();

        relayer = new BasefeeIncentiveRelayer(
            address(treasury),
            address(target),
            target.withParamsCall.selector,
            1 ether,
            1 hours,
            address(coinOracle),
            address(ethOracle)
        );

        treasury.setTotalAllowance(address(relayer), type(uint).max);
        treasury.setPerBlockAllowance(address(relayer), type(uint).max);

        vm.fee(basefee);
    }

    function testConstructor() external {
        assertEq(address(relayer.treasury()), address(treasury));
        assertEq(address(relayer.target()), address(target));
        assertEq(relayer.callSig(), target.withParamsCall.selector);
        assertEq(relayer.fixedReward(), 1 ether);
        assertEq(relayer.callDelay(), 1 hours);
        assertEq(relayer.lastCallMade(), 0);
        assertEq(address(relayer.coinOracle()), address(coinOracle));
        assertEq(address(relayer.ethOracle()), address(ethOracle));
    }

    function testConstructorNullTreasury() external {
        vm.expectRevert("invalid-treasury");
        relayer = new BasefeeIncentiveRelayer(
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
        relayer = new BasefeeIncentiveRelayer(
            address(treasury),
            address(0),
            target.withParamsCall.selector,
            1 ether,
            1 hours,
            address(coinOracle),
            address(ethOracle)
        );
    }

    function testConstructorNullSig() external {
        vm.expectRevert("invalid-call-signature");
        relayer = new BasefeeIncentiveRelayer(
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
        relayer = new BasefeeIncentiveRelayer(
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
        relayer = new BasefeeIncentiveRelayer(
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
        relayer = new BasefeeIncentiveRelayer(
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
        relayer.modifyParameters("fixedReward", 2 ether);
        assertEq(relayer.fixedReward(), 2 ether);

        relayer.modifyParameters("callDelay", 2 weeks);
        assertEq(relayer.callDelay(), 2 weeks);

        vm.expectRevert("invalid-param");
        relayer.modifyParameters("inv", 2 weeks);

        relayer.modifyParameters("coinOracle", address(1));
        assertEq(address(relayer.coinOracle()), address(1));

        relayer.modifyParameters("ethOracle", address(2));
        assertEq(address(relayer.ethOracle()), address(2));

        vm.expectRevert("invalid-param");
        relayer.modifyParameters("inv", address(666));

        vm.expectRevert("invalid-data");
        relayer.modifyParameters("ethOracle", address(0));

        vm.expectRevert("invalid-data");
        relayer.modifyParameters("coinOracle", address(0));
    }

    function testIncentivizedCall() external {
        bytes memory data = abi.encodeWithSelector(
            target.withParamsCall.selector,
            address(123),
            uint(1001)
        );

        vm.prank(address(0x0ddaf));
        address(relayer).call(data);

        uint callCostInCoin = (gasCost * basefee * ethOracle.read()) /
            coinOracle.read();
        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), callCostInCoin + 1 ether); // incentives paid
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

        uint callCostInCoin = (gasCost * basefee * ethOracle.read()) /
            coinOracle.read();
        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), callCostInCoin + 1 ether); // incentives paid
        assertEq(relayer.lastCallMade(), block.timestamp);

        vm.warp(block.timestamp + 1);
        address(relayer).call(data);

        assertEq(target.callsReceived(), 2); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), callCostInCoin + 1 ether); // incentives not paid (too soon)
        assertEq(relayer.lastCallMade(), block.timestamp);
    }

    function testIncentivizedCallNoParams() external {
        relayer = new BasefeeIncentiveRelayer(
            address(treasury),
            address(target),
            target.noParamsCall.selector,
            2 ether,
            1 hours,
            address(coinOracle),
            address(ethOracle)
        );

        treasury.setTotalAllowance(address(relayer), type(uint).max);
        treasury.setPerBlockAllowance(address(relayer), type(uint).max);

        bytes memory data = abi.encodeWithSelector(
            target.noParamsCall.selector
        );

        vm.prank(address(0x0ddaf));
        address(relayer).call(data);

        uint callCostInCoin = (((27520 * basefee * ethOracle.read()) /
            10 ** 18) * 10 ** 18) / coinOracle.read(); // gas cost for non param call cheaper
        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), callCostInCoin + 2 ether); // incentives paid
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

        relayer = new BasefeeIncentiveRelayer(
            address(revertTreasury),
            address(target),
            target.withParamsCall.selector,
            1 ether,
            1 hours,
            address(coinOracle),
            address(ethOracle)
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

    function testIncentivizedCallMultipleSameBlock2() external {
        bytes memory data = abi.encodeWithSelector(
            target.withParamsCall.selector,
            address(123),
            uint(1001)
        );

        vm.prank(address(0x0ddaf));
        address(relayer).call(data);

        uint reward = ((gasCost * basefee * ethOracle.read()) /
            coinOracle.read()) + 1 ether;
        assertEq(target.callsReceived(), 1); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), reward); // incentives paid
        assertEq(relayer.lastCallMade(), block.timestamp);

        relayer.modifyParameters("callDelay", 0);

        vm.prank(address(0x0ddaf));
        address(relayer).call(data);

        reward +=
            ((1346 * basefee * ethOracle.read()) / coinOracle.read()) +
            1 ether; // warm sslot
        assertEq(target.callsReceived(), 2); // call made
        assertEq(coin.balanceOf(address(0x0ddaf)), reward); // incentives paid
        assertEq(relayer.lastCallMade(), block.timestamp);
    }
}

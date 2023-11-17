// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "solmate/tokens/ERC20.sol";
import "../src/Callers/BasefeeOSMDeviationCallBundler.sol";
import "./MockTreasury.sol";

contract MockToken is ERC20 {
    constructor() ERC20("TAI", "TAI", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockReverter {
    bool public revertOnCall;

    function setRevert(bool value) external {
        revertOnCall = value;
    }

    modifier reverter() {
        require(!revertOnCall, "forced revert");
        _;
    }
}

contract MockOracle is MockReverter {
    uint public read;

    constructor(uint price) {
        read = price;
    }

    function setPrice(uint price) external reverter {
        read = price;
    }
}

contract MockOsm is MockReverter {
    MockOracle public orcl;
    uint public read;
    uint public next;

    constructor() {
        read = 1500 ether;
        next = 1700 ether;
        orcl = new MockOracle(2000 ether);
    }

    function updateResult() external reverter() {
        read = next;
        next = orcl.read();
    }

    function getNextResultWithValidity() external view returns (uint256, bool) {
        return (next, true);
    }

    function setRead(uint value) external {
        read = value;
    }

    function setNext(uint value) external {
        next = value;
    }

    function priceSource() external view returns (address) {
        return address(orcl);
    }
}

contract MockOracleRelayer is MockReverter {
    uint public calls;
    address internal _orcl;

    constructor() {
        _orcl = address(new MockOsm());
    }

    function updateCollateralPrice(bytes32 collatName) external reverter {
        if (collatName == "ETH-A" || collatName == "ETH-B" || collatName == "ETH-C")
            calls++;
        else
            revert("updating wrong collateral");
    }

    function orcl(bytes32 collatName) external view returns (address) {
        if (collatName == "ETH-A" || collatName == "ETH-B" || collatName == "ETH-C")
            return _orcl;
    }
}

contract BasefeeOSMDeviationCallBundlerTest is Test {
    BasefeeOSMDeviationCallBundler bundler;
    MockToken coin;
    MockTreasury treasury;
    MockOsm osm;
    MockOracleRelayer oracleRelayer;

    MockOracle coinOracle;
    MockOracle ethOracle;

    uint256 basefee = 30 * 10 ** 9;

    function setUp() public {
        vm.warp(1e6);

        coin = new MockToken();

        treasury = new MockTreasury(address(coin));
        coin.mint(address(treasury), 1e6 ether);

        oracleRelayer = new MockOracleRelayer();
        osm = MockOsm(oracleRelayer.orcl("ETH-A"));

        coinOracle = new MockOracle(3 * 10 ** 18);
        ethOracle = osm.orcl();

        bundler = new BasefeeOSMDeviationCallBundler(
            address(treasury),
            address(osm),
            address(oracleRelayer),
            [bytes32("ETH-A"), "ETH-B", "ETH-C"],
            1 ether,
            1 minutes,
            address(coinOracle),
            address(ethOracle),
            50 // 5%
        );

        treasury.setTotalAllowance(address(bundler), type(uint).max);
        treasury.setPerBlockAllowance(address(bundler), type(uint).max);

        vm.fee(basefee);
    }

    function testConstructor() external {
        assertEq(address(bundler.treasury()), address(treasury));
        assertEq(address(bundler.osm()), address(osm));
        assertEq(address(bundler.oracleRelayer()), address(oracleRelayer));
        assertEq(bundler.fixedReward(), 1 ether);
        assertEq(bundler.callDelay(), 1 minutes);
        assertEq(bundler.lastCallMade(), 0);
        assertEq(address(bundler.coinOracle()), address(coinOracle));
        assertEq(address(bundler.ethOracle()), address(ethOracle));
        assertEq(bundler.collateralA(), bytes32("ETH-A"));
        assertEq(bundler.collateralB(), bytes32("ETH-B"));
        assertEq(bundler.collateralC(), bytes32("ETH-C"));
        assertEq(bundler.acceptedDeviation(), 50);
    }

    function testConstructorNullTreasury() external {
        vm.expectRevert("invalid-treasury");
        bundler = new BasefeeOSMDeviationCallBundler(
            address(0),
            address(osm),
            address(oracleRelayer),
            [bytes32("ETH-A"), "ETH-B", "ETH-C"],
            1 ether,
            1 minutes,
            address(coinOracle),
            address(ethOracle), 
            50 // 5%
        );
    }

    function testConstructorNullOSM() external {
        vm.expectRevert("invalid-osm");
        bundler = new BasefeeOSMDeviationCallBundler(
            address(treasury),
            address(0),
            address(oracleRelayer),
            [bytes32("ETH-A"), "ETH-B", "ETH-C"],
            1 ether,
            1 minutes,
            address(coinOracle),
            address(ethOracle), 
            50 // 5%
        );
    }

    function testConstructorNullOracleRelayer() external {
        vm.expectRevert("invalid-oracle-relayer");
        bundler = new BasefeeOSMDeviationCallBundler(
            address(treasury),
            address(osm),
            address(0),
            [bytes32("ETH-A"), "ETH-B", "ETH-C"],
            1 ether,
            1 minutes,
            address(coinOracle),
            address(ethOracle), 
            50 // 5%
        );
    }

    function testConstructorNullReward() external {
        vm.expectRevert("invalid-reward");
        bundler = new BasefeeOSMDeviationCallBundler(
            address(treasury),
            address(osm),
            address(oracleRelayer),
            [bytes32("ETH-A"), "ETH-B", "ETH-C"],
            0,
            1 minutes,
            address(coinOracle),
            address(ethOracle), 
            50 // 5%
        );
    }

    function testConstructorNullCoinOracle() external {
        vm.expectRevert("invalid-coin-oracle");
        bundler = new BasefeeOSMDeviationCallBundler(
            address(treasury),
            address(osm),
            address(oracleRelayer),
            [bytes32("ETH-A"), "ETH-B", "ETH-C"],
            1 ether,
            1 minutes,
            address(0),
            address(ethOracle), 
            50 // 5%
        );
    }

    function testConstructorNullEthOracle() external {
        vm.expectRevert("invalid-eth-oracle");
        bundler = new BasefeeOSMDeviationCallBundler(
            address(treasury),
            address(osm),
            address(oracleRelayer),
            [bytes32("ETH-A"), "ETH-B", "ETH-C"],
            1 ether,
            1 minutes,
            address(coinOracle),
            address(0),
            50 // 5%
        );
    }

    function testConstructorInvalidDeviation() external {
        vm.expectRevert("invalid-deviation");
        bundler = new BasefeeOSMDeviationCallBundler(
            address(treasury),
            address(osm),
            address(oracleRelayer),
            [bytes32("ETH-A"), "ETH-B", "ETH-C"],
            1 ether,
            1 minutes,
            address(coinOracle),
            address(ethOracle),
            1000
        );
    }    

    function testModifyParameters() external {
        bundler.modifyParameters("fixedReward", 2 ether);
        assertEq(bundler.fixedReward(), 2 ether);

        bundler.modifyParameters("callDelay", 2 weeks);
        assertEq(bundler.callDelay(), 2 weeks);

        vm.expectRevert("invalid-param");
        bundler.modifyParameters("inv", 2 weeks);

        bundler.modifyParameters("coinOracle", address(1));
        assertEq(address(bundler.coinOracle()), address(1));

        bundler.modifyParameters("ethOracle", address(2));
        assertEq(address(bundler.ethOracle()), address(2));

        vm.expectRevert("invalid-param");
        bundler.modifyParameters("inv", address(666));

        vm.expectRevert("invalid-data");
        bundler.modifyParameters("ethOracle", address(0));

        vm.expectRevert("invalid-data");
        bundler.modifyParameters("coinOracle", address(0));

        bundler.modifyParameters("acceptedDeviation", 500); // 50%
        assertEq(bundler.acceptedDeviation(), 500);

        vm.expectRevert("invalid-deviation");
        bundler.modifyParameters("acceptedDeviation", 1000);
    }

    function testIncentivizedCall() external {
        vm.prank(address(0x0ddaf));
        address(bundler).call(""); // anything goes on the data field as long as the sigs do not match any of the contract's functions

        assertEq(osm.read(), 1700 ether);
        assertEq(osm.next(), 2000 ether);
        assertEq(oracleRelayer.calls(), 3);

        assertEq(coin.balanceOf(address(0x0ddaf)), 1197000000000000000 + 1 ether); // incentives paid
        assertEq(bundler.lastCallMade(), block.timestamp);
    }

    function testIncentivizedCallTooSoon() external {
        vm.prank(address(0x0ddaf));
        address(bundler).call(""); // anything goes on the data field as long as the sigs do not match any of the contract's functions

        assertEq(osm.read(), 1700 ether);
        assertEq(osm.next(), 2000 ether);
        assertEq(oracleRelayer.calls(), 3);

        assertEq(coin.balanceOf(address(0x0ddaf)), 1197000000000000000 + 1 ether); // incentives paid
        assertEq(bundler.lastCallMade(), block.timestamp);

        vm.warp(block.timestamp + 1);
        address(bundler).call("");

        assertEq(osm.read(), 2000 ether);
        assertEq(osm.next(), 2000 ether);
        assertEq(oracleRelayer.calls(), 6);
        assertEq(coin.balanceOf(address(0x0ddaf)), 1197000000000000000 + 1 ether); // incentives not paid (too soon)
        assertEq(bundler.lastCallMade(), block.timestamp);
    }

function testIncentivizedCallDeviation() external {
        ethOracle.setPrice(1700 ether);
        vm.prank(address(0x0ddaf));

        // deviation only between current and next prices in osm (mkt price is 1500)
        address(bundler).call(""); // anything goes on the data field as long as the sigs do not match any of the contract's functions

        assertEq(osm.read(), 1700 ether);
        assertEq(osm.next(), 1700 ether);
        assertEq(oracleRelayer.calls(), 3);

        assertEq(coin.balanceOf(address(0x0ddaf)), 1893350000000000000); // incentives paid
        assertEq(bundler.lastCallMade(), block.timestamp);

        // no deviation (all prices the same, should revert)
        vm.warp(block.timestamp + 1 minutes);
        vm.expectRevert("not-enough-deviation");
        address(bundler).call("");

        // deviation only between current osm price and market price
        ethOracle.setPrice(1700 ether + (1700 ether * 5 / 100));

        vm.warp(block.timestamp + 1 minutes);
        vm.expectRevert("not-enough-deviation");
        vm.prank(address(0x0ddaf));
        (bool success, ) =  address(bundler).call("");
        assertFalse(success);

        assertEq(osm.read(), 1700 ether);
        assertEq(osm.next(), 1700 ether + (1700 ether * 5 / 100));
        assertEq(oracleRelayer.calls(), 6);
        assertEq(coin.balanceOf(address(0x0ddaf)), 3104372700000000000); // incentives paid
        assertEq(bundler.lastCallMade(), block.timestamp);
    }

    function testIncentivizedCallTargetsReverts() external {
        osm.setRevert(true);

        vm.expectRevert("forced revert");
        vm.prank(address(0x0ddaf));
        address(bundler).call("");
        assertEq(coin.balanceOf(address(0x0ddaf)), 0); // incentives not paid

        osm.setRevert(false);
        oracleRelayer.setRevert(true);
        vm.expectRevert("forced revert");
        vm.prank(address(0x0ddaf));
        address(bundler).call("");
        assertEq(coin.balanceOf(address(0x0ddaf)), 0); // incentives not paid
    }

    function testIncentivizedCallNoAllowance() external {
        treasury.setTotalAllowance(address(bundler), 0);

        vm.prank(address(0x0ddaf));
        address(bundler).call("");

        assertEq(osm.read(), 1700 ether);
        assertEq(osm.next(), 2000 ether);
        assertEq(oracleRelayer.calls(), 3);

        assertEq(coin.balanceOf(address(0x0ddaf)), 0);
        assertEq(bundler.lastCallMade(), block.timestamp);
    }

    function testIncentivizedCallTreasuryReverts() external {
        MockRevertableTreasury revertTreasury = new MockRevertableTreasury();

        bundler = new BasefeeOSMDeviationCallBundler(
            address(revertTreasury),
            address(osm),
            address(oracleRelayer),
            [bytes32("ETH-A"), "ETH-B", "ETH-C"],
            1 ether,
            1 minutes,
            address(coinOracle),
            address(ethOracle), 
            50 // 5%
        );

        vm.prank(address(0x0ddaf));
        address(bundler).call("0x0ddaf");

        assertEq(osm.read(), 1700 ether);
        assertEq(osm.next(), 2000 ether);
        assertEq(oracleRelayer.calls(), 3);

        assertEq(coin.balanceOf(address(0x0ddaf)), 0);
        assertEq(bundler.lastCallMade(), block.timestamp);
    }
}

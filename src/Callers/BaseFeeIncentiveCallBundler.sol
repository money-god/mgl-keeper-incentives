pragma solidity 0.8.19;

import "../Incentives/BaseFeeIncentive.sol";

// @notice: Unobtrusive incentives for any call on a TAI like system.
// @dev: Assumes an allowance from the stability fee treasury, all oracles return quotes with 18 decimal places.
contract BasefeeIncentiveCallBundler is BaseFeeIncentive {
    // wen immutable arrays? (https://github.com/ethereum/solidity/issues/12587) ==> if you're reading this please go there and support.
    address public immutable target0; // target of first call
    address public immutable target1; // target of second call
    bytes32 public immutable callData0; // calldata of the first incentivized call
    bytes32 public immutable callData1; // calldata of the second incentivized call

    // --- Constructor ---
    constructor(
        address treasury_,
        address[2] memory targets_,
        bytes32[2] memory callDatas_,
        uint256 reward_,
        uint256 delay_,
        address coinOracle_,
        address ethOracle_
    ) BaseFeeIncentive(treasury_, reward_, delay_, coinOracle_, ethOracle_) {
        require(targets_[0] != address(0), "invalid-target");
        require(targets_[1] != address(0), "invalid-target");
        require(callDatas_[0] != bytes32(0), "invalid-call-data");
        require(callDatas_[1] != bytes32(0), "invalid-call-data");

        target0 = targets_[0];
        target1 = targets_[1];
        callData0 = callDatas_[0];
        callData1 = callDatas_[1];
    }

    // @dev Calls are made through the fallback function, meaning any call to this contract will do
    fallback() external payRewards {
        (bool success, ) = target0.call(abi.encode(callData0));
        require(success, "call-failed");
        (success, ) = target1.call(abi.encode(callData1));
        require(success, "call-failed");
    }
}

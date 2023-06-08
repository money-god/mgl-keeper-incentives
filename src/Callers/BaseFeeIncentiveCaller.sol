pragma solidity 0.8.19;

import "../Incentives/BaseFeeIncentive.sol";

// @notice: Unobtrusive incentives for any call on a TAI like system.
// @dev: Assumes an allowance from the stability fee treasury, all oracles return quotes with 18 decimal places.
contract BasefeeIncentiveCaller is BaseFeeIncentive {
    address public immutable target; // target of calls
    bytes32 public immutable callData; // calldata of the incentivized call

    // --- Constructor ---
    constructor(
        address treasury_,
        address target_,
        bytes32 callData_,
        uint256 reward_,
        uint256 delay_,
        address coinOracle_,
        address ethOracle_
    ) BaseFeeIncentive(treasury_, reward_, delay_, coinOracle_, ethOracle_) {
        require(target_ != address(0), "invalid-target");
        require(callData_ != bytes32(0), "invalid-call-data");

        target = target_;
        callData = callData_;
    }    


    // @dev Calls are made through the fallback function
    fallback() external payRewards() {
        (bool success, ) = target.call(abi.encode(callData));
        require(success, "call-failed");
    }
}

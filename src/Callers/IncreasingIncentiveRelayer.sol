// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "../Incentives/IncreasingIncentive.sol";

// @notice: Unobtrusive incentives for any call on a TAI like system.
// @dev: Assumes an allowance from the stability fee treasury.
contract IncreasingIncentiveRelayer is IncreasingIncentive {
    address public immutable target; // target of calls
    bytes4 public immutable callSig; // signature of the incentivized call

    // --- Constructor ---
    constructor(
        address treasury_,
        address target_,
        bytes4 callSig_,
        uint256 baseUpdateCallerReward_,
        uint256 maxUpdateCallerReward_,
        uint256 maxRewardIncreaseDelay_,
        uint256 perSecondCallerRewardIncrease_,
        uint256 delay_
    ) IncreasingIncentive(treasury_, baseUpdateCallerReward_, maxUpdateCallerReward_, maxRewardIncreaseDelay_, perSecondCallerRewardIncrease_, delay_) {
        require(target_ != address(0), "invalid-target");
        require(callSig_ != bytes4(0), "invalid-call-signature");

        target = target_;
        callSig = callSig_;
    }    

    // @dev Calls are made through the fallback function, the call calldata should be exactly the same as the call being made to the target contract
    fallback() external payRewards() {
        require(msg.sig == callSig, "invalid-call");

        (bool success, ) = target.call(msg.data);
        require(success, "call-failed");
    }
}

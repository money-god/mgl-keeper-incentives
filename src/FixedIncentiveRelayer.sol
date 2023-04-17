// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

abstract contract StabilityFeeTreasuryLike {
    function systemCoin() external view virtual returns (address);

    function pullFunds(address, address, uint) external virtual;
}

// @notice: Unobtrusive incentives for any call on a TAI like system.
// @dev: Assumes an allowance from the stability fee treasury.
contract FixedIncentiveRelayer {
    StabilityFeeTreasuryLike public immutable treasury; // The stability fee treasury
    address public immutable coin; // The system coin
    address public immutable target; // target of calls
    bytes4 public immutable callSig; // signature of the incentivized call
    uint256 public fixedReward; // The fixed reward sent by the treasury to a fee receiver (wad)
    uint256 public callDelay; // delay between incentivized calls (seconds)
    uint256 public lastCallMade; // last time a call to target was made (UNIX timestamp)

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event ModifyParameters(bytes32 parameter, uint256 val);
    event RewardCaller(address indexed finalFeeReceiver, uint256 fixedReward);
    event FailRewardCaller(
        bytes revertReason,
        address feeReceiver,
        uint256 amount
    );

    // --- Auth ---
    mapping(address => uint256) public authorizedAccounts;

    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }

    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }

    /**
     * @notice Checks whether msg.sender can call an authed function
     **/
    modifier isAuthorized() {
        require(
            authorizedAccounts[msg.sender] == 1,
            "StabilityFeeTreasury/account-not-authorized"
        );
        _;
    }

    // --- Constructor ---
    constructor(
        address treasury_,
        address target_,
        bytes4 callSig_,
        uint256 reward_,
        uint256 delay_
    ) {
        require(treasury_ != address(0), "invalid-treasury");
        require(target_ != address(0), "invalid-target");
        require(callSig_ != bytes4(0), "invalid-call-signature");
        require(reward_ != 0, "invalid-reward");

        authorizedAccounts[msg.sender] = 1;

        treasury = StabilityFeeTreasuryLike(treasury_);
        target = target_;
        callSig = callSig_;
        fixedReward = reward_;
        callDelay = delay_;
        coin = StabilityFeeTreasuryLike(treasury_).systemCoin();

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("fixedReward", reward_);
        emit ModifyParameters("callDelay", delay_);
    }

    // -- Admin --
    function modifyParameters(
        bytes32 parameter,
        uint256 val
    ) external isAuthorized {
        if (parameter == "fixedReward") fixedReward = val;
        else if (parameter == "callDelay") callDelay = val;
        else revert("invalid-param");
    }

    // @dev Calls are made through the fallback function, the call calldata should be exactly the same as the call being made to the target contract
    fallback() external {
        require(msg.sig == callSig, "invalid-call");

        (bool success, ) = target.call(msg.data);
        require(success, "call-failed");

        if (block.timestamp >= lastCallMade + callDelay) {
            try treasury.pullFunds(msg.sender, coin, fixedReward) {
                emit RewardCaller(msg.sender, fixedReward);
            } catch (bytes memory revertReason) {
                emit FailRewardCaller(revertReason, msg.sender, fixedReward);
            }
        }

        lastCallMade = block.timestamp;
    }
}

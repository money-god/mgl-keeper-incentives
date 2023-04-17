// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

abstract contract StabilityFeeTreasuryLike {
    function getAllowance(address) external view virtual returns (uint, uint);

    function systemCoin() external view virtual returns (address);

    function pullFunds(address, address, uint) external virtual;
}

// @notice: Unobtrusive incentives for any call on a TAI like system.
// @dev: Assumes an allowance from the stability fee treasury.
contract IncreasingIncentiveRelayer {
    StabilityFeeTreasuryLike public immutable treasury; // The stability fee treasury
    address public immutable coin; // The system coin
    address public immutable target; // target of calls
    bytes4 public immutable callSig; // signature of the incentivized call
    uint256 public baseUpdateCallerReward; // Starting reward for the fee receiver/keeper
    uint256 public maxUpdateCallerReward; // Max possible reward for the fee receiver/keeper
    uint256 public maxRewardIncreaseDelay; // Max delay taken into consideration when calculating the adjusted reward
    uint256 public perSecondCallerRewardIncrease; // Rate applied to baseUpdateCallerReward every extra second passed beyond a certain point (e.g next time when a specific function needs to be called)
    uint256 public callDelay; // delay between incentivized calls (seconds)
    uint256 public lastCallMade; // last time a call to target was made (UNIX timestamp)

    uint256 public constant RAY = 10 ** 27;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event ModifyParameters(bytes32 parameter, address addr);
    event ModifyParameters(bytes32 parameter, uint256 val);
    event RewardCaller(address indexed finalFeeReceiver, uint256 reward);
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

    // --- Math ---
    function rpower(uint x, uint n, uint base) public pure returns (uint z) {
        assembly {
            switch x
            case 0 {
                switch n
                case 0 {
                    z := base
                }
                default {
                    z := 0
                }
            }
            default {
                switch mod(n, 2)
                case 0 {
                    z := base
                }
                default {
                    z := x
                }
                let half := div(base, 2) // for rounding.
                for {
                    n := div(n, 2)
                } n {
                    n := div(n, 2)
                } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) {
                        revert(0, 0)
                    }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) {
                        revert(0, 0)
                    }
                    x := div(xxRound, base)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) {
                            revert(0, 0)
                        }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) {
                            revert(0, 0)
                        }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }

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
    ) {
        require(treasury_ != address(0), "invalid-treasury");
        require(target_ != address(0), "invalid-target");
        require(callSig_ != bytes4(0), "invalid-call-signature");
        require(baseUpdateCallerReward_ != 0, "invalid-base-reward");
        require(maxUpdateCallerReward_ != 0, "invalid-max-reward");
        require(maxRewardIncreaseDelay_ != 0, "invalid-reward-increase-delay");
        require(perSecondCallerRewardIncrease_ != 0, "invalid-reward-rate");
        require(delay_ != 0, "invalid-delay");
        require(
            maxUpdateCallerReward_ >= baseUpdateCallerReward_,
            "invalid-max-caller-reward"
        );
        require(
            perSecondCallerRewardIncrease_ >= RAY,
            "invalid-per-second-reward-increase"
        );

        authorizedAccounts[msg.sender] = 1;

        treasury = StabilityFeeTreasuryLike(treasury_);
        target = target_;
        callSig = callSig_;
        baseUpdateCallerReward = baseUpdateCallerReward_;
        maxUpdateCallerReward = maxUpdateCallerReward_;
        maxRewardIncreaseDelay = maxRewardIncreaseDelay_;
        perSecondCallerRewardIncrease = perSecondCallerRewardIncrease_;
        callDelay = delay_;
        coin = StabilityFeeTreasuryLike(treasury_).systemCoin();

        getCallerReward(maxRewardIncreaseDelay_); // check if current params overflow

        emit AddAuthorization(msg.sender);
        emit ModifyParameters(
            "baseUpdateCallerReward",
            baseUpdateCallerReward_
        );
        emit ModifyParameters("maxUpdateCallerReward", maxUpdateCallerReward_);
        emit ModifyParameters(
            "maxRewardIncreaseDelay",
            maxRewardIncreaseDelay_
        );
        emit ModifyParameters(
            "perSecondCallerRewardIncrease",
            perSecondCallerRewardIncrease_
        );
        emit ModifyParameters("callDelay", delay_);
    }

    // -- Admin --
    function modifyParameters(
        bytes32 parameter,
        uint256 val
    ) external isAuthorized {
        if (parameter == "baseUpdateCallerReward") {
            require(
                maxUpdateCallerReward >= val && val > 0,
                "invalid-base-caller-reward"
            );
            baseUpdateCallerReward = val;
            getCallerReward(maxRewardIncreaseDelay); // check if current params overflow
        } else if (parameter == "maxUpdateCallerReward") {
            require(val >= baseUpdateCallerReward, "invalid-max-caller-reward");
            maxUpdateCallerReward = val;
            getCallerReward(maxRewardIncreaseDelay); // check if current params overflow
        } else if (parameter == "maxRewardIncreaseDelay") {
            require(val > 0, "invalid-max-reward-increase-delay");
            maxRewardIncreaseDelay = val;
            getCallerReward(maxRewardIncreaseDelay); // check if current params overflow
        } else if (parameter == "perSecondCallerRewardIncrease") {
            require(val >= RAY, "invalid-per-second-reward-increase");
            perSecondCallerRewardIncrease = val;
            getCallerReward(maxRewardIncreaseDelay); // check if current params overflow
        } else if (parameter == "callDelay") {
            require(val > 0, "invalid-call-delay");
            callDelay = val;
        } else revert("invalid-param");
    }

    function getCallerReward(
        uint256 timeElapsed
    ) public view returns (uint256) {
        if (timeElapsed == 0) return baseUpdateCallerReward;
        if (timeElapsed > maxRewardIncreaseDelay) return maxUpdateCallerReward;

        uint reward = (rpower(perSecondCallerRewardIncrease, timeElapsed, RAY) *
            baseUpdateCallerReward) / RAY;

        if (reward > maxUpdateCallerReward) return maxUpdateCallerReward;

        return reward;
    }

    // @dev Calls are made through the fallback function, the call calldata should be exactly the same as the call being made to the target contract
    fallback() external {
        require(msg.sig == callSig, "invalid-call");

        (bool success, ) = target.call(msg.data);
        require(success, "call-failed");

        if (block.timestamp >= lastCallMade + callDelay) {
            uint256 reward = getCallerReward(
                block.timestamp - lastCallMade - callDelay
            );
            try treasury.pullFunds(msg.sender, coin, reward) {
                emit RewardCaller(msg.sender, reward);
            } catch (bytes memory revertReason) {
                emit FailRewardCaller(revertReason, msg.sender, reward);
            }
        }

        lastCallMade = block.timestamp;
    }
}

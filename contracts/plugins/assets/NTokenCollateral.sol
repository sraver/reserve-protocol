// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "contracts/plugins/assets/AbstractCollateral.sol";
import "contracts/plugins/assets/INotionalProxy.sol";
import "contracts/plugins/assets/INTokenERC20Proxy.sol";
import "contracts/libraries/Fixed.sol";

/**
 * @title NTokenCollateral
 * @notice Collateral plugin for a NToken of fiat collateral
 * Expected: {tok} != {ref}, {ref} is pegged to {target} unless defaulting, {target} == {UoA}
 */
contract NTokenCollateral is Collateral {
    using OracleLib for AggregatorV3Interface;
    using FixLib for uint192;

    INTokenERC20Proxy public immutable nToken;
    INotionalProxy public immutable notionalProxy;
    uint192 public immutable defaultThreshold; // {%} percentage allowed of de-peg // D18
    uint192 private immutable marginRatio; // max drop allowed // D0
    uint192 private maxRefPerTok; // max rate previously seen {ref/tok} // D18

    constructor(
        uint192 _fallbackPrice,
        AggregatorV3Interface _chainlinkFeed,
        IERC20Metadata _erc20Collateral,
        uint192 _maxTradeVolume,
        uint48 _oracleTimeout,
        bytes32 _targetName,
        uint256 _delayUntilDefault,
        address _notionalProxy,
        uint192 _defaultThreshold,
        uint192 _allowedDrop
    )
    Collateral(
        _fallbackPrice,
        _chainlinkFeed,
        _erc20Collateral,
        _maxTradeVolume,
        _oracleTimeout,
        _targetName,
        _delayUntilDefault
    )
    {
        require(_notionalProxy != address(0), "Notional proxy address missing");
        require(_allowedDrop < FIX_ONE, "Allowed refPerTok drop out of range");

        nToken = INTokenERC20Proxy(address(_erc20Collateral));
        notionalProxy = INotionalProxy(_notionalProxy);
        defaultThreshold = _defaultThreshold;
        marginRatio = FIX_ONE - _allowedDrop;
    }

    /// Can return 0, can revert
    /// Shortcut for price(false)
    /// @return {UoA/tok} The current price(), without considering fallback prices
    function strictPrice() external view returns (uint192) {
        return chainlinkFeed.price(oracleTimeout).mul(actualRefPerTok());
    }

    /// Refresh exchange rates and update default status.
    /// The Reserve protocol calls this at least once per transaction, before relying on
    /// this collateral's prices or default status.
    function refresh() external override {
        if (alreadyDefaulted()) return;

        CollateralStatus oldStatus = status();

        uint192 _actualRefPerTok = actualRefPerTok();

        // check if refPerTok rate has decreased below accepted threshold
        if (_actualRefPerTok < refPerTok()) {
            markStatus(CollateralStatus.DISABLED);
        } else {
            // if it didn't, check the peg of the reference
            try chainlinkFeed.price_(oracleTimeout) returns (uint192 currentPrice) {
                // the peg of our reference is always ONE target
                uint192 peg = FIX_ONE;

                // since peg is ONE we dont need to operate the threshold to get the delta
                uint192 delta = defaultThreshold;

                // If the price is below the default-threshold price, default eventually
                // uint192(+/-) is the same as Fix.plus/minus
                if (
                    currentPrice < peg - delta ||
                    currentPrice > peg + delta
                ) {
                    markStatus(CollateralStatus.IFFY);
                }
                else {
                    markStatus(CollateralStatus.SOUND);
                }
            } catch (bytes memory errData) {
                // see: docs/solidity-style.md#Catching-Empty-Data
                if (errData.length == 0) revert();
                // solhint-disable-line reason-string
                markStatus(CollateralStatus.IFFY);
            }
        }

        // store refRate for the next iteration
        if (_actualRefPerTok > maxRefPerTok) {
            maxRefPerTok = _actualRefPerTok;
        }

        // check if updated status
        CollateralStatus newStatus = status();
        if (oldStatus != newStatus) {
            emit DefaultStatusChanged(oldStatus, newStatus);
        }
    }

    /// @return {ref/tok} Actual quantity of whole reference units per whole collateral tokens
    function actualRefPerTok() public view returns (uint192) {
        // fetch value of all current liquidity
        uint192 valueOfAll = _safeWrap(uint256(nToken.getPresentValueUnderlyingDenominated()));
        // fetch total supply of tokens
        uint192 totalSupply = _safeWrap(nToken.totalSupply());
        // divide to get the value of one token
        return valueOfAll.div(totalSupply);
    }

    /// @return {ref/tok} Quantity of whole reference units per whole collateral tokens
    /// @notice This amount has a {margin} space discounted to allow a certain drop on value
    function refPerTok() public view override returns (uint192) {
        // We can do this because we know {margin_ratio} is a
        // small controlled number so it won't overflow
        return maxRefPerTok.div(FIX_ONE).mul(marginRatio);
    }

    /// Claim rewards earned by holding a balance of the ERC20 token
    /// Must emit `RewardsClaimed` for each token rewards are claimed for
    /// @dev delegatecall: let there be dragons!
    /// @custom:interaction
    function claimRewards() external override {
        // claim rewards and returns the number of claimed tokens
        uint256 claimedNote = notionalProxy.nTokenClaimIncentives();
        // Address of NOTE token is the same across all possible liquidity collateral
        IERC20 note = IERC20(0xCFEAead4947f0705A14ec42aC3D44129E1Ef3eD5);
        // Emit event
        emit RewardsClaimed(note, claimedNote);
    }
}

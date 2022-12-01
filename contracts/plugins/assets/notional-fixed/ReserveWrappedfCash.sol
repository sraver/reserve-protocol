// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./IWrappedfCash.sol";
import "./IWrappedfCashFactory.sol";
import "./INotionalProxy.sol";
import "contracts/libraries/Fixed.sol";
import "hardhat/console.sol";


contract ReserveWrappedFCash is ERC20 {
    using SafeERC20 for IERC20Metadata;

    INotionalProxy private immutable notionalProxy;
    IWrappedfCashFactory private immutable wfCashFactory;
    IERC20Metadata private immutable underlyingAsset;
    uint16 private immutable currencyId;

    struct Market {
        uint256 maturity;
        uint8 monthsTenor;
    }

    struct Position {
        uint256 fCash;
        uint256 deposited;
        uint256 maturity;
        uint8 monthsTenor;
    }

    mapping(address => mapping(uint256 => Position)) private accounts;
    mapping(address => mapping(uint256 => bool)) private activeMarket;
    mapping(address => uint256[]) private markets;

    constructor(
        address _notionalProxy,
        address _wfCashFactory,
        IERC20Metadata _underlyingAsset,
        uint16 _currencyId
    ) ERC20("Reserve Wrapped fCash", "rwfCash") {
        notionalProxy = INotionalProxy(_notionalProxy);
        wfCashFactory = IWrappedfCashFactory(_wfCashFactory);
        underlyingAsset = _underlyingAsset;
        currencyId = _currencyId;
    }

    /// @notice Returns the ratio of appreciation of the deposited assets of the calling account.
    /// @return rate The ratio of value of a deposited token to what it's currently worth
    /// @dev This rate might decrease when re-investing because of the fee to enter a market
    function refPerTok(address account) public view returns (uint256 rate) {
        uint256 depositedAmount = depositedBy(account);

        if (depositedAmount == 0) {
            rate = 0;
        }
        else {
            uint256 length = markets[account].length;
            uint256 coefficient = 10 ** underlyingAsset.decimals();
            uint256 maturity;
            uint256 underlyingValue;
            Position storage position;
            IWrappedfCash wfCash;

            // iterate all positions to get the rate
            for (uint i; i < length;) {
                maturity = markets[account][i];
                wfCash = _getWfCash(maturity);
                position = accounts[account][maturity];

                if (wfCash.hasMatured()) {
                    underlyingValue = position.fCash;
                }
                else {
                    underlyingValue = uint256(
                        notionalProxy.getPresentfCashValue(
                            currencyId,
                            maturity,
                            int88(int256(position.fCash)),
                            block.timestamp,
                            false
                        )
                    );
                }

                // accumulate all position's rates
                rate = rate + (underlyingValue * coefficient / position.deposited);

            unchecked {
                i = i + 1;
            }
            }

            // average
            rate = rate / length;
        }
    }

    /// @notice Checks every position the account is in, and if any of the markets
    ///   has matured, redeems the underlying assets and re-lends everything again
    function reinvest() external {
        uint256[] memory currentMarkets = markets[_msgSender()];
        if (currentMarkets.length == 0) return;

        IWrappedfCash wfCash;
        uint256 length = currentMarkets.length;

        for (uint i; i < length; i++) {
            wfCash = _getWfCash(currentMarkets[i]);
            if (wfCash.hasMatured()) {
                notionalProxy.initializeMarkets(currencyId, false);
                _reinvest(wfCash);
            }
        }
    }

    /// @notice Deposits `amount` into the most profitable market at this time
    ///   or the market where the account is already invested
    /// @dev This function may add market positions to an account
    function deposit(uint256 amount) external {
        require(amount > 0, "empty deposit amount");

        Market memory market = _getMostProfitableMarket();

        if (!activeMarket[_msgSender()][market.maturity]) {
            // if account is not in this market, init
            _addMarketPosition(_msgSender(), Position(
                    0,
                    0,
                    market.maturity,
                    market.monthsTenor
                )
            );
        }

        _depositByUser(amount, market.maturity);
    }

    /// @notice Deposits `amount` into the given `marketIndex`
    /// @dev to use this method the account needs to not have any prior position
    /// @dev This function may add market positions to an account
    function depositTo(uint256 amount, uint256 maturity) external {
        require(amount > 0, "empty deposit amount");
        require(maturity > 0, "unspecified maturity");

        Market memory market = _getMarket(maturity);
        require(market.maturity > 0, "market not found");

        if (!activeMarket[_msgSender()][maturity]) {
            // if account is not in this market, init
            _addMarketPosition(_msgSender(), Position(
                    0,
                    0,
                    market.maturity,
                    market.monthsTenor
                )
            );
        }

        _depositByUser(amount, maturity);
    }

    /// @notice Withdraws `amount` of balance from the account
    /// @dev This function may remove market positions from an account
    function withdraw(uint256 amount) external {
        require(amount > 0, "empty withdraw amount");
        uint256 balance = balanceOf(_msgSender());
        require(balance >= amount, "not enough balance");
        uint256 marketsLength = markets[_msgSender()].length;

        // compute the percentage of coins that have to be withdrawn
        uint256 percentageToWithdraw = amount * 1e18 / balance;

        // iterate over all the existing markets
        for (uint i; i < marketsLength; i++) {
            // get maturity of current market
            uint256 maturity = markets[_msgSender()][i];
            // withdraw percentage from this market
            _withdraw(percentageToWithdraw, maturity);
            // check if account data has to be deleted
            if (percentageToWithdraw == 1e18) {
                delete accounts[_msgSender()][maturity];
                delete activeMarket[_msgSender()][maturity];
            }
        }

        // burn the local tokens being withdrawn
        _burn(_msgSender(), amount);

        // clean account data if full gone
        if (percentageToWithdraw == 1e18) {
            delete markets[_msgSender()];
        }
    }

    /** Getters **/

    /// @notice Returns the current active markets on Notional for this currency
    function activeMarkets() external view returns (Market[] memory _activeMarkets) {
        INotionalProxy.MarketParameters[] memory _markets = notionalProxy.getActiveMarkets(currencyId);
        uint256 length = _markets.length;
        require(length > 0, 'no available markets');

        _activeMarkets = new Market[](length);

        for (uint i = 0; i < length; i++) {
            _activeMarkets[i] = Market(_markets[i].maturity, _getMonthsTenor(i));
        }
    }

    /// @notice Returns the amount of tokens deposited by `account`
    function depositedBy(address account) public view returns (uint256 amount) {
        uint256 length = markets[account].length;
        for (uint i; i < length; i++) {
            // get maturity of current market
            uint256 maturity = markets[account][i];
            // sum the deposited amount on this market
            amount = amount + accounts[account][maturity].deposited;
        }
    }

    /// @notice Returns the markets where an `account` has open positions
    function activeMarketsOf(address account) external view returns (uint256[] memory) {
        return markets[account];
    }

    /// @notice Checks if any position in the market is already mature
    function hasMatured() external view returns (bool) {
        uint256 length = markets[_msgSender()].length;
        for (uint i; i < length; i++) {
            // get maturity of current market
            uint256 maturity = markets[_msgSender()][i];
            // sum the deposited amount on this market
            if (maturity <= block.timestamp) {
                return true;
            }
        }
        return false;
    }

    /// @notice Using 8 decimals as the rest of Notional tokens
    function decimals() public pure override returns (uint8) {
        return 8;
    }

    /** Private helpers **/

    /// Creates a new market position on an account
    /// @param account The account to add the position to
    /// @param position The position with the details
    function _addMarketPosition(address account, Position memory position) private {
        activeMarket[account][position.maturity] = true;
        markets[account].push(position.maturity);
        accounts[account][position.maturity] = position;
    }

    /// Deposits `amount` into a specific market maturity`
    /// @param amount The amount to deposit
    /// @param maturity The maturity of the market to enter
    function _depositByUser(uint256 amount, uint256 maturity) private {
        // transfer assets from user
        underlyingAsset.safeTransferFrom(_msgSender(), address(this), amount);

        // get/deploy Notional wrapped contract
        IWrappedfCash wfCash = IWrappedfCash(
            wfCashFactory.deployWrapper(currencyId, uint40(maturity))
        );

        // ask Notional how much fCash we should receive for our assets
        (uint88 fCashAmount,,) = notionalProxy.getfCashLendFromDeposit(
            currencyId, amount, maturity, 0, block.timestamp, true
        );

        // update position
        accounts[_msgSender()][maturity].deposited = accounts[_msgSender()][maturity].deposited +
        amount - _costOfEnteringMarket(amount, maturity);
        accounts[_msgSender()][maturity].fCash = accounts[_msgSender()][maturity].fCash + fCashAmount;

        // mint wfCash
        underlyingAsset.safeApprove(address(wfCash), amount);
        wfCash.mintViaUnderlying(amount, fCashAmount, address(this), 0);

        // mint local wrapped tokens
        _mint(_msgSender(), fCashAmount);
    }

    /// Withdraws `percentage` of underlying on a given `maturity` to the user
    /// @param percentage Portion of the fCash to redeem
    /// @param maturity Maturity of the market we want to redeem from
    function _withdraw(uint256 percentage, uint256 maturity) private {
        // fetch current balances
        uint256 currentfCash = accounts[_msgSender()][maturity].fCash;
        uint256 currentDeposited = accounts[_msgSender()][maturity].deposited;
        // compute amount to redeem
        uint256 fCashToRedeem = currentfCash * percentage / 1e18;
        uint256 depositedToDiscount = currentDeposited * percentage / 1e18;

        // update storage
        accounts[_msgSender()][maturity].fCash = currentfCash - fCashToRedeem;
        accounts[_msgSender()][maturity].deposited = currentDeposited - depositedToDiscount;

        // redeem to the user
        IWrappedfCash wfCash = _getWfCash(maturity);
        wfCash.redeemToUnderlying(fCashToRedeem, _msgSender(), 0);
    }

    /// Process the reinvestment of a certain market position
    /// @param wfCash Market where the account has the position
    /// @dev This function removes markets from accounts, and may add too
    function _reinvest(IWrappedfCash wfCash) private {
        uint256 maturity = wfCash.getMaturity();
        Position storage existingPosition = accounts[_msgSender()][maturity];
        uint256 currentfCashAmount = existingPosition.fCash;
        uint256 underlyingAmount = _convertToAssetDecimals(currentfCashAmount);

        // take everything out
        _burn(_msgSender(), currentfCashAmount);
        wfCash.redeemToUnderlying(currentfCashAmount, address(this), 0);

        // get new market
        Market memory bestMarket = _getMostProfitableMarket();

        // ask Notional how much fCash we should receive for our assets
        (uint88 newfCashAmount,,) = notionalProxy.getfCashLendFromDeposit(
            currencyId, underlyingAmount, bestMarket.maturity, 0, block.timestamp, true
        );

        if (activeMarket[_msgSender()][bestMarket.maturity]) {
            // if account already has a position on this market..
            // get updated wfCash
            wfCash = _getWfCash(bestMarket.maturity);
            // include assets in existing position
            accounts[_msgSender()][bestMarket.maturity].deposited =
            accounts[_msgSender()][bestMarket.maturity].deposited +
            existingPosition.deposited - _costOfEnteringMarket(existingPosition.deposited, bestMarket.maturity);

            accounts[_msgSender()][bestMarket.maturity].fCash =
            accounts[_msgSender()][bestMarket.maturity].fCash + newfCashAmount;
        }
        else {
            // if account has not position in this market..
            // get updated wfCash
            wfCash = IWrappedfCash(
                wfCashFactory.deployWrapper(currencyId, uint40(bestMarket.maturity))
            );
            // create new market position
            _addMarketPosition(_msgSender(), Position(
                    newfCashAmount,
                    0,
                    bestMarket.maturity,
                    bestMarket.monthsTenor
                )
            );
            // update deposited amount on new position
            accounts[_msgSender()][bestMarket.maturity].deposited =
            existingPosition.deposited - _costOfEnteringMarket(existingPosition.deposited, bestMarket.maturity);
        }

        // mint wfCash
        underlyingAsset.approve(address(wfCash), underlyingAmount);
        wfCash.mintViaUnderlying(underlyingAmount, newfCashAmount, address(this), 0);

        // mint local wrapped tokens
        _mint(_msgSender(), newfCashAmount);
    }

    /// @dev Hook that is called before any transfer of tokens.
    ///
    /// It is used to transfer the `deposited` amounts when tokens
    /// are transferred to a different account.
    ///
    /// @dev This function may add and remove markets to/from accounts
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // don't run this code on mint or burn
        if (from == address(0) || to == address(0)) return;

        // compute the percentage of coins that have to be withdrawn
        uint256 percentageToMove = amount * 1e18 / balanceOf(from);

        uint256 maturity;
        uint256 currentfCash;
        uint256 currentDeposited;
        uint256 fCashToMove;
        uint256 depositedToMove;
        uint256 marketsLength = markets[from].length;

        // iterate over all the existing markets to
        // transfer the correspondent percentage of each market
        for (uint i; i < marketsLength; i++) {
            // get maturity of current market
            maturity = markets[from][i];

            // compute the amounts to move for this market
            currentfCash = accounts[from][maturity].fCash;
            currentDeposited = accounts[from][maturity].deposited;
            fCashToMove = currentfCash * percentageToMove / 1e18;
            depositedToMove = currentDeposited * percentageToMove / 1e18;

            // if whole stack is moving
            if (percentageToMove == 1e18) {
                // delete sender account position
                delete accounts[from][maturity];
                delete activeMarket[from][maturity];
            }
            else {
                // otherwise, decrease amounts from sender
                accounts[from][maturity].fCash = currentfCash - fCashToMove;
                accounts[from][maturity].deposited = currentDeposited - depositedToMove;
            }

            // check if receiver already has position on this market
            if (!activeMarket[to][maturity]) {
                _addMarketPosition(to, Position(
                        fCashToMove,
                        depositedToMove,
                        maturity,
                        accounts[to][maturity].monthsTenor
                    )
                );
            }
            else {
                // increase amounts when it already exists
                accounts[to][maturity].fCash = accounts[to][maturity].fCash + fCashToMove;
                accounts[to][maturity].deposited = accounts[to][maturity].deposited + depositedToMove;
            }
        }

        // clean account data if fully gone
        if (percentageToMove == 1e18) {
            delete markets[from];
        }
    }

    /// Compute the cost of depositing `amount` into the selected market
    ///
    /// Entering a market has a 0.3% annualized fee.
    /// The fee is prorated on the days remaining for the market to mature.
    ///
    /// if we deposit on day one on a 1 year tenor market, the cost is 0.3%
    /// if we deposit on day one on a 6 months tenor market, the cost is 0.15%
    /// if we deposit after 3 months on a 6 months tenor market, the cost is 0.075%
    ///
    /// @param amount The amount to deposit
    /// @param maturity Maturity of the market to enter
    function _costOfEnteringMarket(uint256 amount, uint256 maturity) private view returns (uint256) {
        uint32 daysUntilMaturity = _getDaysUntilMaturity(maturity);
        uint32 months = accounts[_msgSender()][maturity].monthsTenor;
        // compute the percentage fee to pay given the market we enter
        // multipy by 100 to avoid decimals
        uint32 marketRate = (months * 1e2) / 12;
        // compute the percentage of fee to pay given the remaining time
        // multipy by 100 to avoid decimals
        uint32 lateEntryDiscount = (daysUntilMaturity * 1e5) / (months * 30);
        // operate everything to obtain the final percentage fee to apply
        uint64 feeBasisPoints = (30 * marketRate * lateEntryDiscount);

        // operate, and then divide by 1e11:
        // 2 to compensate the marketRate op
        // 5 to compensate the lateEntryDiscount op
        // 4 to compensate the basis points units
        // delaying the division increases the precision
        return (amount * feeBasisPoints) / 1e11;
    }

    /// Return the amount of days between now and the maturity time of the market
    function _getDaysUntilMaturity(uint256 maturity) private view returns (uint16) {
        uint40 secs = uint40(maturity) - uint40(block.timestamp);

        return uint16(secs / 1 days);
    }

    /// Convert an amount from 8 decimals to the number of decimals of the underlying asset
    /// @param amount The number to be converted
    function _convertToAssetDecimals(uint256 amount) private view returns (uint256) {
        int8 decimalsDiff = int8(underlyingAsset.decimals()) - 8;
        uint256 coefficient = 10 ** abs(decimalsDiff);
        if (decimalsDiff > 0) {
            return amount * coefficient;
        }
        else {
            return amount / coefficient;
        }
    }

    /// Return an instance to Notional's wfCash contract of the given maturity
    /// @dev if it's used a maturity that is not deployed yet, a deploy will happen
    function _getWfCash(uint256 maturity) internal view returns (IWrappedfCash wfCash){
        // has internal cache so will only deploy if still not deployed
        wfCash = IWrappedfCash(
            wfCashFactory.computeAddress(currencyId, uint40(maturity))
        );
        return wfCash;
    }

    /// Fetch all markets and returns the most profitable one
    /// @return selectedMarket The market with the best rate at the moment
    function _getMostProfitableMarket() private view returns (Market memory selectedMarket) {
        INotionalProxy.MarketParameters[] memory availableMarkets = notionalProxy.getActiveMarkets(currencyId);
        uint256 length = availableMarkets.length;
        require(length > 0, 'no available markets');

        uint256 biggestRate;

        for (uint i = 0; i < length; i++) {
            if (availableMarkets[i].oracleRate > biggestRate) {
                biggestRate = availableMarkets[i].oracleRate;
                selectedMarket.maturity = availableMarkets[i].maturity;
                selectedMarket.monthsTenor = _getMonthsTenor(i);
            }
        }
    }

    /// Fetch all markets and returns the one on the selected maturity
    /// @return selectedMarket The market with the selected maturity
    function _getMarket(uint256 maturity) private view returns (Market memory selectedMarket) {
        INotionalProxy.MarketParameters[] memory availableMarkets = notionalProxy.getActiveMarkets(currencyId);
        uint256 length = availableMarkets.length;
        require(length > 0, 'no available markets');

        for (uint i = 0; i < length; i++) {
            if (availableMarkets[i].maturity == maturity) {
                selectedMarket.maturity = availableMarkets[i].maturity;
                selectedMarket.monthsTenor = _getMonthsTenor(i);
            }
        }
    }

    /// @param index The market index to be checked
    /// @return months Number of months of this tenor
    /// @dev markets always come ordered and are enabled from short to long
    function _getMonthsTenor(uint256 index) private pure returns (uint8 months) {
        if (index == 0) {
            // 3 months
            months = 3;
        }
        else if (index == 1) {
            // 6 months
            months = 6;
        }
        else if (index == 2) {
            // 1 year
            months = 12;
        }
        else if (index == 3) {
            // 2 years
            months = 24;
        }
        else if (index == 4) {
            // 5 years
            months = 60;
        }
        else if (index == 5) {
            // 10 years
            months = 120;
        }
        else if (index == 6) {
            // 20 years
            months = 240;
        }
        else {
            revert("market index too high");
        }
    }
}

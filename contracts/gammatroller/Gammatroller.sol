//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import "./GTokenInterface.sol";
import "./ErrorReporter.sol";
import "./PriceOracleInterface.sol";
import "./GammatrollerInterface.sol";
import "./GammatrollerStorage.sol";
import "./UnitrollerInterface.sol";
import "./GammaInterface.sol";
import "./ExponentialNoError.sol";

/**
 * @title GammaInfinityVault Interface
 * @dev Interface to deposit claimed Gamma into the infinity vault on behalf of the user
 */

interface GammaInfinityVault {

    function depositAuthorized(address userAddress,uint256 _amount) external;

} 

/**
 * @title Reservoir Interface
 * @dev Interface to fetch pending GammaTroller drip from the reservoir
 */

interface Reservoir {

    function drip() external;
    
}

/// @dev contracts to be included GTokenInterface, ErrorReporter, PriceOracleInterface, GammatrollerInterface, GammatrollerStorage, UnitrollerInterface
/// GammaInterface, ExponentialNoError, InterestRateModel, PlanetDiscountInterface, EIP20NonStandardInterface

/**
 * @title GammaTroller
 * @author Planet
 */
contract Gammatroller is GammatrollerV1Storage, GammatrollerInterface, GammatrollerErrorReporter, ExponentialNoError {
    /// @notice Emitted when an admin supports a market
    event MarketListed(GTokenInterface gToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(GTokenInterface gToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(GTokenInterface gToken, address account);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(GTokenInterface gToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when a new GAMMAspeed is calculated for a market
    event GammaSpeedUpdated(GTokenInterface indexed gToken, uint newSpeed);

    /// @notice Emitted when GAMMAis distributed to a supplier
    event DistributedSupplierGamma(GTokenInterface indexed gToken, address indexed supplier, uint gammaDelta, uint gammaSupplyIndex);

    /// @notice Emitted when GAMMAis distributed to a borrower
    event DistributedBorrowerGamma(GTokenInterface indexed gToken, address indexed borrower, uint gammaDelta, uint gammaBorrowIndex);

    /// @notice Emitted when GAMMAis granted by admin
    event GammaGranted(address recipient, uint amount);

    /// @notice Emitted when Reservoir is changed by admin
    event ReservoirUpdated(address newReservoirAddress);

    /// @notice Emitted when GammaBoost is set or updated for a market
    event GammaBoostUpdated(GTokenInterface indexed gToken, uint newBoost);

    /// @notice Emitted when a market's Boost is permanently turned off
    event MarketBoostDeprecated(address gToken);

    /// @notice The initial GAMMAindex for a market
    uint224 public constant gammaInitialIndex = 1e36;

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    function _onlyOwner() private view {
        require(msg.sender == admin, "not admin");
    }

    modifier onlyOwner() {
         _onlyOwner();
        _;
    }

    function _onlyOwnerPauseGuardian() private view {
        require(msg.sender == pauseGuardian || msg.sender == admin, "not admin/pauseGuardian");
    }

    modifier onlyOwnerPauseGuardian(){
        _onlyOwnerPauseGuardian();
        _;
    }

    function _ownerOrStateTrue(bool state) private view {
        require(msg.sender == admin || state, "not admin");

    }
    modifier ownerOrStateTrue(bool state){
        _ownerOrStateTrue(state);
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (GTokenInterface[] memory) {
        return accountAssets[account];
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param gToken The gToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, GTokenInterface gToken) public view returns (bool) {
        return markets[address(gToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param gTokens The list of addresses of the gToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory gTokens) override external returns (uint[] memory) {
        uint len = gTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; ++i) {
            GTokenInterface gToken = GTokenInterface(gTokens[i]);

            results[i] = uint(addToMarketInternal(gToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param gToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(GTokenInterface gToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(gToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(gToken);

        emit MarketEntered(gToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param gTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address gTokenAddress) override external returns (uint) {
        GTokenInterface gToken = GTokenInterface(gTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the gToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = gToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(gTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(gToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set gToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete gToken from the account’s list of assets */
        // load into memory for faster iteration
        GTokenInterface[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; ++i) {
            if (userAssetList[i] == gToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        GTokenInterface[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        //storedList.length--;
        storedList.pop();

        emit MarketExited(gToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param gToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address gToken, address minter, uint mintAmount) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[gToken], "mint paused");

        // Shh - currently unused
        minter;
        mintAmount;

        if (!markets[gToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        updateGammaSupplyIndex(gToken);
        distributeSupplierGamma(gToken, minter);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param gToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of gTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address gToken, address redeemer, uint redeemTokens) override external returns (uint) {
        uint allowed = redeemAllowedInternal(gToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateGammaSupplyIndex(gToken);
        distributeSupplierGamma(gToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address gToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[gToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[gToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, GTokenInterface(gToken), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }
    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param gToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address gToken, address redeemer, uint redeemAmount, uint redeemTokens) override pure external {
        // Shh - currently unused
        gToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param gToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address gToken, address borrower, uint borrowAmount) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[gToken], "borrow paused");

        if (!markets[gToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[gToken].accountMembership[borrower]) {
            // only gTokens may call borrowAllowed if borrower not in market
            require(msg.sender == gToken, "sender not gToken");

            // attempt to add borrower to the market
            // Error err = addToMarketInternal(GTokenInterface(msg.sender), borrower);
            Error addToMarketError = addToMarketInternal(GTokenInterface(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // it should be impossible to break the important invariant
            assert(markets[gToken].accountMembership[borrower]);
        }
        
        if (oracle.getUnderlyingPrice(GTokenInterface(gToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }

        uint borrowCap = borrowCaps[gToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint totalBorrows = GTokenInterface(gToken).totalBorrows();
            uint nextTotalBorrows = totalBorrows + borrowAmount;
            require(nextTotalBorrows < borrowCap, "borrow cap reached");
        }
        // (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, GTokenInterface(gToken), 0, borrowAmount);
        (Error getHypotheticalAccountLiquidityInternalError, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, GTokenInterface(gToken), 0, borrowAmount);

        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: GTokenInterface(gToken).borrowIndex()});
        updateGammaBorrowIndex(gToken, borrowIndex);
        distributeBorrowerGamma(gToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }


    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param gToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(address gToken, address payer, address borrower, uint repayAmount) override external returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[gToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: GTokenInterface(gToken).borrowIndex()});
        updateGammaBorrowIndex(gToken, borrowIndex);
        distributeBorrowerGamma(gToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }


    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param gTokenBorrowed Asset which was borrowed by the borrower
     * @param gTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(address gTokenBorrowed, address gTokenCollateral, address liquidator, address borrower, uint repayAmount) override view external returns (uint) {
        // Shh - currently unused
        liquidator;

        if (!markets[gTokenBorrowed].isListed || !markets[gTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        uint borrowBalance = GTokenInterface(gTokenBorrowed).borrowBalanceStored(borrower);

        /* allow accounts to be liquidated if the market is deprecated */
        if (isDeprecated(GTokenInterface(gTokenBorrowed))) {
            require(borrowBalance >= repayAmount, "repayAmount > borrowBalance");
        } else {
            /* The borrower must have shortfall in order to be liquidatable */
            (Error err, , uint shortfall) = getAccountLiquidityInternal(borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            if (shortfall == 0) {
                return uint(Error.INSUFFICIENT_SHORTFALL);
            }

            /* The liquidator may not repay more than what is allowed by the closeFactor */
            uint maxClose = mul_ScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
            if (repayAmount > maxClose) {
                return uint(Error.TOO_MUCH_REPAY);
            }
        }
        return uint(Error.NO_ERROR);
    }


    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param gTokenCollateral Asset which was used as collateral and will be seized
     * @param gTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address gTokenCollateral,
        address gTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize paused");

        if(!checkMembership(borrower, GTokenInterface(gTokenCollateral))){
            return uint(Error.MARKET_NOT_ENTERED);
        }

        // Shh - currently unused
        seizeTokens;

        if (!markets[gTokenCollateral].isListed || !markets[gTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (GTokenInterface(gTokenCollateral).gammatroller() != GTokenInterface(gTokenBorrowed).gammatroller()) {
            return uint(Error.GAMMATROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateGammaSupplyIndex(gTokenCollateral);
        distributeSupplierGamma(gTokenCollateral, borrower);
        distributeSupplierGamma(gTokenCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param gToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of gTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(address gToken, address src, address dst, uint transferTokens) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(gToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateGammaSupplyIndex(gToken);
        distributeSupplierGamma(gToken, src);
        distributeSupplierGamma(gToken, dst);

        return uint(Error.NO_ERROR);
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `gTokenBalance` is the number of gTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint gTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) external view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, GTokenInterface(address(0)), 0, 0);

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code,
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(address account) internal view returns (Error, uint, uint) {
        return getHypotheticalAccountLiquidityInternal(account, GTokenInterface(address(0)), 0, 0);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param gTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address gTokenModify,
        uint redeemTokens,
        uint borrowAmount) external view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, GTokenInterface(gTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param gTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral gToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        GTokenInterface gTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        // For each asset the account is in
        GTokenInterface[] memory assets = accountAssets[account];

        uint assetsLength = assets.length;

        for (uint i = 0; i < assetsLength; ++i) {
            GTokenInterface asset = assets[i];

            // Read the balances and exchange rate from the gToken
            (oErr, vars.gTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);

            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> ether (normalized price value)
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // sumCollateral += tokensToDenom * gTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.gTokenBalance, vars.sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            // Calculate effects of interacting with gTokenModify
            if (asset == gTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in gToken.liquidateBorrowFresh)
     * @param gTokenBorrowed The address of the borrowed gToken
     * @param gTokenCollateral The address of the collateral gToken
     * @param actualRepayAmount The amount of gTokenBorrowed underlying to convert into gTokenCollateral tokens
     * @return (errorCode, number of gTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(address gTokenBorrowed, address gTokenCollateral, uint actualRepayAmount) override external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(GTokenInterface(gTokenBorrowed)); 
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(GTokenInterface(gTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = GTokenInterface(gTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new price oracle for the gammatroller
      * @dev Admin function to set a new price oracle
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setPriceOracle(PriceOracleInterface newOracle) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Set gammatroller's oracle to newOracle
        oracle = newOracle;


        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the closeFactor used when liquidating borrows
      * @dev Admin function to set closeFactor
      * @param newCloseFactorMantissa New close factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure
      */
    function _setCloseFactor(uint newCloseFactorMantissa) external onlyOwner returns (uint) {

        closeFactorMantissa = newCloseFactorMantissa;

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the collateralFactor for a market
      * @dev Admin function to set per-market collateralFactor
      * @param gToken The market to set the factor on
      * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCollateralFactor(GTokenInterface gToken, uint newCollateralFactorMantissa) override external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        Market storage market = markets[address(gToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(gToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(gToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets liquidationIncentive
      * @dev Admin function to set liquidationIncentive
      * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Add the market to the markets mapping and set it as listed
      * @dev Admin function to set isListed and add support for the market
      * @param gToken The address of the market (token) to list
      * @return uint 0=success, otherwise a failure. (See enum Error for details)
      */
    function _supportMarket(GTokenInterface gToken) override external onlyOwner returns (uint) {

        if (markets[address(gToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        require(gToken.isGToken(), "not GToken"); // Sanity check to make sure its really a GToken

        // Note that isGammaed is not in active use anymore
        //markets[address(gToken)] = Market({isListed: true, isGammaed: false, collateralFactorMantissa: 0});
        markets[address(gToken)].isListed = true;
        markets[address(gToken)].isGammaed = false;
        markets[address(gToken)].collateralFactorMantissa = 0;


        _addMarketInternal(address(gToken));
        _addBoostedMarketInternal(address(gToken));
        _initializeMarket(address(gToken));

        emit MarketListed(gToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(address gToken) internal {
        uint allMarketsLength = allMarkets.length;

        for (uint i = 0; i < allMarketsLength; ++i) {
            require(allMarkets[i] != GTokenInterface(gToken), "already added");
        }
        allMarkets.push(GTokenInterface(gToken));
    }

    function _addBoostedMarketInternal(address gToken) internal {
        uint allBoostedMarketsLength = allBoostedMarkets.length;

        for (uint i = 0; i < allBoostedMarketsLength; ++i) {
            // no need to check if the market is deprecated as a deprecated market will be part of 
            // allMarkets and revert in the require step in _addMarketInternal.
            require(allBoostedMarkets[i] != GTokenInterface(gToken), "already added");
        }
        allBoostedMarkets.push(GTokenInterface(gToken));
        
    }

    function _initializeMarket(address gToken) internal {
        uint32 blockNumber = safe32(block.number, "block number > 32bits");

        GammaMarketState storage supplyState = gammaSupplyState[gToken];
        GammaMarketState storage borrowState = gammaBorrowState[gToken];

        /*
         * Update market state indices
         */
        if (supplyState.index == 0) {
            // Initialize supply state index with default value
            supplyState.index = supplyState.boostIndex = gammaInitialIndex;
        }

        if (borrowState.index == 0) {
            // Initialize borrow state index with default value
            borrowState.index = borrowState.boostIndex = gammaInitialIndex;
        }

        /*
         * Update market state block numbers
         */
         supplyState.block = borrowState.block = blockNumber;
    }

    /**
      * @notice Set the given borrow caps for the given gToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
      * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
      * @param gTokens The addresses of the markets (tokens) to change the borrow caps for
      * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
      */
    function _setMarketBorrowCaps(GTokenInterface[] calldata gTokens, uint[] calldata newBorrowCaps) external onlyOwnerPauseGuardian {

        uint numMarkets = gTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for(uint i = 0; i < numMarkets; ++i) {
            borrowCaps[address(gTokens[i])] = newBorrowCaps[i];
        }
    }

    /**
     * @notice Admin function to change the Borrow Cap Guardian
     * @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
     */
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external onlyOwner {

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) external onlyOwner returns (uint) {


        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(GTokenInterface gToken, bool state) external onlyOwnerPauseGuardian ownerOrStateTrue(state) returns (bool) {

        mintGuardianPaused[address(gToken)] = state;
        return state;
    }

    function _setBorrowPaused(GTokenInterface gToken, bool state) external onlyOwnerPauseGuardian ownerOrStateTrue(state) returns (bool) {
        require(markets[address(gToken)].isListed, "not listed");
        borrowGuardianPaused[address(gToken)] = state;
        return state;
    }

    function _setTransferPaused(bool state) external onlyOwnerPauseGuardian ownerOrStateTrue(state) returns (bool) {

        transferGuardianPaused = state;
        return state;
    }

    function _setSeizePaused(bool state) external onlyOwnerPauseGuardian returns (bool) {

        seizeGuardianPaused = state;
        return state;
    }

    function _become(UnitrollerInterface unitroller) external {
        require(msg.sender == unitroller.admin(), "not unitroller");
        require(unitroller._acceptImplementation() == 0, "not authorized");
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == implementation;
    }

    /*** Gamma Distribution ***/

    /**
     * @notice Accrue GAMMA to the market by updating the supply index
     * @param gToken The market whose supply index to update
     */

    function updateGammaSupplyIndex(address gToken) internal {
        GammaMarketState storage supplyState = gammaSupplyState[gToken];
        uint blockNumber = block.number;
        uint deltaBlocks = blockNumber - uint(supplyState.block);

        if (deltaBlocks > 0 ) {

            (uint256 supplyTokens, uint256 totalFactor) = GTokenInterface(gToken).getMarketData();
            uint supplySpeed = gammaSpeeds[gToken];

            if(supplyTokens > 0 && supplySpeed > 0 ){

                uint256 gammaBoostPercentage = gammaBoostPercentage[gToken];

                uint gammaAccrued = mul_(deltaBlocks, supplySpeed);
                uint gammaAccruedRegular = gammaAccrued * (10000 - gammaBoostPercentage) / (10000);

                supplyState.index = safe224(add_(Double({mantissa: supplyState.index}), fraction(gammaAccruedRegular, supplyTokens)).mantissa, "new index exceeds 224 bits");

                // If gammaBoostPercentage is 0, then we don't need to update it
                if (gammaBoostPercentage != 0 && totalFactor != 0) {

                    uint gammaAccruedBoosted = gammaAccrued * (gammaBoostPercentage) / (10000);
                    supplyState.boostIndex = safe224(add_(Double({mantissa: supplyState.boostIndex}), fraction(gammaAccruedBoosted, totalFactor)).mantissa, "new boost index exceeds 224 bits");

                }
            } 

            supplyState.block = safe32(blockNumber, "block number > 32bits");
        }
    }

    /**
     * @notice Accrue GAMMAto the market by updating the borrow index
     * @param gToken The market whose borrow index to update
     */
    function updateGammaBorrowIndex(address gToken, Exp memory marketBorrowIndex) internal {
        GammaMarketState storage borrowState = gammaBorrowState[gToken];
        uint borrowSpeed = gammaSpeeds[gToken];
        uint blockNumber = block.number;
        uint deltaBlocks = blockNumber - uint(borrowState.block);
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(GTokenInterface(gToken).totalBorrows(), marketBorrowIndex);
            uint gammaAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(gammaAccrued, borrowAmount) : Double({mantissa: 0});
            borrowState.index = safe224(add_(Double({mantissa: borrowState.index}), ratio).mantissa, "new index exceeds 224 bits");
            borrowState.block = safe32(blockNumber, "block number > 32bits");
        } else if (deltaBlocks > 0) {
            borrowState.block = safe32(blockNumber, "block number > 32bits");
        }
    }

    /**
     * @notice Calculate GAMMAaccrued by a supplier and possibly transfer it to them
     * @param gToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute GAMMA to
     */
    function distributeSupplierGamma(address gToken, address supplier) internal {
        (uint256 supplierTokens, uint256 supplierFactor) = GTokenInterface(gToken).getUserData(supplier);        
        uint supplyIndex = gammaSupplyState[gToken].index;
        uint supplierIndex = gammaSupplierIndex[gToken][supplier];
        gammaSupplierIndex[gToken][supplier] = supplyIndex;

        if (supplierIndex == 0) {
            supplierIndex = gammaInitialIndex;
        }

        Double memory deltaIndex = Double({mantissa: sub_(supplyIndex, supplierIndex)});
        uint supplierDelta = mul_(supplierTokens, deltaIndex);
        uint supplierAccrued = add_(gammaAccrued[supplier], supplierDelta);

        uint supplyBoostIndex = gammaSupplyState[gToken].boostIndex;
        uint supplierBoostIndex = gammaSupplierBoostIndex[gToken][supplier];
        gammaSupplierBoostIndex[gToken][supplier] = supplyBoostIndex;

        if (supplierBoostIndex == 0) {
            supplierBoostIndex = gammaInitialIndex;
        }

        if (supplierFactor != 0){
            Double memory deltaBoostIndex = Double({mantissa: sub_(supplyBoostIndex, supplierBoostIndex)});
            uint supplierBoostDelta = mul_(supplierFactor, deltaBoostIndex);
            supplierAccrued = add_(supplierAccrued, supplierBoostDelta);
        }

        gammaAccrued[supplier] = supplierAccrued;
        emit DistributedSupplierGamma(GTokenInterface(gToken), supplier, supplierDelta, supplyIndex);
    }

    /**
     * @notice Calculate GAMMAaccrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param gToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute GAMMAto
     */
    function distributeBorrowerGamma(address gToken, address borrower, Exp memory marketBorrowIndex) internal {
        GammaMarketState storage borrowState = gammaBorrowState[gToken];
        uint borrowIndex = borrowState.index;
        uint borrowerIndex = gammaBorrowerIndex[gToken][borrower];
        gammaBorrowerIndex[gToken][borrower] = borrowIndex;

        if (borrowerIndex == 0) {
            borrowerIndex = gammaInitialIndex;
        }

        Double memory deltaIndex = Double({mantissa: sub_(borrowIndex, borrowerIndex)});
        uint borrowerAmount = div_(GTokenInterface(gToken).borrowBalanceStored(borrower), marketBorrowIndex);
        uint borrowerDelta = mul_(borrowerAmount, deltaIndex);
        uint borrowerAccrued = add_(gammaAccrued[borrower], borrowerDelta);
        gammaAccrued[borrower] = borrowerAccrued;
        emit DistributedBorrowerGamma(GTokenInterface(gToken), borrower, borrowerDelta, borrowIndex);
        
    }
    

    /**
     * @notice Claim all the gammaaccrued by holder in all markets
     * @param holder The address to claim GAMMAfor
     */
    function claimGamma(address holder) external {
        return claimGamma(holder, allMarkets);
    }

    /**
     * @notice Claim all the gammaaccrued by holder in the specified markets
     * @param holder The address to claim GAMMAfor
     * @param gTokens The list of markets to claim GAMMAin
     */
    function claimGamma(address holder, GTokenInterface[] memory gTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimGamma(holders, gTokens, true, true);
    }

    /**
     * @notice Claim all gammaaccrued by the holders
     * @param holders The addresses to claim GAMMAfor
     * @param gTokens The list of markets to claim GAMMAin
     * @param borrowers Whether or not to claim GAMMAearned by borrowing
     * @param suppliers Whether or not to claim GAMMAearned by supplying
     */
    function claimGamma(address[] memory holders, GTokenInterface[] memory gTokens, bool borrowers, bool suppliers) public {
        
        uint gTokensLength = gTokens.length;
        uint holdersLength = holders.length;


        for (uint i = 0; i < gTokensLength; ++i) {
            GTokenInterface gToken = gTokens[i];
            require(markets[address(gToken)].isListed, "not listed");
            if (borrowers == true) {
                Exp memory borrowIndex = Exp({mantissa: gToken.borrowIndex()});
                updateGammaBorrowIndex(address(gToken), borrowIndex);
                for (uint j = 0; j < holdersLength; ++j) {
                    distributeBorrowerGamma(address(gToken), holders[j], borrowIndex);
                }
            }
            if (suppliers == true) {
                updateGammaSupplyIndex(address(gToken));
                for (uint j = 0; j < holdersLength; ++j) {
                    distributeSupplierGamma(address(gToken), holders[j]);
                }
            }
        }
        
        for (uint j = 0; j < holdersLength; ++j) {
            gammaAccrued[holders[j]] = grantGammaInternal(holders[j], gammaAccrued[holders[j]]);
        }
    }

    /**
     * @notice Transfer GAMMA to the user
     * @dev Note: If there is not enough GAMMA, we drip.
     * @param user The address of the user to transfer GAMMAto
     * @param amount The amount of GAMMAto (possibly) transfer
     * @return The amount of GAMMAwhich was NOT transferred to the user
     */
    function grantGammaInternal(address user, uint amount) internal returns (uint) {

        GammaInterface gamma= GammaInterface(0xb3Cb6d2f8f2FDe203a022201C81a96c167607F15);

        if(amount >= gamma.balanceOf(address(this))){
            Reservoir(reservoirAddress).drip();
        }
        if(amount>0 && gamma.balanceOf(address(this)) >= amount){
            if(stakeGammaToVault){
                gamma.approve(gammaInfinityVaultAddress, amount);
                GammaInfinityVault(gammaInfinityVaultAddress).depositAuthorized(user, amount);
            }
            else{
                require(gamma.transfer(user, amount), "gamma transfer failed");            
            }
            return 0;
        }
        return amount;
        
    }

    /**
     * @notice Updates factor after a  token operation
     * This function needs to be called by the iGamma contract after every iGamma Balance
     * changing action like mint / burn / transfer
     * @param _user The users address we are updating
     * @param _newiGammaBalance The new balance of the users iGamma
     */
    function updateFactor(address _user, uint256 _newiGammaBalance) override external {
        require(msg.sender == address(gammaInfinityVaultAddress), "not iGamma");
        uint256 len = allBoostedMarkets.length;
        address gToken;
        uint256 amount;

        for (uint256 i = 0; i <len; ++i) {

            gToken = address(allBoostedMarkets[i]);
            amount = GTokenInterface(gToken).balanceOf(_user);

            if (amount == 0) {
                continue;
            }

            // Keep the flywheel moving
            updateGammaSupplyIndex(gToken);
            distributeSupplierGamma(gToken, _user);

            GTokenInterface(gToken).updateUserAndTotalFactors(_user,_newiGammaBalance);
        }
    }



    /*** Admin ***/

    /**
     * @notice Set whether claimed Gamma is to be staked to the infinity vault or not
     * @param _stakeToVault The bool that is true when gamma is to be staked to infinity
     * vault and false otherwise
     */
    function _setStakeGammaToVault(bool _stakeToVault) external onlyOwner {
        stakeGammaToVault = _stakeToVault;
    }

    /**
     * @notice Updates infinity vault address in GammaTroller and iGamma address in all listed markets
     * @param _newInfinityVaultAddress The new infinity vault address where deposit authorized is called
     * @param _newiGammaAddress The new iGamma address that can call mint, burn and tranfer after any 
     * transaction
     */
    function _updateGammaInfinityVaultAddressAndiGammaAddress(address _newInfinityVaultAddress, address _newiGammaAddress) external onlyOwner{
        require(_newInfinityVaultAddress != address(0) && _newiGammaAddress != address(0), "address(0)");

        _updateGammaInfinityVaultAddress(_newInfinityVaultAddress);
        _updateiGammaAddress(_newiGammaAddress);

    }

    function _updateGammaInfinityVaultAddress(address _newInfinityVaultAddress) internal {
        gammaInfinityVaultAddress = _newInfinityVaultAddress;
     }

    function _updateiGammaAddress(address _newiGammaAddress) internal {
        uint256 len = allMarkets.length;
        for (uint256 i = 0; i <len; ++i) {

            address gToken = address(allMarkets[i]);
            GTokenInterface(gToken)._updateiGammaAddress(_newiGammaAddress);
        }
    }

    /**
     * @notice Updates the Reservoir Address
     * @param _newReservoirAddress The new reservoir address from which Gamma Drip is fetched
     */
    function _updateReservoirAddress(address _newReservoirAddress) external onlyOwner {
        require(_newReservoirAddress != address(0), "address(0)");
        reservoirAddress = _newReservoirAddress;
        emit ReservoirUpdated(reservoirAddress);
    }

    /*** Gamma Distribution Admin ***/

    /**
     * @notice Transfer GAMMA to the recipient
     * @dev Note: If there is not enough GAMMA, we do not perform the transfer all.
     * @param recipient The address of the recipient to transfer GAMMA to
     * @param amount The amount of GAMMA to (possibly) transfer
     */
    function _grantGamma(address recipient, uint amount) external {
        require(adminOrInitializing(), "not admin");
        uint amountLeft = grantGammaInternal(recipient, amount);
        require(amountLeft == 0, "insufficient gamma");
        emit GammaGranted(recipient, amount);
    }

    function _setGammaSpeeds(GTokenInterface[] memory gTokens, uint[] memory gammaSpeeds) external {
        require(adminOrInitializing(), "only admin");

        uint numTokens = gTokens.length;
        require(numTokens == gammaSpeeds.length, "invalid input");

        for (uint i = 0; i < numTokens; ++i) {
            setGammaSpeedInternal(gTokens[i], gammaSpeeds[i]);
        }
    }

   
    function setGammaSpeedInternal(GTokenInterface gToken, uint gammaSpeed) internal {
    
        require(markets[address(gToken)].isListed, "not listed");

        if (gammaSpeeds[address(gToken)] != 0) {
            // Supply speed updated so let's update supply state to ensure that
            //  1. GAMMA accrued properly for the old speed, and
            //  2. GAMMA accrued at the new speed starts after this block.

            updateGammaSupplyIndex(address(gToken));
            updateGammaBorrowIndex(address(gToken), Exp({mantissa: gToken.borrowIndex()}));
        } 

        // note that GAMMAspeed could be set to 0 to halt liquidity rewards for a market
        if (gammaSpeeds[address(gToken)] != gammaSpeed) {
            // Update speed and emit event
            gammaSpeeds[address(gToken)] = gammaSpeed;
            emit GammaSpeedUpdated(gToken, gammaSpeed);
        }

    }

    /**
     * @notice Set GammaBoost for an array of market
     * @param gTokens Array of markets whose GammaBoost to update
     * @param gammaBoosts Array of New GammaBoost for markets
     */
    function setGammaBoost(GTokenInterface[] memory gTokens, uint256[] memory gammaBoosts) public {
        require(adminOrInitializing(), "only admin");

        uint256 len = gTokens.length;
        for (uint256 i = 0; i < len; ++i){
            _setGammaBoostInternal(gTokens[i], gammaBoosts[i]);
        }
    }

     /**
     * @notice Set GammaBoost for a single market
     * @param gToken The market whose GammaBoost to update
     * @param gammaBoost New GammaBoost for market
     */
    function _setGammaBoostInternal(GTokenInterface gToken, uint gammaBoost) internal {
        Market storage market = markets[address(gToken)];
        require(market.isListed == true, "market is not listed");
        bool isBoostDeprecated = gToken.getBoostDeprecatedStatus();
        require(isBoostDeprecated == false, "gamma boost permanently turned off");

        uint currentGammaBoost = gammaBoostPercentage[address(gToken)];

        if (currentGammaBoost != 0) {
            // note that GammaBoost could be set to 0 to halt boost rewards for a market
            updateGammaSupplyIndex(address(gToken));
        }

        if (currentGammaBoost != gammaBoost) {
            gammaBoostPercentage[address(gToken)] = gammaBoost;
            emit GammaBoostUpdated(gToken, gammaBoost);
        }
    }

    /**
     * @notice Permanently delete a market from the allBoostedMarkets array
     * @param gToken The market whose GammaBoost to permanently end
     */

    function _deprecateBoostMarket(address gToken) external onlyOwner{
        Market storage market = markets[gToken];
        require(market.isListed, "not listed");
        require(gammaBoostPercentage[address(gToken)] == 0, "gammaBoost% not zero");

        GTokenInterface(gToken).deprecateBoost();

        /* Delete gToken from the list of Boosted Markets */
        // load into memory for faster iteration
        uint256 len = allBoostedMarkets.length;
        uint256 assetIndex = len;
        for (uint256 i = 0; i < len; ++i) {
            if (address(allBoostedMarkets[i]) == gToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        allBoostedMarkets[assetIndex] = allBoostedMarkets[allBoostedMarkets.length - 1];
        allBoostedMarkets.pop();

        emit MarketBoostDeprecated(gToken);

    }

    /*** Public ***/

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() override external view returns (GTokenInterface[] memory) {
        return allMarkets;
    }

    /**
     * @notice Return all of the Boosted markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of boosted market addresses
     */
    function getAllBoostedMarkets() external view returns (GTokenInterface[] memory) {
        return allBoostedMarkets;
    }

    /**
     * @notice Returns true if the given gToken market has been deprecated
     * @dev All borrows in a deprecated gToken market can be immediately liquidated
     * @param gToken The market to check if deprecated
     */
    function isDeprecated(GTokenInterface gToken) public view returns (bool) {
        return
            markets[address(gToken)].collateralFactorMantissa == 0 && 
            borrowGuardianPaused[address(gToken)] == true && 
            gToken.reserveFactorMantissa() == 1e18
        ;
    }

  

    function getOracle() external override view returns (PriceOracleInterface ) {
        return oracle;
    }
}
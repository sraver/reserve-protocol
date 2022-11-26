# NTokens Notional Collateral Plugin

## What are the collateral token, reference unit, and target unit for this plugin?

This plugin can be deployed four times to cover all types of assets that Notional accepts.

For Fiat collateral plugin:

`tok`: nUSDC  
`ref`: USDC  
`target`: USD  
`UoA`: USD

`tok`: nDAI  
`ref`: DAI  
`target`: USD  
`UoA`: USD

For Non-Fiat collateral plugin:

`tok`: nETH  
`ref`: ETH  
`target`: ETH  
`UoA`: USD

`tok`: nWBTC  
`ref`: BTC   
`target`: BTC  
`UoA`: USD

## How does one configure and deploy an instance of the plugin?

### For the _Collateral_:

NTokens plugin needs some data feeds for computing the `price` of the assets and the `refPerTok`.

Since we are using a revenue hiding strategy, we also need to tell at deployment time how much percentage is
the `refPerTok` allowed to drop.

In the case of the fiat collateral plugin, the only Chainlink price feed that we need is the one converting
the _reference unit_ to the _target unit_.  
In the case of the non-fiat collateral plugin, we need also the feed to convert from _target unit_ to _unit of account_.

In both cases there is an extra address that is required for the plugin to work, which is the address of the
_NotionalProxy_ contract, that allows the plugin to claim the rewards.

### For the _Asset_:

Since the plugin is claiming rewards and those come in form of NOTE tokens, we need to deploy also a new _Asset_
contract that is able to fetch the price.

This asset contract is the _NoteAsset.sol_. In order to deploy this contract we need, apart from the regular arguments,
the address of the Balancer pool that will provide the rate of NOTE to ETH, and a Chainlink feed that will convert
the ETH to USD.

### If the deployer should plug in price feeds, what units does your plugin expect those price feeds to be stated in?

### For the _Collateral_:

- Chainlink feed: tok/USD -- int256
- (if non-fiat): target/USD -- int256

### For the _Asset_:

- Balancer pool: NOTE/ETH -- uint256 -- Address on mainnet: `0x5122E01D819E58BB2E22528c0D68D310f0AA6FD7`
- Chainlink feed: ETH/USD -- int256

## Why should the value (reference units per collateral token) decrease only in exceptional circumstances?

nTokens earn returns in three ways:

- Blended interest rate
- Liquidity Fees
- NOTE Incentives

Given that, the value of nTokens is rising over time in staked assets rate. There is only one caveat,
since trading happens on the liquidity pools, there is a risk of impermanent loss that we fight by using a revenue
hiding strategy.

The expected drop of value in the pools is very low since the exchange rates are very stable. We have looked the
history data and the max value is around 0.9%, so we are confident saying that 1% should be an accepted
`allowedDrop`, or maybe 1.5% to give some more room.

The script used to check those values is this: https://gist.github.com/sraver/3725980c884cadb6efee4ed74151c992

## How does the plugin guarantee that its status() becomes DISABLED in those circumstances?

In the case that the `refPerTok` goes below the _minimum accepted `refPerTok`_, which is a certain percent lower
than the maximum `refPerTok` ever seen, it does a hard default.  
In the case that the _reference_ depegs from the target for longer than a given period of time, then a soft default
happens.
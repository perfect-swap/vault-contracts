# Perfect Strategy Features

## Intro

This is a list of features that any new strategy should implement before being displayed in the Perfect UI.

[1. GasThrottler](#gasthrottler)

## Features

### GasThrottler

Designed to protect regular harvesters from being exploited by front-running bots. More info on the rationale behind it and design at issue [#37](https://github.com/perfectfinance/perfect-contracts/issues/37)

#### How to implement

Just import the `GasThrottler` contract and have your strategy contract inherit from it. The main harvest function should include the `gasThrottle` modifier.

```
import  "../../utils/GasThrottler.sol";

contract StrategyExample is GasThrottler {

    function harvest() external gasThrottle {
        ...
    }
}
```

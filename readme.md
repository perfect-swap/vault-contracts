# PerfectSwap Vaults Contracts
Official repo for strategies and vaults from PerfectSwap Vaults. Community strategists can contribute here to grow the ecosystem.

## Vault Deployment Process
### 1. Select a farm
The first step to have a vault deployed on PerfectSwap Vaults is to select a farm to deploy a vault around. At the moment the rewards for a strategist are:
 - 0.5% of all rewards earned by a vault they deployed.

This means that you want to select a farm with:
1. High APR
2. High expected TVL
3. Long farm life

First time strategists must deploy contracts for farms on existing platforms on PerfectSwap Vaults first. New platforms must undergo an audit by PerfectSwap Vaults dev team before development can begin.

### 2. Prepare the smart contracts
If you decided to do a simple LP vault, or a single asset vault, the most likely thing is that there is a working template that you can use. 

### 3. Test the contracts
If you're doing something completely custom you should add automated tests to facilitate review and diminish risks. If it's a copy/paste from another strategy you can get by with manual testing for now as everything has been battle tested tested quite a bit.

For extra help in debugging a deployed vault during development, you can use the [ProdVaultTest.t.sol](./forge/test/ProdVaultTest.t.sol), which is written using the `forge` framework. Run `yarn installForge` to install if you don't have `forge` installed.

To prep to run the test suite, input the correct vault address, vaultOwner and stratOwner for the chain your testing in `ProdVaultTest.t.sol`, and modify the `yarn forgeTest:vault` script in package.json to pass in the correct RPC url of the chain your vault is on. Then run `yarn forgeTest:vault` to execute the test run. You can use `console.log` within the tests in `ProdVaultTest.t.sol` to output to the console.

### 4. Deploy the smart contracts
Once you are confident that everything works as expected you can do the official deploy of the vault + strategy contracts. 

Make sure the strategy is verified in the scanner. A fool-proof way to verify is to flatten the strategy file using the `yarn flat-hardhat` command and removing the excess licenses from the flattened file. Verify the strategy contract using the flattened file as the source code, solidity version is typically 0.6.12 and is optimized to 200 runs. Constructor arguments can be found from the end of the input data in the contract creation transaction; they are padded out with a large number of 0s (include the 0s).

### 5. Test the vault

Run `yarn start` on the local app terminal and test the vault as if you were a user on the `localhost` page.

**Manual Testing Is Required for All Live Vaults**

0. Give vault approval to spend your want tokens. 
1. Deposit a small amount to test deposit functionality.
2. Withdraw, to test withdraw functionality.
3. Deposit a larger amount wait 30 seconds to a minute and harvest. Check harvest transaction to make sure things are going to the right places.
4. Panic the vault. Funds should be in the strategy.
5. Withdraw 50%.
6. Try to deposit, once you recieve the error message pop up in metamask you can stop. No need to send the transaction through.
7. Unpause.
8. Deposit the withdrawn amount.
9. Harvest again.
10. Switch harvest-on-deposit to `true` for low-cost chains (Polygon, Fantom, Harmony, Celo, Cronos, Moonriver, Moonbeam, Fuse, Syscoin, Emerald).
11. Check that `callReward` is not 0, if needed set `pendingRewardsFunctionName` to the relevant function name from the masterchef.
12. Transfer ownership of the vault and strategy contracts to the owner addresses for the respective chains found in the [address book](https://github.com/perfectswapfinance/perfectswap-api/tree/master/packages/address-book).
13. Leave some funds in the vault until users have deposited after going live, empty vaults will fail validation checks.
14. Run `yarn validate` to ensure that the validation checks will succeed when opening a pull request.

This is required so that maintainers can review everything before the vault is actually live on the app and manage it after its live.

## Troubleshooting
- If you get the following error when testing or deploying on a forked chain: `Error: VM Exception while processing transaction: reverted with reason string 'Address: low-level delegate call failed'`, you are probably using `hardhat` network rather than `localhost`. Make sure you are using `--network localhost` flag for your test or deploy yarn commands.
- If you get the following error when running the fork command i.e. `yarn net bsc`: `FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory`. Run this command to increase heap memory limit: `export NODE_OPTIONS=--max_old_space_size=4096`
- If you are getting hanging deployments on polygon when you run `yarn deploy-strat:polygon`, try manually adding `{gasPrice: 8000000000 * 5}` as the last arg in the deploy commands, i.e. `const vault = await Vault.deploy(predictedAddresses.strategy, vaultParams.mooName, vaultParams.mooSymbol, vaultParams.delay, {gasPrice: 8000000000 * 5}); `

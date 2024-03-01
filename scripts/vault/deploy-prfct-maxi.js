import hardhat, { ethers, web3 } from "hardhat";
import { addressBook } from "blockchain-addressbook";
import vaultV7 from "../../artifacts/contracts/PRFCT/vaults/PrfctVaultV7.sol/PrfctVaultV7.json";
import vaultV7Factory from "../../artifacts/contracts/PRFCT/vaults/PrfctVaultV7Factory.sol/PrfctVaultV7Factory.json";
import stratAbi from "../../artifacts/contracts/PRFCT/strategies/PRFCT/StrategyPrfctMaxiV5Solidly.sol/StrategyPrfctMaxiV5Solidly.json";

const {
  platforms: { equilibre: { router: router}, prfctfinance },
  tokens: {
    KAVA: {address: NATIVE},
    PRFCT: { address: PRFCT },
  },
} = addressBook.kava;

const implementation = web3.utils.toChecksumAddress("0xaC3778DC45B5e415DaA78CCC31f25169bD98C43A");

const vaultParams = {
  mooName: "Moo Kava PRFCT",
  mooSymbol: "mooKavaPRFCT",
  delay: 21600,
};

const strategyParams = {
  rewardPool: prfctfinance.rewardPool,
  unirouter: router,
  strategist: process.env.STRATEGIST_ADDRESS, // some address
  keeper: prfctfinance.keeper,
  prfctFeeRecipient: prfctfinance.prfctFeeRecipient,
  feeConfig: prfctfinance.prfctFeeConfig,
  outputToWantRoute: [[NATIVE, PRFCT, false]],
  verifyStrat: false,
  prfctVaultProxy: prfctfinance.vaultFactory,
  strategyImplementation: implementation,
  useVaultProxy: false,
 // ensId
};

async function main() {
 if (
    Object.values(vaultParams).some(v => v === undefined) ||
    Object.values(strategyParams).some(v => v === undefined)
  ) {
    console.error("one of config values undefined");
    return;
  }

  await hardhat.run("compile");

  console.log("Deploying:", vaultParams.mooName);

  const factory = await ethers.getContractAt(vaultV7Factory.abi, strategyParams.prfctVaultProxy);
  let vault = await factory.callStatic.cloneVault();
  let tx = await factory.cloneVault();
  tx = await tx.wait();
  tx.status === 1
  ? console.log(`Vault ${vault} is deployed with tx: ${tx.transactionHash}`)
  : console.log(`Vault ${vault} deploy failed with tx: ${tx.transactionHash}`);

  let strat = strategyParams.useVaultProxy ? await factory.callStatic.cloneContract(strategyParams.strategyImplementation) : strategyParams.strategyImplementation;
  if (strategyParams.useVaultProxy) {
    let stratTx = await factory.cloneContract(strategyParams.gaugeStakerStrat ? strategyParams.strategyImplementationStaker : strategyParams.strategyImplementation);
    stratTx = await stratTx.wait();
    stratTx.status === 1
    ? console.log(`Strat ${strat} is deployed with tx: ${stratTx.transactionHash}`)
    : console.log(`Strat ${strat} deploy failed with tx: ${stratTx.transactionHash}`);
  }

  const vaultConstructorArguments = [
    strat,
    vaultParams.mooName,
    vaultParams.mooSymbol,
    vaultParams.delay,
  ];


  const vaultContract = await ethers.getContractAt(vaultV7.abi, vault);
  let vaultInitTx = await vaultContract.initialize(...vaultConstructorArguments);
  vaultInitTx = await vaultInitTx.wait()
  vaultInitTx.status === 1
  ? console.log(`Vault Intilization done with tx: ${vaultInitTx.transactionHash}`)
  : console.log(`Vault Intilization failed with tx: ${vaultInitTx.transactionHash}`);

  vaultInitTx = await vaultContract.transferOwnership(prfctfinance.vaultOwner);
  vaultInitTx = await vaultInitTx.wait()
  vaultInitTx.status === 1
  ? console.log(`Vault OwnershipTransfered done with tx: ${vaultInitTx.transactionHash}`)
  : console.log(`Vault Intilization failed with tx: ${vaultInitTx.transactionHash}`);

  const strategyConstructorArguments = [
    strategyParams.rewardPool,
    strategyParams.outputToWantRoute,
    [
      vault,
      strategyParams.unirouter,
      strategyParams.keeper,
      strategyParams.strategist,
      strategyParams.prfctFeeRecipient,
      strategyParams.feeConfig,
    ]
  ];

  let abi = stratAbi.abi;
  const stratContract = await ethers.getContractAt(abi, strat);
  let args = strategyConstructorArguments
  let stratInitTx = await stratContract.initialize(...args);
  stratInitTx = await stratInitTx.wait()
  stratInitTx.status === 1
  ? console.log(`Strat Intilization done with tx: ${stratInitTx.transactionHash}`)
  : console.log(`Strat Intilization failed with tx: ${stratInitTx.transactionHash}`);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
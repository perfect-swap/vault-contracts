import hardhat, { ethers, web3 } from "hardhat";
import vaultV7 from "../../artifacts/contracts/PRFCT/vaults/PrfctVaultV7.sol/PrfctVaultV7.json";
import vaultV7Factory from "../../artifacts/contracts/PRFCT/vaults/PrfctVaultV7Factory.sol/PrfctVaultV7Factory.json";
import stratAbi from "../../artifacts/contracts/PRFCT/strategies/Balancer/StrategyAuraSideChain.sol/StrategyAuraSideChain.json";

const vaultParams = {
  mooName: "Moo Balancer Arb ETH-rETH",
  mooSymbol: "mooBalancerArbETH-rETH",
  delay: 21600,
};

const bytes0 = "0x0000000000000000000000000000000000000000000000000000000000000000";
const admin = web3.utils.toChecksumAddress("0x004b2Cf6888630ABebB2DaD39faAD738655e98C7");

const strategyParams = {
  want: web3.utils.toChecksumAddress("0xadE4A71BB62bEc25154CFc7e6ff49A513B491E81"),
  isComposable: true,
  booster: web3.utils.toChecksumAddress("0x98Ef32edd24e2c92525E59afc4475C1242a30184"),
  pid: 31,

  unirouter: web3.utils.toChecksumAddress("0xBA12222222228d8Ba445958a75a0704d566BF2C8"),
  strategist: admin,
  keeper: admin,
  prfctFeeRecipient: admin,
  prfctFeeConfig: "0x577E2F75A9412EbaE6c354D1c067D1d17fd675Fc",

  nativeToInputRoute: [
    ["0xade4a71bb62bec25154cfc7e6ff49a513b491e81000000000000000000000497", 0, 1],
  ],
  outputToNativeRoute: [
    ["0xcc65a812ce382ab909a11e434dbf75b34f1cc59d000200000000000000000001", 0, 1],
  ],

  nativeToInput: [
    web3.utils.toChecksumAddress("0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"),
    web3.utils.toChecksumAddress("0xadE4A71BB62bEc25154CFc7e6ff49A513B491E81"),
  ],
  outputToNative: [
    web3.utils.toChecksumAddress("0x040d1EdC9569d4Bab2D15287Dc5A4F10F56a56B8"),
    web3.utils.toChecksumAddress("0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"),
  ],

  extraReward: true,
  secondExtraReward: true,

  rewardAssets: [
    "0x1509706a6c66CA549ff0cB464de88231DDBe213B",
    "0x040d1EdC9569d4Bab2D15287Dc5A4F10F56a56B8",
    "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1",
  ],
  rewardRoute: [
    ["0xbcaa6c053cab3dd73a2e898d89a4f84a180ae1ca000100000000000000000458", 0, 1],
    ["0xcc65a812ce382ab909a11e434dbf75b34f1cc59d000200000000000000000001", 1, 2],
  ],
  secondRewardAssets: ["0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000"],
  secondRewardRoute: [["0x0000000000000000000000000000000000000000000000000000000000000000", 0, 1]],
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

  const factory = await ethers.getContractAt(vaultV7Factory.abi, "0xaCE2DF1067653675aB86857F7de137Ae406E4A24"); // PrfctVaultV7Factory
  let vault = await factory.callStatic.cloneVault();
  let tx = await factory.cloneVault();
  tx = await tx.wait();
  tx.status === 1
    ? console.log(`Vault ${vault} is deployed with tx: ${tx.transactionHash}`)
    : console.log(`Vault ${vault} deploy failed with tx: ${tx.transactionHash}`);

  let strat = await factory.callStatic.cloneContract("0x260aA0E743cdA2FF2b3DaE56f84C6B1E75eF468a"); //StrategyAuraSideChain
  let stratTx = await factory.cloneContract("0x260aA0E743cdA2FF2b3DaE56f84C6B1E75eF468a");
  stratTx = await stratTx.wait();
  stratTx.status === 1
    ? console.log(`Strat ${strat} is deployed with tx: ${stratTx.transactionHash}`)
    : console.log(`Strat ${strat} deploy failed with tx: ${stratTx.transactionHash}`);

  const vaultConstructorArguments = [strat, vaultParams.mooName, vaultParams.mooSymbol, vaultParams.delay];

  const vaultContract = await ethers.getContractAt(vaultV7.abi, vault);
  let vaultInitTx = await vaultContract.initialize(...vaultConstructorArguments);
  vaultInitTx = await vaultInitTx.wait();
  vaultInitTx.status === 1
    ? console.log(`Vault Intilization done with tx: ${vaultInitTx.transactionHash}`)
    : console.log(`Vault Intilization failed with tx: ${vaultInitTx.transactionHash}`);

  // vaultInitTx = await vaultContract.transferOwnership("0x0000000000000000000000000000000000000000");
  // vaultInitTx = await vaultInitTx.wait()
  // vaultInitTx.status === 1
  //   ? console.log(`Vault OwnershipTransfered done with tx: ${vaultInitTx.transactionHash}`)
  //   : console.log(`Vault Intilization failed with tx: ${vaultInitTx.transactionHash}`);

  const strategyConstructorArguments = [
    strategyParams.want,
    strategyParams.isComposable,
    strategyParams.nativeToInputRoute,
    strategyParams.outputToNativeRoute,
    strategyParams.booster,
    strategyParams.pid,
    strategyParams.nativeToInput,
    strategyParams.outputToNative,
    [
      vault,
      strategyParams.unirouter,
      strategyParams.keeper,
      strategyParams.strategist,
      strategyParams.prfctFeeRecipient,
      strategyParams.prfctFeeConfig,
    ],
  ];

  const stratContract = await ethers.getContractAt(stratAbi.abi, strat);
  let args = strategyConstructorArguments;
  let stratInitTx = await stratContract.initialize(...args);
  stratInitTx = await stratInitTx.wait();
  stratInitTx.status === 1
    ? console.log(`Strat Intilization done with tx: ${stratInitTx.transactionHash}`)
    : console.log(`Strat Intilization failed with tx: ${stratInitTx.transactionHash}`);

  if (strategyParams.extraReward) {
    stratInitTx = await stratContract.addRewardToken(
      strategyParams.rewardAssets[0],
      strategyParams.rewardRoute,
      strategyParams.rewardAssets,
      bytes0,
      100
    );
    stratInitTx = await stratInitTx.wait();
    stratInitTx.status === 1
      ? console.log(`Reward Added with tx: ${stratInitTx.transactionHash}`)
      : console.log(`Reward Addition failed with tx: ${stratInitTx.transactionHash}`);
  }

  if (strategyParams.secondExtraReward) {
    stratInitTx = await stratContract.addRewardToken(
      "0x912CE59144191C1204E64559FE8253a0e49E6548",
      strategyParams.secondRewardRoute,
      strategyParams.secondRewardAssets,
      "0x912ce59144191c1204e64559fe8253a0e49e65480001f482af49447d8a07e3bd95bd0d56f35241523fbab1",
      100
    );
    stratInitTx = await stratInitTx.wait();
    stratInitTx.status === 1
      ? console.log(`Reward Added with tx: ${stratInitTx.transactionHash}`)
      : console.log(`Reward Addition failed with tx: ${stratInitTx.transactionHash}`);
  }
  // add this info to PR
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });

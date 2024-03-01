import hardhat, { ethers, web3 } from "hardhat";
import vaultV7 from "../../artifacts/contracts/PRFCT/vaults/PrfctVaultV7.sol/PrfctVaultV7.json";
import vaultV7Factory from "../../artifacts/contracts/PRFCT/vaults/PrfctVaultV7Factory.sol/PrfctVaultV7Factory.json";
import stratAbi from "../../artifacts/contracts/PRFCT/strategies/GMX/StrategyGM.sol/StrategyGM.json";

const vaultParams = {
  mooName: "Moo Gmx WBTCb-USDC",
  mooSymbol: "mooGmxWBTCb-USDC",
  delay: 21600,
};

const admin = web3.utils.toChecksumAddress("0x004b2Cf6888630ABebB2DaD39faAD738655e98C7");

const strategyParams = {
  want: web3.utils.toChecksumAddress("0x47c031236e19d024b42f8AE6780E44A573170703"),
  native: web3.utils.toChecksumAddress("0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"),
  long: web3.utils.toChecksumAddress("0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f"),
  short: web3.utils.toChecksumAddress("0xaf88d065e77c8cC2239327C5EDb3A432268e5831"),
  exchange: web3.utils.toChecksumAddress("0x7C68C7866A64FA2160F78EEaE12217FFbf871fa8"),
  depositVault: web3.utils.toChecksumAddress("0xF89e77e8Dc11691C9e8757e84aaFbCD8A67d7A55"),

  unirouter: web3.utils.toChecksumAddress("0xCee843CD04E3758dDC5BCFf08647DddB117151D0"),
  strategist: admin,
  keeper: admin,
  prfctFeeRecipient: admin,
  prfctFeeConfig: "0x577E2F75A9412EbaE6c354D1c067D1d17fd675Fc",
  rewards: [web3.utils.toChecksumAddress("0x912CE59144191C1204E64559FE8253a0e49E6548")]
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

  let strat = await factory.callStatic.cloneContract("0x2e4BDe9B42663dff0EF2F6eC3543124DD66c471f"); //StrategyAuraSideChain
  let stratTx = await factory.cloneContract("0x2e4BDe9B42663dff0EF2F6eC3543124DD66c471f");
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
    strategyParams.native,
    strategyParams.long,
    strategyParams.short,
    strategyParams.exchange,
    strategyParams.depositVault,
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

  
  stratInitTx = await stratContract.setRewards(
    strategyParams.rewards
  );
  stratInitTx = await stratInitTx.wait();
  stratInitTx.status === 1
    ? console.log(`Reward Added with tx: ${stratInitTx.transactionHash}`)
    : console.log(`Reward Addition failed with tx: ${stratInitTx.transactionHash}`);
  
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });

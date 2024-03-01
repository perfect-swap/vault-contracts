const hardhat = require("hardhat");
const { addressBook } = require("blockchain-addressbook");
const { getImplementationAddress } = require("@openzeppelin/upgrades-core");

/**
 * Script used to deploy the basic infrastructure needed to run Prfct.
 */

const ethers = hardhat.ethers;

const {
  platforms: { 
    prfctfinance: {
      treasury,
      devMultisig,
      keeper,
      multicall,
    } },
  tokens: {
    PRFCT: { address: PRFCT },
    WNATIVE: { address: ETH },
  },
} = addressBook.aurora;

const TIMELOCK_ADMIN_ROLE = "0x5f58e3a2316349923ce3780f8d587db2d72378aed66a8261c916544fa6846ca5";
const STRAT_OWNER_DELAY = 21600;
const VAULT_OWNER_DELAY = 0;
const TRUSTED_EOA = "0x3Eb7fB70C03eC4AEEC97C6C6C1B59B014600b7F7";
const KEEPER = keeper;

const config = {
  prfct: null, // addressBook[chainName].tokens.PRFCT.address,
  wnative: null,
  rpc: "https://mainnet.optimism.io",
  chainName: "optimism",
  chainId: 10,
  devMultisig: "0x2c572743B345ED750907dC95D459dbeaC499D8CF",
  treasuryMultisig: "0x4ABa01FB8E1f6BFE80c56Deb367f19F35Df0f4aE",
  multicall: "0x820ae7BF39792D7ce7befC70B0172F4D267F1938",
  vaultOwner: null,
  stratOwner: null,
  treasury: "0x4ABa01FB8E1f6BFE80c56Deb367f19F35Df0f4aE",
  unirouterHasPrfctLiquidity: false,
  unirouter: ethers.constants.AddressZero,
  rewardPool: null,
};

const proposer = config.devMultisig || TRUSTED_EOA;
const timelockProposers = [proposer];
const timelockExecutors = [proposer, KEEPER];

const treasurer = config.treasuryMultisig || TRUSTED_EOA;

async function main() {
  await hardhat.run("compile");

  const deployer = await ethers.getSigner();

  const TimelockController = await ethers.getContractFactory("TimelockController");

  console.log("Checking if should deploy vault owner...");
  if (!config.vaultOwner) {
    console.log("Deploying vault owner.");
    let deployParams = [VAULT_OWNER_DELAY, timelockProposers, timelockExecutors];
    const vaultOwner = await TimelockController.deploy(...deployParams);
    await vaultOwner.deployed();
    await vaultOwner.renounceRole(TIMELOCK_ADMIN_ROLE, deployer.address);
    console.log(`Vault owner deployed to ${vaultOwner.address}`);
  } else {
    console.log(`Vault owner already deployed at ${config.vaultOwner}. Skipping...`);
  }

  console.log("Checking if should deploy strat owner...");
  if (!config.stratOwner) {
    console.log("Deploying strategy owner.");
    const stratOwner = await TimelockController.deploy(STRAT_OWNER_DELAY, timelockProposers, timelockExecutors);
    await stratOwner.deployed();
    await stratOwner.renounceRole(TIMELOCK_ADMIN_ROLE, deployer.address);
    console.log(`Strategy owner deployed to ${stratOwner.address}`);
  } else {
    console.log(`Strat owner already deployed at ${config.stratOwner}. Skipping...`);
  }

  console.log("Checking if should deploy treasury...");
  if (!config.treasury) {
    console.log("Deploying treasury.");
    const Treasury = await ethers.getContractFactory("PrfctTreasury");
    const treasury = await Treasury.deploy();
    await treasury.deployed();
    await treasury.transferOwnership(treasurer);
    console.log(`Treasury deployed to ${treasury.address}`);
  } else {
    console.log(`Treasury already deployed at ${config.treasury}. Skipping...`);
  }

  console.log("Checking if it should deploy a multicall contract...");
  if (!config.multicall) {
    console.log("Deploying multicall");
    const Multicall = await ethers.getContractFactory("Multicall");
    const multicall = await Multicall.deploy();
    await multicall.deployed();
    console.log(`Multicall deployed to ${multicall.address}`);
  } else {
    console.log(`There is already a multicall contract deployed at ${config.multicall}. Skipping.`);
  }

  console.log("Checking if it should deploy a Prfct reward pool...");
  if (!config.rewardPool && config.wnative && config.prfct) {
    console.log("Deploying reward pool.");
    const RewardPool = await ethers.getContractFactory("PrfctRewardPool");
    const rewardPool = await RewardPool.deploy(config.prfct, config.wnative);
    await rewardPool.deployed();
    console.log(`Reward pool deployed to ${rewardPool.address}`);
  } else {
    console.log("Skipping the prfct reward pool for now.");
  }

  console.log("Checking if it should deploy a fee batcher...");
  if (config.wnative && config.prfct) {
    console.log("Deploying fee batcher.");
    const provider = deployer.provider;
    const unirouterAddress = config.unirouterHasPrfctLiquidity ? config.unirouter : ethers.constants.AddressZero;

    // How do we do a fee batcher without a reward pool?
    const PrfctFeeBatch = await ethers.getContractFactory("PrfctFeeBatchV2");
    const batcher = await upgrades.deployProxy(PrfctFeeBatch, [
      config.prfct,
      config.wnative,
      config.treasury,
      config.rewardPool,
      unirouterAddress,
    ]);
    await batcher.deployed();

    const implementationAddr = await getImplementationAddress(provider, batcher.address);

    console.log(`Deployed proxy at ${batcher.address}`);
    console.log(`Deployed implementation at ${implementationAddr}`);

    await rewardPool.transferOwnership(batcher.address);
  } else {
    console.log("Shouldn't deploy a fee batcher as some of the required elements are missing.");
  }
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
  
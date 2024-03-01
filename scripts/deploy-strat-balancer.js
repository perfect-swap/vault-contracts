const hardhat = require("hardhat");

const ethers = hardhat.ethers;

async function main() {
  await hardhat.run("compile");

  ///////////////////////////////////////////////////////////////////////////////////////////////////////////////
  const StrategyAuraSideChain = await ethers.getContractFactory("StrategyAuraSideChain");

  console.log("Deploying: StrategyAuraSideChain");

  const strategyAuraSideChain = await StrategyAuraSideChain.deploy();
  await strategyAuraSideChain.deployed();

  console.log("StrategyAuraSideChain", strategyAuraSideChain.address);

  // await hardhat.run("verify:verify", {
  //   address: strategyAuraSideChain.address,
  //   constructorArguments: [],
  // })
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
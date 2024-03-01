const hardhat = require("hardhat");

const ethers = hardhat.ethers;

async function main() {
  await hardhat.run("compile");

  ///////////////////////////////////////////////////////////////////////////////////////////////////////////////
  const StrategyGM = await ethers.getContractFactory("StrategyGM");

  console.log("Deploying: StrategyGM");

  const strategyGM = await StrategyGM.deploy();
  await strategyGM.deployed();

  console.log("StrategyGM", strategyGM.address);

  await hardhat.run("verify:verify", {
    address: strategyGM.address,
    constructorArguments: [],
  })
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
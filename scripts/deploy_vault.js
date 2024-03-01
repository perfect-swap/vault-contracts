const hardhat = require("hardhat");

const ethers = hardhat.ethers;

async function main() {
  await hardhat.run("compile");

  ///////////////////////////////////////////////////////////////////////////////////////////////////////////////
  const PrfctVaultV7 = await ethers.getContractFactory("PrfctVaultV7");

  console.log("Deploying: PrfctVaultV7");

  const prfctVaultV7 = await PrfctVaultV7.deploy();
  await prfctVaultV7.deployed();

  console.log("PrfctVaultV7", prfctVaultV7.address);

  // await hardhat.run("verify:verify", {
  //   address: prfctVaultV7.address,
  //   constructorArguments: [],
  // })

  ///////////////////////////////////////////////////////////////////////////////////////////////////////////////
  const PrfctVaultV7Factory = await ethers.getContractFactory("PrfctVaultV7Factory");

  console.log("Deploying: PrfctVaultV7Factory");

  const args = [
    prfctVaultV7.address
  ]
  const prfctVaultV7Factory = await PrfctVaultV7Factory.deploy(...args);
  await prfctVaultV7Factory.deployed();

  console.log("PrfctVaultV7Factory", prfctVaultV7Factory.address);

  // await hardhat.run("verify:verify", {
  //   address: prfctVaultV7Factory.address,
  //   constructorArguments: [],
  // })

}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
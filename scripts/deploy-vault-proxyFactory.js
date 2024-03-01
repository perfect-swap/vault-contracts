const hardhat = require("hardhat");

const ethers = hardhat.ethers;

async function main() {
  await hardhat.run("compile");

  const PrfctVaultV7ProxyFactory = await ethers.getContractFactory("PrfctVaultV7ProxyFactory");

  console.log("Deploying: PrfctVaultV7ProxyFactory");

  const prfctVaultV7ProxyFactory = await PrfctVaultV7ProxyFactory.deploy();
  await prfctVaultV7ProxyFactory.deployed();

  console.log("PrfctVaultV7ProxyFactory", prfctVaultV7ProxyFactory.address);

  await hardhat.run("verify:verify", {
    address: prfctVaultV7ProxyFactory.address,
    constructorArguments: [],
  })
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
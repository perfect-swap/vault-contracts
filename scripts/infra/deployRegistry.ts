import hardhat, { ethers, upgrades } from "hardhat";
import { verifyContract } from "../../utils/verifyContract";

const shouldVerifyOnEtherscan = true;

const contractNames = {
  PrfctVaultRegistry: "PrfctRegistry",
};

const implementationConstructorArguments: any[] = []; // proxy implementations cannot have constructors

const deploy = async () => {
  const PrfctVaultRegistryFactory = await ethers.getContractFactory(contractNames.PrfctVaultRegistry)

  console.log("Deploying:", contractNames.PrfctVaultRegistry);

  const constructorArguments: any[] = [];
  const transparentUpgradableProxy = await upgrades.deployProxy(PrfctVaultRegistryFactory, constructorArguments);
  await transparentUpgradableProxy.deployed();

  const implementationAddress = await upgrades.erc1967.getImplementationAddress(transparentUpgradableProxy.address);

  console.log();
  console.log("TransparentUpgradableProxy:", transparentUpgradableProxy.address);
  console.log(`Implementation address (${contractNames.PrfctVaultRegistry}):`, implementationAddress);

  console.log();
  console.log("Running post deployment");

  const verifyContractsPromises: Promise<any>[] = [];
  if (shouldVerifyOnEtherscan) {
    console.log(`Verifying ${contractNames.PrfctVaultRegistry}`);
    verifyContractsPromises.push(verifyContract(implementationAddress, implementationConstructorArguments));
  }
  console.log();

  await Promise.all(verifyContractsPromises);
};

deploy()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });

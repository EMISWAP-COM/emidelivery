const { ethers, network } = require("hardhat");
const hre = require("hardhat");
const { constants, Contract, Signer, utils } = require("ethers");
const { makeid, timeout } = require("../utils/utils");

async function main() {
  const [deployer] = await ethers.getSigners();  
  const TIME_OUT = 8000;
  const emideliveryPROXYAddr = process.env.PROXYADDRESS;

  console.log("Deployer wallet: ", deployer.address);
  console.log("Deployer balance:", (await deployer.getBalance()).toString());

  const EMIDELIVERY = await ethers.getContractFactory("emidelivery");
  const upgraded = await upgrades.upgradeProxy(emideliveryPROXYAddr, EMIDELIVERY);
  console.log("upgraded", upgraded.address);
  await timeout(TIME_OUT);
  emideliveryImpl = await upgrades.erc1967.getImplementationAddress(emideliveryPROXYAddr);
  console.log("new emideliveryImpl deployed to:", emideliveryImpl);

  //verification
  await hre.run("verify:verify", {
    address: emideliveryImpl,
    constructorArguments: [],
  });
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
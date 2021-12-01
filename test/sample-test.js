const { expect } = require("chai");
const { ethers } = require("hardhat");

const CLAIM_TIMEOUT = 300;

describe("emidelivery", function () {
    let esw;
    before(async () => {
        [deployer, owner, Alice, Bob, Clarc] = await ethers.getSigners();
    });

    it("Should return the new greeting once it's changed", async function () {
        const MOCKESW = await ethers.getContractFactory("MockESW");
        esw = await MOCKESW.deploy();
        await esw.deployed();

        EMIDELIVERY = await ethers.getContractFactory("emidelivery");
        EmiDelivery = await upgrades.deployProxy(EMIDELIVERY, [esw.address, owner.address, CLAIM_TIMEOUT]);

        await EmiDelivery.deployed();
    });
});

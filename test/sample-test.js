const { expect } = require("chai");
const { ethers } = require("hardhat");
const { tokens } = require("../utils/utils");
const Wallet = require("ethereumjs-wallet");

const CLAIM_TIMEOUT = 300;
const CLAIM_DAILY_LIMIT = tokens(50_000);
const INIT_SUPPLY = tokens(10_000_000_000);

async function deposite(delivery, wallet) {
    await delivery.connect(wallet).deposite(INIT_SUPPLY);
}

describe("emidelivery", function () {
    let esw, EmiDelivery, SigWallet, SigWallet_PrivateKey;
    before(async () => {
        [deployer, owner, Alice, Bob, Clarc] = await ethers.getSigners();
        const wallet = Wallet.generate();
        SigWallet = wallet.getAddressString();
        SigWallet_PrivateKey = wallet.getPrivateKeyString();
    });

    this.beforeEach(async () => {
        const MOCKESW = await ethers.getContractFactory("MockESW");
        esw = await MOCKESW.deploy(INIT_SUPPLY);
        await esw.deployed();

        EMIDELIVERY = await ethers.getContractFactory("emidelivery");
        EmiDelivery = await upgrades.deployProxy(EMIDELIVERY, [
            SigWallet,
            esw.address,
            owner.address,
            CLAIM_TIMEOUT,
            CLAIM_DAILY_LIMIT,
        ]);

        await EmiDelivery.deployed();

        await esw.transfer(owner.address, await esw.balanceOf(deployer.address));
        await esw.connect(owner).approve(EmiDelivery.address, await esw.balanceOf(owner.address));
    });

    it("owner deposite/withdraw", async function () {
        await deposite(EmiDelivery, owner);
        expect(await esw.balanceOf(EmiDelivery.address)).to.be.equal(INIT_SUPPLY);

        await EmiDelivery.connect(owner).withdraw(INIT_SUPPLY);
        expect(await esw.balanceOf(owner.address)).to.be.equal(INIT_SUPPLY);
    });

    it("claim request", async function () {
        await deposite(EmiDelivery, owner);
        console.log("totalSupply()", (await EmiDelivery.totalSupply()).toString());
        console.log("claimDailyLimit()", (await EmiDelivery.claimDailyLimit()).toString());

        let nextNonce = await EmiDelivery.connect(Alice).getWalletNonce();
        nextNonce++;
        console.log("nextNonce", nextNonce.toString());

        let claimRequest = tokens(60_000);

        let hash = await web3.utils.soliditySha3(Alice.address, claimRequest, nextNonce, EmiDelivery.address);
        //console.log("hash", hash, SigWallet_PrivateKey);

        SigObject = await web3.eth.accounts.sign(hash, SigWallet_PrivateKey);
        //console.log("SigObject", SigObject);

        let SigWallet_recovered = await web3.eth.accounts.recover(SigObject);
        //console.log("SigWallet_recovered", SigWallet_recovered);

        expect(SigWallet_recovered.toUpperCase()).to.be.equal(SigWallet.toUpperCase());
        //console.log("SigWallet", SigWallet, "Alice", Alice.address, "EmiDelivery", EmiDelivery.address);

        let resTx = await EmiDelivery.connect(Alice).request(
            Alice.address,
            claimRequest,
            nextNonce,
            SigObject.signature
        );

        //console.log("resTx", resTx);

        console.log((await EmiDelivery.totalSupply()).toString());
        let AvailableToCollect = await EmiDelivery.connect(Alice).getAvailableToCollect();
        console.log(AvailableToCollect);
        let lockedForRequests = await EmiDelivery.lockedForRequests();
        console.log("lockedForRequests", lockedForRequests);
    });

    it("claim", async function () {
        //console.log("esw %s EmiDelivery %s", esw.address, EmiDelivery.address);
    });
});

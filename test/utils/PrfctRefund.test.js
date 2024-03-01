const { expect } = require("chai");

describe("PrfctRefund", () => {
  const pricePerFullShare = ethers.BigNumber.from("1500000000000000000");
  const burnAddr = "0x000000000000000000000000000000000000dEaD";

  const setup = async () => {
    const [signer, other] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("TestToken");
    const token = await Token.deploy("10000", "Test Token", "TEST");
    const mootoken = await Token.deploy("10000", "Test Moo Token", "mooTEST");

    const PrfctRefund = await ethers.getContractFactory("PrfctRefund");
    const prfctRefund = await PrfctRefund.deploy(token.address, mootoken.address, pricePerFullShare);

    return { signer, other, token, mootoken, prfctRefund };
  };

  it("Initializes the contract correctly", async () => {
    const { token, mootoken, prfctRefund } = await setup();

    expect(await prfctRefund.token()).to.equal(token.address);
    expect(await prfctRefund.mootoken()).to.equal(mootoken.address);
    expect(await prfctRefund.pricePerFullShare()).to.equal(pricePerFullShare);
  });

  it("Refunds nothing if you send it 0 shares", async () => {
    const { other, token, prfctRefund } = await setup();
    await token.transfer(prfctRefund.address, 150);

    const balanceBefore = await token.balanceOf(prfctRefund.address);
    await prfctRefund.connect(other).refund();
    const balanceAfter = await token.balanceOf(prfctRefund.address);

    expect(balanceBefore).to.equal(balanceAfter);
  });

  it("Refunds the correct number of token per share", async () => {
    const { other, token, mootoken, prfctRefund } = await setup();
    const userShares = 100;
    await token.transfer(prfctRefund.address, 500);
    await mootoken.transfer(other.address, userShares);

    const balTokenBefore = await token.balanceOf(other.address);
    const balMootokenBefore = await mootoken.balanceOf(other.address);
    const balRefunderBefore = await token.balanceOf(prfctRefund.address);

    await mootoken.connect(other).approve(prfctRefund.address, userShares);
    await prfctRefund.connect(other).refund();

    const balTokenAfter = await token.balanceOf(other.address);
    const balMootokenAfter = await mootoken.balanceOf(other.address);
    const balRefunderAfter = await token.balanceOf(prfctRefund.address);

    const expectedRefund = pricePerFullShare.mul(userShares).div("1000000000000000000");
    expect(balTokenAfter).to.equal(balTokenBefore.add(expectedRefund));
    expect(balMootokenAfter).to.equal(balMootokenBefore.sub(userShares));
    expect(balRefunderAfter).to.equal(balRefunderBefore.sub(expectedRefund));
  });

  it("Burns the shares by sending them to 0xdead", async () => {
    const { other, token, mootoken, prfctRefund } = await setup();
    const userShares = 100;
    await token.transfer(prfctRefund.address, 500);
    await mootoken.transfer(other.address, userShares);

    const balMooBefore = await mootoken.balanceOf(other.address);
    const balBurnBefore = await mootoken.balanceOf(burnAddr);

    await mootoken.connect(other).approve(prfctRefund.address, userShares);
    await prfctRefund.connect(other).refund();

    const balMooAfter = await mootoken.balanceOf(other.address);
    const balBurnAfter = await mootoken.balanceOf(burnAddr);

    expect(balMooAfter).to.equal(balMooBefore.sub(userShares));
    expect(balBurnAfter).to.equal(balBurnBefore.add(userShares));
  });
});

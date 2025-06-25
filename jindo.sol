const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with:", deployer.address);

  const totalSupply = hre.ethers.utils.parseEther("180000000000000");

  const devWallet = "YOUR_DEV_WALLET";
  const treasuryWallet = "YOUR_TREASURY_WALLET";
  const liquidityWallet = "YOUR_LIQUIDITY_WALLET";

  const JINDO = await hre.ethers.getContractFactory("JINDO");
  const jindo = await JINDO.deploy(devWallet, treasuryWallet, liquidityWallet);
  await jindo.deployed();
  console.log("JINDO deployed to:", jindo.address);

  const vestAmount = hre.ethers.utils.parseEther("18000000000000"); // 10%
  const vestDuration = 60 * 60 * 24 * 90; // 90 days

  const Vesting = await hre.ethers.getContractFactory("JINDOVesting");
  const vesting = await Vesting.deploy(jindo.address, vestAmount, vestDuration);
  await vesting.deployed();
  console.log("Vesting contract deployed to:", vesting.address);

  // Transfer 10% of JINDO to vesting contract
  const tx = await jindo.transfer(vesting.address, vestAmount);
  await tx.wait();
  console.log("Transferred 10% to vesting contract");
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

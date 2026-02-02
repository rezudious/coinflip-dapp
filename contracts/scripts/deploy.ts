import hre from "hardhat";
import { ethers } from "hardhat";

// Chainlink VRF v2.5 — Base Sepolia (docs.chain.link/vrf/v2-5/supported-networks)
const VRF_COORDINATOR = "0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE";
const KEY_HASH =
  "0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71";

// Recommended flat fee per game (used when creators call createGame(betAmount, flatFee))
const RECOMMENDED_FLAT_FEE_ETH = "0.001";

async function main() {
  const subscriptionId = process.env.VRF_SUBSCRIPTION_ID;
  if (!subscriptionId) {
    throw new Error(
      "VRF_SUBSCRIPTION_ID not set. Create a subscription at https://vrf.chain.link and add it to .env"
    );
  }

  const [deployer] = await ethers.getSigners();
  console.log("Deploying CoinFlip with account:", deployer.address);
  console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH");

  const CoinFlip = await ethers.getContractFactory("CoinFlip");
  const coinFlip = await CoinFlip.deploy(
    VRF_COORDINATOR,
    subscriptionId,
    KEY_HASH
  );

  await coinFlip.waitForDeployment();
  const address = await coinFlip.getAddress();

  console.log("CoinFlip deployed to:", address);
  console.log("Recommended flat fee when creating games:", RECOMMENDED_FLAT_FEE_ETH, "ETH");
  console.log("");
  console.log("Next steps:");
  console.log("1. Add this contract as a consumer in your VRF subscription at https://vrf.chain.link");
  console.log("2. Verify on BaseScan (run below if BASESCAN_API_KEY is set):");
  console.log(`   npx hardhat verify --network baseSepolia ${address} ${VRF_COORDINATOR} ${subscriptionId} ${KEY_HASH}`);

  // Verify on BaseScan if API key is set
  if (process.env.BASESCAN_API_KEY) {
    console.log("\nVerifying contract on BaseScan...");
    try {
      await hre.run("verify:verify", {
        address,
        constructorArguments: [VRF_COORDINATOR, subscriptionId, KEY_HASH],
      });
      console.log("Contract verified successfully.");
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      if (message.includes("Already Verified")) {
        console.log("Contract is already verified.");
      } else {
        console.error("Verification failed:", message);
      }
    }
  } else {
    console.log("\nSkipping verification (BASESCAN_API_KEY not set).");
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });

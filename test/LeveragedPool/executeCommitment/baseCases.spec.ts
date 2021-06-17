import { ethers } from "hardhat";
import chai from "chai";
import chaiAsPromised from "chai-as-promised";
import {
  PoolSwapLibrary,
  LeveragedPool,
  TestToken,
  ERC20,
} from "../../../typechain";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { POOL_CODE } from "../../constants";
import {
  getEventArgs,
  deployPoolAndTokenContracts,
  getRandomInt,
  generateRandomAddress,
  createCommit,
  CommitEventArgs,
  timeout,
} from "../../utilities";
import { BytesLike } from "ethers";

chai.use(chaiAsPromised);
const { expect } = chai;

const amountCommitted = ethers.utils.parseEther("2000");
const amountMinted = ethers.utils.parseEther("10000");
const feeAddress = generateRandomAddress();
const lastPrice = getRandomInt(99999999, 1);
const updateInterval = 2;
const frontRunningInterval = 1; // seconds
const fee = "0x00000000000000000000000000000000";
const leverage = 2;
let imbalance: BytesLike;
const commitType = [2]; //long mint;

describe("LeveragedPool - executeCommitment: Basic test cases", () => {
  let token: TestToken;
  let pool: LeveragedPool;
  let library: PoolSwapLibrary;
  let signers: SignerWithAddress[];

  describe("Revert cases", () => {
    before(async () => {
      const result = await deployPoolAndTokenContracts(
        POOL_CODE,
        lastPrice,
        10,
        5,
        fee,
        leverage,
        feeAddress,
        amountMinted
      );
      pool = result.pool;
      signers = result.signers;
      token = result.token;
      library = result.library;
      imbalance = await library.getRatio(
        ethers.utils.parseEther("50"),
        ethers.utils.parseEther("10")
      );
    });
    it("should revert if the commitment is too new", async () => {
      await token.approve(pool.address, amountCommitted);
      const commit = await createCommit(
        pool,
        commitType,
        imbalance,
        amountCommitted
      );
      await expect(
        pool.executeCommitment([commit.commitID])
      ).to.be.rejectedWith(Error);
    });
    it("should revert if the max imbalance is less than the current imbalance of the pairs", async () => {
      await token.approve(pool.address, amountCommitted.mul(2));
      const commit = await createCommit(
        pool,
        commitType,
        imbalance,
        amountCommitted
      );
      await timeout(6000); // wait six seconds
      await pool.executePriceChange(5);
      await pool.executeCommitment([commit.commitID]);
      const commit2 = await createCommit(
        pool,
        commitType,
        imbalance,
        amountCommitted
      );
      await expect(
        pool.executeCommitment([commit2.commitID])
      ).to.be.rejectedWith(Error);
    });
    it("should revert if the commitment doesn't exist", async () => {
      await expect(pool.executeCommitment([9])).to.be.rejectedWith(Error);
    });
  });

  describe("Single commitment", () => {
    let commit: CommitEventArgs;
    beforeEach(async () => {
      const result = await deployPoolAndTokenContracts(
        POOL_CODE,
        lastPrice,
        updateInterval,
        frontRunningInterval,
        fee,
        leverage,
        feeAddress,
        amountMinted
      );
      pool = result.pool;
      signers = result.signers;
      token = result.token;
      library = result.library;

      imbalance = await library.getRatio(
        ethers.utils.parseEther("5"),
        ethers.utils.parseEther("2")
      );

      await token.approve(pool.address, amountCommitted);
      commit = await createCommit(pool, commitType, imbalance, amountCommitted);
    });

    it("should remove the commitment after execution", async () => {
      expect((await pool.commits(commit.commitID)).amount).to.eq(
        amountCommitted
      );
      await timeout(2000);
      await pool.executePriceChange(9);
      await pool.executeCommitment([commit.commitID]);
      expect((await pool.commits(commit.commitID)).amount).to.eq(0);
    });
    it("should emit an event for commitment removal", async () => {
      await timeout(2000);
      await pool.executePriceChange(9);
      const receipt = await (
        await pool.executeCommitment([commit.commitID])
      ).wait();
      expect(getEventArgs(receipt, "ExecuteCommit")?.commitID).to.eq(
        commit.commitID
      );
    });
    it("should allow anyone to execute a commitment", async () => {
      await timeout(2000);
      await pool.executePriceChange(9);
      await pool.connect(signers[1]).executeCommitment([commit.commitID]);
      expect((await pool.commits(commit.commitID)).amount).to.eq(0);
    });
  });
});
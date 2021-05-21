import { ethers } from "hardhat";
import chai from "chai";
import chaiAsPromised from "chai-as-promised";
import {
  PoolKeeper__factory,
  PoolKeeper,
  OracleWrapper__factory,
  OracleWrapper,
} from "../../typechain";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { MARKET, ORACLE, OPERATOR_ROLE, ADMIN_ROLE } from "../constants";

chai.use(chaiAsPromised);
const { expect } = chai;

describe("PoolKeeper - createMarket", () => {
  let poolKeeper: PoolKeeper;
  let oracleWrapper: OracleWrapper;
  let signers: SignerWithAddress[];
  beforeEach(async () => {
    // Deploy the contracts
    signers = await ethers.getSigners();

    const oracleWrapperFactory = (await ethers.getContractFactory(
      "OracleWrapper",
      signers[0]
    )) as OracleWrapper__factory;
    oracleWrapper = await oracleWrapperFactory.deploy();
    await oracleWrapper.deployed();

    const poolKeeperFactory = (await ethers.getContractFactory(
      "PoolKeeper",
      signers[0]
    )) as PoolKeeper__factory;
    poolKeeper = await poolKeeperFactory.deploy(oracleWrapper.address);
    await poolKeeper.deployed();

    await oracleWrapper.grantRole(
      ethers.utils.keccak256(ethers.utils.toUtf8Bytes(OPERATOR_ROLE)),
      poolKeeper.address
    );

    // Sanity check the deployment
    expect(
      await poolKeeper.hasRole(
        ethers.utils.keccak256(ethers.utils.toUtf8Bytes(ADMIN_ROLE)),
        signers[0].address
      )
    ).to.eq(true);
    expect(
      await poolKeeper.hasRole(
        ethers.utils.keccak256(ethers.utils.toUtf8Bytes(OPERATOR_ROLE)),
        signers[0].address
      )
    ).to.eq(true);
    expect(
      await oracleWrapper.hasRole(
        ethers.utils.keccak256(ethers.utils.toUtf8Bytes(ADMIN_ROLE)),
        signers[0].address
      )
    ).to.eq(true);
  });

  it("should create a pool in the given market", async () => {});

  it("should emit an event containing the details of the new pool", async () => {});

  it("should add the pool to the list of pools", async () => {});

  it("should revert if the market doesn't exist", async () => {});

  it("should revert if the pool already exists", async () => {});

  it("should revert if quoteToken parameter is the zero address", async () => {});

  it("should revert if the fee address is the zero address", async () => {});

  it("should revert if the front running interval is larger than the update interval", async () => {});
});

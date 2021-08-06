import { ethers } from "hardhat"
import chai from "chai"
import chaiAsPromised from "chai-as-promised"
import {
    PoolKeeper__factory,
    PoolKeeper,
    PoolSwapLibrary__factory,
    PoolFactory__factory,
    TestOracleWrapper__factory,
    TestChainlinkOracle__factory,
    TestOracleWrapper,
    PoolFactory,
} from "../../typechain"

import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers"
import { OPERATOR_ROLE, ADMIN_ROLE, POOL_CODE, MARKET_CODE } from "../constants"
import { generateRandomAddress } from "../utilities"

chai.use(chaiAsPromised)
const { expect } = chai

let deploymentData: any

describe("PoolKeeper - createPool", () => {
    let poolKeeper: PoolKeeper
    let factory: PoolFactory
    let signers: SignerWithAddress[]
    beforeEach(async () => {
        // Deploy the contracts
        signers = await ethers.getSigners()

        const chainlinkOracleFactory = (await ethers.getContractFactory(
            "TestChainlinkOracle",
            signers[0]
        )) as TestChainlinkOracle__factory
        const chainlinkOracle = await chainlinkOracleFactory.deploy()

        // Deploy tokens
        const oracleWrapperFactory = (await ethers.getContractFactory(
            "TestOracleWrapper",
            signers[0]
        )) as TestOracleWrapper__factory
        const oracleWrapper = await oracleWrapperFactory.deploy(
            chainlinkOracle.address
        )
        await oracleWrapper.deployed()

        const libraryFactory = (await ethers.getContractFactory(
            "PoolSwapLibrary",
            signers[0]
        )) as PoolSwapLibrary__factory
        const library = await libraryFactory.deploy()
        await library.deployed()
        const poolKeeperFactory = (await ethers.getContractFactory(
            "PoolKeeper",
            {
                signer: signers[0],
            }
        )) as PoolKeeper__factory
        const PoolFactory = (await ethers.getContractFactory("PoolFactory", {
            signer: signers[0],
            libraries: { PoolSwapLibrary: library.address },
        })) as PoolFactory__factory
        factory = await (await PoolFactory.deploy()).deployed()
        poolKeeper = await poolKeeperFactory.deploy(factory.address)
        await poolKeeper.deployed()
        await oracleWrapper.grantRole(
            ethers.utils.keccak256(ethers.utils.toUtf8Bytes(OPERATOR_ROLE)),
            poolKeeper.address
        )

        await factory.setPoolKeeper(poolKeeper.address)

        // Sanity check the deployment
        expect(
            await poolKeeper.hasRole(
                ethers.utils.keccak256(ethers.utils.toUtf8Bytes(ADMIN_ROLE)),
                signers[0].address
            )
        ).to.eq(true)

        expect(await oracleWrapper.isAdmin(signers[0].address)).to.eq(true)
        deploymentData = {
            owner: poolKeeper.address,
            poolCode: POOL_CODE,
            frontRunningInterval: 5,
            updateInterval: 10,
            fee: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5],
            leverageAmount: 5,
            feeAddress: generateRandomAddress(),
            quoteToken: generateRandomAddress(),
            oracleWrapper: oracleWrapper.address,
        }
    })

    it("should create a new pool in the given market", async () => {
        const receipt = await (await factory.deployPool(deploymentData)).wait()
        const event = receipt?.events?.find((el) => el.event === "DeployPool")
        expect(!!(await signers[0].provider?.getCode(event?.args?.pool))).to.eq(
            true
        )
    })

    it("should emit an event containing the details of the new pool", async () => {
        const receipt = await (await factory.deployPool(deploymentData)).wait()
        const event = receipt?.events?.find((el) => el.event === "DeployPool")
        expect(!!event).to.eq(true)
        expect(!!event?.args?.pool).to.eq(true)
    })

    it("should revert if the pool already exists", async () => {
        await (await factory.deployPool(deploymentData)).wait()
        await expect(factory.deployPool(deploymentData)).to.be.rejectedWith(
            Error
        )
    })
})

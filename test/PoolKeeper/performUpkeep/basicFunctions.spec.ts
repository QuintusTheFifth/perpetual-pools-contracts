import { ethers } from "hardhat"
import chai from "chai"
import chaiAsPromised from "chai-as-promised"
import { generateRandomAddress, getEventArgs, timeout } from "../../utilities"

import { MARKET_2, POOL_CODE } from "../../constants"
import {
    PoolFactory__factory,
    PoolKeeper,
    PoolKeeper__factory,
    PoolSwapLibrary__factory,
    TestChainlinkOracle__factory,
    TestOracleWrapper,
    TestOracleWrapper__factory,
    TestToken__factory,
} from "../../../typechain"
import { MARKET, POOL_CODE_2 } from "../../constants"
import { BigNumber } from "ethers"
import { Result } from "ethers/lib/utils"
import { count } from "console"

chai.use(chaiAsPromised)
const { expect } = chai

let quoteToken: string
let oracleWrapper: TestOracleWrapper
let poolKeeper: PoolKeeper

const updateInterval = 10

const setupHook = async () => {
    const signers = await ethers.getSigners()

    // Deploy quote token
    const testToken = (await ethers.getContractFactory(
        "TestToken",
        signers[0]
    )) as TestToken__factory
    const token = await testToken.deploy("TEST TOKEN", "TST1")
    await token.deployed()
    await token.mint(10000, signers[0].address)
    quoteToken = token.address

    const chainlinkOracleFactory = (await ethers.getContractFactory(
        "TestChainlinkOracle",
        signers[0]
    )) as TestChainlinkOracle__factory
    const chainlinkOracle = await chainlinkOracleFactory.deploy()

    // Deploy oracle. Using a test oracle for predictability
    const oracleWrapperFactory = (await ethers.getContractFactory(
        "TestOracleWrapper",
        signers[0]
    )) as TestOracleWrapper__factory
    oracleWrapper = await oracleWrapperFactory.deploy(chainlinkOracle.address)
    await oracleWrapper.deployed()

    // Deploy pool keeper
    const libraryFactory = (await ethers.getContractFactory(
        "PoolSwapLibrary",
        signers[0]
    )) as PoolSwapLibrary__factory
    const library = await libraryFactory.deploy()
    await library.deployed()
    const poolKeeperFactory = (await ethers.getContractFactory("PoolKeeper", {
        signer: signers[0],
    })) as PoolKeeper__factory
    const PoolFactory = (await ethers.getContractFactory("PoolFactory", {
        signer: signers[0],
        libraries: { PoolSwapLibrary: library.address },
    })) as PoolFactory__factory
    const factory = await (await PoolFactory.deploy()).deployed()
    poolKeeper = await poolKeeperFactory.deploy(factory.address)
    await poolKeeper.deployed()
    await factory.setPoolKeeper(poolKeeper.address)

    await oracleWrapper.incrementPrice()
    // Create pool
    const deploymentData = {
        owner: poolKeeper.address,
        keeper: poolKeeper.address,
        poolCode: POOL_CODE,
        frontRunningInterval: 1,
        updateInterval: updateInterval,
        fee: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        leverageAmount: 1,
        feeAddress: generateRandomAddress(),
        quoteToken: quoteToken,
        oracleWrapper: oracleWrapper.address,
    }
    await (await factory.deployPool(deploymentData)).wait()

    await oracleWrapper.incrementPrice()
    const deploymentData2 = {
        owner: poolKeeper.address,
        keeper: poolKeeper.address,
        poolCode: POOL_CODE_2,
        frontRunningInterval: 1,
        updateInterval: updateInterval,
        fee: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        leverageAmount: 2,
        feeAddress: generateRandomAddress(),
        quoteToken: quoteToken,
        oracleWrapper: oracleWrapper.address,
    }
    await (await factory.deployPool(deploymentData2)).wait()
}
const callData = [POOL_CODE, POOL_CODE_2]

interface Upkeep {
    cumulativePrice: BigNumber
    lastSamplePrice: BigNumber
    executionPrice: BigNumber
    lastExecutionPrice: BigNumber
    count: number
    updateInterval: number
    roundStart: number
}
describe("PoolKeeper - performUpkeep: basic functionality", () => {
    let oldRound: Upkeep
    let newRound: Upkeep
    let oldExecutionPrice: BigNumber
    let newExecutionPrice: BigNumber
    let oldLastExecutionPrice: BigNumber
    let newLastExecutionPrice: BigNumber
    let oldRoundStart: BigNumber
    let newRoundStart: BigNumber
    describe("Base cases", () => {
        beforeEach(setupHook)
        it("should not revert if performData is invalid", async () => {
            await poolKeeper.performUpkeepMultiplePools([
                "INVALID",
                POOL_CODE,
                POOL_CODE_2,
            ])
        })
    })

    describe("Upkeep - Price execution", () => {
        let event: Result | undefined
        let lastTime: BigNumber
        before(async () => {
            await setupHook()
            // process a few upkeeps
            lastTime = await poolKeeper.lastExecutionTime(POOL_CODE)
            await oracleWrapper.incrementPrice()
            await timeout(updateInterval * 1000 + 1000)
            const result = await (
                await poolKeeper.performUpkeepMultiplePools(callData)
            ).wait()
            oldExecutionPrice = await poolKeeper.executionPrice(POOL_CODE)
            oldLastExecutionPrice = await poolKeeper.lastExecutionPrice(
                POOL_CODE
            )
            event = getEventArgs(result, "ExecutePriceChange")
        })
        it("should emit an event with the details", async () => {
            expect(event?.updateInterval).to.eq(updateInterval)
            expect(event?.oldPrice).to.eq(oldLastExecutionPrice)
            expect(event?.newPrice).to.eq(oldExecutionPrice)
            expect(event?.pool).to.eq(POOL_CODE)
        })
        it("should set last execution time", async () => {
            expect(
                (await poolKeeper.lastExecutionTime(POOL_CODE)).gt(
                    BigNumber.from(lastTime)
                )
            ).to.equal(true)
        })
    })

    describe("Upkeep - New round", () => {
        before(async () => {
            // Check starting conditions
            await setupHook()
            // process a few upkeeps
            await oracleWrapper.incrementPrice()

            oldRoundStart = await poolKeeper.poolRoundStart(POOL_CODE)
            oldExecutionPrice = await poolKeeper.executionPrice(POOL_CODE)
            // delay and upkeep again
            await timeout(updateInterval * 1000 + 1000)

            await poolKeeper.performUpkeepMultiplePools(callData)
            newExecutionPrice = await poolKeeper.executionPrice(POOL_CODE)
            newLastExecutionPrice = await poolKeeper.lastExecutionPrice(
                POOL_CODE
            )
            newRoundStart = await poolKeeper.poolRoundStart(POOL_CODE)
        })
        it("should clear the old round data", async () => {
            const price = ethers.utils.parseEther(
                (await oracleWrapper.getPrice()).toString()
            )
            expect(newRoundStart.gt(oldRoundStart)).to.equal(true)
            expect(newExecutionPrice.gt(oldExecutionPrice)).to.equal(true)
            expect(newExecutionPrice).to.equal(price)
        })
        it("should calculate a new execution price", async () => {
            expect(newLastExecutionPrice).to.eq(oldExecutionPrice)
            expect(newExecutionPrice.gt(oldExecutionPrice)).to.equal(true)
        })
    })
})

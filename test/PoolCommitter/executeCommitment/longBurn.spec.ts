import { ethers } from "hardhat"
import chai from "chai"
import chaiAsPromised from "chai-as-promised"
import {
    LeveragedPool,
    TestToken,
    ERC20,
    PoolSwapLibrary,
    PoolCommitter,
} from "../../../types"
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers"
import {
    DEFAULT_FEE,
    DEFAULT_MINT_AMOUNT,
    LONG_BURN,
    LONG_MINT,
    POOL_CODE,
} from "../../constants"
import {
    deployPoolAndTokenContracts,
    generateRandomAddress,
    createCommit,
    CommitEventArgs,
    timeout,
    getCurrentTotalCommit,
} from "../../utilities"

chai.use(chaiAsPromised)
const { expect } = chai

const amountCommitted = ethers.utils.parseEther("2000")
const amountMinted = ethers.BigNumber.from(DEFAULT_MINT_AMOUNT)
const feeAddress = generateRandomAddress()
const updateInterval = 200
const frontRunningInterval = 100 // seconds
const fee = DEFAULT_FEE
const leverage = 2

describe("LeveragedPool - executeCommitment: Long Burn", () => {
    let token: TestToken

    let longToken: ERC20
    let poolCommitter: PoolCommitter
    let pool: LeveragedPool
    let signers: SignerWithAddress[]
    let commit: CommitEventArgs
    let library: PoolSwapLibrary
    describe("Long Burn", () => {
        beforeEach(async () => {
            const result = await deployPoolAndTokenContracts(
                POOL_CODE,
                frontRunningInterval,
                updateInterval,
                leverage,
                feeAddress,
                fee
            )
            pool = result.pool
            signers = result.signers
            token = result.token
            library = result.library
            longToken = result.longToken
            poolCommitter = result.poolCommitter
            await pool.setKeeper(signers[0].address)
            await token.approve(pool.address, amountMinted)
            commit = await createCommit(
                poolCommitter,
                [LONG_MINT],
                amountCommitted
            )
            await timeout(updateInterval * 1000)
            await pool.poolUpkeep(9, 10)
            await poolCommitter.claim(signers[0].address)
            await longToken.approve(pool.address, amountCommitted)
            commit = await createCommit(
                poolCommitter,
                [LONG_BURN],
                amountCommitted
            )
        })
        it("should adjust the live long pool balance", async () => {
            expect(await pool.longBalance()).to.eq(amountCommitted)
            await timeout(updateInterval * 1000)
            await pool.poolUpkeep(9, 10)
            await poolCommitter.claim(signers[0].address)
            expect(await pool.longBalance()).to.eq(0)
        })
        it("should reduce the shadow long burn pool balance", async () => {
            expect(
                (await getCurrentTotalCommit(poolCommitter)).longBurnAmount
            ).to.equal(amountCommitted)
            await timeout(updateInterval * 1000)
            await pool.poolUpkeep(9, 10)
            expect(
                await (
                    await getCurrentTotalCommit(poolCommitter)
                ).longBurnAmount
            ).to.eq(0)
        })
        it("should transfer quote tokens to the commit owner", async () => {
            expect(await token.balanceOf(signers[0].address)).to.eq(
                amountMinted.sub(amountCommitted)
            )
            await timeout(updateInterval * 1000)
            await pool.poolUpkeep(9, 10)
            await poolCommitter.claim(signers[0].address)
            expect(await token.balanceOf(signers[0].address)).to.eq(
                amountMinted
            )
        })
    })
})

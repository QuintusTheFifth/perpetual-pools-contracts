// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "../interfaces/IPoolCommitter.sol";
import "../interfaces/ILeveragedPool.sol";
import "./PoolToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./PoolSwapLibrary.sol";
import "../interfaces/IOracleWrapper.sol";

/*
@title The pool controller contract
*/
contract PoolCommitter is IPoolCommitter, Ownable {
    // #### Globals

    address public leveragedPool;

    // MAX_INT
    uint128 public constant NO_COMMITS_REMAINING = type(uint128).max;
    uint128 public earliestCommitUnexecuted = NO_COMMITS_REMAINING;
    uint128 public latestCommitUnexecuted;
    uint128 public commitIDCounter;
    mapping(uint128 => Commit) public commits;
    mapping(uint256 => uint112) public shadowPools;

    address public factory;

    constructor(address _factory) {
        // set the factory on deploy
        factory = _factory;
    }

    function commit(CommitType commitType, uint112 amount) external override {
        require(amount > 0, "Amount must not be zero");
        uint128 currentCommitIDCounter = commitIDCounter;
        commitIDCounter = currentCommitIDCounter + 1;

        // create commitment
        commits[currentCommitIDCounter] = Commit({
            commitType: commitType,
            amount: amount,
            owner: msg.sender,
            created: uint40(block.timestamp)
        });
        uint256 _commitType = commitTypeToUint(commitType);
        shadowPools[_commitType] = shadowPools[_commitType] + amount;

        if (earliestCommitUnexecuted == NO_COMMITS_REMAINING) {
            earliestCommitUnexecuted = currentCommitIDCounter;
        }
        latestCommitUnexecuted = currentCommitIDCounter;

        emit CreateCommit(currentCommitIDCounter, amount, commitType);

        // pull in tokens
        if (commitType == CommitType.LongMint || commitType == CommitType.ShortMint) {
            // minting: pull in the quote token from the commiter
            ILeveragedPool(leveragedPool).quoteTokenTransferFrom(msg.sender, leveragedPool, amount);
        } else if (commitType == CommitType.LongBurn) {
            // long burning: pull in long pool tokens from commiter
            ILeveragedPool(leveragedPool).burnTokens(0, amount, msg.sender);
        } else if (commitType == CommitType.ShortBurn) {
            // short burning: pull in short pool tokens from commiter
            ILeveragedPool(leveragedPool).burnTokens(1, amount, msg.sender);
        }
    }

    function uncommit(uint128 _commitID) external override {
        Commit memory _commit = commits[_commitID];
        require(msg.sender == _commit.owner, "Unauthorized");
        _uncommit(_commit, _commitID);
    }

    function _uncommit(Commit memory _commit, uint128 _commitID) internal {
        // reduce pool commitment amount
        uint256 _commitType = commitTypeToUint(_commit.commitType);
        shadowPools[_commitType] = shadowPools[_commitType] - _commit.amount;
        emit RemoveCommit(_commitID, _commit.amount, _commit.commitType);

        delete commits[_commitID];

        if (earliestCommitUnexecuted == _commitID) {
            // This is the first unexecuted commit, so we can bump this up one
            earliestCommitUnexecuted += 1;
        }
        if (earliestCommitUnexecuted > latestCommitUnexecuted) {
            // We have just bumped earliestCommitUnexecuted above latestCommitUnexecuted,
            // we have therefore run out of commits
            earliestCommitUnexecuted = NO_COMMITS_REMAINING;
        }
        if (latestCommitUnexecuted == _commitID && earliestCommitUnexecuted != NO_COMMITS_REMAINING) {
            // This is the latest commit unexecuted that we are trying to delete.
            latestCommitUnexecuted -= 1;
        }

        // release tokens
        if (_commit.commitType == CommitType.LongMint || _commit.commitType == CommitType.ShortMint) {
            // minting: return quote tokens to the commit owner
            ILeveragedPool(leveragedPool).quoteTokenTransfer(msg.sender, _commit.amount);
        } else if (_commit.commitType == CommitType.LongBurn) {
            // long burning: return long pool tokens to commit owner
            ILeveragedPool(leveragedPool).mintTokens(0, _commit.amount, msg.sender);
        } else if (_commit.commitType == CommitType.ShortBurn) {
            // short burning: return short pool tokens to the commit owner
            ILeveragedPool(leveragedPool).mintTokens(1, _commit.amount, msg.sender);
        }
    }

    function executeAllCommitments() external override onlyPool {
        if (earliestCommitUnexecuted == NO_COMMITS_REMAINING) {
            return;
        }
        uint128 nextEarliestCommitUnexecuted;
        ILeveragedPool pool = ILeveragedPool(leveragedPool);
        uint256 frontRunningInterval = pool.frontRunningInterval();
        uint256 lastPriceTimestamp = pool.lastPriceTimestamp();
        for (uint128 i = earliestCommitUnexecuted; i <= latestCommitUnexecuted; i++) {
            IPoolCommitter.Commit memory _commit = commits[i];
            nextEarliestCommitUnexecuted = i;
            // These two checks are so a given call to executeCommitment won't revert,
            // allowing us to continue iterations, as well as update nextEarliestCommitUnexecuted.
            if (_commit.owner == address(0)) {
                // Commit deleted (uncommitted) or already executed
                nextEarliestCommitUnexecuted += 1; // It makes sense to set the next unexecuted to the next number
                continue;
            }
            if (lastPriceTimestamp - _commit.created <= frontRunningInterval) {
                // This commit is the first that was too late.
                break;
            }
            emit ExecuteCommit(i);
            try IPoolCommitter(address(this)).executeCommitment(_commit) {
                delete commits[i];
            } catch {
                _uncommit(_commit, i);
                emit FailedCommitExecution(i);
            }
            if (i == latestCommitUnexecuted) {
                // We have reached the last one
                earliestCommitUnexecuted = NO_COMMITS_REMAINING;
                return;
            }
        }
        earliestCommitUnexecuted = nextEarliestCommitUnexecuted;
    }

    /**
     * @notice Executes a single commitment.
     * @param _commit The commit to execute
     */
    function executeCommitment(Commit memory _commit) external override onlySelf {
        ILeveragedPool pool = ILeveragedPool(leveragedPool);
        uint112 shortBalance = pool.shortBalance();
        uint112 longBalance = pool.longBalance();
        uint256 _commitType = commitTypeToUint(_commit.commitType);
        shadowPools[_commitType] = shadowPools[_commitType] - _commit.amount;
        if (_commit.commitType == CommitType.LongMint) {
            uint112 mintAmount = PoolSwapLibrary.getMintAmount(
                PoolToken(pool.poolTokens()[0]).totalSupply(), // long token total supply,
                _commit.amount, // amount of quote tokens commited to enter
                longBalance, // total quote tokens in the long pull
                shadowPools[commitTypeToUint(CommitType.LongBurn)] // total pool tokens commited to be burned
            );

            pool.mintTokens(0, mintAmount, _commit.owner);
            // update long and short balances
            pool.setNewPoolBalances(longBalance + _commit.amount, shortBalance);
        } else if (_commit.commitType == CommitType.LongBurn) {
            uint112 amountOut = PoolSwapLibrary.getAmountOut(
                PoolSwapLibrary.getRatio(
                    longBalance,
                    uint112(
                        uint112(PoolToken(pool.poolTokens()[0]).totalSupply()) +
                            shadowPools[commitTypeToUint(CommitType.LongBurn)] +
                            _commit.amount
                    )
                ),
                _commit.amount
            );

            // update long and short balances
            pool.setNewPoolBalances(longBalance - amountOut, shortBalance);
            pool.quoteTokenTransfer(_commit.owner, amountOut);
        } else if (_commit.commitType == CommitType.ShortMint) {
            uint112 mintAmount = PoolSwapLibrary.getMintAmount(
                PoolToken(pool.poolTokens()[1]).totalSupply(), // short token total supply
                _commit.amount,
                shortBalance,
                shadowPools[commitTypeToUint(CommitType.ShortBurn)]
            );

            pool.mintTokens(1, mintAmount, _commit.owner);
            pool.setNewPoolBalances(longBalance, shortBalance + _commit.amount);
        } else if (_commit.commitType == CommitType.ShortBurn) {
            uint112 amountOut = PoolSwapLibrary.getAmountOut(
                PoolSwapLibrary.getRatio(
                    shortBalance,
                    uint112(PoolToken(pool.poolTokens()[1]).totalSupply()) +
                        shadowPools[commitTypeToUint(CommitType.ShortBurn)] +
                        _commit.amount
                ),
                _commit.amount
            );

            // update long and short balances
            pool.setNewPoolBalances(longBalance, shortBalance - amountOut);
            pool.quoteTokenTransfer(_commit.owner, amountOut);
        }
    }

    /**
     * @return A Commit of a given ID
     */
    function getCommit(uint128 _commitID) public view override returns (Commit memory) {
        return commits[_commitID];
    }

    function setQuoteAndPool(address quoteToken, address _leveragedPool) external override onlyFactory {
        require(quoteToken != address(0), "Quote token address cannot be 0 address");
        require(_leveragedPool != address(0), "Leveraged pool address cannot be 0 address");
        leveragedPool = _leveragedPool;
        IERC20 _token = IERC20(quoteToken);
        _token.approve(leveragedPool, _token.totalSupply());
    }

    function commitTypeToUint(CommitType _commit) public pure returns (uint256) {
        if (_commit == CommitType.ShortMint) {
            return 0;
        } else if (_commit == CommitType.ShortBurn) {
            return 1;
        } else if (_commit == CommitType.LongMint) {
            return 2;
        } else if (_commit == CommitType.LongBurn) {
            return 3;
        } else {
            return 0;
        }
    }

    modifier onlyFactory() {
        require(msg.sender == factory, "Commiter: not factory");
        _;
    }

    modifier onlyPool() {
        require(msg.sender == leveragedPool, "msg.sender not leveragedPool");
        _;
    }

    modifier onlySelf() {
        require(msg.sender == address(this), "msg.sender not self");
        _;
    }
}

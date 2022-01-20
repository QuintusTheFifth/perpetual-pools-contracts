//SPDX-License-Identifier: CC-BY-NC-ND-4.0
pragma solidity 0.8.7;

/// @title The contract factory for the keeper and pool contracts. Utilizes minimal clones to keep gas costs low
interface IPoolFactory {
    struct PoolDeployment {
        string poolName; // The name to identify a pool by
        uint32 frontRunningInterval; // The minimum number of seconds that must elapse before a commit can be executed. Must be smaller than or equal to the update interval to prevent deadlock
        uint32 updateInterval; // The minimum number of seconds that must elapse before a price change
        uint16 leverageAmount; // The amount of exposure to price movements for the pool
        address quoteToken; // The digital asset that the pool accepts
        address oracleWrapper; // The IOracleWrapper implementation for fetching price feed data
        address settlementEthOracle; // The oracle to fetch the price of Ether in terms of the settlement token
        address invariantCheckContract; // The IInvariantCheck contract that performs invariant checking
    }

    // #### Events
    /**
     * @notice Creates a notification when a pool is deployed
     * @param pool Address of the new pool
     * @param ticker Ticker of the neew pool
     */
    event DeployPool(address indexed pool, address poolCommitter, string ticker);

    /**
     * @notice Creates a notification when the pool keeper changes
     * @param _poolKeeper Address of the new pool keeper
     */
    event PoolKeeperChanged(address _poolKeeper);

    /**
     * @notice Indicates that the maximum allowed leverage has changed
     * @param leverage New maximum allowed leverage value
     */
    event MaxLeverageChanged(uint256 indexed leverage);

    /**
     * @notice Indicates that the receipient of fees has changed
     * @param receiver Address of the new receipient of fees
     */
    event FeeReceiverChanged(address indexed receiver);

    /**
     * @notice Indicates that the receipient of fees has changed
     * @param fee Address of the new receipient of fees
     */
    event SecondaryFeeSplitChanged(uint256 indexed fee);

    /**
     * @notice Indicates that the trading fee has changed
     * @param fee New trading fee
     */
    event FeeChanged(uint256 indexed fee);

    /**
     * @notice Indicates that the minting and burning fees have changed
     * @param mint Minting fee
     * @param burn Burning fee
     */
    event MintAndBurnFeesChanged(uint256 indexed mint, uint256 indexed burn);

    // #### Getters for Globals
    function pools(uint256 id) external view returns (address);

    function numPools() external view returns (uint256);

    function isValidPool(address _pool) external view returns (bool);

    function isValidPoolCommitter(address _poolCommitter) external view returns (bool);

    // #### Functions
    function deployPool(PoolDeployment calldata deploymentParameters) external returns (address);

    function getOwner() external returns (address);

    function setPoolKeeper(address _poolKeeper) external;

    function setAutoClaim(address _autoClaim) external;

    function setMaxLeverage(uint16 newMaxLeverage) external;

    function setFeeReceiver(address _feeReceiver) external;

    function setFee(uint256 _fee) external;

    function setSecondaryFeeSplitPercent(uint256 newFeePercent) external;

    function setMintAndBurnFee(uint256 _mintingFee, uint256 _burningFee) external;
}

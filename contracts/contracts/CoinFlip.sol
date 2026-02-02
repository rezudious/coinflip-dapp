// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title CoinFlip
 * @notice Peer-to-peer coin flip game on Base using Chainlink VRF v2.5 for provably fair randomness.
 * @dev Player A creates a game with a bet and flat fee; Player B joins and picks heads/tails; VRF resolves the outcome.
 */
contract CoinFlip is VRFConsumerBaseV2Plus {
    // ============ Types ============

    /// @dev Choice: 0 = heads, 1 = tails
    enum Choice {
        Heads,
        Tails
    }

    /// @dev Game lifecycle states
    enum GameStatus {
        Created,  // Waiting for Player B to join
        Pending,  // Player B joined, VRF requested, awaiting result
        Resolved  // VRF returned, winner paid
    }

    /// @dev Single game state
    struct Game {
        address creator;      // Player A
        address joiner;       // Player B (zero until joined)
        uint256 betAmount;    // ETH each player must put in (wei)
        uint256 flatFee;      // Fee taken from creator at creation (wei)
        Choice choice;       // Player B's pick: Heads or Tails
        GameStatus status;   // Current state
    }

    // ============ State ============

    /// @notice Next game ID (incremented when a game is created)
    uint256 public nextGameId;

    /// @notice Maps game ID => game data
    mapping(uint256 => Game) public games;

    /// @notice Maps VRF request ID => game ID (for callback)
    mapping(uint256 => uint256) public requestIdToGameId;

    /// @notice Accumulated flat fees available for owner withdrawal
    uint256 public accumulatedFees;

    // ============ VRF config (Base Sepolia) ============

    uint256 internal s_subscriptionId;
    bytes32 internal s_keyHash;
    uint32 internal constant CALLBACK_GAS_LIMIT = 200_000;
    uint16 internal constant REQUEST_CONFIRMATIONS = 0; // Base Sepolia min is 0
    uint32 internal constant NUM_WORDS = 1;

    // ============ Events ============

    event GameCreated(
        uint256 indexed gameId,
        address indexed creator,
        uint256 betAmount,
        uint256 flatFee
    );

    event GameJoined(
        uint256 indexed gameId,
        address indexed joiner,
        Choice choice
    );

    event RandomnessRequested(uint256 indexed gameId, uint256 requestId);

    event GameResolved(
        uint256 indexed gameId,
        address indexed winner,
        Choice result
    );

    event FeesWithdrawn(address indexed to, uint256 amount);

    // ============ Errors ============

    error InvalidBetAmount();
    error InvalidFlatFee();
    error InvalidValue();
    error GameNotOpen();
    error AlreadyJoined();
    error TransferFailed();
    error NoFeesToWithdraw();

    // ============ Constructor ============

    /**
     * @param _vrfCoordinator Chainlink VRF v2.5 coordinator (Base Sepolia: 0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE)
     * @param _subscriptionId Subscription ID from https://vrf.chain.link (must add this contract as consumer)
     * @param _keyHash Gas lane key hash (Base Sepolia 30 gwei: 0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71)
     */
    constructor(
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        s_subscriptionId = _subscriptionId;
        s_keyHash = _keyHash;
    }

    // ============ External: Create game (Player A) ============

    /**
     * @notice Create a new coin flip game. Caller deposits bet + flat fee in ETH.
     * @param _betAmount Amount each player must bet (wei). Player B must send this when joining.
     * @param _flatFee Fee retained by the contract (wei). Deducted from creator's msg.value; accumulates for owner withdrawal.
     */
    function createGame(uint256 _betAmount, uint256 _flatFee) external payable {
        if (_betAmount == 0) revert InvalidBetAmount();
        if (_flatFee == 0) revert InvalidFlatFee();
        if (msg.value != _betAmount + _flatFee) revert InvalidValue();

        uint256 gameId = nextGameId++;
        games[gameId] = Game({
            creator: msg.sender,
            joiner: address(0),
            betAmount: _betAmount,
            flatFee: _flatFee,
            choice: Choice.Heads, // ignored until join
            status: GameStatus.Created
        });

        emit GameCreated(gameId, msg.sender, _betAmount, _flatFee);
    }

    // ============ External: Join game (Player B) ============

    /**
     * @notice Join an open game by matching the bet and choosing heads or tails.
     * @param _gameId ID of the game from GameCreated.
     * @param _choice 0 = Heads, 1 = Tails.
     */
    function joinGame(uint256 _gameId, Choice _choice) external payable {
        Game storage g = games[_gameId];
        if (g.status != GameStatus.Created) revert GameNotOpen();
        if (g.joiner != address(0)) revert AlreadyJoined();
        if (msg.value != g.betAmount) revert InvalidValue();

        g.joiner = msg.sender;
        g.choice = _choice;
        g.status = GameStatus.Pending;

        emit GameJoined(_gameId, msg.sender, _choice);

        // Request randomness from Chainlink VRF v2.5
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: true})
                )
            })
        );

        requestIdToGameId[requestId] = _gameId;
        emit RandomnessRequested(_gameId, requestId);
    }

    // ============ Internal: VRF callback ============

    /**
     * @notice Called by the VRF coordinator with the random value. Resolves the game and pays the winner.
     * @dev Winner receives the pot (2 * betAmount). The flat fee stays in the contract and accumulates for owner withdrawal.
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        uint256 gameId = requestIdToGameId[requestId];
        Game storage g = games[gameId];
        assert(g.status == GameStatus.Pending);

        // Result: 0 = heads, 1 = tails (one word, so randomWords[0] % 2)
        Choice result = randomWords[0] % 2 == 0 ? Choice.Heads : Choice.Tails;
        address winner = result == g.choice ? g.joiner : g.creator;

        uint256 betAmount = g.betAmount;
        uint256 pot = betAmount * 2; // Winner takes the pot (minus the flat fee = pot is 2*bet, fee stays in contract)
        uint256 fee = g.flatFee;

        g.status = GameStatus.Resolved;
        accumulatedFees += fee;

        (bool ok, ) = winner.call{value: pot}("");
        if (!ok) revert TransferFailed();

        emit GameResolved(gameId, winner, result);
    }

    // ============ External: Owner ============

    /**
     * @notice Withdraw accumulated flat fees to the owner. Uses inherited onlyOwner from VRFConsumerBaseV2Plus.
     */
    function withdrawFees() external onlyOwner {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToWithdraw();

        accumulatedFees = 0;
        address _owner = owner();
        (bool ok, ) = _owner.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit FeesWithdrawn(_owner, amount);
    }

    // ============ View ============

    /**
     * @notice Get full game details for a given ID.
     */
    function getGame(
        uint256 _gameId
    )
        external
        view
        returns (
            address creator,
            address joiner,
            uint256 betAmount,
            uint256 flatFee,
            Choice choice,
            GameStatus status
        )
    {
        Game storage g = games[_gameId];
        return (
            g.creator,
            g.joiner,
            g.betAmount,
            g.flatFee,
            g.choice,
            g.status
        );
    }
}

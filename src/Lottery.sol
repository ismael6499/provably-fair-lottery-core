// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @title Multi-Round VRF Lottery
/// @author Agustin Acosta
/// @notice A multi-round lottery system using Chainlink VRF V2.5 for provably fair winner selection.
/// Each round has a configurable time window, ticket price, and max tickets per player.
/// Three winners are selected per round with a 50/30/20 prize split.
/// @dev Inherits VRFConsumerBaseV2Plus which provides s_vrfCoordinator and ConfirmedOwner (onlyOwner).
contract Lottery is VRFConsumerBaseV2Plus {
    // ─────────────────────────────────────────────
    // Enums
    // ─────────────────────────────────────────────

    /// @notice Lifecycle state of a lottery round
    enum RoundState {
        OPEN, // Accepting ticket purchases
        CALCULATING, // VRF request sent, awaiting callback
        CLOSED // Winners paid (or round refunded)
    }

    // ─────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────

    /// @notice Full data for a single lottery round
    struct Round {
        RoundState state;
        uint256 startTime;
        uint256 endTime;
        uint256 ticketPrice;
        uint256 maxTicketsPerPlayer;
        uint256 minPlayers;
        uint16 protocolFeeBps;
        uint256 prizePool;
        uint256 protocolFeeCollected;
        address[] players; // one entry per ticket (weighted odds)
        address[] uniquePlayers; // deduplicated player addresses
        address[3] winners; // 1st, 2nd, 3rd
        uint256[3] payouts; // prize amounts per tier
        uint256 vrfRequestId;
        bool refunded;
    }

    /// @notice Owner-configurable parameters for future rounds
    struct LotteryConfig {
        uint256 ticketPrice;
        uint256 roundDuration;
        uint256 maxTicketsPerPlayer;
        uint256 minPlayers;
        uint16 protocolFeeBps; // basis points, max 1000 (10%)
    }

    // ─────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────

    error Lottery__RoundNotOpen(uint256 roundId);
    error Lottery__RoundNotCalculating(uint256 roundId);
    error Lottery__RoundStillOpen(uint256 roundId);
    error Lottery__InsufficientPayment(uint256 sent, uint256 required);
    error Lottery__MaxTicketsExceeded(uint256 requested, uint256 max);
    error Lottery__ZeroTickets();
    error Lottery__TransferFailed(address recipient, uint256 amount);
    error Lottery__NotEnoughPlayers(uint256 current, uint256 required);
    error Lottery__InvalidTicketPrice();
    error Lottery__InvalidRoundDuration();
    error Lottery__InvalidMaxTickets();
    error Lottery__InvalidProtocolFee();
    error Lottery__InvalidMinPlayers();
    error Lottery__NoRefundAvailable();
    error Lottery__NothingToWithdraw();
    error Lottery__PreviousRoundNotClosed();

    // ─────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────

    event RoundStarted(uint256 indexed roundId, uint256 startTime, uint256 endTime, uint256 ticketPrice);
    event TicketsPurchased(uint256 indexed roundId, address indexed player, uint256 quantity, uint256 totalPlayerTickets);
    event DrawRequested(uint256 indexed roundId, uint256 indexed vrfRequestId);
    event WinnersSelected(uint256 indexed roundId, address[3] winners, uint256[3] payouts);
    event RoundRefunded(uint256 indexed roundId, uint256 playerCount);
    event RefundClaimed(uint256 indexed roundId, address indexed player, uint256 amount);
    event ProtocolFeeCollected(uint256 indexed roundId, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event ConfigUpdated(uint256 ticketPrice, uint256 roundDuration, uint256 maxTicketsPerPlayer, uint256 minPlayers, uint16 protocolFeeBps);

    // ─────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────

    uint16 private constant MAX_PROTOCOL_FEE_BPS = 1000; // 10%
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 3; // one random word per prize tier
    uint16 private constant FIRST_PLACE_BPS = 5000; // 50%
    uint16 private constant SECOND_PLACE_BPS = 3000; // 30%
    // Third place gets the remainder (~20%) to avoid rounding dust

    // ─────────────────────────────────────────────
    // Immutables (VRF config set at deploy)
    // ─────────────────────────────────────────────

    bytes32 private immutable i_keyHash;
    uint256 private immutable i_subscriptionId;
    uint32 private immutable i_callbackGasLimit;

    // ─────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────

    LotteryConfig private s_config;
    uint256 private s_currentRoundId;
    uint256 private s_accumulatedFees;

    mapping(uint256 roundId => Round) private s_rounds;
    mapping(uint256 vrfRequestId => uint256 roundId) private s_vrfRequestToRound;
    mapping(uint256 roundId => mapping(address player => uint256 tickets)) private s_playerTickets;

    // ─────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────

    /// @param vrfCoordinator Chainlink VRF V2.5 Coordinator address
    /// @param keyHash Gas lane key hash
    /// @param subscriptionId VRF subscription ID (uint256 in V2.5)
    /// @param callbackGasLimit Max gas for the VRF callback
    /// @param ticketPrice Initial ticket price in wei
    /// @param roundDuration Duration of each round in seconds
    /// @param maxTicketsPerPlayer Max tickets one address can buy per round
    /// @param minPlayers Minimum unique players for a valid draw
    /// @param protocolFeeBps Protocol fee in basis points (max 1000 = 10%)
    constructor(
        address vrfCoordinator,
        bytes32 keyHash,
        uint256 subscriptionId,
        uint32 callbackGasLimit,
        uint256 ticketPrice,
        uint256 roundDuration,
        uint256 maxTicketsPerPlayer,
        uint256 minPlayers,
        uint16 protocolFeeBps
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        if (ticketPrice == 0) revert Lottery__InvalidTicketPrice();
        if (roundDuration == 0) revert Lottery__InvalidRoundDuration();
        if (maxTicketsPerPlayer == 0) revert Lottery__InvalidMaxTickets();
        if (minPlayers == 0) revert Lottery__InvalidMinPlayers();
        if (protocolFeeBps > MAX_PROTOCOL_FEE_BPS) revert Lottery__InvalidProtocolFee();

        i_keyHash = keyHash;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;

        s_config = LotteryConfig({
            ticketPrice: ticketPrice,
            roundDuration: roundDuration,
            maxTicketsPerPlayer: maxTicketsPerPlayer,
            minPlayers: minPlayers,
            protocolFeeBps: protocolFeeBps
        });
    }

    // ─────────────────────────────────────────────
    // External — Core
    // ─────────────────────────────────────────────

    /// @notice Start a new lottery round. Snapshots the current config.
    function startNewRound() external onlyOwner {
        // Ensure previous round (if any) is closed before starting a new one
        if (s_currentRoundId > 0) {
            Round storage prev = s_rounds[s_currentRoundId];
            if (prev.state != RoundState.CLOSED) revert Lottery__PreviousRoundNotClosed();
        }

        s_currentRoundId++;
        uint256 roundId = s_currentRoundId;
        LotteryConfig memory cfg = s_config;

        Round storage r = s_rounds[roundId];
        r.state = RoundState.OPEN;
        r.startTime = block.timestamp;
        r.endTime = block.timestamp + cfg.roundDuration;
        r.ticketPrice = cfg.ticketPrice;
        r.maxTicketsPerPlayer = cfg.maxTicketsPerPlayer;
        r.minPlayers = cfg.minPlayers;
        r.protocolFeeBps = cfg.protocolFeeBps;

        emit RoundStarted(roundId, r.startTime, r.endTime, r.ticketPrice);
    }

    /// @notice Buy tickets for the current active round
    /// @param quantity Number of tickets to purchase
    function buyTickets(uint256 quantity) external payable {
        if (quantity == 0) revert Lottery__ZeroTickets();

        uint256 roundId = s_currentRoundId;
        Round storage r = s_rounds[roundId];

        if (r.state != RoundState.OPEN) revert Lottery__RoundNotOpen(roundId);
        if (block.timestamp >= r.endTime) revert Lottery__RoundNotOpen(roundId);

        uint256 totalCost = r.ticketPrice * quantity;
        if (msg.value < totalCost) revert Lottery__InsufficientPayment(msg.value, totalCost);

        uint256 currentTickets = s_playerTickets[roundId][msg.sender];
        if (currentTickets + quantity > r.maxTicketsPerPlayer) {
            revert Lottery__MaxTicketsExceeded(currentTickets + quantity, r.maxTicketsPerPlayer);
        }

        // Effects
        if (currentTickets == 0) {
            r.uniquePlayers.push(msg.sender);
        }
        s_playerTickets[roundId][msg.sender] = currentTickets + quantity;

        for (uint256 i; i < quantity; ++i) {
            r.players.push(msg.sender);
        }
        r.prizePool += totalCost;

        emit TicketsPurchased(roundId, msg.sender, quantity, currentTickets + quantity);

        // Refund excess ETH (Interaction last — CEI)
        uint256 excess = msg.value - totalCost;
        if (excess > 0) {
            (bool ok,) = payable(msg.sender).call{value: excess}("");
            if (!ok) revert Lottery__TransferFailed(msg.sender, excess);
        }
    }

    /// @notice Trigger the draw for a round whose time has expired.
    /// @dev Anyone can call this once the round time is up.
    /// If minimum players not met, the round is marked as refundable instead of requesting VRF.
    /// @param roundId The round to draw
    function requestDraw(uint256 roundId) external {
        Round storage r = s_rounds[roundId];

        if (r.state != RoundState.OPEN) revert Lottery__RoundNotOpen(roundId);
        if (block.timestamp < r.endTime) revert Lottery__RoundStillOpen(roundId);

        // Not enough unique players → refund path
        if (r.uniquePlayers.length < r.minPlayers) {
            r.state = RoundState.CLOSED;
            r.refunded = true;
            emit RoundRefunded(roundId, r.uniquePlayers.length);
            return;
        }

        // Transition to CALCULATING before external call (CEI)
        r.state = RoundState.CALCULATING;

        // Request 3 random words from Chainlink VRF V2.5
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_keyHash,
                subId: i_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: i_callbackGasLimit,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        r.vrfRequestId = requestId;
        s_vrfRequestToRound[requestId] = roundId;

        emit DrawRequested(roundId, requestId);
    }

    /// @notice Claim a refund for a cancelled round (not enough players)
    /// @param roundId The refunded round
    function claimRefund(uint256 roundId) external {
        Round storage r = s_rounds[roundId];

        if (!r.refunded) revert Lottery__NoRefundAvailable();

        uint256 tickets = s_playerTickets[roundId][msg.sender];
        if (tickets == 0) revert Lottery__NoRefundAvailable();

        uint256 refundAmount = tickets * r.ticketPrice;

        // Effects before interaction (CEI)
        s_playerTickets[roundId][msg.sender] = 0;

        (bool ok,) = payable(msg.sender).call{value: refundAmount}("");
        if (!ok) revert Lottery__TransferFailed(msg.sender, refundAmount);

        emit RefundClaimed(roundId, msg.sender, refundAmount);
    }

    // ─────────────────────────────────────────────
    // External — Owner Admin
    // ─────────────────────────────────────────────

    /// @notice Update ticket price for future rounds
    function setTicketPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert Lottery__InvalidTicketPrice();
        s_config.ticketPrice = newPrice;
        _emitConfigUpdated();
    }

    /// @notice Update round duration for future rounds
    function setRoundDuration(uint256 newDuration) external onlyOwner {
        if (newDuration == 0) revert Lottery__InvalidRoundDuration();
        s_config.roundDuration = newDuration;
        _emitConfigUpdated();
    }

    /// @notice Update max tickets per player for future rounds
    function setMaxTicketsPerPlayer(uint256 newMax) external onlyOwner {
        if (newMax == 0) revert Lottery__InvalidMaxTickets();
        s_config.maxTicketsPerPlayer = newMax;
        _emitConfigUpdated();
    }

    /// @notice Update minimum players for future rounds
    function setMinPlayers(uint256 newMin) external onlyOwner {
        if (newMin == 0) revert Lottery__InvalidMinPlayers();
        s_config.minPlayers = newMin;
        _emitConfigUpdated();
    }

    /// @notice Update protocol fee for future rounds
    function setProtocolFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_PROTOCOL_FEE_BPS) revert Lottery__InvalidProtocolFee();
        s_config.protocolFeeBps = newFeeBps;
        _emitConfigUpdated();
    }

    /// @notice Withdraw accumulated protocol fees
    function withdrawFees(address to) external onlyOwner {
        uint256 amount = s_accumulatedFees;
        if (amount == 0) revert Lottery__NothingToWithdraw();

        s_accumulatedFees = 0;

        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert Lottery__TransferFailed(to, amount);

        emit FeesWithdrawn(to, amount);
    }

    // ─────────────────────────────────────────────
    // External — View
    // ─────────────────────────────────────────────

    function getRound(uint256 roundId) external view returns (Round memory) {
        return s_rounds[roundId];
    }

    function getCurrentRoundId() external view returns (uint256) {
        return s_currentRoundId;
    }

    function getConfig() external view returns (LotteryConfig memory) {
        return s_config;
    }

    function getPlayerTickets(uint256 roundId, address player) external view returns (uint256) {
        return s_playerTickets[roundId][player];
    }

    function getAccumulatedFees() external view returns (uint256) {
        return s_accumulatedFees;
    }

    function getRoundPlayers(uint256 roundId) external view returns (address[] memory) {
        return s_rounds[roundId].players;
    }

    function getRoundUniquePlayers(uint256 roundId) external view returns (address[] memory) {
        return s_rounds[roundId].uniquePlayers;
    }

    function getRoundWinners(uint256 roundId) external view returns (address[3] memory) {
        return s_rounds[roundId].winners;
    }

    function getRoundPayouts(uint256 roundId) external view returns (uint256[3] memory) {
        return s_rounds[roundId].payouts;
    }

    // ─────────────────────────────────────────────
    // Internal — VRF Callback
    // ─────────────────────────────────────────────

    /// @dev Called by VRF Coordinator via rawFulfillRandomWords.
    /// Selects 3 unique winners, calculates prizes, and distributes payouts.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 roundId = s_vrfRequestToRound[requestId];
        Round storage r = s_rounds[roundId];

        // Calculate protocol fee from the snapshot bps
        uint256 totalPool = r.prizePool;
        uint256 protocolFee = (totalPool * r.protocolFeeBps) / 10_000;
        uint256 distributablePool = totalPool - protocolFee;

        s_accumulatedFees += protocolFee;
        r.protocolFeeCollected = protocolFee;

        // Determine number of winners (capped at unique player count)
        uint256 numUniquePlayers = r.uniquePlayers.length;
        uint256 numWinners = numUniquePlayers < 3 ? numUniquePlayers : 3;

        // Select unique winners
        address[] memory selected = _selectUniqueWinners(r.players, randomWords, numWinners);

        // Calculate payouts based on number of winners
        uint256[3] memory payouts;

        if (numWinners == 1) {
            payouts[0] = distributablePool;
        } else if (numWinners == 2) {
            payouts[0] = (distributablePool * 6000) / 10_000; // 60%
            payouts[1] = distributablePool - payouts[0]; // 40% (remainder)
        } else {
            payouts[0] = (distributablePool * FIRST_PLACE_BPS) / 10_000; // 50%
            payouts[1] = (distributablePool * SECOND_PLACE_BPS) / 10_000; // 30%
            payouts[2] = distributablePool - payouts[0] - payouts[1]; // 20% (remainder avoids dust)
        }

        // Store winners and payouts (Effects)
        for (uint256 i; i < numWinners; ++i) {
            r.winners[i] = selected[i];
        }
        r.payouts = payouts;
        r.state = RoundState.CLOSED;

        emit ProtocolFeeCollected(roundId, protocolFee);

        // Transfer prizes (Interactions last — CEI)
        for (uint256 i; i < numWinners; ++i) {
            (bool ok,) = payable(r.winners[i]).call{value: payouts[i]}("");
            if (!ok) revert Lottery__TransferFailed(r.winners[i], payouts[i]);
        }

        emit WinnersSelected(roundId, r.winners, r.payouts);
    }

    // ─────────────────────────────────────────────
    // Internal — Helpers
    // ─────────────────────────────────────────────

    /// @dev Select `numWinners` unique winners from the ticket pool.
    /// Each random word is used as a seed. If a collision occurs (same player
    /// already selected), re-hash with an incrementing nonce until a unique player is found.
    /// More tickets = more entries = higher probability of being selected.
    function _selectUniqueWinners(
        address[] storage tickets,
        uint256[] calldata randomWords,
        uint256 numWinners
    ) internal view returns (address[] memory winners) {
        winners = new address[](numWinners);
        uint256 totalTickets = tickets.length;

        for (uint256 i; i < numWinners; ++i) {
            uint256 seed = randomWords[i];
            address selected;
            uint256 attempts;

            // Use a generous attempt limit to handle small pools.
            // With keccak256 re-hashing, collisions resolve quickly.
            uint256 maxAttempts = totalTickets * 10;
            do {
                uint256 index = uint256(keccak256(abi.encode(seed, attempts))) % totalTickets;
                selected = tickets[index];
                ++attempts;
            } while (_isDuplicate(winners, selected, i) && attempts < maxAttempts);

            winners[i] = selected;
        }
    }

    /// @dev Check if `candidate` already appears in `winners` at indices [0, currentIdx).
    function _isDuplicate(address[] memory winners, address candidate, uint256 currentIdx)
        internal
        pure
        returns (bool)
    {
        for (uint256 j; j < currentIdx; ++j) {
            if (winners[j] == candidate) return true;
        }
        return false;
    }

    /// @dev Emit the full config update event.
    function _emitConfigUpdated() private {
        LotteryConfig memory cfg = s_config;
        emit ConfigUpdated(cfg.ticketPrice, cfg.roundDuration, cfg.maxTicketsPerPlayer, cfg.minPlayers, cfg.protocolFeeBps);
    }
}

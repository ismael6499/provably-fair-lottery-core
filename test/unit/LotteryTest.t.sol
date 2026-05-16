// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Lottery} from "../../src/Lottery.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract LotteryTest is Test {
    // ─────────────────────────────────────────────
    // Contracts
    // ─────────────────────────────────────────────

    Lottery public lottery;
    VRFCoordinatorV2_5Mock public vrfCoordinator;

    // ─────────────────────────────────────────────
    // VRF Mock Config
    // ─────────────────────────────────────────────

    uint96 constant MOCK_BASE_FEE = 0.25 ether;
    uint96 constant MOCK_GAS_PRICE = 1e9;
    int256 constant MOCK_WEI_PER_UNIT_LINK = 4e15;

    // ─────────────────────────────────────────────
    // Lottery Config
    // ─────────────────────────────────────────────

    bytes32 constant KEY_HASH = bytes32(uint256(1));
    uint32 constant CALLBACK_GAS_LIMIT = 500_000;
    uint256 constant TICKET_PRICE = 0.01 ether;
    uint256 constant ROUND_DURATION = 1 hours;
    uint256 constant MAX_TICKETS_PER_PLAYER = 10;
    uint256 constant MIN_PLAYERS = 3;
    uint16 constant PROTOCOL_FEE_BPS = 500; // 5%

    // ─────────────────────────────────────────────
    // Actors
    // ─────────────────────────────────────────────

    address OWNER = makeAddr("owner");
    address PLAYER1 = makeAddr("player1");
    address PLAYER2 = makeAddr("player2");
    address PLAYER3 = makeAddr("player3");
    address PLAYER4 = makeAddr("player4");
    address PLAYER5 = makeAddr("player5");

    uint256 subscriptionId;

    // ─────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────

    function setUp() public {
        // 1. Deploy VRF Coordinator Mock
        vrfCoordinator = new VRFCoordinatorV2_5Mock(MOCK_BASE_FEE, MOCK_GAS_PRICE, MOCK_WEI_PER_UNIT_LINK);

        // 2. Create & fund subscription
        subscriptionId = vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(subscriptionId, 1000 ether);

        // 3. Deploy Lottery (owner is msg.sender in VRFConsumerBaseV2Plus → ConfirmedOwner)
        vm.prank(OWNER);
        lottery = new Lottery(
            address(vrfCoordinator),
            KEY_HASH,
            subscriptionId,
            CALLBACK_GAS_LIMIT,
            TICKET_PRICE,
            ROUND_DURATION,
            MAX_TICKETS_PER_PLAYER,
            MIN_PLAYERS,
            PROTOCOL_FEE_BPS
        );

        // 4. Register lottery as VRF consumer
        vrfCoordinator.addConsumer(subscriptionId, address(lottery));

        // 5. Fund player accounts
        vm.deal(PLAYER1, 10 ether);
        vm.deal(PLAYER2, 10 ether);
        vm.deal(PLAYER3, 10 ether);
        vm.deal(PLAYER4, 10 ether);
        vm.deal(PLAYER5, 10 ether);
    }

    // ═════════════════════════════════════════════
    // Category 1: Deployment & Configuration
    // ═════════════════════════════════════════════

    function test_constructorSetsOwner() public view {
        assertEq(lottery.owner(), OWNER);
    }

    function test_constructorSetsConfig() public view {
        Lottery.LotteryConfig memory cfg = lottery.getConfig();
        assertEq(cfg.ticketPrice, TICKET_PRICE);
        assertEq(cfg.roundDuration, ROUND_DURATION);
        assertEq(cfg.maxTicketsPerPlayer, MAX_TICKETS_PER_PLAYER);
        assertEq(cfg.minPlayers, MIN_PLAYERS);
        assertEq(cfg.protocolFeeBps, PROTOCOL_FEE_BPS);
    }

    function test_initialRoundIdIsZero() public view {
        assertEq(lottery.getCurrentRoundId(), 0);
    }

    function test_constructorRevertsOnZeroTicketPrice() public {
        vm.expectRevert(Lottery.Lottery__InvalidTicketPrice.selector);
        new Lottery(address(vrfCoordinator), KEY_HASH, subscriptionId, CALLBACK_GAS_LIMIT, 0, ROUND_DURATION, MAX_TICKETS_PER_PLAYER, MIN_PLAYERS, PROTOCOL_FEE_BPS);
    }

    // ═════════════════════════════════════════════
    // Category 2: Round Management
    // ═════════════════════════════════════════════

    function test_startNewRoundIncrementsRoundId() public {
        vm.prank(OWNER);
        lottery.startNewRound();
        assertEq(lottery.getCurrentRoundId(), 1);
    }

    function test_startNewRoundSetsCorrectState() public {
        vm.prank(OWNER);
        lottery.startNewRound();

        Lottery.Round memory r = lottery.getRound(1);
        assertEq(uint256(r.state), uint256(Lottery.RoundState.OPEN));
        assertEq(r.startTime, block.timestamp);
        assertEq(r.endTime, block.timestamp + ROUND_DURATION);
        assertEq(r.ticketPrice, TICKET_PRICE);
        assertEq(r.maxTicketsPerPlayer, MAX_TICKETS_PER_PLAYER);
        assertEq(r.minPlayers, MIN_PLAYERS);
        assertEq(r.protocolFeeBps, PROTOCOL_FEE_BPS);
    }

    function test_startNewRoundSnapshotsConfig() public {
        // Change config AFTER starting round 1
        vm.startPrank(OWNER);
        lottery.startNewRound();
        lottery.setTicketPrice(0.05 ether);
        vm.stopPrank();

        // Round 1 should have the original ticket price
        Lottery.Round memory r = lottery.getRound(1);
        assertEq(r.ticketPrice, TICKET_PRICE);
    }

    function test_startNewRoundEmitsEvent() public {
        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true);
        emit Lottery.RoundStarted(1, block.timestamp, block.timestamp + ROUND_DURATION, TICKET_PRICE);
        lottery.startNewRound();
    }

    function test_cannotStartRoundWhilePreviousIsOpen() public {
        vm.startPrank(OWNER);
        lottery.startNewRound();

        vm.expectRevert(Lottery.Lottery__PreviousRoundNotClosed.selector);
        lottery.startNewRound();
        vm.stopPrank();
    }

    function test_onlyOwnerCanStartRound() public {
        vm.prank(PLAYER1);
        vm.expectRevert();
        lottery.startNewRound();
    }

    // ═════════════════════════════════════════════
    // Category 3: Ticket Purchasing
    // ═════════════════════════════════════════════

    function test_buyTicketsSingleTicket() public {
        _startRound();

        vm.prank(PLAYER1);
        lottery.buyTickets{value: TICKET_PRICE}(1);

        assertEq(lottery.getPlayerTickets(1, PLAYER1), 1);
    }

    function test_buyTicketsMultipleTickets() public {
        _startRound();

        vm.prank(PLAYER1);
        lottery.buyTickets{value: TICKET_PRICE * 5}(5);

        assertEq(lottery.getPlayerTickets(1, PLAYER1), 5);
    }

    function test_buyTicketsMaxTickets() public {
        _startRound();

        vm.prank(PLAYER1);
        lottery.buyTickets{value: TICKET_PRICE * MAX_TICKETS_PER_PLAYER}(MAX_TICKETS_PER_PLAYER);

        assertEq(lottery.getPlayerTickets(1, PLAYER1), MAX_TICKETS_PER_PLAYER);
    }

    function test_buyTicketsIncrementsPrizePool() public {
        _startRound();

        vm.prank(PLAYER1);
        lottery.buyTickets{value: TICKET_PRICE * 3}(3);

        Lottery.Round memory r = lottery.getRound(1);
        assertEq(r.prizePool, TICKET_PRICE * 3);
    }

    function test_buyTicketsTracksUniquePlayers() public {
        _startRound();

        vm.prank(PLAYER1);
        lottery.buyTickets{value: TICKET_PRICE}(1);

        // Same player buys again — should NOT duplicate in uniquePlayers
        vm.prank(PLAYER1);
        lottery.buyTickets{value: TICKET_PRICE}(1);

        address[] memory unique = lottery.getRoundUniquePlayers(1);
        assertEq(unique.length, 1);
        assertEq(unique[0], PLAYER1);
    }

    function test_buyTicketsWeightedPlayerEntries() public {
        _startRound();

        vm.prank(PLAYER1);
        lottery.buyTickets{value: TICKET_PRICE * 3}(3);

        address[] memory players = lottery.getRoundPlayers(1);
        assertEq(players.length, 3);
        assertEq(players[0], PLAYER1);
        assertEq(players[1], PLAYER1);
        assertEq(players[2], PLAYER1);
    }

    function test_buyTicketsRefundsExcess() public {
        _startRound();

        uint256 balanceBefore = PLAYER1.balance;
        uint256 overpay = 0.005 ether;

        vm.prank(PLAYER1);
        lottery.buyTickets{value: TICKET_PRICE + overpay}(1);

        // Player should get the overpay refunded
        assertEq(PLAYER1.balance, balanceBefore - TICKET_PRICE);
    }

    function test_buyTicketsEmitsEvent() public {
        _startRound();

        vm.prank(PLAYER1);
        vm.expectEmit(true, true, false, true);
        emit Lottery.TicketsPurchased(1, PLAYER1, 2, 2);
        lottery.buyTickets{value: TICKET_PRICE * 2}(2);
    }

    function test_buyTicketsRevertsWhenRoundNotOpen() public {
        // No round started yet (roundId = 0)
        vm.prank(PLAYER1);
        vm.expectRevert(abi.encodeWithSelector(Lottery.Lottery__RoundNotOpen.selector, 0));
        lottery.buyTickets{value: TICKET_PRICE}(1);
    }

    function test_buyTicketsRevertsInsufficientPayment() public {
        _startRound();

        vm.prank(PLAYER1);
        vm.expectRevert(abi.encodeWithSelector(Lottery.Lottery__InsufficientPayment.selector, 0.005 ether, TICKET_PRICE));
        lottery.buyTickets{value: 0.005 ether}(1);
    }

    function test_buyTicketsRevertsMaxTicketsExceeded() public {
        _startRound();

        vm.prank(PLAYER1);
        lottery.buyTickets{value: TICKET_PRICE * MAX_TICKETS_PER_PLAYER}(MAX_TICKETS_PER_PLAYER);

        vm.prank(PLAYER1);
        vm.expectRevert(abi.encodeWithSelector(Lottery.Lottery__MaxTicketsExceeded.selector, MAX_TICKETS_PER_PLAYER + 1, MAX_TICKETS_PER_PLAYER));
        lottery.buyTickets{value: TICKET_PRICE}(1);
    }

    // ═════════════════════════════════════════════
    // Category 4: Draw & VRF Integration
    // ═════════════════════════════════════════════

    function test_requestDrawTransitionsToCalculating() public {
        _startRoundWithPlayers(3);

        lottery.requestDraw(1);

        Lottery.Round memory r = lottery.getRound(1);
        assertEq(uint256(r.state), uint256(Lottery.RoundState.CALCULATING));
    }

    function test_requestDrawEmitsEvent() public {
        _startRoundWithPlayers(3);

        vm.expectEmit(true, false, false, false);
        emit Lottery.DrawRequested(1, 0); // requestId unknown, just check roundId
        lottery.requestDraw(1);
    }

    function test_requestDrawSetsVrfRequestId() public {
        _startRoundWithPlayers(3);
        lottery.requestDraw(1);

        Lottery.Round memory r = lottery.getRound(1);
        assertTrue(r.vrfRequestId > 0);
    }

    function test_requestDrawRevertsIfRoundStillOpen() public {
        _startRound();
        _buyTicketsForPlayer(PLAYER1, 1);

        vm.expectRevert(abi.encodeWithSelector(Lottery.Lottery__RoundStillOpen.selector, 1));
        lottery.requestDraw(1);
    }

    function test_fulfillRandomWordsSelectsThreeWinners() public {
        uint256 requestId = _startRoundAndRequestDraw(3);

        vrfCoordinator.fulfillRandomWords(requestId, address(lottery));

        Lottery.Round memory r = lottery.getRound(1);
        assertEq(uint256(r.state), uint256(Lottery.RoundState.CLOSED));
        assertTrue(r.winners[0] != address(0));
        assertTrue(r.winners[1] != address(0));
        assertTrue(r.winners[2] != address(0));
    }

    function test_fulfillRandomWordsWinnersAreUnique() public {
        uint256 requestId = _startRoundAndRequestDraw(5);

        vrfCoordinator.fulfillRandomWords(requestId, address(lottery));

        Lottery.Round memory r = lottery.getRound(1);
        assertTrue(r.winners[0] != r.winners[1]);
        assertTrue(r.winners[1] != r.winners[2]);
        assertTrue(r.winners[0] != r.winners[2]);
    }

    function test_fulfillRandomWordsPaysPrizes() public {
        uint256 requestId = _startRoundAndRequestDraw(3);

        uint256 totalPool = TICKET_PRICE * 3; // 3 players, 1 ticket each
        uint256 protocolFee = (totalPool * PROTOCOL_FEE_BPS) / 10_000;
        uint256 distributable = totalPool - protocolFee;

        uint256 expectedFirst = (distributable * 5000) / 10_000;
        uint256 expectedSecond = (distributable * 3000) / 10_000;
        uint256 expectedThird = distributable - expectedFirst - expectedSecond;

        // Record balances before fulfillment
        uint256 bal1Before = PLAYER1.balance;
        uint256 bal2Before = PLAYER2.balance;
        uint256 bal3Before = PLAYER3.balance;

        vrfCoordinator.fulfillRandomWords(requestId, address(lottery));

        Lottery.Round memory r = lottery.getRound(1);

        // Check payouts sum to distributable
        assertEq(r.payouts[0] + r.payouts[1] + r.payouts[2], distributable);
        assertEq(r.payouts[0], expectedFirst);
        assertEq(r.payouts[1], expectedSecond);
        assertEq(r.payouts[2], expectedThird);

        // Each winner should have received their payout
        for (uint256 i; i < 3; ++i) {
            address winner = r.winners[i];
            uint256 balBefore;
            if (winner == PLAYER1) balBefore = bal1Before;
            else if (winner == PLAYER2) balBefore = bal2Before;
            else balBefore = bal3Before;

            assertEq(winner.balance, balBefore + r.payouts[i]);
        }
    }

    function test_fulfillRandomWordsCollectsProtocolFee() public {
        uint256 requestId = _startRoundAndRequestDraw(3);

        vrfCoordinator.fulfillRandomWords(requestId, address(lottery));

        uint256 totalPool = TICKET_PRICE * 3;
        uint256 expectedFee = (totalPool * PROTOCOL_FEE_BPS) / 10_000;

        assertEq(lottery.getAccumulatedFees(), expectedFee);

        Lottery.Round memory r = lottery.getRound(1);
        assertEq(r.protocolFeeCollected, expectedFee);
    }

    function test_fulfillRandomWordsWithDeterministicValues() public {
        uint256 requestId = _startRoundAndRequestDraw(5);

        uint256[] memory specificWords = new uint256[](3);
        specificWords[0] = 111;
        specificWords[1] = 222;
        specificWords[2] = 333;

        vrfCoordinator.fulfillRandomWordsWithOverride(requestId, address(lottery), specificWords);

        Lottery.Round memory r = lottery.getRound(1);
        assertEq(uint256(r.state), uint256(Lottery.RoundState.CLOSED));
        assertTrue(r.winners[0] != address(0));
        assertTrue(r.winners[1] != address(0));
        assertTrue(r.winners[2] != address(0));
    }

    // ═════════════════════════════════════════════
    // Category 5: Full Round Lifecycle
    // ═════════════════════════════════════════════

    function test_fullLifecycleThreePlayersOneTicketEach() public {
        vm.prank(OWNER);
        lottery.startNewRound();

        vm.prank(PLAYER1);
        lottery.buyTickets{value: TICKET_PRICE}(1);
        vm.prank(PLAYER2);
        lottery.buyTickets{value: TICKET_PRICE}(1);
        vm.prank(PLAYER3);
        lottery.buyTickets{value: TICKET_PRICE}(1);

        vm.warp(block.timestamp + ROUND_DURATION + 1);

        lottery.requestDraw(1);
        Lottery.Round memory rCalc = lottery.getRound(1);
        assertEq(uint256(rCalc.state), uint256(Lottery.RoundState.CALCULATING));

        vrfCoordinator.fulfillRandomWords(rCalc.vrfRequestId, address(lottery));

        Lottery.Round memory rClosed = lottery.getRound(1);
        assertEq(uint256(rClosed.state), uint256(Lottery.RoundState.CLOSED));
        assertFalse(rClosed.refunded);

        address[3] memory winners = rClosed.winners;
        for (uint256 i; i < 3; ++i) {
            assertTrue(
                winners[i] == PLAYER1 || winners[i] == PLAYER2 || winners[i] == PLAYER3
            );
        }
    }

    function test_fullLifecycleFivePlayersMultipleTickets() public {
        vm.prank(OWNER);
        lottery.startNewRound();

        vm.prank(PLAYER1);
        lottery.buyTickets{value: TICKET_PRICE * 5}(5);
        vm.prank(PLAYER2);
        lottery.buyTickets{value: TICKET_PRICE * 3}(3);
        vm.prank(PLAYER3);
        lottery.buyTickets{value: TICKET_PRICE * 1}(1);
        vm.prank(PLAYER4);
        lottery.buyTickets{value: TICKET_PRICE * 2}(2);
        vm.prank(PLAYER5);
        lottery.buyTickets{value: TICKET_PRICE * 4}(4);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.requestDraw(1);

        Lottery.Round memory r = lottery.getRound(1);
        vrfCoordinator.fulfillRandomWords(r.vrfRequestId, address(lottery));

        r = lottery.getRound(1);
        assertEq(uint256(r.state), uint256(Lottery.RoundState.CLOSED));

        uint256 totalPool = TICKET_PRICE * 15;
        uint256 fee = (totalPool * PROTOCOL_FEE_BPS) / 10_000;
        uint256 distributable = totalPool - fee;
        assertEq(r.payouts[0] + r.payouts[1] + r.payouts[2], distributable);
    }

    // ═════════════════════════════════════════════
    // Category 6: Multiple Rounds
    // ═════════════════════════════════════════════

    function test_canRunMultipleRoundsSequentially() public {
        uint256 reqId1 = _startRoundAndRequestDraw(3);
        vrfCoordinator.fulfillRandomWords(reqId1, address(lottery));
        assertEq(lottery.getCurrentRoundId(), 1);

        vm.prank(OWNER);
        lottery.startNewRound();
        assertEq(lottery.getCurrentRoundId(), 2);

        _buyTicketsForPlayer(PLAYER1, 1);
        _buyTicketsForPlayer(PLAYER2, 1);
        _buyTicketsForPlayer(PLAYER3, 1);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.requestDraw(2);

        Lottery.Round memory r2 = lottery.getRound(2);
        vrfCoordinator.fulfillRandomWords(r2.vrfRequestId, address(lottery));

        r2 = lottery.getRound(2);
        assertEq(uint256(r2.state), uint256(Lottery.RoundState.CLOSED));
    }

    function test_roundsAreIndependent() public {
        uint256 reqId1 = _startRoundAndRequestDraw(3);
        vrfCoordinator.fulfillRandomWords(reqId1, address(lottery));

        Lottery.Round memory r1 = lottery.getRound(1);
        uint256 r1Pool = r1.prizePool;

        vm.prank(OWNER);
        lottery.startNewRound();
        vm.prank(PLAYER1);
        lottery.buyTickets{value: TICKET_PRICE * 5}(5);
        vm.prank(PLAYER2);
        lottery.buyTickets{value: TICKET_PRICE * 5}(5);
        vm.prank(PLAYER3);
        lottery.buyTickets{value: TICKET_PRICE * 5}(5);

        Lottery.Round memory r1After = lottery.getRound(1);
        assertEq(r1After.prizePool, r1Pool);
    }

    function test_feesAccumulateAcrossRounds() public {
        uint256 reqId1 = _startRoundAndRequestDraw(3);
        vrfCoordinator.fulfillRandomWords(reqId1, address(lottery));
        uint256 feesAfterR1 = lottery.getAccumulatedFees();

        vm.prank(OWNER);
        lottery.startNewRound();
        _buyTicketsForPlayer(PLAYER1, 1);
        _buyTicketsForPlayer(PLAYER2, 1);
        _buyTicketsForPlayer(PLAYER3, 1);
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.requestDraw(2);
        Lottery.Round memory r2 = lottery.getRound(2);
        vrfCoordinator.fulfillRandomWords(r2.vrfRequestId, address(lottery));

        assertTrue(lottery.getAccumulatedFees() > feesAfterR1);
    }

    // ═════════════════════════════════════════════
    // Category 7: Refund Mechanism
    // ═════════════════════════════════════════════

    function test_requestDrawRefundsWhenNotEnoughPlayers() public {
        _startRound();
        _buyTicketsForPlayer(PLAYER1, 1);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.requestDraw(1);

        Lottery.Round memory r = lottery.getRound(1);
        assertEq(uint256(r.state), uint256(Lottery.RoundState.CLOSED));
        assertTrue(r.refunded);
    }

    function test_requestDrawRefundsTwoPlayers() public {
        _startRound();
        _buyTicketsForPlayer(PLAYER1, 2);
        _buyTicketsForPlayer(PLAYER2, 3);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.requestDraw(1);

        Lottery.Round memory r = lottery.getRound(1);
        assertTrue(r.refunded);
    }

    function test_requestDrawRefundEmitsEvent() public {
        _startRound();
        _buyTicketsForPlayer(PLAYER1, 1);

        vm.warp(block.timestamp + ROUND_DURATION + 1);

        vm.expectEmit(true, false, false, true);
        emit Lottery.RoundRefunded(1, 1);
        lottery.requestDraw(1);
    }

    function test_claimRefundTransfersCorrectAmount() public {
        _startRound();

        vm.prank(PLAYER1);
        lottery.buyTickets{value: TICKET_PRICE * 3}(3);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.requestDraw(1);

        uint256 balBefore = PLAYER1.balance;
        vm.prank(PLAYER1);
        lottery.claimRefund(1);

        assertEq(PLAYER1.balance, balBefore + TICKET_PRICE * 3);
    }

    function test_claimRefundEmitsEvent() public {
        _startRound();
        _buyTicketsForPlayer(PLAYER1, 2);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.requestDraw(1);

        vm.prank(PLAYER1);
        vm.expectEmit(true, true, false, true);
        emit Lottery.RefundClaimed(1, PLAYER1, TICKET_PRICE * 2);
        lottery.claimRefund(1);
    }

    function test_claimRefundZerosOutTickets() public {
        _startRound();
        _buyTicketsForPlayer(PLAYER1, 2);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.requestDraw(1);

        vm.prank(PLAYER1);
        lottery.claimRefund(1);

        assertEq(lottery.getPlayerTickets(1, PLAYER1), 0);
    }

    function test_cannotDoubleClaimRefund() public {
        _startRound();
        _buyTicketsForPlayer(PLAYER1, 1);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.requestDraw(1);

        vm.prank(PLAYER1);
        lottery.claimRefund(1);

        vm.prank(PLAYER1);
        vm.expectRevert(Lottery.Lottery__NoRefundAvailable.selector);
        lottery.claimRefund(1);
    }

    function test_claimRefundRevertsIfRoundNotRefunded() public {
        uint256 requestId = _startRoundAndRequestDraw(3);
        vrfCoordinator.fulfillRandomWords(requestId, address(lottery));

        vm.prank(PLAYER1);
        vm.expectRevert(Lottery.Lottery__NoRefundAvailable.selector);
        lottery.claimRefund(1);
    }

    function test_claimRefundRevertsIfNoTickets() public {
        _startRound();
        _buyTicketsForPlayer(PLAYER1, 1);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.requestDraw(1);

        vm.prank(PLAYER2);
        vm.expectRevert(Lottery.Lottery__NoRefundAvailable.selector);
        lottery.claimRefund(1);
    }

    // ═════════════════════════════════════════════
    // Category 8: Access Control
    // ═════════════════════════════════════════════

    function test_onlyOwnerCanSetTicketPrice() public {
        vm.prank(PLAYER1);
        vm.expectRevert();
        lottery.setTicketPrice(0.02 ether);
    }

    function test_onlyOwnerCanSetRoundDuration() public {
        vm.prank(PLAYER1);
        vm.expectRevert();
        lottery.setRoundDuration(2 hours);
    }

    function test_onlyOwnerCanSetMaxTickets() public {
        vm.prank(PLAYER1);
        vm.expectRevert();
        lottery.setMaxTicketsPerPlayer(20);
    }

    function test_onlyOwnerCanSetProtocolFee() public {
        vm.prank(PLAYER1);
        vm.expectRevert();
        lottery.setProtocolFee(200);
    }

    function test_onlyOwnerCanSetMinPlayers() public {
        vm.prank(PLAYER1);
        vm.expectRevert();
        lottery.setMinPlayers(5);
    }

    function test_onlyOwnerCanWithdrawFees() public {
        vm.prank(PLAYER1);
        vm.expectRevert();
        lottery.withdrawFees(PLAYER1);
    }

    function test_ownerCanUpdateConfig() public {
        vm.startPrank(OWNER);
        lottery.setTicketPrice(0.05 ether);
        lottery.setRoundDuration(2 hours);
        lottery.setMaxTicketsPerPlayer(20);
        lottery.setMinPlayers(5);
        lottery.setProtocolFee(200);
        vm.stopPrank();

        Lottery.LotteryConfig memory cfg = lottery.getConfig();
        assertEq(cfg.ticketPrice, 0.05 ether);
        assertEq(cfg.roundDuration, 2 hours);
        assertEq(cfg.maxTicketsPerPlayer, 20);
        assertEq(cfg.minPlayers, 5);
        assertEq(cfg.protocolFeeBps, 200);
    }

    function test_setTicketPriceRevertsOnZero() public {
        vm.prank(OWNER);
        vm.expectRevert(Lottery.Lottery__InvalidTicketPrice.selector);
        lottery.setTicketPrice(0);
    }

    function test_setProtocolFeeRevertsOnExcessive() public {
        vm.prank(OWNER);
        vm.expectRevert(Lottery.Lottery__InvalidProtocolFee.selector);
        lottery.setProtocolFee(1001);
    }

    // ═════════════════════════════════════════════
    // Category 9: Protocol Fee Withdrawal
    // ═════════════════════════════════════════════

    function test_withdrawFeesTransfersToRecipient() public {
        uint256 requestId = _startRoundAndRequestDraw(3);
        vrfCoordinator.fulfillRandomWords(requestId, address(lottery));

        uint256 fees = lottery.getAccumulatedFees();
        assertTrue(fees > 0);

        address recipient = makeAddr("feeRecipient");
        uint256 recipientBalBefore = recipient.balance;

        vm.prank(OWNER);
        lottery.withdrawFees(recipient);

        assertEq(recipient.balance, recipientBalBefore + fees);
        assertEq(lottery.getAccumulatedFees(), 0);
    }

    function test_withdrawFeesEmitsEvent() public {
        uint256 requestId = _startRoundAndRequestDraw(3);
        vrfCoordinator.fulfillRandomWords(requestId, address(lottery));

        uint256 fees = lottery.getAccumulatedFees();
        address recipient = makeAddr("feeRecipient");

        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true);
        emit Lottery.FeesWithdrawn(recipient, fees);
        lottery.withdrawFees(recipient);
    }

    function test_withdrawFeesRevertsWhenNothingToWithdraw() public {
        vm.prank(OWNER);
        vm.expectRevert(Lottery.Lottery__NothingToWithdraw.selector);
        lottery.withdrawFees(OWNER);
    }

    function test_zeroProtocolFeeResultsInNoDeduction() public {
        vm.prank(OWNER);
        Lottery zeroFeeLottery = new Lottery(
            address(vrfCoordinator), KEY_HASH, subscriptionId, CALLBACK_GAS_LIMIT,
            TICKET_PRICE, ROUND_DURATION, MAX_TICKETS_PER_PLAYER, MIN_PLAYERS, 0
        );
        vrfCoordinator.addConsumer(subscriptionId, address(zeroFeeLottery));

        vm.prank(OWNER);
        zeroFeeLottery.startNewRound();

        address[] memory players = new address[](3);
        players[0] = PLAYER1;
        players[1] = PLAYER2;
        players[2] = PLAYER3;
        for (uint256 i; i < 3; ++i) {
            vm.prank(players[i]);
            zeroFeeLottery.buyTickets{value: TICKET_PRICE}(1);
        }

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        zeroFeeLottery.requestDraw(1);

        Lottery.Round memory r = zeroFeeLottery.getRound(1);
        vrfCoordinator.fulfillRandomWords(r.vrfRequestId, address(zeroFeeLottery));

        assertEq(zeroFeeLottery.getAccumulatedFees(), 0);

        r = zeroFeeLottery.getRound(1);
        assertEq(r.protocolFeeCollected, 0);
        assertEq(r.payouts[0] + r.payouts[1] + r.payouts[2], TICKET_PRICE * 3);
    }

    // ═════════════════════════════════════════════
    // Category 10: Edge Cases — Player Count
    // ═════════════════════════════════════════════

    function test_onePlayerGetsEntirePool() public {
        vm.prank(OWNER);
        Lottery singleLottery = new Lottery(
            address(vrfCoordinator), KEY_HASH, subscriptionId, CALLBACK_GAS_LIMIT,
            TICKET_PRICE, ROUND_DURATION, MAX_TICKETS_PER_PLAYER, 1, PROTOCOL_FEE_BPS
        );
        vrfCoordinator.addConsumer(subscriptionId, address(singleLottery));

        vm.prank(OWNER);
        singleLottery.startNewRound();

        vm.prank(PLAYER1);
        singleLottery.buyTickets{value: TICKET_PRICE * 3}(3);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        singleLottery.requestDraw(1);

        Lottery.Round memory r = singleLottery.getRound(1);
        uint256 balBefore = PLAYER1.balance;

        vrfCoordinator.fulfillRandomWords(r.vrfRequestId, address(singleLottery));

        r = singleLottery.getRound(1);
        assertEq(r.winners[0], PLAYER1);
        assertEq(r.winners[1], address(0));
        assertEq(r.winners[2], address(0));

        uint256 totalPool = TICKET_PRICE * 3;
        uint256 fee = (totalPool * PROTOCOL_FEE_BPS) / 10_000;
        assertEq(r.payouts[0], totalPool - fee);
        assertEq(r.payouts[1], 0);
        assertEq(r.payouts[2], 0);

        assertEq(PLAYER1.balance, balBefore + r.payouts[0]);
    }

    function test_twoPlayersGet60_40Split() public {
        vm.prank(OWNER);
        Lottery twoPlayerLottery = new Lottery(
            address(vrfCoordinator), KEY_HASH, subscriptionId, CALLBACK_GAS_LIMIT,
            TICKET_PRICE, ROUND_DURATION, MAX_TICKETS_PER_PLAYER, 2, PROTOCOL_FEE_BPS
        );
        vrfCoordinator.addConsumer(subscriptionId, address(twoPlayerLottery));

        vm.prank(OWNER);
        twoPlayerLottery.startNewRound();

        vm.prank(PLAYER1);
        twoPlayerLottery.buyTickets{value: TICKET_PRICE}(1);
        vm.prank(PLAYER2);
        twoPlayerLottery.buyTickets{value: TICKET_PRICE}(1);

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        twoPlayerLottery.requestDraw(1);

        Lottery.Round memory r = twoPlayerLottery.getRound(1);
        vrfCoordinator.fulfillRandomWords(r.vrfRequestId, address(twoPlayerLottery));

        r = twoPlayerLottery.getRound(1);

        uint256 totalPool = TICKET_PRICE * 2;
        uint256 fee = (totalPool * PROTOCOL_FEE_BPS) / 10_000;
        uint256 distributable = totalPool - fee;

        uint256 expectedFirst = (distributable * 6000) / 10_000;
        uint256 expectedSecond = distributable - expectedFirst;

        assertEq(r.payouts[0], expectedFirst);
        assertEq(r.payouts[1], expectedSecond);
        assertEq(r.payouts[2], 0);

        assertTrue(r.winners[0] != r.winners[1]);
        assertEq(r.winners[2], address(0));
    }

    function test_manyPlayersWinnersFromPool() public {
        vm.prank(OWNER);
        lottery.startNewRound();

        for (uint256 i; i < 10; ++i) {
            address player = makeAddr(string(abi.encodePacked("massPlayer", vm.toString(i))));
            vm.deal(player, 1 ether);
            vm.prank(player);
            lottery.buyTickets{value: TICKET_PRICE * 2}(2);
        }

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.requestDraw(1);

        Lottery.Round memory r = lottery.getRound(1);
        vrfCoordinator.fulfillRandomWords(r.vrfRequestId, address(lottery));

        r = lottery.getRound(1);
        assertEq(uint256(r.state), uint256(Lottery.RoundState.CLOSED));

        assertTrue(r.winners[0] != r.winners[1]);
        assertTrue(r.winners[1] != r.winners[2]);
        assertTrue(r.winners[0] != r.winners[2]);
    }

    // ═════════════════════════════════════════════
    // Category 11: Fuzz Tests
    // ═════════════════════════════════════════════

    function testFuzz_buyTicketsAcceptsValidAmounts(uint256 quantity) public {
        quantity = bound(quantity, 1, MAX_TICKETS_PER_PLAYER);
        _startRound();

        uint256 payment = quantity * TICKET_PRICE;
        vm.deal(PLAYER1, payment);

        vm.prank(PLAYER1);
        lottery.buyTickets{value: payment}(quantity);

        assertEq(lottery.getPlayerTickets(1, PLAYER1), quantity);
    }

    function testFuzz_buyTicketsRevertsOnExcessiveQuantity(uint256 quantity) public {
        quantity = bound(quantity, MAX_TICKETS_PER_PLAYER + 1, MAX_TICKETS_PER_PLAYER + 100);
        _startRound();

        uint256 payment = quantity * TICKET_PRICE;
        vm.deal(PLAYER1, payment);

        vm.prank(PLAYER1);
        vm.expectRevert(abi.encodeWithSelector(Lottery.Lottery__MaxTicketsExceeded.selector, quantity, MAX_TICKETS_PER_PLAYER));
        lottery.buyTickets{value: payment}(quantity);
    }

    function testFuzz_protocolFeeNeverExceedsPrizePool(uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 0, 1000));

        vm.prank(OWNER);
        Lottery fuzzLottery = new Lottery(
            address(vrfCoordinator), KEY_HASH, subscriptionId, CALLBACK_GAS_LIMIT,
            TICKET_PRICE, ROUND_DURATION, MAX_TICKETS_PER_PLAYER, 3, feeBps
        );
        vrfCoordinator.addConsumer(subscriptionId, address(fuzzLottery));

        vm.prank(OWNER);
        fuzzLottery.startNewRound();

        address[] memory players = new address[](3);
        for (uint256 i; i < 3; ++i) {
            players[i] = makeAddr(string(abi.encodePacked("fuzzPlayer", vm.toString(i))));
            vm.deal(players[i], 1 ether);
            vm.prank(players[i]);
            fuzzLottery.buyTickets{value: TICKET_PRICE}(1);
        }

        vm.warp(block.timestamp + ROUND_DURATION + 1);
        fuzzLottery.requestDraw(1);

        Lottery.Round memory r = fuzzLottery.getRound(1);
        vrfCoordinator.fulfillRandomWords(r.vrfRequestId, address(fuzzLottery));

        r = fuzzLottery.getRound(1);
        assertTrue(r.protocolFeeCollected <= r.prizePool);
        assertEq(r.payouts[0] + r.payouts[1] + r.payouts[2] + r.protocolFeeCollected, r.prizePool);
    }

    // ═════════════════════════════════════════════
    // Test Helpers
    // ═════════════════════════════════════════════

    function _startRound() internal {
        vm.prank(OWNER);
        lottery.startNewRound();
    }

    function _buyTicketsForPlayer(address player, uint256 quantity) internal {
        vm.prank(player);
        lottery.buyTickets{value: TICKET_PRICE * quantity}(quantity);
    }

    function _startRoundWithPlayers(uint256 numPlayers) internal {
        _startRound();

        address[5] memory allPlayers = [PLAYER1, PLAYER2, PLAYER3, PLAYER4, PLAYER5];
        for (uint256 i; i < numPlayers && i < 5; ++i) {
            _buyTicketsForPlayer(allPlayers[i], 1);
        }

        vm.warp(block.timestamp + ROUND_DURATION + 1);
    }

    function _startRoundAndRequestDraw(uint256 numPlayers) internal returns (uint256 requestId) {
        _startRoundWithPlayers(numPlayers);
        lottery.requestDraw(1);

        Lottery.Round memory r = lottery.getRound(1);
        return r.vrfRequestId;
    }
}
